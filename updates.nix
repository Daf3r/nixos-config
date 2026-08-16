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
  #   And `--elevation-strategy none`, which the script below now passes, takes
  #   that accidental cover away for good: nh no longer shells out through sudo
  #   at all, it runs nix directly as whoever it already is. Re-measured through
  #   nh itself, as euid 0, against a repository owned by somebody else --
  #   without this config `nh os boot --elevation-strategy none` dies with `is
  #   not owned by current user`; with it, it gets past the fetch. So this is
  #   not leftover from the first attempt, it is load-bearing for the fixed one.
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

  # The root half of an apply. It activates and, only after that succeeds,
  # finalises the prepared status. The git fast-forward has already happened,
  # as ${user}, via `upd apply --ff-only` -- if root did the merge, .git would
  # end up with root-owned objects and the user's next commit would fail.
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
  #
  # `--elevation-strategy none` is not optional and it is not a style choice.
  # Without it this unit dies in under a second, and it did, on the machine:
  #
  #   nixos-upd-apply[1395582]: 0: Don't run nh os as root. It will escalate
  #                                its privileges internally as needed.
  #   nixos-upd-apply@boot.service: Main process exited, code=exited, status=1
  #
  # nh refuses to be root on purpose, because it expects to be started by a user
  # and to elevate itself. Here it is already root and there is nothing to
  # elevate, which is exactly what `none` says. `--bypass-root-check` also gets
  # past the refusal -- measured, with a `! Bypassing root check; running nix as
  # root` warning -- but it leaves the strategy at `auto`, so nh would go on
  # hunting for doas/sudo/run0/pkexec while already root and without a TTY. One
  # of the two options describes the situation and the other only silences the
  # complaint about it.
  #
  # This body is what `applyCommand` below runs against the real nh, as euid 0,
  # at build time. Editing the nh line here without reading that check first is
  # how the same twelve-hour round happens twice.
  applyScript = pkgs.writeShellScript "nixos-upd-apply-body" ''
    set -euo pipefail
    mode="''${1:-}"
    case "$mode" in
      switch|boot) ;;
      *) printf 'nixos-upd-apply: unknown mode %q\n' "$mode" >&2; exit 1 ;;
    esac
    # The safe.directory exemption travels with the command that needs it rather
    # than sitting in the unit's Environment=, where it started. Two reasons, and
    # the second is the one that moved it: it is the only thing standing between
    # this command and `is not owned by current user`, so it belongs next to the
    # command; and in the unit it was a second place to delete it from, invisible
    # to the build-time check below. Measured -- with it in the unit, dropping it
    # left the whole system building green.
    export XDG_CONFIG_HOME=${applyGitConfig}
    exec ${pkgs.nh}/bin/nh os "$mode" --elevation-strategy none ${lib.escapeShellArg repo}
  '';

  # What the unit actually executes -- and it is `applyScript` byte for byte,
  # installed by a derivation that first runs it against the real nh binary and
  # refuses to produce anything if nh turns it down. Making the checked copy the
  # thing ExecStart points at is the whole mechanism: there is no way to get the
  # script into the system without the check having passed, which is the same
  # bargain the bats suite already gets from `doCheck` above.
  #
  # It exists because the root refusal above shipped. Nothing in the suite could
  # have caught it: bats stubs `nh`, and a stub accepts whatever it is handed --
  # the one thing that knows nh rejects this command line is nh. So the check
  # runs the real binary. What it does *not* need is root, a daemon, or an
  # activation:
  #
  #   `unshare -Ur` gives a process euid 0 inside a user namespace, which is all
  #   nh's check looks at (`Uid::effective().is_root()`), and unprivileged user
  #   namespaces nest inside the nix build sandbox -- verified, not assumed.
  #
  #   The repository path in the script does not exist inside the sandbox, so
  #   the run dies at flake resolution. That is *after* the root check, which is
  #   what makes the two outcomes tell different stories.
  #
  # nh probes `nix --version` and `nix config show experimental-features` before
  # it ever looks at the uid, hence nix on the PATH and NIX_CONFIG below. That is
  # also this check's main fragility: an nh that grows a new pre-flight probe
  # would fail here for a reason that has nothing to do with the invocation. It
  # fails *loudly* and the control below says which of the two happened, which is
  # the trade this file keeps making -- a build that stops with an explanation
  # beats a check that quietly stops checking.
  applyCommand = pkgs.runCommand "nixos-upd-apply"
    {
      nativeBuildInputs = [ pkgs.util-linux pkgs.nh pkgs.git config.nix.package ];
      # nh shells out to nix for both pre-flight probes, and the sandbox has no
      # nix.conf, so without this it dies before reaching anything we care about.
      NIX_CONFIG = "experimental-features = nix-command flakes";
    }
    ''
      bail="Don't run nh os as root"

      # A precondition, not a formality. If the real repository were visible
      # from in here, running the real apply command below would not stop at a
      # missing flake -- it would start building the system inside a build.
      if [ -e ${lib.escapeShellArg repo} ]; then
        echo "check: ${repo} is visible from inside this build."
        echo "check: running the apply command here could start a real build."
        echo "check: refusing rather than finding out. Is the sandbox off?"
        exit 1
      fi

      # --- the control ------------------------------------------------------
      # A plain unflagged `nh os`, run the same way, must still be refused. If
      # it is not, nothing below proves anything: either the namespace stopped
      # handing out euid 0, or nh stopped refusing root, or it died on some new
      # pre-flight probe before it got that far. Any of the three and this check
      # has to be looked at rather than trusted -- so it says so and stops.
      #
      # Deliberately *not* derived from the script by deleting the flag from it,
      # which was the first version. That control disappears exactly when the
      # flag does, so reverting the fix failed here, with a message about the
      # control being misplaced -- a guard blaming the wrong thing, which is the
      # same defect this task spent its morning removing from `upd apply`.
      unshare -Ur nh os boot --dry /nonexistent-flake-xyz > control.log 2>&1 || true
      if ! grep -qF "$bail" control.log; then
        echo "check: an unflagged \`nh os\` run as root was NOT refused, so this"
        echo "check: check can no longer tell a good command line from a bad one."
        echo "--- what the control printed ---"
        cat control.log
        exit 1
      fi

      # --- a copy of the script that records nh's arguments ------------------
      # Running the real script proves nh accepts the command line; it does not
      # prove *which* command line, because nh dies at flake resolution long
      # before the verb matters and prints the same complaint either way.
      # Measured: hardcoding `nh os boot` and never propagating $mode left the
      # build green with this check announcing it had run both modes -- which in
      # production is `nixos-upd-apply@switch` activating a `boot`, or a `boot`
      # activating in place.
      #
      # So the argument vector is read rather than inferred: the same script
      # with nh's store path swapped for a recorder. That is a derived copy, and
      # deriving a copy is what went wrong with the first control in this file,
      # so the two differences are worth stating -- the substitution is asserted
      # to have landed, and it removes nothing that is under test. The
      # unmodified script is still what the loop below runs against the real nh.
      nh_path="$(sed -n 's/^exec \([^ ]*\) .*/\1/p' ${applyScript})"
      if [ -z "$nh_path" ]; then
        echo "check: cannot find the nh invocation in the apply command, so its"
        echo "check: arguments cannot be read. Has the script's shape changed?"
        cat ${applyScript}
        exit 1
      fi
      mkdir -p rec
      cat > rec/nh <<'RECORDER'
#!/bin/sh
printf 'ARGV:'
for a in "$@"; do printf ' [%s]' "$a"; done
echo
RECORDER
      chmod +x rec/nh
      sed "s|^exec $nh_path |exec $PWD/rec/nh |" ${applyScript} > recorded
      if cmp -s recorded ${applyScript}; then
        echo "check: swapping nh for the recorder changed nothing, so the"
        echo "check: argument assertions below would be reading the real nh."
        exit 1
      fi
      chmod +x recorded

      # --- the thing being checked ------------------------------------------
      # Both instances the polkit rules name, not just one. `switch` and `boot`
      # are separate arms of the script's `case`, so checking only `boot` left
      # `switch` free to be broken -- and the mirror of that was measured: with
      # only `boot` checked, deleting `boot` from the `case` shipped a broken
      # @boot unit with the build green.
      for mode in switch boot; do
        # The script prints its own euid first, so the log carries the proof
        # that it ran as root. Without it, deleting the `unshare` from this line
        # would leave the run as an ordinary user, nh would have nothing to
        # complain about, and the check would pass while testing nothing.
        unshare -Ur sh -c 'echo "euid=$(id -u)"; exec '${applyScript}' "$1"' _ "$mode" \
          > real.log 2>&1 || true
        if ! grep -qx "euid=0" real.log; then
          echo "check: the $mode run was not root, so nh was never going to"
          echo "check: refuse it and this proves nothing."
          cat real.log
          exit 1
        fi

        # The named failures come first, and the order is load-bearing rather
        # than tidy. Reverting the flag makes nh bail at the root check, so it
        # never reaches the flake and the catch-all below would fire on it --
        # a red build carrying the wrong diagnosis, which is the defect this
        # branch keeps finding in its own guards. Measured that way round
        # before it was reordered.
        if grep -qF "$bail" real.log; then
          echo "check: nh refuses the $mode command line as root."
          echo "check: this is the failure of 2026-08-11, back again -- the unit"
          echo "check: died in 48 ms and the switch never happened."
          echo "--- what it printed ---"
          cat real.log
          exit 1
        fi

        # `--bypass-root-check` also gets past the refusal, so the assertion
        # above cannot tell the two apart -- measured, it stayed green when the
        # flag was swapped. What does tell them apart is that nh announces the
        # second one, and the announcement is the thing worth refusing: it means
        # the strategy is still `auto` and nh will go looking for
        # doas/sudo/run0/pkexec while already root and without a TTY.
        if grep -qF "Bypassing root check" real.log; then
          echo "check: the $mode command line silences nh's root refusal instead"
          echo "check: of telling nh there is nothing to elevate. Use"
          echo "check: --elevation-strategy none, not --bypass-root-check."
          cat real.log
          exit 1
        fi

        # And last, the positive one, which is what stops the three above from
        # being satisfied by a log nh never wrote. Every one of them is a
        # negative -- "the log does not say X" -- and an empty log passes them
        # all. Measured, before this existed: pointing the script at a
        # non-existent nh binary, and deleting `boot` from the script's own
        # `case`, both left the build green with this check announcing that nh
        # accepted the command line. It had not run.
        #
        # The anchor is nh's own complaint about the flake path, which proves
        # four things at once: nh ran, it got past the root check, it reached
        # installable resolution, and it was handed *this* repository rather
        # than one out of NH_FLAKE or a mangled argument. A bare "Flake
        # reference" proves the first three; carrying the path costs nothing and
        # covers the fourth.
        #
        # It depends on ${repo} not existing inside the sandbox, which is the
        # same precondition asserted at the top, for the same reason.
        if ! grep -qF "Flake reference" real.log \
           || ! grep -qF ${lib.escapeShellArg repo} real.log; then
          echo "check: the $mode run never reached nh's flake resolution, so"
          echo "check: nothing above it was actually exercised. nh may not have"
          echo "check: run at all, or may have been handed another flake."
          echo "--- what it printed ---"
          cat real.log
          exit 1
        fi

        # And what nh was actually handed. Last on purpose, like the anchor
        # above it: the runtime failures are the more specific diagnosis, and a
        # red build carrying the wrong reason has already cost this branch a
        # round. One equality covers the verb, the mode reaching it, the flag
        # spelled the way nh understands it, and the repository.
        got="$(./recorded "$mode")"
        want="ARGV: [os] [$mode] [--elevation-strategy] [none] [${repo}]"
        if [ "$got" != "$want" ]; then
          echo "check: the $mode instance would not hand nh the $mode verb."
          echo "check:   esperado: $want"
          echo "check:   recibido: $got"
          exit 1
        fi
      done

      # --- and that the mode guard still refuses ------------------------------
      # The negative half of the same guard, which the loop above cannot reach
      # because it only ever passes valid modes. Measured: deleting the `*)` arm
      # left the build green, and root can start any instance of a template, so
      # polkit is not what keeps this closed -- the script is.
      #
      # The empty string is in the list because it is the mode nobody types on
      # purpose: it is what an unset variable expands to, and in Task 6 an empty
      # mode sailed through `upd apply` as `switch`.
      # `bad_out`, not `out`: stdenv's $out is the output path, and shadowing it
      # here made `install` at the bottom fail with an empty target. Found by the
      # build, which is the argument for the check being in the build.
      for bad in --frobnicate switchh boot-ish ""; do
        bad_out="$(./recorded "$bad" 2>&1)" && bad_rc=0 || bad_rc=$?

        # Reaching nh first, because it is the specific and dangerous outcome:
        # the guard is gone and an arbitrary word is on its way to becoming an
        # nh subcommand. Measured -- with the exit status tested first, deleting
        # the `*)` arm reported "the apply command accepted the mode", which is
        # true but is the consequence, not the fault.
        case "$bad_out" in
          *ARGV:*)
            echo "check: the mode '$bad' reached nh instead of being refused."
            echo "check:   $bad_out"
            exit 1 ;;
        esac
        if [ "$bad_rc" -eq 0 ]; then
          echo "check: the apply command accepted the mode '$bad' and exited 0."
          exit 1
        fi
        case "$bad_out" in
          *"unknown mode"*) ;;
          *)
            echo "check: the mode '$bad' was refused without saying so, which is"
            echo "check: the difference between a guard and an accident."
            echo "check:   $bad_out"
            exit 1 ;;
        esac
      done

      # --- and that the git config is found where the command points at it ---
      # Narrower than it looks, and the wording matters: this proves the file is
      # where the apply command says and carries the right path, not that
      # libgit2 honours it. That half was measured by hand (see applyGitConfig)
      # and its live proof is the first real apply, because a repository owned
      # by somebody else is exactly what a build sandbox does not have.
      #
      # The path is read *out of the script* rather than interpolated again from
      # Nix, and that is what gives the assertion teeth: an export that goes
      # missing, or one that points somewhere else, both land here. Measured --
      # with the two sides interpolated independently, deleting the export from
      # the script left the whole system building green.
      xdg="$(sed -n 's/^export XDG_CONFIG_HOME=//p' ${applyScript})"
      if [ -z "$xdg" ]; then
        echo "check: the apply command sets no XDG_CONFIG_HOME, so nothing tells"
        echo "check: libgit2 that ${repo} may be opened by a uid that does not"
        echo "check: own it. As root, that is where the apply stops."
        exit 1
      fi
      mkdir -p nohome
      got="$(XDG_CONFIG_HOME=$xdg HOME=$PWD/nohome \
             git config --get-all safe.directory || true)"
      if [ "$got" != ${lib.escapeShellArg repo} ]; then
        echo "check: with the XDG_CONFIG_HOME the apply command exports, git"
        echo "check: reads safe.directory as '$got' instead of '${repo}'."
        exit 1
      fi

      echo "check: nh ran as root for switch and for boot, was handed that verb"
      echo "check: and ${repo}, and did not have to be told to ignore its own"
      echo "check: refusal; every other mode is refused before nh sees it; and"
      echo "check: the safe.directory exemption is readable where it points"
      install -m 0555 ${applyScript} $out
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
      ExecStart = "${applyCommand} %i";
      # `upd apply --ff-only` cannot clear the status: at that point only the
      # repository moved and the privileged activation may still fail. This
      # runs only after ExecStart succeeds, so the DMS click has one honest
      # boundary: system applied, then prepared changes disappear. Run the
      # finalizer as the regular user: status_write creates a private temporary
      # file and the next DMS poll must remain able to read the replacement.
      # `boot` is a deliberate no-op in finalize because that mode still waits
      # for reboot.
      ExecStartPost = "${pkgs.util-linux}/bin/runuser -u ${user} -- ${nixos-upd}/bin/upd finalize %i";
      # nh shells out to nix, which needs these on a system unit's minimal PATH.
      # XDG_CONFIG_HOME is deliberately NOT here: the safe.directory exemption
      # lives inside the script, so that the build-time check runs the same
      # environment the unit does. See applyScript.
      Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
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
