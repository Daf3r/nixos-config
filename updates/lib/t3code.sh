# shellcheck shell=bash
#
# t3code publishes Linux builds only as an AppImage attached to a GitHub
# release, so the release API is the version source.

# stdin: the GitHub "latest release" JSON. stdout: the version, no leading v.
t3code_latest_version() {
  local tag
  tag="$(jq -er '.tag_name' 2>/dev/null)" || {
    echo "t3code_latest_version: no tag_name in input" >&2
    return 1
  }
  printf '%s\n' "${tag#v}"
}
