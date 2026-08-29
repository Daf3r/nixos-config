#!/usr/bin/env bash
set -euo pipefail

# Update the official ChatGPT Linux package. OpenAI publishes one mutable
# `latest` URL, so this checks both the Debian version and the fixed-output hash
# on every run. A same-version hash change is still an update: leaving it
# untouched is exactly what made the old engine fail with `hash mismatch`.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"
# shellcheck source=lib/chatgpt.sh
source "$LIB_DIR/chatgpt.sh"

URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-chatgpt-desktop: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-chatgpt-desktop: --repo is required" >&2; exit 1; }

target="$repo/pkgs/chatgpt-desktop.nix"
[ -f "$target" ] || { echo "bump-chatgpt-desktop: no $target" >&2; exit 1; }

current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"
current_hash="$(sed -n 's/^ *hash = "\(sha256-[^"]*\)";/\1/p' "$target" | head -n1)"
prefetch="$(nix store prefetch-file --json "$URL")"
latest_hash="$(jq -er '.hash' <<<"$prefetch")"
store_path="$(jq -er '.storePath' <<<"$prefetch")"
latest="$(chatgpt_deb_version "$store_path")"

hash_changed=false
[ "$current_hash" != "$latest_hash" ] && hash_changed=true

if [ "$latest" != "$current" ] || [ "$hash_changed" = true ]; then
  nixpin_set "$target" "$latest" "$latest_hash"
fi

jq -nc \
  --arg f "$current" \
  --arg t "$latest" \
  --arg fh "$current_hash" \
  --arg th "$latest_hash" \
  --argjson hc "$hash_changed" \
  '{name: "chatgpt-desktop", kind: "local_pkg", from: $f, to: $t,
    hash_changed: $hc, from_hash: $fh, to_hash: $th}'
