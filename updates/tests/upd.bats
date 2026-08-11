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

upd() { REPO="${REPO:-$WORK/repo}" STATE_DIR="$STATE" bash "$UPD" "$@"; }

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
  # And it must say what to do about it, or the flag is trivia. Deliberately
  # not `upd apply --boot`, which the plan wrote here: that flag does not
  # exist, and `upd apply --boot` was measured doing a hot `nh os switch` with
  # the flag ignored -- advice that does the opposite of what it says.
  [[ "$output" == *"reinicia"* ]]
  [[ "$output" != *"--boot"* ]]
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
  # Measured before the guard: `upd apply --boot` fast-forwarded the repository
  # and ran `nh os switch` -- the flag accepted, ignored, and the hot
  # activation done anyway. An option that silently does the opposite of its
  # name is worse than no option, and `--boot` is exactly the flag a reader of
  # the reboot advice would reach for before Task 6 lands it.
  make_rig
  run upd apply --boot
  [ "$status" -eq 1 ]
  [[ "$output" == *"--boot"* ]]
  [ ! -s "$NH_MARKER" ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse main)" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]

  # A second flag, chosen because it will never become legal. Task 6 turns
  # `--boot` into a real option, and that day the case above has to be inverted
  # -- taking the only cover for "an unknown argument is refused" with it
  # unless something else is holding the guard down. This is that something.
  run upd apply --frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"--frobnicate"* ]]
  [ ! -s "$NH_MARKER" ]
  [ "$(cat "$REPO/flake.lock")" = "v1" ]
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
