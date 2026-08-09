# shellcheck shell=bash
#
# Rewrite the `version` and `hash` pins of a locally-packaged derivation.
#
# Writes to a temp file *in the same directory as the target* and renames only
# after both substitutions are confirmed present. The temp file must live
# alongside the target, not in $TMPDIR: if it were on a different filesystem,
# `mv` could not do a real `renameat` and would fall back to copy, which
# unlinks and recreates the destination before writing any content — turning
# a signal, full disk, or I/O error mid-copy into a truncated or missing
# `.nix` file. A half-applied pin — new version, old hash — is already the
# worst outcome we want to risk; a truncated file is worse still.
#
# The temp file is cleaned up on every return path via an EXIT/RETURN trap,
# so a failure (or a signal) between mktemp and mv never leaves it behind in
# the repo.

nixpin_set() {
  local file=$1 version=$2 hash=$3 tmp

  if [ ! -f "$file" ]; then
    echo "nixpin_set: no such file: $file" >&2
    return 1
  fi

  case "$hash" in
    sha256-*) ;;
    *) echo "nixpin_set: hash must be SRI (sha256-…), got: $hash" >&2; return 1 ;;
  esac

  tmp="$(mktemp "$file.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT RETURN

  sed -e "s|version = \"[^\"]*\";|version = \"$version\";|" \
      -e "s|hash = \"sha256-[^\"]*\";|hash = \"$hash\";|" \
      "$file" > "$tmp"

  # Confirm both landed before replacing anything.
  if ! grep -q "version = \"$version\";" "$tmp" \
    || ! grep -q "hash = \"$hash\";" "$tmp"; then
    echo "nixpin_set: substitution did not apply to $file" >&2
    return 1
  fi

  # Preserve the original mode: mktemp creates 0600, but tracked .nix files
  # are 0644 and must stay that way.
  chmod --reference="$file" "$tmp"
  mv "$tmp" "$file"
}
