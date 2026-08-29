#!/usr/bin/env bats

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/repo/pkgs"
  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg.nix" "$WORK/repo/pkgs/minecraft-launcher.nix"
  cat > "$WORK/bin/nix" <<'EOF'
#!BASH_PLACEHOLDER
printf '%s\n' '{"hash":"sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}'
EOF
  sed -i "1s|#!BASH_PLACEHOLDER|#!$BASH|" "$WORK/bin/nix"
  chmod +x "$WORK/bin/nix"
  export PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

@test "the Minecraft bootstrap hash drift is reported and pinned" {
  run bash "${BATS_TEST_DIRNAME}/../bump-minecraft-launcher.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  jq -e '.name == "minecraft-launcher" and .from == .to and .hash_changed == true' <<<"$output"
  grep -q 'hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";' "$WORK/repo/pkgs/minecraft-launcher.nix"
}
