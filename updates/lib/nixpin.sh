# shellcheck shell=bash
#
# Rewrite the `version` and `hash` pins of a locally-packaged derivation.
#
# Writes to a temp file *in the same directory as the target* and renames only
# after both substitutions are confirmed present. The temp file must live
# alongside the target, not in $TMPDIR: if it were on a different filesystem,
# `mv` could not do a real `renameat` and would fall back to copy, which
# unlinks and recreates the destination before writing any content — turning
# a full disk or I/O error mid-copy into a truncated or missing `.nix` file.
# A half-applied pin — new version, old hash — is already the worst outcome
# we want to risk; a truncated file is worse still.
#
# The temp file is cleaned up on every return (success or failure) via a
# self-clearing RETURN trap. This deliberately never touches the EXIT trap:
# traps are global, not scoped to this function, so installing an EXIT trap
# here — even one that tries to save and restore whatever was there before —
# fights with whatever the caller (or, under `bats`, the test harness itself)
# already has installed on EXIT. An earlier version of this function did
# exactly that save/restore-via-`eval` dance and it silently corrupted bats'
# own internal teardown trap, producing duplicate test results with no
# explanation. RETURN fires on every normal return from this function, which
# is every path below, without ever taking over a slot the caller owns.
# It does NOT cover an untrapped fatal signal or a bare `exit` call between
# mktemp and mv: bash does not run RETURN traps in either case, so a temp
# file can still be left behind if the process dies there. That gap is left
# undefended rather than "fixed" by grabbing the EXIT trap, which caused
# worse problems than it solved.

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
  trap 'rm -f "$tmp"; trap - RETURN' RETURN

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
  # are 0644 and must stay that way. A failed chmod must not ship anyway.
  if ! chmod --reference="$file" "$tmp"; then
    echo "nixpin_set: failed to preserve mode of $file" >&2
    return 1
  fi

  mv "$tmp" "$file"
}
