#!/usr/bin/env bash
set -euo pipefail

# Update the Claude Desktop override in pkgs/claude-desktop-newer.nix. The flake
# input pins an old build, so the override is the one that ships. The version
# comes from Anthropic's apt index, the newest `claude-desktop` stanza, and the
# hash comes from the same stanza, checked against a real download of the .deb.
# Nothing is written unless both agree. The index is never allowed to move the
# pin backwards: a lagging mirror must not turn an installed version into a
# downgrade.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"

INDEX_URL="https://downloads.claude.ai/claude-desktop/apt/stable/dists/stable/main/binary-amd64/Packages"
POOL_URL="https://downloads.claude.ai/claude-desktop/apt/stable/"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-claude-desktop: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-claude-desktop: --repo is required" >&2; exit 1; }

target="$repo/pkgs/claude-desktop-newer.nix"
[ -f "$target" ] || { echo "bump-claude-desktop: no $target" >&2; exit 1; }

current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"
current_hash="$(sed -n 's/^ *hash = "\(sha256-[^"]*\)";/\1/p' "$target" | head -n1)"

# One line per claude-desktop stanza: version, filename, sha256 (hex). The
# stanzas are separated by blank lines; RS= makes awk read them whole.
stanzas="$(curl -sSfL --max-time 60 "$INDEX_URL" | awk -v RS= -v FS='\n' '
  {
    pkg = ""; ver = ""; file = ""; sha = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^Package: /)  pkg  = substr($i, 10)
      if ($i ~ /^Version: /)  ver  = substr($i, 10)
      if ($i ~ /^Filename: /) file = substr($i, 11)
      if ($i ~ /^SHA256: /)   sha  = substr($i, 9)
    }
    if (pkg == "claude-desktop" && ver != "" && file != "" && sha != "")
      print ver, file, sha
  }')"

[ -n "$stanzas" ] || { echo "bump-claude-desktop: the apt index has no claude-desktop stanza" >&2; exit 1; }

# Newest by version sort, so 2.42304.0 beats 2.37337.1 and the order of the
# index does not matter.
read -r latest filename sha256_hex < <(sort -k1,1V <<<"$stanzas" | tail -n1)

# Refuse to move backwards: keep the pin when the index is behind it.
newest="$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n1)"
if [ "$newest" != "$latest" ]; then
  latest="$current"
  filename=""
fi

hash_changed=false
latest_hash="$current_hash"

if [ -n "$filename" ]; then
  index_hash="$(nix hash convert --hash-algo sha256 --to sri "$sha256_hex")"
  prefetch="$(nix store prefetch-file --json "$POOL_URL$filename")"
  latest_hash="$(jq -er '.hash' <<<"$prefetch")"

  # The index is the reference: a .deb whose bytes differ from what Anthropic
  # published is not written into the pin.
  if [ "$latest_hash" != "$index_hash" ]; then
    echo "bump-claude-desktop: the downloaded $filename hashes to $latest_hash, the index says $index_hash; nothing written" >&2
    exit 1
  fi

  [ "$current_hash" != "$latest_hash" ] && hash_changed=true
fi

if [ "$latest" != "$current" ] || [ "$hash_changed" = true ]; then
  nixpin_set "$target" "$latest" "$latest_hash"
fi

jq -nc \
  --arg f "$current" \
  --arg t "$latest" \
  --arg fh "$current_hash" \
  --arg th "$latest_hash" \
  --argjson hc "$hash_changed" \
  '{name: "claude-desktop", kind: "local_pkg", from: $f, to: $t,
    hash_changed: $hc, from_hash: $fh, to_hash: $th}'
