#!/usr/bin/env bats

# bump-claude-desktop reads Anthropic's apt index and prefetches the .deb. Both
# are stubbed here: curl serves the fixture index, and nix answers
# `hash convert` and `store prefetch-file` from environment variables. Nothing
# touches the network.

SRI_INDEX="sha256-dM0szCnSQWUUTkVcvIcsbMKiSiY7g+c0IOlfiRZtSqQ="
SRI_OLD="sha256-QXRbCRTw/1FjGh/xu0A7g2v1yZWEXMpnQt05vKOi2hQ="

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/repo/pkgs"

  # The shape of pkgs/claude-desktop-newer.nix as it is on disk: the bump has to
  # find `version =` and the fetchurl `hash =` lines, and leave `url` alone.
  cat > "$WORK/repo/pkgs/claude-desktop-newer.nix" <<EOF
claude-desktop.overrideAttrs (o: rec {
  version = "2.37337.1";
  buildInputs = o.buildInputs ++ [ pipewire ];
  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_\${version}_amd64.deb";
    hash = "$SRI_OLD";
  };
})
EOF

  cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$CD_INDEX"
EOF
  cat > "$WORK/bin/nix" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  hash) printf '%s\n' "$CD_SRI_INDEX" ;;
  store) printf '{"hash":"%s","storePath":"/nix/store/fake.deb"}\n' "$CD_PREFETCH" ;;
  *) echo "unexpected nix call: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$WORK/bin/curl" "$WORK/bin/nix"

  export PATH="$WORK/bin:$PATH"
  export CD_INDEX="${BATS_TEST_DIRNAME}/fixtures/claude-desktop-packages.txt"
  export CD_SRI_INDEX="$SRI_INDEX"
  export CD_PREFETCH="$SRI_INDEX"
}

teardown() {
  rm -rf "$WORK"
}

@test "the bump takes the newest claude-desktop stanza, not the first one in the index" {
  run bash "${BATS_TEST_DIRNAME}/../bump-claude-desktop.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  jq -e '.name == "claude-desktop" and .from == "2.37337.1" and .to == "2.42304.0" and .hash_changed == true' <<<"$output"
  grep -q 'version = "2.42304.0";' "$WORK/repo/pkgs/claude-desktop-newer.nix"
  grep -q "hash = \"$SRI_INDEX\";" "$WORK/repo/pkgs/claude-desktop-newer.nix"
}

@test "the bump changes only the version and hash lines, and the url stays derived from version" {
  cp "$WORK/repo/pkgs/claude-desktop-newer.nix" "$WORK/orig.nix"

  run bash "${BATS_TEST_DIRNAME}/../bump-claude-desktop.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  changed="$(diff "$WORK/orig.nix" "$WORK/repo/pkgs/claude-desktop-newer.nix" | grep -c '^[<>]')"
  [ "$changed" -eq 4 ]
  grep -q 'claude-desktop_${version}_amd64.deb' "$WORK/repo/pkgs/claude-desktop-newer.nix"
}

@test "an index behind the pin never moves the pin backwards" {
  sed -i 's/version = "2.37337.1";/version = "2.42304.0";/' "$WORK/repo/pkgs/claude-desktop-newer.nix"
  before="$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")"

  # Replace the index with one that only knows 2.37337.1.
  head -n 7 "$CD_INDEX" > "$WORK/old-index.txt"
  export CD_INDEX="$WORK/old-index.txt"

  run bash "${BATS_TEST_DIRNAME}/../bump-claude-desktop.sh" --repo "$WORK/repo"
  [ "$status" -eq 0 ]
  jq -e '.from == "2.42304.0" and .to == "2.42304.0" and .hash_changed == false' <<<"$output"
  [ "$before" = "$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")" ]
}

@test "a .deb whose hash differs from the index is not written into the pin" {
  export CD_PREFETCH="sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  before="$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")"

  run bash "${BATS_TEST_DIRNAME}/../bump-claude-desktop.sh" --repo "$WORK/repo"
  [ "$status" -ne 0 ]
  [[ "$output" != *'"name"'* ]]
  [ "$before" = "$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")" ]
}

@test "an index with no claude-desktop stanza fails instead of writing anything" {
  grep -v '^Package: claude-desktop' "$CD_INDEX" > "$WORK/no-cd.txt"
  export CD_INDEX="$WORK/no-cd.txt"
  before="$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")"

  run bash "${BATS_TEST_DIRNAME}/../bump-claude-desktop.sh" --repo "$WORK/repo"
  [ "$status" -ne 0 ]
  [ "$before" = "$(cat "$WORK/repo/pkgs/claude-desktop-newer.nix")" ]
}
