#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/chatgpt.sh"
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/control" "$WORK/bin" "$WORK/repo/pkgs"

  printf 'Package: chatgpt\nVersion: 26.825.31414\nArchitecture: amd64\n' \
    > "$WORK/control/control"
  tar -cJf "$WORK/control.tar.xz" -C "$WORK/control" control
  printf '2.0\n' > "$WORK/debian-binary"
  # The data member is irrelevant to the metadata parser, but a Debian archive
  # must contain it so this fixture catches a parser that accidentally relies
  # on a non-Debian layout.
  tar -cJf "$WORK/data.tar.xz" --files-from /dev/null
  ar r "$WORK/chatgpt.deb" "$WORK/debian-binary" "$WORK/control.tar.xz" "$WORK/data.tar.xz" >/dev/null

  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg.nix" "$WORK/repo/pkgs/chatgpt-desktop.nix"
  cat > "$WORK/bin/nix" <<EOF
#!$BASH
printf '%s\\n' '{"hash":"sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=","storePath":"$WORK/chatgpt.deb"}'
EOF
  chmod +x "$WORK/bin/nix"
  export PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

@test "chatgpt_deb_version reads the official Debian control metadata" {
  run chatgpt_deb_version "$WORK/chatgpt.deb"
  [ "$status" -eq 0 ]
  [ "$output" = "26.825.31414" ]
}

@test "the ChatGPT bump follows a new version and its hash" {
  run bash "${BATS_TEST_DIRNAME}/../bump-chatgpt-desktop.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  jq -e '.name == "chatgpt-desktop" and .from == "1.0.0" and .to == "26.825.31414" and .hash_changed == true' <<<"$output"
  grep -q 'version = "26.825.31414";' "$WORK/repo/pkgs/chatgpt-desktop.nix"
  grep -q 'hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";' "$WORK/repo/pkgs/chatgpt-desktop.nix"
}

@test "a same-version ChatGPT hash refresh is not reported as current" {
  sed -i 's/version = "1.0.0";/version = "26.825.31414";/' "$WORK/repo/pkgs/chatgpt-desktop.nix"

  run bash "${BATS_TEST_DIRNAME}/../bump-chatgpt-desktop.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  jq -e '.from == .to and .hash_changed == true' <<<"$output"
  grep -q 'hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";' "$WORK/repo/pkgs/chatgpt-desktop.nix"
}
