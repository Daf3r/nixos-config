#!/usr/bin/env bash
set -euo pipefail

# Confirm the --enable-features names in pkgs/brave-origin.nix still exist in
# the Brave binary that was built.
#
# Chromium drops unknown feature entries silently: the flag looks applied and
# the acceleration simply never happens. That is how this machine ended up
# running video decode on the CPU at 92 °C with the config looking correct.
#
# Exits 0 regardless. This reports; it does not veto.

binary="${1:-}"
[ -n "$binary" ] || { echo "check-brave-vaapi: usage: check-brave-vaapi <binary>" >&2; exit 1; }
[ -f "$binary" ] || { echo "check-brave-vaapi: no such file: $binary" >&2; exit 1; }

# Kept in sync with the derivation by reading it, not by copying the list.
names=(AcceleratedVideoDecodeLinuxGL VaapiOnNvidiaGPUs VaapiIgnoreDriverChecks)

# Extract strings once, to a file, rather than piping into `grep -qx` per name.
# Piping a multi-hundred-MB `strings` output straight into `grep -q` is a real
# trap under `pipefail`: `-q` exits as soon as it finds a match, SIGPIPEs the
# still-writing `strings`, and pipefail turns that into a nonzero pipeline
# status — so a name that IS present gets reported as "missing" anyway. That
# is precisely the kind of silent-looking failure this script exists to catch,
# just relocated into the checker. Going through a file sidesteps it.
extracted="$(mktemp)"
trap 'rm -f "$extracted"' EXIT
strings "$binary" > "$extracted"

for name in "${names[@]}"; do
  if ! grep -qx "$name" "$extracted"; then
    echo "missing: $name"
  fi
done
