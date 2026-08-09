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

@test "brave_sha256_for returns the hex hash of the requested version" {
  run bash -c "brave_sha256_for 1.93.132 < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "e77a5cef4f7801acbd88087119d85c5d4f0f96d4402f4d699a66f681ad01e828" ]
}

@test "brave_sha256_for returns brave-origin's hash, not brave-browser's, for a version both packages have" {
  # The fixture gives brave-browser its own stanza at 1.93.134, positioned
  # *before* brave-origin's 1.93.134 stanza, and 1.93.134 is not the first
  # brave-origin stanza either. This single case guards two failure modes at
  # once: a filter that matches "Package: " instead of "Package: brave-origin"
  # (would return brave-browser's hash, ba17704c...), and an association bug
  # that returns whichever stanza's hash it saw first regardless of the
  # requested version (would return 1.93.132's hash, e77a5cef...).
  run bash -c "brave_sha256_for 1.93.134 < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "288b8f3c875bcd855dfd1127fd8559d7e09522277cfd569e3fb2d44e106ec532" ]
}

@test "brave_sha256_for returns the correct hash for a later, non-first version" {
  run bash -c "brave_sha256_for 1.92.144 < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "2222222222222222222222222222222222222222222222222222222222222222" ]
}

@test "brave_sha256_for fails for a version that only exists under a different package" {
  # 1.93.140 exists in the fixture, but only as brave-browser.
  run bash -c "brave_sha256_for 1.93.140 < '$FIX'"
  [ "$status" -eq 1 ]
}

@test "brave_sha256_for fails for a version that is not there" {
  run bash -c "brave_sha256_for 9.9.9 < '$FIX'"
  [ "$status" -eq 1 ]
}

@test "brave_latest_version fails on empty input" {
  run bash -c "brave_latest_version < /dev/null"
  [ "$status" -eq 1 ]
}
