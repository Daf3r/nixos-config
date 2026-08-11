#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/inputs.sh"
  # Driven through `run bash -c` like closure.bats, to pin the exit status
  # independently of the bats shell. A child bash does not inherit shell
  # functions, so it has to be exported.
  export -f inputs_diff
  BEFORE="${BATS_TEST_DIRNAME}/fixtures/lock-before.json"
  AFTER="${BATS_TEST_DIRNAME}/fixtures/lock-after.json"
  FOLLOWS="${BATS_TEST_DIRNAME}/fixtures/lock-follows.json"
}

@test "inputs_diff reports nothing when both sides are the same file" {
  run bash -c "inputs_diff '$AFTER' '$AFTER' | jq -e '. == []'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff skips an input that exists on only one side" {
  # `dms` and `dms-plugins` were both added between c7dec43 and today. An input
  # that appeared is not an input that moved: reporting it as a change with an
  # empty `from` would put a meaningless row in the panel every time an input
  # is added.
  #
  # The two fixtures differ ONLY by those additions -- no root input moved
  # between them -- so a bare "the added ones are absent" assertion over
  # BEFORE→AFTER is satisfied by a function that always answers `[]`, which is
  # the exact failure this whole engine exists to remove. So a real move is
  # forced into the new side first, and the assertion is on the entire name
  # list: the mover has to be there and the two newcomers have to not be.
  jq '.nodes.nixpkgs_3.locked.rev = "2222222222222222222222222222222222222222"' "$AFTER" > "$BATS_TMPDIR/added-and-moved.json"
  run bash -c "inputs_diff '$BEFORE' '$BATS_TMPDIR/added-and-moved.json' | jq -e 'map(.name) == [\"nixpkgs\"]'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff reports a moved input with short revs" {
  jq '.nodes.nixpkgs_3.locked.rev = "0000000000000000000000000000000000000000"' "$AFTER" > "$BATS_TMPDIR/moved.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/moved.json' | jq -e '.[0].to == \"0000000\" and (.[0].from | length) == 7 and .[0].kind == \"input\"'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff names the input, not the internal node key" {
  # nixpkgs appears in the lock as node `nixpkgs_3` because of follows
  # resolution. A panel that says "nixpkgs_3 moved" is leaking lock internals.
  jq '.nodes.nixpkgs_3.locked.rev = "1111111111111111111111111111111111111111"' "$AFTER" > "$BATS_TMPDIR/moved.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/moved.json' | jq -e '.[0].name == \"nixpkgs\"'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff walks a whole follows path instead of taking its first segment" {
  # lock-follows.json is real `nix flake lock` output (2026-08-11), only its
  # file:// URLs shortened. Its root carries `"deep": ["dep2", "a"]` -- what nix
  # writes for a top-level `inputs.deep.follows = "dep2/a"`. That is not a
  # hypothetical shape; it was generated to check this and it came out of nix.
  #
  # Taking `.[0]` of that path lands on node `dep2` instead of node `a`, and
  # then `deep` is reported carrying dep2's revision. Here node `a` is the one
  # that moves and `dep2` does not, so the shortcut reports nothing at all
  # while the correct walk reports `deep` moving off `a`'s real rev.
  jq '.nodes.a.locked.rev = "3333333333333333333333333333333333333333"' "$FOLLOWS" > "$BATS_TMPDIR/deep.json"
  run bash -c "inputs_diff '$FOLLOWS' '$BATS_TMPDIR/deep.json' | jq -e 'map(.name) == [\"deep\"] and .[0].from == \"e4910e7\" and .[0].to == \"3333333\"'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff skips an input whose node has no rev instead of emitting a null" {
  # Not every input type carries a rev. `local` in lock-follows.json is a real
  # `path:` input as nix locked it: narHash and lastModified, no rev at all.
  # Read without a fallback, its rev is null, null is never equal to anything,
  # and the input is reported as moved on every single run with `from` and `to`
  # as JSON nulls -- garbage in the panel, and permanent.
  #
  # Asserting on the raw text as well as on the list: a `from: null` reaching
  # the bar is the failure being prevented, and only the name list would still
  # look right if the field were emitted as a null under some other name.
  jq '.nodes.local.locked.narHash = "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa="' "$FOLLOWS" > "$BATS_TMPDIR/norev.json"
  run bash -c "inputs_diff '$FOLLOWS' '$BATS_TMPDIR/norev.json' | jq -e '. == []'"
  [ "$status" -eq 0 ]
  run bash -c "inputs_diff '$FOLLOWS' '$FOLLOWS' | grep -c null"
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "inputs_diff refuses a lock with no root inputs instead of reporting nothing moved" {
  # Silence is the failure mode this file exists to remove: the first real run
  # of the engine moved six inputs and named none of them. If a future lock
  # format stops keeping the names under `.nodes[.root].inputs`, defaulting
  # that lookup to `{}` turns every comparison into `[]` -- "nothing moved" --
  # with a clean exit status and nothing anywhere to say the reader had gone
  # blind. It has to be an error the caller can turn into a warning.
  jq 'del(.nodes[.root].inputs)' "$AFTER" > "$BATS_TMPDIR/rootless.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/rootless.json' 2> '$BATS_TMPDIR/rootless-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/rootless-err.txt"
  # Both directions: the guard has to look at the old side too.
  run bash -c "inputs_diff '$BATS_TMPDIR/rootless.json' '$AFTER' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "inputs_diff fails on a lock it cannot read or parse" {
  # A missing file is the first-run case: nothing has written the previous lock
  # yet. jq exits 2 there and 5 on a lock whose root cannot be indexed, and
  # neither number is what this function promises, so both are mapped onto 1.
  printf 'not json at all\n' > "$BATS_TMPDIR/junk.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/junk.json' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/does-not-exist.json' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf '' > "$BATS_TMPDIR/empty.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/empty.json' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "inputs_diff refuses to run without two lock paths" {
  # The callers run under `set -euo pipefail`. Reaching for an unset $1 there
  # is an unbound-variable abort that kills the whole calling script, which is
  # not the exit status this function promises and leaves no useful message.
  run bash -c "set -euo pipefail; inputs_diff 2> '$BATS_TMPDIR/args-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/args-err.txt"
  run bash -c "set -euo pipefail; inputs_diff '$AFTER' 2>/dev/null"
  [ "$status" -eq 1 ]
}

@test "inputs_diff ends its output with a newline" {
  # Same contract as closure_parse: `inputs_diff old new > file` has to leave a
  # well-formed text file and not one that ends mid-line. bats strips the
  # trailing newline from $output, so this has to look at the byte.
  run bash -c "inputs_diff '$AFTER' '$AFTER' | tail -c 1 | od -An -c | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" = '\n' ]
}
