# shellcheck shell=bash

# Read the package identity from an official ChatGPT Debian archive. The
# download URL is intentionally mutable (`latest`), so the engine must inspect
# the archive it prefetched instead of treating the URL or the Nix pin as the
# version source.
chatgpt_deb_control() {
  local deb=$1 member control_archive control_path rc

  [ -f "$deb" ] || {
    echo "chatgpt_deb_control: no such file: $deb" >&2
    return 1
  }

  member="$(ar t "$deb" | awk '$0 ~ /^control[.]tar[.](xz|gz|zst)$/ { print; exit }')"
  [ -n "$member" ] || {
    echo "chatgpt_deb_control: no supported control archive in $deb" >&2
    return 1
  }

  control_archive="$(mktemp)"
  if ! case "$member" in
    control.tar.xz) ar p "$deb" "$member" | xz -dc > "$control_archive" ;;
    control.tar.gz) ar p "$deb" "$member" | gzip -dc > "$control_archive" ;;
    control.tar.zst) ar p "$deb" "$member" | zstd -dc > "$control_archive" ;;
    *)
      echo "chatgpt_deb_control: unsupported control archive: $member" >&2
      false
      ;;
  esac
  then
    rm -f "$control_archive"
    return 1
  fi

  control_path="$(tar -tf "$control_archive" | awk '$0 == "./control" || $0 == "control" { print; exit }')"
  if [ -z "$control_path" ]; then
    echo "chatgpt_deb_control: control file is missing from $deb" >&2
    rm -f "$control_archive"
    return 1
  fi

  tar -xOf "$control_archive" "$control_path"
  rc=$?
  rm -f "$control_archive"
  return "$rc"
}

chatgpt_deb_version() {
  local deb=$1 package version
  package="$(chatgpt_deb_control "$deb" | awk -F': ' '$1 == "Package" { print $2; exit }')"
  [ "$package" = "chatgpt" ] || {
    echo "chatgpt_deb_version: expected Package: chatgpt, got: ${package:-missing}" >&2
    return 1
  }

  version="$(chatgpt_deb_control "$deb" | awk -F': ' '$1 == "Version" { print $2; exit }')"
  [ -n "$version" ] || {
    echo "chatgpt_deb_version: Package: chatgpt has no Version field" >&2
    return 1
  }
  printf '%s\n' "$version"
}
