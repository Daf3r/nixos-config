# shellcheck shell=bash
#
# Rewrite the `version` and `hash` pins of a locally-packaged derivation.
#
# Writes to a temp file and renames only after both substitutions are confirmed
# present. A half-applied pin — new version, old hash — is the worst outcome
# here: it builds, downloads the wrong file, and fails with a hash mismatch that
# points at nothing obvious.

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

  tmp="$(mktemp)"
  sed -e "s|version = \"[^\"]*\";|version = \"$version\";|" \
      -e "s|hash = \"sha256-[^\"]*\";|hash = \"$hash\";|" \
      "$file" > "$tmp"

  # Confirm both landed before replacing anything.
  if ! grep -q "version = \"$version\";" "$tmp" \
    || ! grep -q "hash = \"$hash\";" "$tmp"; then
    rm -f "$tmp"
    echo "nixpin_set: substitution did not apply to $file" >&2
    return 1
  fi

  mv "$tmp" "$file"
}
