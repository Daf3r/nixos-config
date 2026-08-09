# shellcheck shell=bash
#
# Read Brave's own apt index. Brave Origin ships nowhere else — it is not in
# nixpkgs and has no GitHub releases — so this file is the only version source.
#
# The index holds several versions of the same package at once and does not
# order them, so the newest has to be selected by version comparison rather
# than by position.

# stdin: a Debian Packages index. stdout: the highest brave-origin version.
brave_latest_version() {
  local v
  v="$(awk '
    /^Package: brave-origin$/ { in_pkg = 1; next }
    /^$/                      { in_pkg = 0 }
    in_pkg && /^Version: /    { print $2 }
  ' | sort -V | tail -n1)"

  if [ -z "$v" ]; then
    echo "brave_latest_version: no brave-origin stanza in input" >&2
    return 1
  fi
  printf '%s\n' "$v"
}

# stdin: a Debian Packages index. $1: version. stdout: that version's hex SHA256.
brave_sha256_for() {
  local want=${1-} h
  h="$(awk -v want="$want" '
    /^Package: brave-origin$/ { in_pkg = 1; match_v = 0; next }
    /^$/                      { in_pkg = 0; match_v = 0 }
    in_pkg && $1 == "Version:" && $2 == want { match_v = 1 }
    in_pkg && match_v && $1 == "SHA256:"     { print $2; exit }
  ')"

  if [ -z "$h" ]; then
    echo "brave_sha256_for: no SHA256 for version $want" >&2
    return 1
  fi
  printf '%s\n' "$h"
}
