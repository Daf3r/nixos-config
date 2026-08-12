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
  TYPECHANGE="${BATS_TEST_DIRNAME}/fixtures/lock-typechange.json"
  NESTED="${BATS_TEST_DIRNAME}/fixtures/lock-follows-nested.json"
  SELFNAME="${BATS_TEST_DIRNAME}/fixtures/lock-follows-selfname.json"
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

@test "inputs_diff resolves a follows path from the root, not from where the walk is standing" {
  # EVERY follows path in a flake.lock is relative to the root node, including
  # the ones written inside an internal node. This repo's own lock has two:
  # `dms.inputs.nixpkgs = ["nixpkgs"]` and the same under home-manager, and
  # both mean the ROOT's nixpkgs -- read relative to their own node they would
  # be circular.
  #
  # lock-follows.json cannot catch a walk that forgets this, because every
  # segment there resolves straight to a string. This fixture is the shape that
  # does, and it is real `nix flake lock` output for
  # `inputs.depB.inputs.inner.follows = "pin"` plus
  # `inputs.deepA.follows = "depB/inner"`:
  #
  #   root:  {"deepA": ["depB","inner"], "depB": "depB", "pin": "pin_2"}
  #   depB:  {"inner": ["pin"], "pin": "pin"}
  #
  # `deepA` walks to depB, finds `inner` is itself a follows path, and that
  # path is root-relative: root's `pin` is node `pin_2`. Resolving it against
  # depB instead lands on depB's own `pin`, which is node `pin` -- a DIFFERENT
  # repository with a different rev, and no error anywhere. The two leaf repos
  # were given different content on purpose so the wrong answer is a wrong rev
  # and not a coincidence.
  #
  # So: move node `pin_2` and `deepA` has to move with it.
  jq '.nodes.pin_2.locked.rev = "9999999999999999999999999999999999999999"' "$NESTED" > "$BATS_TMPDIR/nested-moved.json"
  run bash -c "inputs_diff '$NESTED' '$BATS_TMPDIR/nested-moved.json' | jq -e 'map(.name) == [\"deepA\",\"pin\"] and (.[0] | .from == \"37c5755\" and .to == \"9999999\")'"
  [ "$status" -eq 0 ]
  # And the mirror: moving node `pin` -- depB's own, the one the wrong
  # resolution would pick -- must move nothing at the root at all.
  jq '.nodes.pin.locked.rev = "8888888888888888888888888888888888888888"' "$NESTED" > "$BATS_TMPDIR/nested-other.json"
  run bash -c "inputs_diff '$NESTED' '$BATS_TMPDIR/nested-other.json' | jq -e '. == []'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff terminates on a follows segment named after a root input" {
  # The same root-relative rule, in the form that does not merely give a wrong
  # answer. Real `nix flake lock` output for
  # `inputs.depB.inputs.pin.follows = "pin"` plus
  # `inputs.deepB.follows = "depB/pin"`:
  #
  #   root:  {"deepB": ["depB","pin"], "depB": "depB", "pin": "pin"}
  #   depB:  {"inner": "inner", "pin": ["pin"]}
  #
  # A walk that resolves `["pin"]` against depB looks up depB's `pin`, which is
  # `["pin"]` again, and recurses forever -- measured as jq exhausting memory,
  # inside a systemd unit. Nothing about this is exotic: the collision is only
  # that a segment shares a name with a root input, and
  # `dms.inputs.nixpkgs = ["nixpkgs"]` is already in this repo's lock, one
  # top-level `inputs.X.follows = "dms/nixpkgs"` away from being reached.
  #
  # The address-space cap is the point of the test: without it a regression
  # here does not fail, it hangs and eats the machine. 512 MB is far above what
  # the correct walk needs and far below what the runaway wants.
  jq '.nodes.pin.locked.rev = "7777777777777777777777777777777777777777"' "$SELFNAME" > "$BATS_TMPDIR/selfname-moved.json"
  run bash -c "ulimit -v 524288; inputs_diff '$SELFNAME' '$BATS_TMPDIR/selfname-moved.json' | jq -e 'map(.name) == [\"deepB\",\"pin\"]'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff refuses a root input pointing at a node the lock does not have" {
  # A dangling node key reads as "no rev", the empty-rev filter drops it, and
  # the input silently vanishes from the report: five names become four and the
  # exit status stays 0. That is the same silence the no-root-inputs guard
  # exists to refuse, so it gets the same treatment rather than an exception
  # nobody could see.
  jq '.nodes[.root].inputs.nixpkgs = "nixpkgs_99"' "$AFTER" > "$BATS_TMPDIR/dangling.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/dangling.json' 2> '$BATS_TMPDIR/dangling-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/dangling-err.txt"
  grep -q 'nixpkgs_99' "$BATS_TMPDIR/dangling-err.txt"
  # A reference that is neither a node key nor a follows path is the same class
  # of unreadable lock and gets the same refusal, rather than being carried
  # along to fail as something more confusing further down.
  jq '.nodes[.root].inputs.nixpkgs = 42' "$AFTER" > "$BATS_TMPDIR/notaref.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/notaref.json' 2> '$BATS_TMPDIR/notaref-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/notaref-err.txt"
}

@test "inputs_diff names the segment when a follows path leads nowhere" {
  # A segment that does not exist already fails -- null is neither a node key
  # nor a path, so it lands in the catch-all refusal. Status and silence are
  # identical either way, measured, which is exactly why this asserts on the
  # message: without the specific guard the operator gets
  # "an input reference that is neither a node key nor a follows path: null",
  # which does not say which path, which node, or which segment. A corrupt lock
  # is the one moment that message has a job to do.
  jq '.nodes.depB.inputs.inner = ["noexiste"]' "$NESTED" > "$BATS_TMPDIR/badseg.json"
  run bash -c "inputs_diff '$BATS_TMPDIR/badseg.json' '$BATS_TMPDIR/badseg.json' 2> '$BATS_TMPDIR/badseg-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/badseg-err.txt"
  grep -q 'noexiste' "$BATS_TMPDIR/badseg-err.txt"
}

@test "inputs_diff does not report an input that has no rev on either side" {
  # Not every input type carries a rev. `local` in lock-follows.json is a real
  # `path:` input as nix locked it: narHash and lastModified, no rev at all.
  #
  # This is the harmless half and the name says so: revless on both sides
  # compares equal to itself and drops out through the equality filter alone.
  # It holds with the `// ""` fallback deleted, measured, so it is NOT what
  # pins that fallback -- the test below it is. What this one pins is that a
  # revless input never reaches the bar at all, in either shape.
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

@test "inputs_diff skips an input that had a rev on one side and none on the other" {
  # The case above is the harmless half -- revless on BOTH sides compares equal
  # to itself and drops out for free, so it holds with the rev fallback deleted
  # and with the empty-rev filter deleted. Measured: both mutations survive it.
  #
  # This is the half that bites, and it is one edit away in any flake: point an
  # input at a local checkout and its type changes from git to path, which
  # takes the rev with it. Both fixtures here are real `nix flake lock` output
  # for exactly that pair of flakes, with only the file:// URLs shortened.
  #
  # There is no honest row to print. `from` is a rev and `to` is not a thing.
  # Drop the `// ""` fallback and it prints `to: null`; drop the filter that
  # rejects the empty side and it prints `to: ""`. Both were measured, and both
  # are a plausible-looking input name in the panel with garbage beside it.
  run bash -c "inputs_diff '$FOLLOWS' '$TYPECHANGE' | jq -e '. == []'"
  [ "$status" -eq 0 ]
  # And in reverse: the input gains a rev rather than losing one.
  run bash -c "inputs_diff '$TYPECHANGE' '$FOLLOWS' | jq -e '. == []'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff skips an input that disappeared from the new side" {
  # The mirror of the added case, and it fails differently: names are collected
  # from the OLD lock, so an input missing from the new side is looked up there
  # and comes back null. null is not equal to the old rev and null is not equal
  # to "" either, so it sails through both filters and prints as moved, with
  # `to` as a JSON null. Measured on this fixture pair.
  #
  # Real inputs do get removed -- `zen` was dropped from this very flake in
  # ab10238 -- and a removal is not a move. Same reasoning as the added case:
  # the panel is a list of what moved, and a half-empty row is worse than no
  # row at all.
  #
  # A real move is forced alongside so the assertion is not one an
  # always-empty function could pass: the mover has to be named and the two
  # departed inputs have to not be.
  jq '.nodes.nixpkgs_3.locked.rev = "4444444444444444444444444444444444444444"' "$BEFORE" > "$BATS_TMPDIR/moved-before.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/moved-before.json' | jq -e 'map(.name) == [\"nixpkgs\"]'"
  [ "$status" -eq 0 ]
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
  # The missing file gets its own check before jq is reached, purely so the
  # message names this function: jq calls it `Bad JSON in --slurpfile old ...`,
  # which names neither. A lock that is not there yet is the ordinary first-run
  # case, so it is the message someone will actually read.
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/does-not-exist.json' 2> '$BATS_TMPDIR/missing-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'inputs_diff' "$BATS_TMPDIR/missing-err.txt"
  grep -q 'does-not-exist.json' "$BATS_TMPDIR/missing-err.txt"
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
