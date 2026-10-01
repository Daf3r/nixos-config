#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/discord-sources.json at the newest stable Discord for Linux.
#
# Why this exists at all: Discord refuses to run a host older than the one its
# servers want, and nixpkgs carries it a few days behind upstream, so the client
# was routinely one release short and asked to be updated (running 1.0.158 with
# 1.0.160 out, on 2026-10-01). The package itself is still nixpkgs' -- see
# pkgs/discord.nix -- and only this one JSON file is ours.
#
# Discord publishes a manifest that already carries every URL and the SHA-256 of
# the host and of each native module, so nothing is downloaded to bump: the
# manifest is the whole check. This is the same API nixpkgs' own update.py reads,
# and it rejects any User-Agent that is not a Discord-Updater one.
#
# Contract, as for the other bump scripts: one JSON object on stdout, moved or
# not; the file is replaced whole or not at all. A manifest that is missing the
# host, a module, or a well-formed hash is refused rather than half-written --
# a new host with the old modules is a client that starts and then cannot join
# a voice channel, which looks exactly like a Discord problem.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"

MANIFEST_URL="https://updates.discord.com/distributions/app/manifests/latest?channel=stable&platform=linux&arch=x64"
USER_AGENT="Discord-Updater/1"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-discord: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-discord: --repo is required" >&2; exit 1; }

target="$repo/pkgs/discord-sources.json"
[ -f "$target" ] || { echo "bump-discord: no $target" >&2; exit 1; }

current="$(jq -er '."linux-stable".version' "$target")"

manifest="$(curl -sSL --max-time 60 -A "$USER_AGENT" "$MANIFEST_URL")"

# Everything the pin needs, checked before anything is computed from it.
# `package_sha256` must be 64 hex digits: it is turned into a Nix hash below,
# and an empty or truncated one would otherwise become a valid-looking hash of
# nothing.
if ! jq -e '
  def hex: type == "string" and test("^[0-9a-f]{64}$");
  (.full.host_version | type == "array" and length == 3 and all(type == "number"))
  and (.full.url | type == "string" and startswith("https://"))
  and (.full.package_sha256 | hex)
  and (.modules | type == "object" and length > 0)
  and all(.modules[];
        (.full.module_version | type == "number")
        and (.full.url | type == "string" and startswith("https://"))
        and (.full.package_sha256 | hex))
' >/dev/null <<<"$manifest"; then
  echo "bump-discord: the manifest is missing the host or a module, or a hash is malformed; $target left as it is" >&2
  exit 1
fi

latest="$(jq -r '.full.host_version | map(tostring) | join(".")' <<<"$manifest")"

if [ "$latest" = "$current" ]; then
  jq -nc --arg f "$current" --arg t "$current" \
    '{name: "discord", kind: "local_pkg", from: $f, to: $t}'
  exit 0
fi

# hex -> SRI for the host and for every module, once each. `nix hash convert` is
# what bump-brave-origin.sh uses for the same job.
sri_map='{}'
while read -r hex; do
  sri="$(nix hash convert --hash-algo sha256 --to sri "$hex")"
  sri_map="$(jq -c --arg h "$hex" --arg s "$sri" '. + {($h): $s}' <<<"$sri_map")"
done < <(jq -r '.full.package_sha256, (.modules[].full.package_sha256)' <<<"$manifest" | sort -u)

# Same shape and key order as nixpkgs' sources.json, restricted to the one
# variant this machine installs. metadata.nix indexes it as "linux-stable".
tmp="$(mktemp "$target.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

jq --argjson sri "$sri_map" --arg version "$latest" '
  {"linux-stable": {
    distro: {hash: $sri[.full.package_sha256], url: .full.url},
    kind: "distro",
    modules: (.modules | with_entries({key, value: {
      hash: $sri[.value.full.package_sha256],
      url: .value.full.url,
      version: .value.full.module_version}})),
    version: $version}}
' <<<"$manifest" > "$tmp"

# Read it back before replacing anything: version present, every hash an SRI.
jq -e --arg v "$latest" '
  ."linux-stable" as $s
  | $s.version == $v
  and ($s.distro.hash | startswith("sha256-"))
  and all($s.modules[]; .hash | startswith("sha256-"))
' "$tmp" >/dev/null || { echo "bump-discord: the rewritten pin did not read back; $target left as it is" >&2; exit 1; }

chmod --reference="$target" "$tmp"
mv "$tmp" "$target"
trap - EXIT

jq -nc --arg f "$current" --arg t "$latest" \
  '{name: "discord", kind: "local_pkg", from: $f, to: $t}'
