#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/closure.sh"
  # Every case below drives the function through `run bash -c`, to pin stdin
  # and the exit status independently of the bats shell. A child bash does not
  # inherit shell functions, so it has to be exported -- same as brave.bats
  # and t3code.bats.
  export -f closure_parse
  FIX="${BATS_TEST_DIRNAME}/fixtures/diff-closures.txt"
}

@test "closure_parse classifies an addition" {
  run bash -c "closure_parse < '$FIX' | jq -e '.added[] | select(.name==\"somethingnew\") | .to == \"1.2.3\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse classifies a removal" {
  # A removal is the shape that matters most: it is how the 2026-08-11 diff
  # announced that applying would delete dms-shell. If it were misfiled as a
  # change, the panel would show a version bump where a package disappears.
  printf 'gone: 1.0 → \xe2\x88\x85, -1.0 MiB\n' > "$BATS_TMPDIR/one.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/one.txt' | jq -e '.removed[0].name == \"gone\" and .removed[0].from == \"1.0\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse keeps the last comma field as size, not as a version" {
  # `multiver: 1.0, 1.0-fish → 2.0, 2.0-fish, 1.5 MiB` — versions are comma
  # separated and so is the size. Treating the trailing size as a version is
  # the obvious wrong parse.
  run bash -c "closure_parse < '$FIX' | jq -e '.changed[] | select(.name==\"multiver\") | .to == \"2.0, 2.0-fish\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse handles a line with a size and no versions" {
  run bash -c "closure_parse < '$FIX' | jq -e '.changed[] | select(.name==\"kitty\") | .from == \"\" and .to == \"\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse counts the size of a line that has no versions" {
  # `kitty: 51.2 KiB` -- same version string, different closure -- is a real
  # shape and carries a real size. Identifying the size only by a leading
  # comma silently drops every one of them: on the 2026-08-11 diff that is
  # 2.56 of 8.88 MB gone, and the bar would report 6.33 as if it were the
  # whole delta.
  printf 'kitty: 1024.0 KiB\n' > "$BATS_TMPDIR/nover.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/nover.txt' | jq -e '.size_delta_mb == 1'"
  [ "$status" -eq 0 ]
}

@test "closure_parse sums sizes across units into MB" {
  printf 'a: 1 → 2, 1.0 MiB\nb: 1 → 2, 1024.0 KiB\nc: 1 → 2, -0.5 MiB\n' > "$BATS_TMPDIR/sizes.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/sizes.txt' | jq -e '.size_delta_mb > 1.49 and .size_delta_mb < 1.51'"
  [ "$status" -eq 0 ]
}

@test "closure_parse refuses input it could not parse at all" {
  # Silence is the failure mode this whole engine exists to remove. If a future
  # nix changes the format, an empty closure_diff would render as "nothing
  # changed" in the bar. It must be an error the caller can turn into a warning.
  printf 'this is not a diff\nnor is this\n' > "$BATS_TMPDIR/junk.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/junk.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "closure_parse on empty input is an empty diff, not an error" {
  run bash -c ": | closure_parse | jq -e '.added == [] and .removed == [] and .changed == [] and .size_delta_mb == 0'"
  [ "$status" -eq 0 ]
}
