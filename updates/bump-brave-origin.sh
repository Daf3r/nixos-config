#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/brave-origin.nix at the newest brave-origin in Brave's apt index.
#
# No download: the index publishes each file's SHA256 in hex, and `nix hash
# convert` turns that into the SRI form the derivation wants. Fetching the .deb
# only to hash it would cost 130 MB per check for a value already published.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"
# shellcheck source=lib/brave.sh
source "$LIB_DIR/brave.sh"

INDEX_URL="https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-brave-origin: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-brave-origin: --repo is required" >&2; exit 1; }

target="$repo/pkgs/brave-origin.nix"
[ -f "$target" ] || { echo "bump-brave-origin: no $target" >&2; exit 1; }

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
curl -sSL --max-time 120 "$INDEX_URL" > "$index"

latest="$(brave_latest_version < "$index")"
current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"

if [ "$latest" = "$current" ]; then
  echo "brave-origin $current (current)"
  exit 0
fi

hex="$(brave_sha256_for "$latest" < "$index")"
sri="$(nix hash convert --hash-algo sha256 --to sri "$hex")"

nixpin_set "$target" "$latest" "$sri"
echo "brave-origin $current -> $latest"
