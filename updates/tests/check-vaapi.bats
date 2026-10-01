#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-brave-vaapi.sh"
  WORK="$(mktemp -d)"
  # A stand-in "binary": `strings` reads any file, so a text file works.
  printf 'AcceleratedVideoDecodeLinuxGL\nVaapiOnNvidiaGPUs\nVaapiIgnoreDriverChecks\n' \
    > "$WORK/good"
  printf 'AcceleratedVideoDecodeLinuxGL\nVaapiIgnoreDriverChecks\n' > "$WORK/missing-one"
}

teardown() {
  rm -rf "$WORK"
}

@test "reports nothing when every feature name is present" {
  run bash "$SCRIPT" "$WORK/good"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "reports the name that is absent" {
  run bash "$SCRIPT" "$WORK/missing-one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing: VaapiOnNvidiaGPUs"* ]]
}

# Chromium stopped embedding the plain feature name around Brave 1.94 and keeps
# only the C++ identifier, `k<Name>`; the runtime name is that string minus the
# leading `k`. Measured on 1.93.136 vs 1.96.59: SkiaGraphite, OverlayScrollbar,
# ParallelDownloading and the three VA-API names all went from `Name` to
# `kName`. Reading only the plain form made every check since then warn that
# all three features were missing while they were there.
@test "accepts the k-prefixed identifier Chromium embeds in newer builds" {
  printf 'kAcceleratedVideoDecodeLinuxGL\nkVaapiOnNvidiaGPUs\nkVaapiIgnoreDriverChecks\n' \
    > "$WORK/k-form"
  run bash "$SCRIPT" "$WORK/k-form"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "still reports a name when neither the plain nor the k form is present" {
  printf 'kAcceleratedVideoDecodeLinuxGL\nkVaapiIgnoreDriverChecks\nVaapiOnNvidiaGPUsRenamed\n' \
    > "$WORK/k-missing-one"
  run bash "$SCRIPT" "$WORK/k-missing-one"
  [ "$status" -eq 0 ]
  [ "$output" = "missing: VaapiOnNvidiaGPUs" ]
}

@test "exits 0 even when names are missing, so it never blocks an update" {
  run bash "$SCRIPT" "$WORK/missing-one"
  [ "$status" -eq 0 ]
}

@test "fails loudly when the binary does not exist" {
  run bash "$SCRIPT" "$WORK/nope"
  [ "$status" -eq 1 ]
}

@test "the hardcoded name list still matches pkgs/brave-origin.nix" {
  nixfile="${BATS_TEST_DIRNAME}/../../pkgs/brave-origin.nix"
  for name in AcceleratedVideoDecodeLinuxGL VaapiOnNvidiaGPUs VaapiIgnoreDriverChecks; do
    grep -q "\"$name\"" "$nixfile"
  done
  # And the reverse: no feature was added to the derivation without being added
  # here, which would leave it unverified.
  count="$(sed -n '/enableFeatures =/,/++ lib.optional enableVulkan/p' "$nixfile" \
    | grep -cE '^\s+"[A-Za-z0-9]+"')"
  [ "$count" -eq 3 ]
}
