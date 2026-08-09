#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/nixpin.sh"
  WORK="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg.nix" "$WORK/pkg.nix"
}

teardown() {
  rm -rf "$WORK"
}

@test "nixpin_set rewrites both version and hash" {
  run nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 0 ]
  grep -q 'version = "2.0.0";' "$WORK/pkg.nix"
  grep -q 'hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";' "$WORK/pkg.nix"
}

@test "nixpin_set leaves the rest of the file alone" {
  nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  grep -q 'url = "https://example.invalid/thing-\${version}.deb";' "$WORK/pkg.nix"
}

@test "nixpin_set rejects a non-SRI hash and changes nothing" {
  before="$(cat "$WORK/pkg.nix")"
  run nixpin_set "$WORK/pkg.nix" "2.0.0" "deadbeef"
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/pkg.nix")" = "$before" ]
}

@test "nixpin_set fails on a missing file" {
  run nixpin_set "$WORK/nope.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 1 ]
}

@test "nixpin_set fails atomically when the hash line is missing" {
  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg-nohash.nix" "$WORK/nohash.nix"
  before="$(cat "$WORK/nohash.nix")"
  run nixpin_set "$WORK/nohash.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/nohash.nix")" = "$before" ]
}

@test "nixpin_set preserves the file mode on success" {
  chmod 644 "$WORK/pkg.nix"
  nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$(stat -c '%a' "$WORK/pkg.nix")" = "644" ]
}

@test "nixpin_set creates its temp file beside the target, not in \$TMPDIR" {
  # Spy on mktemp: log the template it was called with, then delegate to the
  # real command. A shell function shadows the external command for any
  # unqualified call made in this shell, including from inside nixpin_set.
  # nixpin_set invokes it inside a `$(...)` command substitution, which runs
  # in a subshell — a variable assignment here would not survive back to
  # this test, so the call is logged to a file instead.
  local calls="$WORK/.mktemp-calls"
  mktemp() {
    echo "$1" >> "$calls"
    command mktemp "$@"
  }

  nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="

  [ -s "$calls" ]
  local captured_template
  captured_template="$(cat "$calls")"
  [ "$(dirname "$captured_template")" = "$(dirname "$WORK/pkg.nix")" ]
}

@test "nixpin_set leaves no temp file behind when the substitution fails" {
  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg-nohash.nix" "$WORK/nohash.nix"
  run nixpin_set "$WORK/nohash.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 1 ]
  local leftovers
  leftovers="$(find "$WORK" -maxdepth 1 -name 'nohash.nix.??????')"
  [ -z "$leftovers" ]
}
