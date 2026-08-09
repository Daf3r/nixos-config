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
  jq -e '.schema == 1' "$WORK/s.json"
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
