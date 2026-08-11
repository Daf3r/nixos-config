{ config, lib, pkgs, ... }:

# Prepared-update engine. Design: docs/superpowers/specs/2026-08-09-actualizacion-automatica-design.md
#
# It prepares and reports; it never applies. Two silent failures on this machine
# are the reason: Chromium renaming Brave's VA-API feature names without warning
# (CPU decode at 92 °C, config looking correct), and nixpkgs here being unstable,
# carrying both the NVIDIA driver and niri.
#
# Runs as daf3r, not root: `nixos-rebuild build` only writes to the store, so
# privileges would buy nothing and risk plenty. Note the corollary — DynamicUser
# is deliberately NOT used. `upd apply`, run by the user in a terminal, takes the
# engine's own $STATE_DIR/lock to rule out a run in progress; under DynamicUser
# the state directory belongs to a transient uid the user is not, so every
# `upd apply` would die on an unopenable lock.
let
  # The one user this engine acts for. The unit runs as them, the state
  # directory belongs to them, and `upd` in their terminal shares both.
  user = "daf3r";

  # Read-only source for the engine and the target of `upd apply`. Both sides
  # must name the same repository, so it is written once here.
  repo = "/home/${user}/nixos-config";

  # The branch the engine prepares *from* and the only branch `upd apply` will
  # fast-forward. These two must be the same string, and the whole reason it is
  # bound here is that a divergence is invisible: `upd apply` refuses when the
  # checked-out branch is not $BRANCH, so a $BRANCH that does not match the one
  # the engine prepared from turns that gate into a check of the wrong name —
  # it would happily fast-forward some other branch and leave main behind.
  # $BRANCH stays overridable (it is the test knob the scripts were built
  # around), but its default now comes from a single place for both entry
  # points instead of from two independent literals in two shell files.
  branch = "main";

  # Matches StateDirectory=nixos-upd below, which is what actually creates it.
  stateDir = "/var/lib/nixos-upd";

  # Everything the five entry points shell out to. This list is longer than it
  # looks like it needs to be, and every addition is a failure that already
  # happened or was one run away:
  #
  #   util-linux   flock. Its absence is exit 127 from a `set -e` script, which
  #                reads as "the engine is broken" and cost a full day.
  #   jq           every status.json write is validated with it, so without it
  #                *every* code path lands in the unwritable-status branch and
  #                the blame falls on status.json.
  #   findutils    `find` is not in coreutils. Without it the two stale-worktree
  #                cleanup sweeps fail silently (they end in `|| true`) and
  #                $STATE_DIR grows without bound.
  #   binutils     `strings`, the only tool the VA-API check has. Missing it,
  #                the check aborts and the one regression this engine exists
  #                to catch goes unreported.
  #   bash         the scripts invoke each other by name (`bash bump-*.sh`), so
  #                it must be on PATH and not merely in the shebang.
  #   nh           only `upd apply` needs it, and it is not in systemPackages
  #                anywhere in this config — unwrapped, apply would fast-forward
  #                the repository and then refuse to switch.
  #   nodejs       `npm view`, for the claude-code version report.
  #   nix          taken from config.nix.package so the engine talks to the same
  #                daemon and the same CLI the rest of the system does.
  #
  # Nothing here may be assumed to come from the user profile: `strings`, `npm`
  # and friends live in /etc/profiles/per-user/daf3r/bin, which a systemd unit
  # does not have on its PATH.
  runtimeDeps = [
    pkgs.bash
    pkgs.coreutils
    pkgs.curl
    pkgs.jq
    pkgs.git
    pkgs.gnused
    pkgs.gawk
    pkgs.gnugrep
    pkgs.findutils
    pkgs.binutils
    pkgs.util-linux
    config.nix.package
    pkgs.nixos-rebuild
    pkgs.nh
    pkgs.nodejs
  ];

  # Kept next to runtimeDeps because the install check below resolves each of
  # these against the *generated* wrapper's PATH. Reading the Nix list above
  # proves nothing; running `command -v` under the shipped wrapper's own PATH
  # does.
  runtimeCommands = [
    "bash" "env" "mktemp" "readlink" "timeout" "date" "sort" "head" "tail"
    "curl" "jq" "git" "sed" "awk" "grep" "find" "strings" "flock"
    "nix" "nixos-rebuild" "nh" "npm" "node"
  ];

  entryPoints = [ "nixos-upd" "upd" "bump-brave-origin" "bump-t3code-app" "check-brave-vaapi" ];

  # A git configuration whose entire content is "${repo} may be opened by
  # whoever is reading this". It exists for the apply unit below and for nothing
  # else, which is why it is a directory handed to that one unit through
  # XDG_CONFIG_HOME rather than a line in /etc/gitconfig: the exemption is
  # narrow, it is attached to the one process that needs it, and no other user
  # or service on this machine inherits it.
  #
  # Why it is needed at all, measured on 2026-08-11 rather than assumed:
  #
  #   `nix` resolves a bare path to a git flakeref. `nix flake metadata
  #   ${repo}` reports `git+file://${repo}`, so the apply reads the repository
  #   through nix's git fetcher, not as a plain directory.
  #
  #   That fetcher is libgit2 (nix 2.34.8 links libgit2 1.9.4), and libgit2
  #   refuses to open a repository whose owner is not the calling euid. The
  #   binary imports `git_libgit2_init` and *not* `git_libgit2_opts`, so nix
  #   cannot be turning that validation off.
  #
  #   Reproduced end to end: `nix flake metadata` on a root-owned repository,
  #   run as daf3r, fails with `repository path '...' is not owned by current
  #   user (libgit2 error code = 7)`. The unit is the same mismatch with the
  #   sides swapped -- root reading a repository owned by ${user}.
  #
  #   The reason nobody meets this by hand is `sudo`: libgit2 accepts a
  #   repository owned by $SUDO_UID, so `sudo nh os switch ~/nixos-config`
  #   works. A systemd unit has no SUDO_UID, so it does not.
  #
  # And the shape of the fix was measured too, because the obvious one is
  # wrong: `GIT_CONFIG_GLOBAL` pointing at the same file changes nothing, since
  # that variable is git(1)'s and libgit2 does not read it. `HOME` and
  # `XDG_CONFIG_HOME` both work; XDG_CONFIG_HOME is the one used here because
  # moving root's HOME into the store would also move its cache and state
  # directories into a read-only path.
  applyGitConfig = pkgs.writeTextFile {
    name = "nixos-upd-apply-gitconfig";
    destination = "/git/config";
    text = ''
      [safe]
      directory = ${repo}
    '';
  };

  # The root half of an apply. It does one thing: activate. The git
  # fast-forward has already happened, as ${user}, via `upd apply --ff-only` --
  # if root did the merge, .git would end up with root-owned objects and the
  # user's next commit would fail.
  #
  # A unit rather than a child of the shell, so a `dms restart` in the middle of
  # a twenty-minute switch does not orphan it and its result stays queryable
  # afterwards. Instance name is the nh verb, and nothing else is accepted.
  #
  # The mode is checked here rather than trusted, because the polkit rules
  # below are not the only way in: root can start any instance of a template,
  # and `%i` is whatever was typed. Defaulted with `:-` so an empty instance
  # gets this script's own sentence rather than bash's `unbound variable`, and
  # printed with `%q` so that sentence *names* the empty string instead of
  # trailing off -- `upd apply ""` taught that lesson in Task 6, where an empty
  # mode sailed through as `switch`.
  #
  # No TimeoutStartSec. Checked rather than assumed, because a twenty-minute
  # activation under the manager's 90-second default would be killed halfway:
  # `Type=oneshot` disables the start timeout, and every oneshot on this machine
  # that does not set one reports `TimeoutStartUSec=infinity`.
  applyScript = pkgs.writeShellScript "nixos-upd-apply" ''
    set -euo pipefail
    mode="''${1:-}"
    case "$mode" in
      switch|boot) ;;
      *) printf 'nixos-upd-apply: unknown mode %q\n' "$mode" >&2; exit 1 ;;
    esac
    exec ${pkgs.nh}/bin/nh os "$mode" ${lib.escapeShellArg repo}
  '';

  nixos-upd = pkgs.stdenvNoCC.mkDerivation {
    pname = "nixos-upd";
    version = "1";
    src = ./updates;
    nativeBuildInputs = [
      pkgs.makeWrapper
      # For checkPhase below. bats and shellcheck are the check itself; the
      # rest is what the suites shell out to and what stdenv does not already
      # provide. Each one was a real failure in the sandbox before it was added:
      # without binutils the three check-vaapi tests exit 127 on `strings`, and
      # without util-linux upd.sh's apply preflight refuses on a missing
      # `flock`. That is the same class of gap the installCheck below exists to
      # catch at runtime, arriving here at test time instead.
      pkgs.bats
      pkgs.shellcheck
      pkgs.git
      pkgs.jq
      pkgs.binutils
      pkgs.util-linux
    ];

    # The suite was written alongside these scripts and then never run by
    # anything but a human typing `bats updates/tests/`. A test suite that only
    # runs when someone remembers is not a guarantee, it is a habit -- and the
    # habit is what fails on the day the change is small enough to feel safe.
    # Wiring it in here means the module cannot be built, let alone switched to,
    # with a red suite.
    #
    # Hermetic on purpose: nothing below reaches the network or the running
    # system. The suites use fixtures for the two upstream feeds, stub `nh`, and
    # build their git repositories from scratch under $TMPDIR.
    doCheck = true;
    checkPhase = ''
      runHook preCheck

      # git refuses to do anything useful without somewhere to look for a
      # config, and stdenv's /homeless-shelter is not writable.
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"

      # check-vaapi.bats deliberately reaches out of this src to
      # ../../pkgs/brave-origin.nix: its job is to prove that the feature-name
      # list hardcoded in check-brave-vaapi.sh still matches the derivation,
      # which is a cross-file invariant and is worthless if the test is allowed
      # to check the list against itself. src is ./updates, so the file has to
      # be placed where the test looks for it. This also makes the derivation
      # depend on brave-origin.nix, which is correct: editing the feature list
      # there must rebuild and re-check this.
      mkdir -p ../pkgs
      cp ${./pkgs/brave-origin.nix} ../pkgs/brave-origin.nix

      # --print-output-on-failure because the only person who will ever read
      # this is someone staring at a nix build log with no way to re-run the
      # test interactively; bare bats prints the failing assertion and not the
      # output that explains it.
      bats --print-output-on-failure tests/

      # shellcheck from inside this directory, not from the flake root: the
      # `# shellcheck source=lib/....sh` directives in the entry points are
      # resolved relative to the working directory, and from anywhere else they
      # silently degrade to SC1091 "not following" -- so -x would look like it
      # was following the libraries while checking nothing.
      shellcheck -x -- *.sh lib/*.sh

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/libexec/nixos-upd $out/bin
      cp -r ./lib $out/libexec/nixos-upd/lib
      cp ./*.sh $out/libexec/nixos-upd/
      # The bats suites already ran, in checkPhase above; they are a build-time
      # gate, not something the system needs at runtime. `cp ./*.sh` does not
      # pick the directory up in the first place, so this is a guard against a
      # future `cp -r .` rather than a removal of anything currently copied.
      rm -rf $out/libexec/nixos-upd/tests

      # `#!/usr/bin/env bash` resolves through PATH at exec time. The wrapper
      # sets a PATH that contains bash, so it would work — but only from the
      # wrapper. Rewriting the shebangs makes the scripts runnable directly
      # from the store too, which is how they are debugged.
      patchShebangs $out/libexec/nixos-upd

      for s in ${lib.concatStringsSep " " entryPoints}; do
        chmod +x $out/libexec/nixos-upd/$s.sh
        makeWrapper $out/libexec/nixos-upd/$s.sh $out/bin/$s \
          --set LIB_DIR $out/libexec/nixos-upd/lib \
          --set-default REPO ${lib.escapeShellArg repo} \
          --set-default BRANCH ${lib.escapeShellArg branch} \
          --set-default STATE_DIR ${lib.escapeShellArg stateDir} \
          --prefix PATH : $out/bin \
          --prefix PATH : ${lib.makeBinPath runtimeDeps}
      done

      runHook postInstall
    '';

    # A missing binary here is not a build error, it is a runtime one, and the
    # shape it takes at runtime is either exit 127 out of a `set -e` script or a
    # swallowed `|| true`. So it is turned into a build error: for every wrapper
    # that ships, take that wrapper's *own* PATH lines and resolve every command
    # the scripts call under them, starting from an empty environment.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      for w in ${lib.concatStringsSep " " (map (e: "$out/bin/${e}") entryPoints)}; do
        pathlines=$(grep -E '^(export )?PATH=' "$w") \
          || { echo "install check: $w sets no PATH at all"; exit 1; }
        for c in ${lib.concatStringsSep " " runtimeCommands}; do
          env -i "PATHLINES=$pathlines" "CMD=$c" "W=$w" ${pkgs.bash}/bin/bash -c '
            PATH=
            eval "$PATHLINES"
            command -v "$CMD" >/dev/null 2>&1 \
              || { echo "install check: $CMD is not on the PATH of $W"; exit 1; }
          ' || exit 1
        done
      done
      echo "install check: all ${toString (builtins.length runtimeCommands)} commands resolve on all ${toString (builtins.length entryPoints)} wrappers"

      runHook postInstallCheck
    '';

    meta = {
      description = "Prepared-update engine: prepares a system update nightly and never applies it";
      platforms = lib.platforms.linux;
    };
  };
in
{
  environment.systemPackages = [ nixos-upd ];

  # StateDirectory below creates this on the unit's first start, but `upd check`
  # runs the engine in the foreground as the user, without systemd, and it may
  # well be the first thing that ever runs. As daf3r it cannot mkdir inside
  # /var/lib, so without this the very first `upd check` fails on an
  # unwritable state directory.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0755 ${user} users -"
  ];

  systemd.services.nixos-upd = {
    description = "Prepare a system update without applying it";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Skip on battery. A full system build is not what a laptop on its own
    # power should be doing unattended.
    #
    # This is a *unit* condition, not a service setting: systemd parses
    # Condition*= in [Unit] only, and a ConditionACPower placed under
    # serviceConfig lands in [Service], where it is an unknown key — the unit
    # still loads, the condition is silently never evaluated, and the nightly
    # build runs on battery exactly as if the line had never been written.
    unitConfig.ConditionACPower = true;

    # The engine reads $BRANCH and $REPO from the environment; the wrappers
    # already default them to the same values. Stating them here as well keeps
    # `systemctl cat nixos-upd.service` self-describing and makes the pairing
    # with `upd` checkable without unwrapping a store path — both sides come
    # from the single binding at the top of this file.
    environment = {
      REPO = repo;
      BRANCH = branch;
      STATE_DIR = stateDir;
    };

    serviceConfig = {
      Type = "oneshot";
      User = user;
      # Creates and owns /var/lib/nixos-upd. Deliberately paired with a real
      # User= and never with DynamicUser: the user's own `upd apply` has to be
      # able to open the lock file in here.
      StateDirectory = "nixos-upd";
      WorkingDirectory = stateDir;
      ExecStart = "${nixos-upd}/bin/nixos-upd";
      # A full evaluation plus build of the system closure. Unstable nixpkgs
      # here means a kernel, the NVIDIA driver or Electron can land in one
      # night, and a timeout kills the run just as it is doing the work that
      # matters most to see.
      TimeoutStartSec = "3h";
    };
  };

  # The activation half of an apply, as its own unit. The repository half --
  # the fast-forward -- is `upd apply --ff-only`, run as ${user} before this is
  # started, and the split exists so each half runs as whoever it has to be.
  #
  # Whoever starts this has to look at the result. `systemctl start` on a
  # oneshot blocks until it finishes and exits non-zero when it failed
  # (measured: exit 1, `Job for ... failed because the control process exited
  # with error code`), so a person at a terminal is told. `systemctl start
  # --no-block` returns 0 immediately and tells nobody anything, and polling
  # ActiveState/Result afterwards does not recover it: a unit that has never
  # run and a unit that finished successfully both report
  # `inactive`/`success`, so only the failure is legible and only if the poll
  # happens to land after the job started. Measured with a throwaway user unit
  # -- see the Task 7 report. The bar plugin therefore starts this *blocking*,
  # off the UI thread, and reports the exit status; the spec's earlier
  # `--no-block` was corrected in the same commit as this unit.
  systemd.services."nixos-upd-apply@" = {
    description = "Apply the prepared system update (%i)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${applyScript} %i";
      Environment = [
        # nh shells out to nix, which needs these on a system unit's minimal PATH.
        "PATH=/run/current-system/sw/bin:/run/wrappers/bin"
        # The safe.directory exemption, and the only reason this unit needs any
        # git configuration at all. Without it the activation dies before it
        # starts, with libgit2 refusing to open a repository root does not own.
        # See applyGitConfig above for the measurements.
        "XDG_CONFIG_HOME=${applyGitConfig}"
      ];
    };
  };

  # Two levels on purpose.
  #
  # The check only builds -- it can never change the running system -- so
  # demanding a password for it is friction with nothing bought. The apply gets
  # auth_admin every time, and deliberately NOT auth_admin_keep: a five-minute
  # grace period on the one action that changes the system is exactly what we do
  # not want.
  #
  # `return undefined` rather than a bare fallthrough on every path that is not
  # ours, so this rule never becomes the answer for an action it was not written
  # about -- gaming.nix registers a rule too, and polkit stops at the first one
  # that returns a value.
  #
  # A polkit rule can be syntactically fine and silently authorise nothing --
  # that already happened on this machine with gamemode. The acceptance test is
  # starting the unit and seeing the prompt, not reading this block.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id != "org.freedesktop.systemd1.manage-units") return undefined;
      if (subject.user != "${user}") return undefined;
      var unit = action.lookup("unit");
      if (unit == "nixos-upd.service") return polkit.Result.YES;
      if (unit == "nixos-upd-apply@switch.service" ||
          unit == "nixos-upd-apply@boot.service") return polkit.Result.AUTH_ADMIN;
      return undefined;
    });
  '';

  systemd.timers.nixos-upd = {
    description = "Daily prepared-update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      # The laptop is not on at a fixed hour, and nothing here is urgent.
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
}
