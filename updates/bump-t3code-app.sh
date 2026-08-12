#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/t3code-app.nix at the newest t3code release.
#
# This prefetches the AppImage to learn its hash, which costs ~160 MB on every
# bump. That is NOT because no checksum is published -- an earlier version of
# this comment claimed GitHub publishes none, and acting on that belief is what
# the download costs. electron-builder attaches `latest-linux.yml` to every
# release alongside the AppImage, and it carries the asset's sha512 in base64:
#
#   version: 0.0.32
#   files:
#     - url: T3-Code-0.0.32-x86_64.AppImage
#       sha512: Fw0jT37GHjlS1UVI1VVgP06WLGCvy9TJh4VyQPME2TLO0rV9gkqLC/Gw3suiiPRjLNeBgnPR3tt+vGZKvwRj2Q==
#
# `sha512-` + that base64 is already a valid Nix SRI string, so no conversion is
# needed either -- the yml is a few hundred bytes and would replace the whole
# download, exactly as brave-origin uses the apt index's published SHA256.
#
# It is not used yet because the pin writer cannot accept it: nixpin_set rejects
# any hash that does not start with `sha256-`, and its sed only rewrites lines
# matching `hash = "sha256-…";`, so handing it a sha512 SRI fails the guard and,
# if the guard were removed, would substitute nothing. Teaching nixpin_set the
# other algorithms is the change this wants, and it is not a comment fix.
#
# The prefetch only happens when the version actually moved.

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

# One JSON object on stdout, moved or not; see the same block in
# bump-brave-origin.sh for why this is not prose any more.
if [ "$latest" = "$current" ]; then
  jq -nc --arg f "$current" --arg t "$current" \
    '{name: "t3code-app", kind: "local_pkg", from: $f, to: $t}'
  exit 0
fi

url="https://github.com/pingdotgg/t3code/releases/download/v${latest}/T3-Code-${latest}-x86_64.AppImage"
sri="$(nix store prefetch-file --json "$url" | jq -er '.hash')"

nixpin_set "$target" "$latest" "$sri"
jq -nc --arg f "$current" --arg t "$latest" \
  '{name: "t3code-app", kind: "local_pkg", from: $f, to: $t}'
