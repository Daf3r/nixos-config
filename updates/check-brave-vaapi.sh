#!/usr/bin/env bash
set -euo pipefail

# Confirm the --enable-features names in pkgs/brave-origin.nix still exist in
# the Brave binary that was built.
#
# Chromium drops unknown feature entries silently: the flag looks applied and
# the acceleration simply never happens. That is how this machine ended up
# running video decode on the CPU at 92 °C with the config looking correct.
#
# Exits 0 for missing feature names: this reports, it does not veto. It only
# exits non-zero for a path that is not a file at all — with one deliberate
# exception, noted below at the `strings` call: an existing-but-unreadable
# file (permission denied, I/O error) also exits non-zero, on purpose.

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
# If `strings` cannot actually read $binary (permission denied, truncated or
# corrupt file, I/O error) it exits non-zero and `set -e` stops the script
# here, non-zero, even though the path passed the `-f` check above. That is a
# deliberate exception to "only a missing path exits non-zero": staying
# silent and reporting all three names "missing" would misrepresent a read
# failure as a real regression, and a loud stop is easier to notice and fix
# than a false alarm that looks identical to the real thing this script
# exists to catch.
#
# Do NOT reach for `|| true` to get a strict never-nonzero-except-missing-path
# contract out of this: it does not give you one. `|| true` flattens *every*
# non-zero exit to 0, the missing-path exit 1 above included, so the one failure
# the contract says it preserves is the first thing it throws away -- and it
# throws it away into the same empty output a clean pass produces. The real
# caller does the opposite on purpose: nixos-upd.sh captures the exit status
# (`vaapi_out="$(... )" || vaapi_rc=$?`) and turns any non-zero into a
# brave_vaapi_check_failed warning, so an unrunnable check reads as unrun rather
# than as passed. A caller that genuinely must not abort should do the same.
strings "$binary" > "$extracted"

for name in "${names[@]}"; do
  if ! grep -qx "$name" "$extracted"; then
    echo "missing: $name"
  fi
done
