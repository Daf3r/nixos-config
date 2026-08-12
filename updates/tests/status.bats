#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/status.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "status_write produces valid json with the envelope fields" {
  run status_write "$WORK/s.json" "ready" '{"changes":[]}'
  [ "$status" -eq 0 ]
  jq -e '.schema == 2' "$WORK/s.json"
  jq -e '.state == "ready"' "$WORK/s.json"
  jq -e '.checked_at | type == "string"' "$WORK/s.json"
}

@test "status_write merges the body in" {
  status_write "$WORK/s.json" "ready" '{"changes":[{"name":"nixpkgs"}]}'
  jq -e '.changes[0].name == "nixpkgs"' "$WORK/s.json"
}

@test "status_write rejects an invalid body and writes nothing" {
  run status_write "$WORK/s.json" "ready" 'not json'
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/s.json" ]
}

@test "status_write rejects a body that is valid JSON but not an object" {
  # `null` is valid JSON, so a check that only guards against parse errors
  # (relying on `jq --argjson` to fail on malformed input) would let this
  # through: `{...} + null` succeeds in jq and evaluates to `{...}`
  # unchanged, silently dropping the caller's body instead of refusing to
  # write. Only an explicit `type == "object"` check catches it. Same for
  # an array or a bare string/number: jq's `+` does error on those, but
  # relying on that incidental failure is not the same contract as
  # validating up front, and `null` is proof the incidental path has a gap.
  run status_write "$WORK/s.json" "ready" 'null'
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/s.json" ]
}

@test "status_write leaves no temp files behind" {
  status_write "$WORK/s.json" "current" '{}'
  [ "$(find "$WORK" -type f | wc -l)" -eq 1 ]
}

@test "status_write creates its temp file beside the target, not in \$TMPDIR" {
  # Spy on mktemp: log the template it was called with, then delegate to the
  # real command. A shell function shadows the external command for any
  # unqualified call made in this shell, including from inside status_write.
  # status_write invokes it inside a `$(...)` command substitution, which
  # runs in a subshell — a variable assignment here would not survive back
  # to this test, so the call is logged to a file instead. This is the test
  # that catches "simplify" regressions such as writing to a bare `mktemp`
  # (which defaults into $TMPDIR) or, worse, dropping the temp file/rename
  # entirely in favor of `jq ... > "$path"`: in that broken version mktemp
  # is never called at all, so the log stays empty and the assertion below
  # fails.
  local calls="$WORK/.mktemp-calls"
  mktemp() {
    echo "$1" >> "$calls"
    command mktemp "$@"
  }

  status_write "$WORK/s.json" "ready" '{}'

  [ -s "$calls" ]
  local captured_template
  captured_template="$(cat "$calls")"
  [ "$(dirname "$captured_template")" = "$(dirname "$WORK/s.json")" ]
}

@test "status_write leaves no temp file behind when rendering the envelope fails" {
  # Force the jq invocation that renders the envelope (the one called with
  # -n) to fail, while leaving the earlier validation call (called with -e)
  # untouched. This simulates a failure between mktemp and mv — the window
  # a missing `rm -f` on the failure path would leak a temp file into $WORK.
  jq() {
    case "$1" in
      -n) return 1 ;;
      *) command jq "$@" ;;
    esac
  }
  export -f jq

  run status_write "$WORK/s.json" "ready" '{}'

  [ "$status" -eq 1 ]
  [ ! -f "$WORK/s.json" ]
  local leftovers
  leftovers="$(find "$WORK" -maxdepth 1 -name '.status.??????')"
  [ -z "$leftovers" ]
}

@test "status_write replaces the target by rename, not by overwriting its content" {
  # The temp-file-location test above only proves *where* the temp file was
  # created; it says nothing about the final step actually being a rename.
  # `cp "$tmp" "$path"` (instead of `mv`) keeps the temp file in the same
  # directory and still gets cleaned up by the RETURN trap, so it would
  # pass every test above — but a reader polling `$path` with a plain
  # `read()` can observe it mid-copy, exactly the half-written window this
  # whole file exists to prevent. A rename swaps the directory entry to a
  # new inode atomically; an in-place overwrite (copy, or truncate-and-
  # write) reuses the old inode. Comparing inodes across two writes catches
  # the difference deterministically, no race needed.
  status_write "$WORK/s.json" "ready" '{"a":1}'
  local inode_before inode_after
  inode_before="$(stat -c %i "$WORK/s.json")"
  status_write "$WORK/s.json" "ready" '{"a":2}'
  inode_after="$(stat -c %i "$WORK/s.json")"
  [ "$inode_before" != "$inode_after" ]
}

@test "status_write fails cleanly instead of aborting a set -e caller when mktemp cannot create a temp file" {
  # Task 7 runs under `set -euo pipefail`. A bare `tmp="$(mktemp ...)"`
  # (no `if !` around it) is a plain command: if mktemp fails, errexit
  # trips right there, and — when status_write is invoked unconditionally,
  # not as the condition of an `if`/`||` — that takes the whole calling
  # script down with only mktemp's raw stderr line, before status_write's
  # own error handling ever runs (confirmed separately: the unguarded
  # version prints just "mktemp: failed to create file..." and nothing
  # else; the guarded version below also prints status_write's own
  # diagnostic first). Point the target at a directory that does not
  # exist so mktemp has nowhere to create the temp file, and require the
  # controlled diagnostic to appear before the process exits.
  run bash -c '
    source "'"${BATS_TEST_DIRNAME}"'/../lib/status.sh"
    status_write "'"$WORK"'/missing-dir/s.json" "ready" "{}"
  '
  [ "$status" -eq 1 ]
  [[ "$output" == *"status_write: could not create a temp file"* ]]
  [ ! -e "$WORK/missing-dir" ]
}

@test "status_write does not let the body override schema, state, or checked_at" {
  # jq's `+` gives the right-hand operand precedence. If the body were on
  # the right (`{schema:...} + $body`), a body carrying its own `schema`,
  # `state`, or `checked_at` key would silently win over the envelope —
  # and the envelope is the only thing a reader (`upd.sh`'s `[ "$schema" =
  # "$SCHEMA" ]` gate, `upd apply`'s `.state == "ready"` gate) can trust. A
  # body is caller-supplied data; it must never be able to forge the contract.
  status_write "$WORK/s.json" "ready" '{"schema":99,"state":"pwned","checked_at":"nope","x":1}'
  jq -e '.schema == 2' "$WORK/s.json"
  jq -e '.state == "ready"' "$WORK/s.json"
  jq -e '.checked_at != "nope"' "$WORK/s.json"
  jq -e '.x == 1' "$WORK/s.json"
}

@test "status_write writes the requested state, not just whatever the caller happened to pass in the other tests" {
  # Every other test in this file passes "ready", so a `status_write` that
  # ignored $state entirely and hardcoded "ready" into the envelope would
  # pass all of them. Use a different state and check it lands verbatim.
  status_write "$WORK/s.json" "build_failed" '{}'
  jq -e '.state == "build_failed"' "$WORK/s.json"
}

@test "status_write still refuses a body that would forge the envelope" {
  # The envelope must win over the body -- unchanged from schema 1, retested
  # because the schema bump touches that exact jq expression. The test above
  # forges all three envelope keys at once; this one forges the schema with a
  # *plausible* neighbouring value and a state a reader acts on differently,
  # which is the shape a producer bug would really take.
  status_write "$WORK/s.json" "ready" '{"schema":99,"state":"current"}'
  jq -e '.schema == 2 and .state == "ready"' "$WORK/s.json"
}

@test "status_write refuses to write when the target path already exists as a directory" {
  # mktemp's template only needs $path's *parent* to exist, so mktemp
  # itself would succeed. But `mv "$tmp" "$path"` on a directory target
  # moves the temp file *into* that directory instead of replacing it —
  # silent "success" with nothing at the path a reader is polling, the
  # worst failure mode for the engine's only output surface.
  mkdir -p "$WORK/s.json"
  run status_write "$WORK/s.json" "ready" '{}'
  [ "$status" -eq 1 ]
  [ -d "$WORK/s.json" ]
  [ -z "$(find "$WORK/s.json" -mindepth 1)" ]
}
