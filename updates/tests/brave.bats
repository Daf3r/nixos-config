#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/brave.sh"
  # Each test below runs its command via `bash -c`, a fresh subshell that
  # does not inherit plain shell functions from this bats process — only
  # exported ones. Without this, every call below would fail with
  # "command not found" (exit 127) regardless of brave.sh's correctness.
  export -f brave_latest_version brave_sha256_for
  FIX="${BATS_TEST_DIRNAME}/fixtures/brave-packages.txt"
}

@test "brave_latest_version picks the highest version, not the first listed" {
  run bash -c "brave_latest_version < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "1.93.134" ]
}

@test "brave_latest_version ignores the brave-browser package" {
  run bash -c "brave_latest_version < '$FIX'"
  [ "$output" != "1.93.140" ]
}

@test "brave_sha256_for returns the hex hash of the requested version" {
  run bash -c "brave_sha256_for 1.93.132 < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "e77a5cef4f7801acbd88087119d85c5d4f0f96d4402f4d699a66f681ad01e828" ]
}

@test "brave_sha256_for fails for a version that is not there" {
  run bash -c "brave_sha256_for 9.9.9 < '$FIX'"
  [ "$status" -eq 1 ]
}

@test "brave_latest_version fails on empty input" {
  run bash -c "brave_latest_version < /dev/null"
  [ "$status" -eq 1 ]
}
