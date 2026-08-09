#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/t3code.sh"
  # Each test below runs its command via `bash -c`, a fresh subshell that
  # does not inherit plain shell functions from this bats process — only
  # exported ones. Without this, every call below would fail with
  # "command not found" (exit 127) regardless of t3code.sh's correctness,
  # and a test asserting failure (status -eq 1) would pass vacuously.
  export -f t3code_latest_version
  FIX="${BATS_TEST_DIRNAME}/fixtures/t3code-release.json"
}

@test "t3code_latest_version strips the leading v from the tag" {
  run bash -c "t3code_latest_version < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "0.0.34" ]
}

@test "t3code_latest_version fails when there is no tag" {
  run bash -c "echo '{}' | t3code_latest_version"
  [ "$status" -eq 1 ]
}

@test "t3code_latest_version fails on invalid json" {
  run bash -c "echo 'not json' | t3code_latest_version"
  [ "$status" -eq 1 ]
}
