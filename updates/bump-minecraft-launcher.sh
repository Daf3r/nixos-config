#!/usr/bin/env bash
set -euo pipefail

# Mojang's Linux download is a mutable bootstrap archive and does not expose a
# stable release API. The launcher core updates itself after installation, but
# the Nix fixed-output pin still has to follow changes to that bootstrap. This
# detector therefore reports and repairs source-hash drift even when the
# package's bootstrap version field stays the same.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"

URL="https://launcher.mojang.com/download/Minecraft.tar.gz"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-minecraft-launcher: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-minecraft-launcher: --repo is required" >&2; exit 1; }

target="$repo/pkgs/minecraft-launcher.nix"
[ -f "$target" ] || { echo "bump-minecraft-launcher: no $target" >&2; exit 1; }

current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"
current_hash="$(sed -n 's/^ *hash = "\(sha256-[^"]*\)";/\1/p' "$target" | head -n1)"
latest_hash="$(nix store prefetch-file --json "$URL" | jq -er '.hash')"
hash_changed=false
[ "$current_hash" != "$latest_hash" ] && hash_changed=true

if [ "$hash_changed" = true ]; then
  nixpin_set "$target" "$current" "$latest_hash"
fi

jq -nc \
  --arg f "$current" \
  --arg t "$current" \
  --arg fh "$current_hash" \
  --arg th "$latest_hash" \
  --argjson hc "$hash_changed" \
  '{name: "minecraft-launcher", kind: "local_pkg", from: $f, to: $t,
    hash_changed: $hc, from_hash: $fh, to_hash: $th}'
