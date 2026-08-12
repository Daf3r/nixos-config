#!/usr/bin/env bats
#
# `upd` is the only place the engine's findings reach a human, so what is
# tested here is mostly "does it stay quiet when it must not". Two of these
# tests exist specifically because a version without them passed everything
# else: the unknown-state arm (a reader that prints a heading and exits 0 for a
# state it does not know) and the warnings block (a `ready` with findings
# rendering identically to a clean one).

# `run --separate-stderr` is a flag on `run`, and flags on `run` are a 1.5
# feature: without this line bats runs them anyway and prints a BW02 warning
# after the suite, which in the nix build log is a warning nobody will ever be
# in a position to act on.
bats_require_minimum_version 1.5.0

UPD="${BATS_TEST_DIRNAME}/../upd.sh"

setup() {
  WORK="$(mktemp -d)"
  STATE="$WORK/state"
  mkdir -p "$STATE"
  # A stub `nh`, so the apply tests can prove activation was NOT reached --
  # and, on the happy path, that it was reached with the right argument.
  #
  # The shebang is written as $BASH rather than `/usr/bin/env bash`: these
  # stubs are reached through execve (PATH lookup for `nh`, a bare `exec` for
  # the engine), so the interpreter path has to exist. Now that the suite runs
  # inside the nix build sandbox there is no /usr/bin/env there, and four tests
  # failed with "bad interpreter" -- the stub never ran and the assertion about
  # upd.sh's behaviour was really an assertion about the sandbox's /usr/bin.
  mkdir -p "$WORK/bin"
  { printf '#!%s\n' "$BASH"; cat <<'EOF'
printf '%s\n' "$*" >> "$NH_MARKER"
EOF
  } > "$WORK/bin/nh"
  chmod +x "$WORK/bin/nh"
  export NH_MARKER="$WORK/nh-called"
  : > "$NH_MARKER"
  PATH="$WORK/bin:$PATH"

  # Stand-ins for the system profile and the running system, the two things
  # `status` compares. They are the only thing any subcommand reads from the
  # *running* machine, and left at their defaults they would make the tests
  # below say different things depending on who runs the suite: a laptop whose
  # profile is ahead of its running system really is in that state, so "no
  # blockers on a clean main" would pass or fail on a fact about the host
  # rather than about the reader.
  #
  # The default pair is the ordinary case -- the two agree -- and reaches the
  # same generation by two different paths, one of them a symlink, so it also
  # holds down the fact that both sides are resolved before being compared.
  mkdir -p "$WORK/gen1" "$WORK/gen2"
  ln -s "$WORK/gen1" "$WORK/perfil"
  SYS_PROFILE="$WORK/perfil"
  SYS_CURRENT="$WORK/gen1"
}

teardown() {
  rm -rf "$WORK"
}

status_json() { # $1 the JSON body, written as-is
  printf '%s\n' "$1" > "$STATE/status.json"
}

# A schema 2 `ready`: one input that moved, one hand-packaged app that moved,
# one that did not, and a closure diff. The unchanged `brave-origin` entry is
# deliberate -- the engine reports every local package on every run, moved or
# not, so `from == to` is the ordinary case and the reader has to keep it out
# of the change list on its own.
ready_status() {
  status_json '{"build":{"ok":true,"log":"/l"},"branch":"auto/update",
    "changes":[{"name":"nixpkgs","kind":"input","from":"f13ff45","to":"279b4a8"},
      {"name":"brave-origin","kind":"local_pkg","from":"1.93.134","to":"1.93.134"},
      {"name":"t3code-app","kind":"local_pkg","from":"0.0.32","to":"0.0.33"}],
    "closure_diff":{"added":[{"name":"libnew","to":"1.0"}],
      "removed":[{"name":"libold","from":"0.9"},{"name":"libgone","from":"0.1"}],
      "changed":[{"name":"gcc","from":"16.1.0","to":"16.2.0"},
        {"name":"samba","from":"4.23.8","to":"4.23.10"},
        {"name":"libxmp","from":"4.7.1","to":"4.7.2"}],
      "size_delta_mb":8.88},
    "reboot_recommended":false,"reboot_reason":[],
    "warnings":'"${1:-[]}"',"unmanaged":[],
    "schema":2,"checked_at":"2026-08-09T03:00:11+02:00","state":"ready"}'
}

# A throwaway $REPO plus the clone the engine would have left beside it: on
# auto/update, clean, with a `result` symlink and one prepared commit.
make_rig() {
  REPO="$WORK/repo"
  mkdir -p "$REPO"
  git init -q -b main "$REPO"
  printf 'v1\n' > "$REPO/flake.lock"
  printf 'result\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
  git clone -q --no-hardlinks "$REPO" "$STATE/wt"
  git -C "$STATE/wt" checkout -q -B auto/update
  printf 'v2\n' > "$STATE/wt/flake.lock"
  git -C "$STATE/wt" add -A
  git -C "$STATE/wt" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -qm "auto: actualizacion preparada"
  ln -s /run/current-system "$STATE/wt/result"
  ready_status
}

# GIT_CEILING_DIRECTORIES for the same reason upd_status carries it, spelled
# out in the comment below: `apply` walks up from $REPO with `git status` and
# `symbolic-ref` too, so the contract test that removes $REPO/.git rested on no
# ancestor of $TMPDIR being a git repository. Measured today the walk stops at
# the /tmp mount boundary -- a fact about this machine, not about the reader,
# and one nobody would think to check before moving $TMPDIR. Both helpers reach
# the same script; only one of them was pinned.
upd() { REPO="${REPO:-$WORK/repo}" STATE_DIR="$STATE" GIT_CEILING_DIRECTORIES="$WORK" bash "$UPD" "$@"; }

# `status` with the two system paths pinned. `env` rather than a bare
# assignment prefix in front of `run`, which is what the plan wrote: the prefix
# does reach the child (measured), but only through bash's rule that temporary
# assignments to a *function* call are exported for its duration, across two
# nested helpers here. `env` says the same thing without depending on it, and it
# is the form this file already uses for BRANCH further down.
#
# GIT_CEILING_DIRECTORIES stops git's search for a repository at $WORK. Without
# it, "says it could not read the repo" depends on $TMPDIR not being inside a
# git repository: `rev-parse --is-inside-work-tree` walks up from $REPO, so on a
# machine whose temporary directory happened to live under a checkout it would
# find *that* one, report a work tree, and the test would silently invert into
# asserting the opposite of what it names. Not the case here today, which is
# exactly the kind of thing that changes without anyone deciding to change it.
upd_status() { # $@ the arguments after `status`
  env REPO="${REPO:-$WORK/repo}" STATE_DIR="$STATE" \
      GIT_CEILING_DIRECTORIES="$WORK" \
      _UPD_SYSTEM_PROFILE="$SYS_PROFILE" _UPD_CURRENT_SYSTEM="$SYS_CURRENT" \
      bash "$UPD" status "$@"
}

# --- show -------------------------------------------------------------------

@test "show says so when no check has run yet" {
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hay ninguna comprobacion todavia"* ]]
}

@test "show refuses a status.json it cannot parse" {
  printf 'no soy json{' > "$STATE/status.json"
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es un objeto JSON legible"* ]]
}

@test "show refuses a schema from the future and says the reader is the old side" {
  # A file newer than this reader: the engine that wrote it is not the one
  # packaged next to this script, so the system is what needs updating.
  status_json '{"schema":3,"checked_at":"x","state":"ready","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema 3"* ]]
  [[ "$output" == *"actualiza el sistema"* ]]
  [[ "$output" != *"upd check"* ]]
}

@test "show refuses a schema 1 status file and points at the fix that actually works" {
  # The direction schema 2 opened up, and the one daf3r will hit: the nightly
  # timer runs the *installed* engine, so a system still on schema 1 rewrites
  # status.json in schema 1, and the switch that follows leaves a schema 2
  # reader looking at it. Advising "actualiza el sistema" there points at a
  # no-op -- the system is already up to date, and what rewrites the file is
  # `upd check`. Same rule as the `--boot` advice: pointing someone at
  # something that does nothing is worse than not advising at all.
  status_json '{"schema":1,"state":"ready","checked_at":"x","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema 1"* ]]
  [[ "$output" == *"upd check"* ]]
  [[ "$output" != *"actualiza el sistema"* ]]
}

@test "show refuses a schema that is not a number without leaking a shell error" {
  # Both refusals above compare numerically, and `[ ausente -lt 2 ]` is a bash
  # error, not a false: it returns 2, which the `if` reads as false, so without
  # the guard the reader prints the shell's diagnostic and then advises updating
  # the system on top of it.
  #
  # What is asserted is this reader's OWN sentence, not the absence of bash's.
  # This test used to assert `!= *"integer expression"*` and nothing else, and
  # that wording is not the one bash 5.3.15 uses -- it says `[: dos: integer
  # expected`. Measured against a copy of upd.sh with the whole `case` deleted:
  # the reader leaked `[: dos: integer expected`, advised "actualiza el
  # sistema", and all three assertions still passed. A test that survives the
  # deletion of the line it names holds nothing down, so the anchor is now the
  # message only this file can produce; the negative is cut back to `integer`,
  # which is in every wording bash has used for this error.
  status_json '{"schema":"dos","state":"ready","checked_at":"x","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema dos"* ]]
  [[ "$output" == *"no es un numero de schema"* ]]
  [[ "$output" != *"integer"* ]]

  # And the same when there is no schema key at all, which is what
  # `.schema // "ausente"` produces.
  status_json '{"state":"ready","checked_at":"x","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"ausente"* ]]
  [[ "$output" == *"no es un numero de schema"* ]]
  [[ "$output" != *"integer"* ]]
}

@test "show refuses a schema of digits that bash cannot compare either" {
  # The same defect as above, reached through the arm that was meant to be the
  # safe one: `*[!0-9]*` accepts a digit string of any length, and `[` parses it
  # with strtoimax. Measured on the reader before the length cap, with a schema
  # of twenty nines: `[: 99999999999999999999: integer expected` on stderr, and
  # then "actualiza el sistema" -- advice derived from a comparison that never
  # happened.
  status_json '{"schema":99999999999999999999,"state":"ready","checked_at":"x","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es un numero de schema"* ]]
  [[ "$output" != *"integer"* ]]
  [[ "$output" != *"actualiza el sistema"* ]]
}

@test "an unrecognised state is loud and exits non-zero" {
  # The regression this file exists for. Without the default arm the reader
  # prints the heading, falls through the case, and exits 0 -- which reads
  # exactly like "nothing to do".
  status_json '{"schema":2,"checked_at":"x","state":"rolled_back","warnings":[]}'
  run upd
  [ "$status" -eq 2 ]
  [[ "$output" == *"estado desconocido"* ]]
  [[ "$output" == *"rolled_back"* ]]
}

@test "a ready with warnings looks different from a clean one" {
  ready_status
  run upd
  [ "$status" -eq 0 ]
  clean="$output"
  [[ "$clean" != *"AVISO"* ]]

  ready_status '[{"code":"local_bump_failed","detail":"brave-origin se quedo atras"}]'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" != "$clean" ]]
  [[ "$output" == *"AVISOS: 1"* ]]
  [[ "$output" == *"AVISO [local_bump_failed] brave-origin se quedo atras"* ]]
}

@test "show lists changes[] instead of local_pkgs" {
  ready_status
  run upd
  [ "$status" -eq 0 ]
  # The input the run moved, named, with both revisions -- the whole reason
  # schema 2 exists: the first real run moved six inputs and named none.
  [[ "$output" == *"nixpkgs f13ff45 -> 279b4a8"* ]]
  [[ "$output" == *"t3code-app 0.0.32 -> 0.0.33"* ]]
  # A package that did not move is not a change. It is still in `changes[]`
  # (the engine reports the check ran), so the filtering is the reader's job.
  [[ "$output" != *"brave-origin"* ]]
}

@test "show summarises the closure diff with its three counts and the size" {
  # Without this the entire closure_diff block can be deleted from the reader
  # with every other test still green: nothing else in this file reads it.
  #
  # The three cardinals in the fixture are deliberately all different -- 3, 1
  # and 2. With `changed` and `added` both at one, swapping the two in the
  # reader produced byte-identical output and the mutant survived; a test whose
  # fixture cannot tell two fields apart is not testing that they are the right
  # two.
  ready_status
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 paquetes cambian"* ]]
  [[ "$output" == *"1 entran"* ]]
  [[ "$output" == *"2 salen"* ]]
  [[ "$output" == *"8.88 MB"* ]]
}

@test "show announces a recommended reboot, and stays quiet when none is needed" {
  # The negative half is not padding: an unconditional notice would pass the
  # positive assertions alone, and an advisory that fires on every update is
  # one nobody reads.
  ready_status
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" != *"REINICIO"* ]]

  status_json '{"build":{"ok":true,"log":"/l"},"branch":"auto/update","changes":[],
    "closure_diff":{"added":[],"removed":[],"changed":[],"size_delta_mb":0},
    "reboot_recommended":true,"reboot_reason":["nvidia-open","nvidia-x11"],
    "warnings":[],"unmanaged":[],
    "schema":2,"checked_at":"x","state":"ready"}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"nvidia-open"* ]]
  [[ "$output" == *"nvidia-x11"* ]]
  [[ "$output" == *"REINICIO"* ]]
  # And it must say what to do about it, or the flag is trivia. This assertion
  # was the inverse until Task 6: the advice deliberately avoided naming
  # `upd apply --boot`, because that flag was accepted, ignored, and answered
  # with a hot `nh os switch` -- advice that did the opposite of what it said.
  # Now the flag does what its name says, so the advice names it. The two moved
  # together on purpose; naming a flag is only safe while it behaves.
  # Anchored to the advisory's own sentence, not to `--boot` appearing anywhere
  # in the output. It was the looser form until the footer below started naming
  # `--boot` too, at which point deleting the flag from *this* line left the
  # test green -- caught by mutation, not by reading. Two places that can
  # satisfy one assertion means the assertion covers neither.
  [[ "$output" == *'aplicalo con `upd apply --boot`'* ]]
  [[ "$output" == *"reinicia"* ]]

  # And the footer agrees with it. Measured live the day `--boot` landed: the
  # advisory said `upd apply --boot` and four lines further down the footer
  # said `aplicar: upd apply`, on the same screen -- the hot activation the
  # advisory exists to avoid, printed last and therefore the one that sticks.
  [[ "$output" != *"aplicar:  upd apply"$'\n'* ]]
  [[ "$output" == *"aplicar:  upd apply --boot"* ]]

  # The ordinary case keeps the plain footer: an update that needs no reboot
  # must not be pushed through `--boot`, which would leave the system running
  # the old generation until someone reboots for no reason.
  ready_status
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"aplicar:  upd apply"* ]]
  [[ "$output" != *"--boot"* ]]
}

@test "show refuses whole rather than print half a report when jq fails" {
  # The reboot flag is read once and used twice, and hoisting that read out of
  # an `if [ "$(jq …)" ]` condition and into an assignment moved it into a
  # context where errexit acts. Measured on the version between the two: `show`
  # printed its heading and then died with RC=5 -- jq's code, which this file's
  # header does not document, over half a report.
  #
  # Both halves are asserted: the documented refusal, and that nothing was
  # printed before it. The second is what makes the read's *position* matter
  # rather than just its guard.
  ready_status
  status_json "$(jq '.reboot_recommended = true' "$STATE/status.json")"
  { printf '#!%s\n' "$BASH"; cat <<EOF
for a in "\$@"; do
  case "\$a" in
    *reboot_recommended*) echo "jq: fallo simulado" >&2; exit 5 ;;
  esac
done
exec $(command -v jq) "\$@"
EOF
  } > "$WORK/bin/jq"
  chmod +x "$WORK/bin/jq"

  run --separate-stderr upd
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no pude leer si esta actualizacion pide reinicio"* ]]
}

@test "show survives a ready body missing the schema 2 fields" {
  # Not a producer path -- the engine always writes all of them -- but a
  # hand-edited or truncated file must not take the reader down with a jq
  # error and an exit code nothing documents. `upd show` promises 0, 1 or 2.
  status_json '{"schema":2,"checked_at":"x","state":"ready","warnings":[]}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"actualizacion preparada"* ]]
}

@test "warnings are shown on current too, not only on ready" {
  # `current` and a silently failed bump co-occur precisely when the failed
  # bump is what left the closure unchanged.
  status_json '{"schema":2,"checked_at":"x","state":"current",
    "warnings":[{"code":"local_bump_failed","detail":"t3code-app se quedo atras"}]}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"todo al dia"* ]]
  [[ "$output" == *"t3code-app se quedo atras"* ]]
}

@test "warnings are shown on build_failed too" {
  status_json '{"schema":2,"checked_at":"x","state":"build_failed",
    "build":{"ok":false,"log":"/var/lib/nixos-upd/last.log"},
    "warnings":[{"code":"local_bump_failed","detail":"brave-origin se quedo atras"}]}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO compila"* ]]
  [[ "$output" == *"/var/lib/nixos-upd/last.log"* ]]
  [[ "$output" == *"brave-origin se quedo atras"* ]]
}

@test "a body without the warnings key does not take the reader down" {
  # nixos-upd.sh's fail() has one fallback body, for a jq failure, that omits
  # `warnings` entirely. Effectively unreachable, which is exactly why nothing
  # would notice if this reader assumed the key were there.
  status_json '{"schema":2,"checked_at":"x","state":"check_failed",
    "error":"no se pudo codificar el mensaje"}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no se pudo codificar el mensaje"* ]]
}

@test "a warnings field that is not a list is reported, not skipped" {
  status_json '{"schema":2,"checked_at":"x","state":"current","warnings":"boom"}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no es una lista"* ]]
}

@test "diff prints the saved closure diff, and says so when there is none" {
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hay diff guardado"* ]]

  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  ready_status
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.85.121 -> 1.86.2"* ]]
  [[ "$output" == *"comprobado: 2026-08-09T03:00:11+02:00"* ]]
  [[ "$output" != *"ANTERIOR"* ]]
}

@test "diff marks itself stale when the last check left no new diff" {
  # diff.txt is written only on the ready path, so after a failed run it
  # survives describing an older comparison while status.json has moved on.
  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  status_json '{"schema":2,"checked_at":"2026-08-05T03:00:11+02:00",
    "state":"check_failed","error":"nix flake update failed","warnings":[]}'
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"comprobacion ANTERIOR"* ]]
  [[ "$output" == *"check_failed"* ]]
  [[ "$output" == *"2026-08-05T03:00:11+02:00"* ]]
  [[ "$output" == *"1.85.121 -> 1.86.2"* ]]
}

@test "diff says so when it cannot date itself at all" {
  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"no se de cuando es este diff"* ]]
}

@test "an unknown subcommand prints usage and fails" {
  run upd frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"uso: upd"* ]]
}

# --- status --json ----------------------------------------------------------
#
# This subcommand exists for the desktop panel, and the panel's whole problem is
# that two of the things which stop an apply are not in status.json and cannot
# be: the state of the working tree and the branch it has checked out. They
# change long after the nightly run wrote its file. Everything below is about
# those live facts being reported *as data*, next to the file, with an exit code
# that does not lie about whether there was an answer.

@test "status --json reports a dirty tree as a blocker and still exits 0" {
  # Exit 0 is load-bearing and is why it is asserted on nearly every case here:
  # a panel that reads non-zero as "no data" would go blank precisely when it
  # has the most to say. Non-zero is reserved for "there is no object at all".
  make_rig
  touch "$REPO/scratch.txt"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("dirty_tree")'
}

@test "status --json sees a modified tracked file, not only an untracked one" {
  make_rig
  printf 'editado a mano\n' >> "$REPO/flake.lock"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("dirty_tree")'
}

@test "status --json reports the wrong branch as a blocker, naming both" {
  make_rig
  git -C "$REPO" checkout -q -b experimento
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("wrong_branch")'
  # Both names, because "wrong branch" without them is a dead end for whoever
  # reads it off the panel: the fix is `git switch <the other one>`.
  echo "$output" | jq -e '.blockers[] | select(.code == "wrong_branch") | .detail
                          | test("experimento") and test("main")'
}

@test "status --json reports a detached HEAD as a wrong_branch blocker" {
  make_rig
  git -C "$REPO" checkout -q --detach HEAD
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("wrong_branch")'
  echo "$output" | jq -e '.blockers[] | select(.code == "wrong_branch") | .detail
                          | test("desprendido")'
}

@test "status --json has no blockers on a clean main" {
  # Also the negative half of the pending-reboot pair below: setup() points the
  # two profiles at the same generation, so a reader that ignored them -- or
  # never received them -- would decide this from the host's own profiles and
  # one of the two tests would fail.
  make_rig
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers == []'
}

@test "status --json reports a profile that has parted ways with the running system" {
  # `nh os boot` does not move /run/current-system, so the next nightly check
  # finds the system unchanged and reports `ready` again -- and the panel would
  # cheerfully offer to apply the very same update a second time.
  make_rig
  SYS_CURRENT="$WORK/gen2"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("pending_reboot")'
  # The wording has to survive the *other* direction too, so it says which two
  # things disagree and not which one is ahead.
  echo "$output" | jq -e '.blockers[] | select(.code == "pending_reboot") | .detail
                          | test("no son la misma generacion")
                            and (test("proximo arranque") | not)'
}

@test "status --json blocks when the profile is the one left behind" {
  # The other direction, and the reason the detail above is worded the way it
  # is: `nixos-rebuild test` and `nh os test` activate without writing the
  # profile, so they leave it on the *older* generation while
  # /run/current-system is on the newer one. Same inequality, opposite sign.
  # Blocking is right either way -- the two disagree and an apply on top of
  # that stacks a third state on the pile -- but a message about something
  # staged for the next boot would be flatly false here.
  make_rig
  SYS_PROFILE="$WORK/gen2"
  SYS_CURRENT="$WORK/gen1"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("pending_reboot")'
  echo "$output" | jq -e '.blockers[] | select(.code == "pending_reboot") | .detail
                          | test("proximo arranque") | not'
}

@test "status --json reports the engine's own lock as engine_running" {
  make_rig
  flock "$STATE/lock" -c 'sleep 3' &
  local locker=$!
  sleep 0.4
  run upd_status --json
  kill "$locker" 2>/dev/null || true
  wait "$locker" 2>/dev/null || true
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("engine_running")'
}

@test "status --json does not pass a lock it cannot open off as a running engine" {
  # The defect measured in the plan's version of this arm: a single
  # `! (exec 9>"$STATE_DIR/lock" && flock -n 9)` cannot tell "the engine holds
  # it" from "I could not open it at all", and reports the first for both. That
  # one is permanent -- a root-owned lock file after a change of User= in the
  # unit, a $STATE_DIR gone read-only -- so the panel would draw a dead button
  # for ever and blame a check that is not running, which is the exact shape of
  # advice this project keeps deleting. `apply` already distinguishes the two;
  # so must this.
  #
  # A directory where the lock file should be, rather than a chmod: it fails the
  # open for any uid, including the one the nix sandbox happens to build under.
  make_rig
  mkdir "$STATE/lock"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("lock_uncheckable")'
  echo "$output" | jq -e '.blockers | map(.code) | index("engine_running") == null'
}

@test "status --json says it could not read the repo instead of inventing a branch" {
  # Same rule one layer up: with no readable git repository at $REPO both git
  # calls fail, and a reader that only looked at their output would announce a
  # clean tree and a detached HEAD -- two statements about a repository it never
  # managed to open.
  make_rig
  rm -rf "$REPO/.git"
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("repo_uncheckable")'
  echo "$output" | jq -e '.blockers | map(.code) | index("wrong_branch") == null'
  echo "$output" | jq -e '.blockers | map(.code) | index("dirty_tree") == null'
}

@test "status --json gives every blocker a code and a detail that says something" {
  # The panel renders `detail` verbatim, so an empty one is a disabled button
  # with no explanation next to it.
  make_rig
  touch "$REPO/scratch.txt"
  git -C "$REPO" checkout -q -b experimento
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | length >= 2'
  echo "$output" | jq -e '.blockers | all(.code | type == "string" and (length > 0))'
  echo "$output" | jq -e '.blockers | all(.detail | type == "string" and (length > 0))'
}

@test "status --json emits the engine's object unfiltered" {
  # `show` drops the `from == to` rows because a human does not need them. This
  # one must not: the consumer is a machine that counts and groups on its own,
  # and a second, differently-filtered view of the same file is how the two
  # start disagreeing. Everything the file carries is passed through, and
  # `blockers` is added beside it.
  make_rig
  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "object"'
  echo "$output" | jq -e '.changes | map(.name) | index("brave-origin")'
  echo "$output" | jq -e '.state == "ready" and .schema == 2'
  echo "$output" | jq -e '.closure_diff.size_delta_mb == 8.88'
  echo "$output" | jq -e '.reboot_recommended == false and .warnings == []'
  echo "$output" | jq -e '.checked_at == "2026-08-09T03:00:11+02:00"'
}

@test "status --json refuses a file it cannot vouch for instead of emitting half an object" {
  # Unlike `show`, which prints its refusal and is done, this one is read by a
  # program: exit 1 and nothing on stdout is the only way to say "no answer".
  # An object with the blockers filled in and the rest of the file unknown would
  # be read as an answer.
  #
  # `--separate-stderr` is what makes that assertable at all. A bare `run`
  # merges the two streams into $output, and the first version of this test
  # asserted `! echo "$output" | jq -e .` on the merged pair -- which proves
  # only that the *concatenation* does not parse. Measured on a copy with
  # `jq -n '{blockers:[]}'` inserted just before require_readable_status: stdout
  # carried `{"blockers": []}`, stderr carried the refusal, the two together did
  # not parse, and the test stayed green over precisely the half-object it names.
  #
  # And the assertion is on $output, not on $stdout: `run --separate-stderr`
  # leaves $output holding stdout and $stderr holding stderr, and defines no
  # $stdout at all (measured on bats 1.14). `[ -z "$stdout" ]` would be a test
  # that passes on an undefined variable, which is the same defect one layer up.
  make_rig
  status_json '{"schema":3,"state":"ready","checked_at":"x","warnings":[]}'
  run --separate-stderr upd_status --json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"schema 3"* ]]

  printf 'no soy json{' > "$STATE/status.json"
  run --separate-stderr upd_status --json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no es un objeto JSON legible"* ]]

  rm -f "$STATE/status.json"
  run --separate-stderr upd_status --json
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no hay ninguna comprobacion todavia"* ]]
}

@test "status --json refuses rather than emit an object without its blockers" {
  # The seam between lib/blockers.sh's contract and this subcommand's. That
  # function promises 0 on every path it can foresee, which leaves the ones it
  # cannot -- a broken jq, an unwritable $TMPDIR. Without the guard, `set -e`
  # kills the subcommand carrying whatever exit code the failure had, and this
  # file's header assigns meanings to 1 and 2 that such a code does not have.
  #
  # Injected through $LIB_DIR, the same move nixos-upd.bats already makes for
  # closure_reboot: the subcommand under test is the real one, only the library
  # it sources is replaced. There is no way to reach this from the outside --
  # which is exactly why the guard would otherwise be code nobody ever ran.
  make_rig
  mkdir -p "$WORK/lib-roto"
  { printf '# shellcheck shell=bash\n'
    printf 'blockers_live() { return 3; }\n'
  } > "$WORK/lib-roto/blockers.sh"

  run --separate-stderr env REPO="$REPO" STATE_DIR="$STATE" \
    LIB_DIR="$WORK/lib-roto" bash "$UPD" status --json
  # Not 3, and not a partial object: the documented refusal.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"bloqueos en vivo"* ]]
}

@test "status refuses arguments it does not understand" {
  # `--json` is not decoration: it is the promise that the format is stable
  # enough for a program. Defaulting to it, or accepting a trailing argument and
  # ignoring it, is what `apply --boot` was measured doing before its own guard
  # landed -- and the day a second format exists, everything written for the
  # first would already have been accepted.
  make_rig
  run upd_status
  [ "$status" -eq 1 ]
  [[ "$output" == *"uso: upd status --json"* ]]

  run upd_status --texto
  [ "$status" -eq 1 ]
  [[ "$output" == *"--texto"* ]]

  run upd_status --json --frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"--frobnicate"* ]]
}

@test "the usage text announces the apply modes" {
  # Same reason as the one below: a mode nothing mentions is a mode nobody
  # finds. And `--boot` in particular is what the reboot advice tells people to
  # type, so the two texts have to agree.
  run upd frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"--boot"* ]]
  [[ "$output" == *"--ff-only"* ]]
}

@test "the usage text announces status" {
  # An entry point nothing mentions is one nobody finds, and this is the only
  # one the panel will ever call.
  run upd frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"status"* ]]
  [[ "$output" == *"--json"* ]]
}

# --- apply ------------------------------------------------------------------

@test "apply refuses an argument it does not know instead of ignoring it" {
  # This is the inversion the previous version of this test announced. `--boot`
  # used to be here as the *illegal* flag -- measured accepted and ignored, with
  # `nh os switch` run anyway -- and it is now a real option, so its case moved
  # to "apply --boot calls nh os boot". What stayed is the flag chosen back then
  # precisely because it will never become legal, and it is what keeps the guard
  # covered across that inversion.
  make_rig
  run upd apply --frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"--frobnicate"* ]]
  [ ! -s "$NH_MARKER" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]

  # A flag that *looks* like the new ones, because "starts with --" is not the
  # test and a guard written as one would let this through.
  run upd apply --ff
  [ "$status" -eq 1 ]
  [[ "$output" == *"--ff"* ]]
  [ ! -s "$NH_MARKER" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]

  # And two legal flags at once, which is neither of the two things they mean.
  # The old guard was `[ "$#" -gt 1 ]`: widening it to accept one argument must
  # not widen it to accept any number of them.
  run upd apply --boot --ff-only
  [ "$status" -eq 1 ]
  [ ! -s "$NH_MARKER" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]

  # An empty argument is not "no argument". `upd apply "$FLAG"` with FLAG unset
  # went straight through the guard into a hot `switch` -- measured, and it is
  # the same silent-activation shape the guard exists to close, arriving through
  # the one input nobody types on purpose.
  run upd apply ""
  [ "$status" -eq 1 ]
  [ ! -s "$NH_MARKER" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ]

  # And the refusal has to show it. `${*:2}` renders an empty argument as
  # nothing, so this used to answer "he recibido: --boot" -- rejecting the user
  # for something that on its own is perfectly legal.
  run upd apply --boot ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"'--boot'"* ]]
  [[ "$output" == *"''"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply --ff-only fast-forwards and stops before activating" {
  # The half the bar plugin drives. The repository half has to run as daf3r --
  # a merge done as root leaves root-owned objects in .git and breaks the next
  # commit made by hand -- and the activation half is a systemd unit started
  # separately, so this exists to be the first of the two.
  make_rig
  prepared="$(git -C "$STATE/wt" rev-parse auto/update)"
  run upd apply --ff-only
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$prepared" ]
  [ "$(cat "$REPO/flake.lock")" = "v2" ]
  # The whole point: the repository moved and nothing was activated.
  [ ! -s "$NH_MARKER" ]
  # And it says so, because a command that silently does half of what its name
  # suggests is the failure mode this subcommand keeps closing.
  [[ "$output" == *"--ff-only"* ]]
}

@test "apply --ff-only runs the same guards as a full apply" {
  # "Every guard the current apply runs" is the contract, and the risk of a
  # mode flag is that it grows a shortcut past them. Two are checked, one from
  # each end of the sequence: the dirty tree, which refuses before anything is
  # written, and the `ready` gate, which refuses after the lock is taken.
  make_rig
  touch "$REPO/scratch.txt"
  run upd apply --ff-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"cambios sin commitear"* ]]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
  rm "$REPO/scratch.txt"

  status_json '{"schema":2,"checked_at":"x","state":"build_failed","warnings":[]}'
  run upd apply --ff-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hay ninguna actualizacion lista"* ]]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
}

@test "apply --ff-only does not require nh, and the other modes still do" {
  # The preflight refuses when `nh` is missing so that a fast-forward is never
  # left without its activation. Under --ff-only that state is the goal, and
  # the mode exists for the bar plugin, which has no reason to carry `nh` on
  # its PATH -- so the check would be refusing over a tool the run will not use.
  #
  # A PATH containing everything apply uses *except* `nh`, and emphatically not
  # `rm "$WORK/bin/nh"`: removing the stub only uncovers the real `nh` further
  # down $PATH. Measured -- the first version of this test fast-forwarded the
  # throwaway repository and then ran the machine's actual `nh os switch` on it,
  # getting as far as nh refusing for want of a flake.nix. A stub cannot hide a
  # binary that exists; only a PATH without it can.
  make_rig
  mkdir -p "$WORK/minbin"
  for t in bash git jq flock readlink sed dirname mktemp cat rm tr head; do
    ln -s "$(command -v "$t")" "$WORK/minbin/$t"
  done
  # The premise, asserted: on a machine where `nh` lived somewhere inside that
  # list this test would quietly prove nothing.
  run env PATH="$WORK/minbin" bash -c 'command -v nh'
  [ "$status" -ne 0 ]

  # The mode that does need it still refuses, and still refuses *before*
  # touching the repository, which is why that check is a preflight and not an
  # afterthought.
  run env PATH="$WORK/minbin" REPO="$REPO" STATE_DIR="$STATE" bash "$UPD" apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"nh no esta en el PATH"* ]]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]

  run env PATH="$WORK/minbin" REPO="$REPO" STATE_DIR="$STATE" bash "$UPD" apply --ff-only
  [ "$status" -eq 0 ]
  [ "$(cat "$REPO/flake.lock")" = "v2" ]
}

@test "apply refuses with its own words when jq fails after the status was read" {
  # The only assignment in the arm that had no guard. It sits at the top level,
  # where errexit acts, so a jq failure took apply down with jq's exit code and
  # jq's message -- measured at exit 5. require_readable_status ran two jq calls
  # on this same file a moment earlier, which is why the failure has to be
  # injected per-query here: a jq that is simply missing dies further up with a
  # sentence of its own, but one invocation failing on its own (ENOMEM, an
  # ulimit) is not covered by the two that succeeded.
  #
  # Stubbed through PATH, the mechanism this file already uses for `nh`.
  make_rig
  { printf '#!%s\n' "$BASH"; cat <<EOF
for a in "\$@"; do
  case "\$a" in
    *.state*) echo "jq: fallo simulado" >&2; exit 5 ;;
  esac
done
exec $(command -v jq) "\$@"
EOF
  } > "$WORK/bin/jq"
  chmod +x "$WORK/bin/jq"

  run upd apply
  # 1, not 5: the documented refusal, not whatever the failing tool returned.
  [ "$status" -eq 1 ]
  [[ "$output" == *"no pude leer el estado"* ]]
  [ ! -s "$NH_MARKER" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
}

@test "apply --boot activates for the next boot instead of in place" {
  # The mode the reboot advice points at. `nh os boot` writes the profile and
  # leaves /run/current-system alone, which is exactly the state `status --json`
  # reports as `pending_reboot` afterwards.
  make_rig
  prepared="$(git -C "$STATE/wt" rev-parse auto/update)"
  run upd apply --boot
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$prepared" ]
  # `os boot`, and emphatically not `os switch`: the two differ by exactly the
  # hot activation the advice exists to avoid.
  [ "$(cat "$NH_MARKER")" = "os boot $REPO" ]
}

@test "apply refuses a dirty target tree, prints it, and fetches nothing" {
  make_rig
  touch "$REPO/SCRATCH-TEST"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"cambios sin commitear; no aplico"* ]]
  [[ "$output" == *"?? SCRATCH-TEST"* ]]
  # Nothing was activated, and nothing was even written into the repository:
  # the refusal comes before the fetch.
  [ ! -s "$NH_MARKER" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
  [ "$(git -C "$REPO" log --oneline | wc -l)" -eq 1 ]
}

@test "apply refuses a modified tracked file as well as an untracked one" {
  make_rig
  printf 'editado a mano\n' >> "$REPO/flake.lock"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"M flake.lock"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a dirty tree even when the repo config hides it" {
  # status.showUntrackedFiles=no silences the untracked half of the check
  # entirely; the safety rule must not be switchable from a config file this
  # engine does not control.
  make_rig
  git -C "$REPO" config status.showUntrackedFiles no
  touch "$REPO/NOTAS.txt"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"cambios sin commitear; no aplico"* ]]
  [[ "$output" == *"?? NOTAS.txt"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a tree git cannot read instead of calling it clean" {
  # Git can return 0 with no porcelain when a directory below the work tree is
  # unreadable, leaving the old stdout-only guard with a false clean verdict.
  # The apply side must match blockers_live and surface the warning as an
  # uncheckable repository.
  make_rig
  mkdir "$REPO/secreto"
  chmod 000 "$REPO/secreto"

  run upd apply
  chmod 700 "$REPO/secreto"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no puedo leer entero el arbol"* ]]
  [[ "$output" == *"secreto"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a repository it cannot open, without blaming the HEAD" {
  # Measured before the guard existed, with $REPO/.git removed: `git status`
  # printed nothing on stdout, so the dirty-tree guard announced a clean tree,
  # and `symbolic-ref` then failed exactly as it does on a real detached HEAD,
  # so the only sentence apply gave was `esta con el HEAD desprendido; ponlo en
  # una rama antes de aplicar` -- advice to `git switch` inside a repository
  # that is not there. Two confident statements about a repository that was
  # never opened.
  make_rig
  rm -rf "$REPO/.git"

  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no puedo leer $REPO como repositorio git"* ]]
  # The negative half is the point of the test: without it, the old wording
  # satisfies "it refused" just as well as the new one.
  [[ "$output" != *"HEAD desprendido"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a bare repository instead of calling its tree clean" {
  # The guard above reports by printing, not by failing: `rev-parse
  # --is-inside-work-tree` in a bare repository prints `false` and exits 0. A
  # version of it that only looked at the exit status let a bare $REPO through,
  # and then `git status` exited 128 with an empty stdout and the dirty-tree
  # guard announced a clean tree -- the false conclusion the whole block exists
  # to prevent, reached through the block itself.
  #
  # The panel is not wrong here today, but it gets there by another road: its
  # opening check has the same blind spot, and what saves it is the stderr and
  # exit-status capture around its `git status`, which turns the same bare
  # repository into `repo_uncheckable` with git's own sentence in the detail.
  # Both halves are asserted so that road stays open too.
  make_rig
  rm -rf "$REPO"
  git init -q --bare "$REPO"

  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("repo_uncheckable")'

  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no puedo leer $REPO como repositorio git con arbol de trabajo"* ]]
  # Never the two sentences that would mean it had believed the bare repository:
  # a clean tree, or a branch verdict about one.
  [[ "$output" != *"HEAD desprendido"* ]]
  [[ "$output" != *"esta en la rama"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply says a detached HEAD is a detached HEAD" {
  # The guard that prints this had no test of its own anywhere in the suite --
  # measured in Task 6 by mutating its `|| die` into `|| cur_branch=""` and
  # running everything: all green, because the branch guard below it refuses
  # anyway, with `esta en la rama ''`, empty quotes where a name should be. So
  # the sentence is pinned here, on a repository that really is detached, which
  # is the one situation where it is the right thing to say.
  make_rig
  git -C "$REPO" checkout -q --detach HEAD

  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"$REPO esta con el HEAD desprendido; ponlo en una rama antes de aplicar"* ]]
  # Not the branch guard wearing empty quotes, which is what speaks when this
  # one is weakened rather than removed.
  [[ "$output" != *"esta en la rama ''"* ]]
  [ ! -s "$NH_MARKER" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
}

@test "apply refuses to fast-forward a branch that is not the engine's" {
  # Reproduced before the fix: with $REPO on `experimento`, an ancestor of main
  # with no commits of its own, apply moved *experimento* onto the prepared
  # commit and switched -- so the system ran a commit that is not on main, and
  # every later apply refused with advice that could not fix it.
  make_rig
  git -C "$REPO" branch experimento HEAD
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "trabajo en main"
  git -C "$STATE/wt" fetch -q "$REPO" main
  git -C "$STATE/wt" checkout -q -B auto/update FETCH_HEAD
  printf 'v3\n' > "$STATE/wt/flake.lock"
  git -C "$STATE/wt" add -A
  git -C "$STATE/wt" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -qm "auto: actualizacion preparada"
  git -C "$REPO" checkout -q experimento

  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"esta en la rama 'experimento'"* ]]
  [[ "$output" == *"prepara desde 'main'"* ]]
  [[ "$output" == *"switch main"* ]]
  # experimento must be exactly where it was, and nothing activated.
  [ "$(git -C "$REPO" rev-parse experimento)" = "$(git -C "$REPO" rev-parse main~1)" ]
  [ ! -s "$NH_MARKER" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
}

@test "apply honours BRANCH when the engine is pointed at another one" {
  make_rig
  git -C "$REPO" branch -m main produccion
  run env BRANCH=produccion REPO="$REPO" STATE_DIR="$STATE" bash "$UPD" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

@test "apply refuses when the state is not ready" {
  make_rig
  status_json '{"schema":2,"checked_at":"x","state":"build_failed","warnings":[]}'
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hay ninguna actualizacion lista"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses while the engine holds the lock" {
  # status.json is written at the end of a run but auto/update is force-moved
  # near its start, so during a run the file on disk can describe a branch that
  # has already moved. Sharing the engine's lock is what closes that window.
  make_rig
  flock "$STATE/lock" -c 'sleep 3' &
  local locker=$!
  sleep 0.4
  run upd apply
  kill "$locker" 2>/dev/null || true
  wait "$locker" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"comprobacion en marcha"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a clone that is not this engine's clone of the repo" {
  make_rig
  git -C "$STATE/wt" remote set-url origin /tmp/otro-repo
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es de"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a clone whose HEAD is not the prepared branch" {
  # A run killed midway leaves the clone somewhere else; the source that
  # produced result is then no longer on disk in a form anyone can name.
  make_rig
  git -C "$STATE/wt" checkout -q --detach HEAD~1
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es auto/update"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses when the target branch moved past the prepared commit" {
  make_rig
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "trabajo del usuario"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es antecesor"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply fast-forwards and switches, naming what it applies" {
  make_rig
  prepared="$(git -C "$STATE/wt" rev-parse auto/update)"
  run upd apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"aplicando sobre main"* ]]
  [[ "$output" == *"auto: actualizacion preparada"* ]]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$prepared" ]
  [ "$(cat "$REPO/flake.lock")" = "v2" ]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

@test "apply warns, but proceeds, when the built closure is gone" {
  make_rig
  rm "$STATE/wt/result"
  run upd apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ya no apunta a ningun closure"* ]]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

# --- the contract the two surfaces share -------------------------------------
#
# Five of the six blockers are expressed twice: once in lib/blockers.sh, for the
# panel, and once as a guard inside `apply`, for the terminal. That duplication
# is deliberate -- `apply` refusing on its own account is what makes it safe to
# run without a panel, and wiring it through `blockers_live` would couple the
# command to the panel's library -- but duplication is how two readings of one
# rule drift apart. This repository has closed that shape twice already: the
# filter in `show` versus `status --json`, and the reboot advisory versus the
# footer under it.
#
# So the agreement is pinned here rather than left to good intentions. Each of
# these builds one situation and asserts both halves of it: the panel reports
# the blocker, **and** the terminal refuses. Deleting either half turns one of
# these red, which is the whole point -- the tests above cover each surface
# alone, and none of them would notice the two disagreeing.
#
# `pending_reboot` is deliberately absent: it is the one blocker `apply` does
# not reproduce, and that asymmetry is a decision (a person may stack a
# generation knowingly; the panel's drive-by user should not). It is written up
# in the task report rather than encoded here.
#
# Each of these also pins *which* refusal `apply` gives, and not merely that it
# gave one. Measured: without that, a guard can be deleted and the test stays
# green because a later guard stops the run for an unrelated reason -- "it
# refused" is satisfied by any of six exits.
#
# All five are anchored now. The fifth, the unreadable repository, was left
# unanchored through Task 6 on purpose and the rule it left behind was "anchor
# the message where it is right today, and write down where it is not": there
# `apply` reached its detached-HEAD guard and blamed that, so pinning the
# wording would have fixed a false sentence in place. Task 7 gave `apply` the
# repository check `blockers_live` already opened with, which is what made the
# fifth anchorable.

@test "contrato: un arbol sucio bloquea el panel y frena el terminal" {
  make_rig
  touch "$REPO/scratch.txt"

  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("dirty_tree")'

  run upd apply
  [ "$status" -eq 1 ]
  # The whole sentence, tail included: the clone guard further up says "el clon
  # en ... tiene cambios sin commitear" about a different tree entirely, so
  # matching only "cambios sin commitear" would accept the wrong refusal.
  [[ "$output" == *"el arbol de trabajo tiene cambios sin commitear; no aplico"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "contrato: la rama equivocada bloquea el panel y frena el terminal" {
  make_rig
  git -C "$REPO" checkout -q -b experimento

  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("wrong_branch")'

  run upd apply
  [ "$status" -eq 1 ]
  # Both branch names, because the refusal is only useful if it says which one
  # the repository is on and which one the engine prepares from.
  [[ "$output" == *"esta en la rama 'experimento' y el motor prepara desde 'main'"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "contrato: el motor en marcha bloquea el panel y frena el terminal" {
  make_rig
  flock "$STATE/lock" -c 'sleep 3' &
  local locker=$!
  sleep 0.4

  run upd_status --json
  local st_status=$status
  local st_output=$output

  run upd apply
  local ap_status=$status
  local ap_output=$output

  kill "$locker" 2>/dev/null || true
  wait "$locker" 2>/dev/null || true

  [ "$st_status" -eq 0 ]
  echo "$st_output" | jq -e '.blockers | map(.code) | index("engine_running")'
  [ "$ap_status" -eq 1 ]
  # This is the one refusal `apply` gives that is a claim about *another*
  # process, so it is the one worth pinning: the same sentence comes out when
  # the lock cannot even be opened if its own guard is removed, and there it
  # would be false.
  [[ "$ap_output" == *"hay una comprobacion en marcha ahora mismo"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "contrato: un repo ilegible bloquea el panel y frena el terminal" {
  make_rig
  rm -rf "$REPO/.git"

  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("repo_uncheckable")'

  run upd apply
  [ "$status" -eq 1 ]
  # The fifth pair, anchored at last. It stayed unanchored through Task 6 for a
  # stated reason -- `apply` reached its detached-HEAD guard and blamed that,
  # and pinning a false sentence would have fixed the defect in place. Task 7
  # gave `apply` the same repository check `blockers_live` opens with, so the
  # two surfaces now name the same thing and the agreement can be held down.
  [[ "$output" == *"no puedo leer $REPO como repositorio git"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "contrato: un lock inabrible bloquea el panel y frena el terminal" {
  make_rig
  rm -f "$STATE/lock"
  mkdir "$STATE/lock"

  run upd_status --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.blockers | map(.code) | index("lock_uncheckable")'

  run upd apply
  [ "$status" -eq 1 ]
  # "no puedo abrir", not "hay una comprobacion en marcha": nothing is running
  # here, and this is exactly the pair the guard keeps apart. Deleting it makes
  # the run fall through to `flock -n 9` on an unopened descriptor and blame a
  # check that does not exist.
  [[ "$output" == *"no puedo abrir $STATE/lock; sin el no puedo descartar una comprobacion en marcha"* ]]
  [ ! -s "$NH_MARKER" ]
}

# --- check ------------------------------------------------------------------

@test "check runs the engine directly, not through systemctl" {
  # $BASH, not `/usr/bin/env bash`: upd.sh reaches this with a bare `exec`, and
  # /usr/bin/env does not exist inside the nix build sandbox.
  { printf '#!%s\n' "$BASH"; cat <<'EOF'
echo "motor ejecutado"
EOF
  } > "$WORK/bin/motor"
  chmod +x "$WORK/bin/motor"
  run env NIXOS_UPD="$WORK/bin/motor" STATE_DIR="$STATE" bash "$UPD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"motor ejecutado"* ]]
  [[ "$output" != *"systemctl"* ]]
}
