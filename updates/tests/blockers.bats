#!/usr/bin/env bats
#
# `blockers_live` is driven end to end by upd.bats, through `upd status --json`,
# and that is where its behaviour is pinned. This file exists for the two
# clauses of its contract that the end-to-end tests cannot reach and that were
# both found to be false once already:
#
#   1. the argument list survives values that begin with a dash. Reaching that
#      through `upd status --json` needs a $REPO whose name starts with one,
#      with a git repository inside it -- a contortion in a file whose harness
#      builds $REPO for every test. Here it is one call.
#   2. nothing is written to stderr. Nothing in upd.bats separates the two
#      streams for this, and `run --separate-stderr` makes it one assertion.
#
# Everything else -- which blockers appear when -- stays in upd.bats, where it
# is tested through the interface the panel actually calls. Duplicating it here
# would mean two places to update and one of them silently drifting.

bats_require_minimum_version 1.5.0

setup() {
  WORK="$(mktemp -d)"
  # shellcheck source=../lib/blockers.sh
  source "${BATS_TEST_DIRNAME}/../lib/blockers.sh"

  # A clean repository on `main`, plus the two profile paths pointing at the
  # same generation: the baseline where every blocker is silent, so a test that
  # expects one is not reading a leftover from the fixture.
  REPO="$WORK/repo"
  git init -q -b main "$REPO"
  printf 'v1\n' > "$REPO/flake.lock"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
  mkdir -p "$WORK/gen"
  LOCK="$WORK/lock"
  GEN="$WORK/gen"
}

teardown() {
  chmod -R u+rwX "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}

@test "the baseline this file measures against is empty" {
  run blockers_live "$REPO" main "$LOCK" "$GEN" "$GEN"
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]
}

@test "a detail that begins with a dash is not read as an option" {
  # The one reachable way in: `git -C` accepts a path that starts with a dash
  # (measured), and the wrong_branch detail begins with $repo, so the value
  # handed to jq begins with one too. Without the `--` before the arguments,
  # jq parses it: measured, `-x` and `--json` exit 2 with "Unknown option", and
  # `--args` is accepted and yields `detail: null` -- a disabled button with no
  # explanation next to it.
  cd "$WORK"
  mv repo ./-raro
  run blockers_live -raro produccion "$LOCK" "$GEN" "$GEN"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.code == "wrong_branch") | .detail | startswith("-raro")'
}

@test "every argument reaches jq as data, never as a flag" {
  # The same hole from the other side, and without git: the two values jq
  # measurably mis-parses are `--args` (silently) and `--arg` (loudly), so they
  # go in as a branch name and a repository path and have to come back out
  # unchanged.
  cd "$WORK"
  mv repo ./--args
  run blockers_live --args --arg "$LOCK" "$GEN" "$GEN"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array" and length > 0'
  echo "$output" | jq -e 'all(.detail != null and .detail != "")'
  echo "$output" | jq -e '.[] | select(.code == "wrong_branch") | .detail | startswith("--args")'
}

@test "it writes nothing to stderr, even when git complains" {
  # git's own diagnostics are the ones that used to leak: `git status` in a work
  # tree it cannot fully read prints a warning, exits 0, and prints nothing on
  # stdout. Both halves are asserted here -- the warning does not reach the
  # caller's stderr, and it does not pass for a clean tree either.
  mkdir "$REPO/secreto"
  printf 'x\n' > "$REPO/secreto/b.txt"
  chmod 000 "$REPO/secreto"
  run --separate-stderr blockers_live "$REPO" main "$LOCK" "$GEN" "$GEN"
  chmod 755 "$REPO/secreto"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  echo "$output" | jq -e 'map(.code) | index("repo_uncheckable")'
}

@test "a tree git cannot read whole is never reported as clean" {
  # The finding this arm exists for, asserted as a negative: silence about
  # dirty_tree is the failure mode, not the passing one.
  mkdir "$REPO/secreto"
  printf 'x\n' > "$REPO/secreto/b.txt"
  chmod 000 "$REPO/secreto"
  run blockers_live "$REPO" main "$LOCK" "$GEN" "$GEN"
  chmod 755 "$REPO/secreto"
  [ "$status" -eq 0 ]
  [ "$output" != "[]" ]
  # And it says which directory, or the message is a dead end for whoever reads
  # it off the panel.
  echo "$output" | jq -e '.[] | select(.code == "repo_uncheckable") | .detail | test("secreto")'
}

@test "a readable dirty tree is still reported as dirty" {
  # The other side of the same branch: the new guard must not have swallowed the
  # ordinary case it sits in front of.
  touch "$REPO/scratch.txt"
  run blockers_live "$REPO" main "$LOCK" "$GEN" "$GEN"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'map(.code) | index("dirty_tree")'
  echo "$output" | jq -e 'map(.code) | index("repo_uncheckable") == null'
}
