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
