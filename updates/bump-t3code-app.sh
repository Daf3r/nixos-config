#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/t3code-app.nix at the newest t3code release.
#
# GitHub publishes no checksum for release assets, so unlike brave-origin this
# has to prefetch the AppImage to learn its hash. That only happens when the
# version actually moved.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"
# shellcheck source=lib/t3code.sh
source "$LIB_DIR/t3code.sh"

API="https://api.github.com/repos/pingdotgg/t3code/releases/latest"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-t3code-app: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-t3code-app: --repo is required" >&2; exit 1; }

target="$repo/pkgs/t3code-app.nix"
[ -f "$target" ] || { echo "bump-t3code-app: no $target" >&2; exit 1; }

latest="$(curl -sSL --max-time 60 "$API" | t3code_latest_version)"
current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"

if [ "$latest" = "$current" ]; then
  echo "t3code-app $current (current)"
  exit 0
fi

url="https://github.com/pingdotgg/t3code/releases/download/v${latest}/T3-Code-${latest}-x86_64.AppImage"
sri="$(nix store prefetch-file --json "$url" | jq -er '.hash')"

nixpin_set "$target" "$latest" "$sri"
echo "t3code-app $current -> $latest"
