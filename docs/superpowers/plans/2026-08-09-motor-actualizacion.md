# Prepared-update engine — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daily systemd timer that prepares a fully-built system update — flake inputs plus the two locally-packaged apps — verifies it, and reports it, without ever applying it or touching `~/nixos-config`.

**Architecture:** Small single-purpose bash scripts under `updates/`, split so the parsing logic is pure and testable without network access. A `stdenvNoCC.mkDerivation` copies the tree into the store and wraps each entry point with `LIB_DIR` and a closed `PATH`. A system-level systemd unit runs it as `daf3r`, since building needs no root.

**Tech Stack:** bash, bats (tests), nix, systemd.

## Global Constraints

- Target repo: `/home/daf3r/nixos-config`. Flake attribute: `daf3r-starter`.
- **The engine never writes to `~/nixos-config`** and never runs `switch`. Both are the core safety property of the spec.
- All scripts: `set -euo pipefail`.
- The user's shell is **fish**. Every command in this plan is written for `bash -c` or run through `nix run`; do not write bash heredocs into a fish prompt.
- Commits in this repo: **no `Co-Authored-By` trailer**, author `Daf3r <87869353+Daf3r@users.noreply.github.com>` (already the repo's git config).
- Comments inside `.nix` and `.sh` files are written in **English**, matching the rest of the repo.
- Run tests with: `nix run nixpkgs#bats -- updates/tests/`
- State directory at runtime: `/var/lib/nixos-upd` (created by systemd `StateDirectory=`).

## File Structure

```
updates/
  lib/nixpin.sh          rewrite version+hash in a .nix file, atomically
  lib/brave.sh           parse Brave's apt Packages index (pure)
  lib/t3code.sh          parse the GitHub release JSON (pure)
  lib/status.sh          build and write status.json atomically
  bump-brave-origin.sh   network + nixpin + brave
  bump-t3code-app.sh     network + nixpin + t3code
  check-brave-vaapi.sh   verify feature names survive in the built binary
  nixos-upd.sh           the orchestrator the timer runs
  upd.sh                 the user-facing command
  tests/*.bats           one file per lib
  tests/fixtures/*       real captured data, trimmed
updates.nix              NixOS module: the package, the service, the timer
configuration.nix        one import line added
```

---

### Task 1: Atomic version+hash rewriting

Both bump scripts need this, so it lands first. Each target file contains
**exactly one** `version = "…";` and **exactly one** `hash = "sha256-…";`
(verified 2026-08-09), so a global substitution is safe.

**Files:**
- Create: `updates/lib/nixpin.sh`
- Create: `updates/tests/nixpin.bats`
- Create: `updates/tests/fixtures/sample-pkg.nix`

**Interfaces:**
- Consumes: nothing.
- Produces: `nixpin_set <file> <version> <sri_hash>` → exit 0 on success, exit 1 and **file untouched** on any failure.

- [ ] **Step 1: Write the fixture**

Create `updates/tests/fixtures/sample-pkg.nix`, shaped like the real files:

```nix
{ fetchurl }:
let
  version = "1.0.0";
in
{
  src = fetchurl {
    url = "https://example.invalid/thing-${version}.deb";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
}
```

- [ ] **Step 2: Write the failing test**

Create `updates/tests/nixpin.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/nixpin.sh"
  WORK="$(mktemp -d)"
  cp "${BATS_TEST_DIRNAME}/fixtures/sample-pkg.nix" "$WORK/pkg.nix"
}

teardown() {
  rm -rf "$WORK"
}

@test "nixpin_set rewrites both version and hash" {
  run nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 0 ]
  grep -q 'version = "2.0.0";' "$WORK/pkg.nix"
  grep -q 'hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";' "$WORK/pkg.nix"
}

@test "nixpin_set leaves the rest of the file alone" {
  nixpin_set "$WORK/pkg.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  grep -q 'url = "https://example.invalid/thing-\${version}.deb";' "$WORK/pkg.nix"
}

@test "nixpin_set rejects a non-SRI hash and changes nothing" {
  before="$(cat "$WORK/pkg.nix")"
  run nixpin_set "$WORK/pkg.nix" "2.0.0" "deadbeef"
  [ "$status" -eq 1 ]
  [ "$(cat "$WORK/pkg.nix")" = "$before" ]
}

@test "nixpin_set fails on a missing file" {
  run nixpin_set "$WORK/nope.nix" "2.0.0" "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/nixpin.bats`
Expected: FAIL — `updates/lib/nixpin.sh` does not exist.

- [ ] **Step 4: Write the implementation**

Create `updates/lib/nixpin.sh`:

```bash
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/nixpin.bats`
Expected: 4 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/nixos-config
git add updates/lib/nixpin.sh updates/tests/nixpin.bats updates/tests/fixtures/sample-pkg.nix
git commit -m "updates: reescritura atomica de version y hash"
```

---

### Task 2: Parse Brave's apt index

**Files:**
- Create: `updates/lib/brave.sh`
- Create: `updates/tests/brave.bats`
- Create: `updates/tests/fixtures/brave-packages.txt`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `brave_latest_version` — reads a Packages index on **stdin**, prints the highest `brave-origin` version. Exit 1 if none found.
  - `brave_sha256_for <version>` — reads the index on stdin, prints the **hex** SHA256 for that version. Exit 1 if not found.

The index carries `SHA256:` for every file, so no download is needed to pin a
hash. Verified 2026-08-09: converting the published hex for 1.93.132 reproduces
the SRI hash already committed in `pkgs/brave-origin.nix`, byte for byte.

- [ ] **Step 1: Write the fixture**

Create `updates/tests/fixtures/brave-packages.txt`. Versions are deliberately
out of order, and a second package is present, because the index really does
contain both:

```
Package: brave-browser
Version: 1.93.140
Filename: pool/main/b/brave-browser/brave-browser_1.93.140_amd64.deb
SHA256: 1111111111111111111111111111111111111111111111111111111111111111

Package: brave-origin
Version: 1.93.134
Filename: pool/main/b/brave-origin/brave-origin_1.93.134_amd64.deb
SHA256: 288b8f3c875bcd855dfd1127fd8559d7e09522277cfd569e3fb2d44e106ec532

Package: brave-origin
Version: 1.92.144
Filename: pool/main/b/brave-origin/brave-origin_1.92.144_amd64.deb
SHA256: 2222222222222222222222222222222222222222222222222222222222222222

Package: brave-origin
Version: 1.93.132
Filename: pool/main/b/brave-origin/brave-origin_1.93.132_amd64.deb
SHA256: e77a5cef4f7801acbd88087119d85c5d4f0f96d4402f4d699a66f681ad01e828
```

- [ ] **Step 2: Write the failing test**

Create `updates/tests/brave.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/brave.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/brave-packages.txt"
}

@test "brave_latest_version picks the highest version, not the first listed" {
  run bash -c "brave_latest_version < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "1.93.134" ]
}

@test "brave_latest_version ignores the brave-browser package" {
  run bash -c "brave_latest_version < '$FIX'"
  [ "$output" != "1.93.140" ]
}

@test "brave_sha256_for returns the hex hash of the requested version" {
  run bash -c "brave_sha256_for 1.93.132 < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "e77a5cef4f7801acbd88087119d85c5d4f0f96d4402f4d699a66f681ad01e828" ]
}

@test "brave_sha256_for fails for a version that is not there" {
  run bash -c "brave_sha256_for 9.9.9 < '$FIX'"
  [ "$status" -eq 1 ]
}

@test "brave_latest_version fails on empty input" {
  run bash -c "brave_latest_version < /dev/null"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/brave.bats`
Expected: FAIL — `updates/lib/brave.sh` does not exist.

- [ ] **Step 4: Write the implementation**

Create `updates/lib/brave.sh`:

```bash
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
  local want=$1 h
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/brave.bats`
Expected: 5 tests, all PASS.

- [ ] **Step 6: Commit**

```bash
cd ~/nixos-config
git add updates/lib/brave.sh updates/tests/brave.bats updates/tests/fixtures/brave-packages.txt
git commit -m "updates: leer el indice apt de Brave, la unica fuente de version"
```

---

### Task 3: `bump-brave-origin`

**Files:**
- Create: `updates/bump-brave-origin.sh`

**Interfaces:**
- Consumes: `nixpin_set` (Task 1), `brave_latest_version` and `brave_sha256_for` (Task 2).
- Produces: an executable taking `--repo <dir>`. Prints `brave-origin <old> -> <new>` on a change, `brave-origin <v> (current)` when already newest. Exit 0 on both; exit 1 on failure, having changed nothing.

- [ ] **Step 1: Write the implementation**

Create `updates/bump-brave-origin.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/brave-origin.nix at the newest brave-origin in Brave's apt index.
#
# No download: the index publishes each file's SHA256 in hex, and `nix hash
# convert` turns that into the SRI form the derivation wants. Fetching the .deb
# only to hash it would cost 130 MB per check for a value already published.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/nixpin.sh
source "$LIB_DIR/nixpin.sh"
# shellcheck source=lib/brave.sh
source "$LIB_DIR/brave.sh"

INDEX_URL="https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages"

repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) echo "bump-brave-origin: unknown argument: $1" >&2; exit 1 ;;
  esac
done
[ -n "$repo" ] || { echo "bump-brave-origin: --repo is required" >&2; exit 1; }

target="$repo/pkgs/brave-origin.nix"
[ -f "$target" ] || { echo "bump-brave-origin: no $target" >&2; exit 1; }

index="$(mktemp)"
trap 'rm -f "$index"' EXIT
curl -sSL --max-time 120 "$INDEX_URL" > "$index"

latest="$(brave_latest_version < "$index")"
current="$(sed -n 's/^ *version = "\(.*\)";/\1/p' "$target" | head -n1)"

if [ "$latest" = "$current" ]; then
  echo "brave-origin $current (current)"
  exit 0
fi

hex="$(brave_sha256_for "$latest" < "$index")"
sri="$(nix hash convert --hash-algo sha256 --to sri "$hex")"

nixpin_set "$target" "$latest" "$sri"
echo "brave-origin $current -> $latest"
```

- [ ] **Step 2: Verify it reports the real current state**

Run:

```bash
cd ~/nixos-config && bash updates/bump-brave-origin.sh --repo "$PWD"
```

Expected: `brave-origin 1.93.132 -> 1.93.134` (or a later version). It has now
modified `pkgs/brave-origin.nix`.

- [ ] **Step 3: Verify the hash it wrote is genuinely correct**

This is the step that proves the no-download shortcut is sound — that the hex
SHA256 from the apt index really is the hash of the `.deb` nix will fetch.

```bash
cd ~/nixos-config && git add -N pkgs/brave-origin.nix && \
  nixos-rebuild build --flake .#daf3r-starter 2>&1 | tail -5
```

Expected: `Done. The new configuration is /nix/store/…`. A wrong hash fails
loudly and specifically, with `hash mismatch in fixed-output derivation`, so
this is a real check and not a formality.

- [ ] **Step 4: Verify idempotency**

Run: `cd ~/nixos-config && bash updates/bump-brave-origin.sh --repo "$PWD"`
Expected: `brave-origin 1.93.134 (current)` — and `git diff` shows no new change.

- [ ] **Step 5: Revert the working tree**

The engine must own this bump, not a manual run:

```bash
cd ~/nixos-config && git checkout pkgs/brave-origin.nix
```

- [ ] **Step 6: Commit**

```bash
cd ~/nixos-config
git add updates/bump-brave-origin.sh
git commit -m "updates: bump de brave-origin sin descargar el .deb"
```

---

### Task 4: `bump-t3code-app`

**Files:**
- Create: `updates/lib/t3code.sh`
- Create: `updates/tests/t3code.bats`
- Create: `updates/tests/fixtures/t3code-release.json`
- Create: `updates/bump-t3code-app.sh`

**Interfaces:**
- Consumes: `nixpin_set` (Task 1).
- Produces:
  - `t3code_latest_version` — reads the GitHub release JSON on **stdin**, prints the version with the leading `v` stripped. Exit 1 if absent.
  - `bump-t3code-app.sh --repo <dir>` — same output contract as Task 3.

Unlike Brave, GitHub does not publish a usable checksum here, so this one does
prefetch the asset. The AppImage is ~100 MB and t3code releases rarely, so the
cost is acceptable; it is skipped entirely when the version is unchanged.

- [ ] **Step 1: Write the fixture**

Create `updates/tests/fixtures/t3code-release.json`, trimmed from the real API response:

```json
{
  "tag_name": "v0.0.34",
  "name": "v0.0.34",
  "assets": [
    {
      "name": "T3-Code-0.0.34-x86_64.AppImage",
      "browser_download_url": "https://github.com/pingdotgg/t3code/releases/download/v0.0.34/T3-Code-0.0.34-x86_64.AppImage"
    }
  ]
}
```

- [ ] **Step 2: Write the failing test**

Create `updates/tests/t3code.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/t3code.sh"
  FIX="${BATS_TEST_DIRNAME}/fixtures/t3code-release.json"
}

@test "t3code_latest_version strips the leading v from the tag" {
  run bash -c "t3code_latest_version < '$FIX'"
  [ "$status" -eq 0 ]
  [ "$output" = "0.0.34" ]
}

@test "t3code_latest_version fails when there is no tag" {
  run bash -c "echo '{}' | t3code_latest_version"
  [ "$status" -eq 1 ]
}

@test "t3code_latest_version fails on invalid json" {
  run bash -c "echo 'not json' | t3code_latest_version"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/t3code.bats`
Expected: FAIL — `updates/lib/t3code.sh` does not exist.

- [ ] **Step 4: Write the lib**

Create `updates/lib/t3code.sh`:

```bash
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/t3code.bats`
Expected: 3 tests, all PASS.

- [ ] **Step 6: Write the bump script**

Create `updates/bump-t3code-app.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Point pkgs/t3code-app.nix at the newest t3code release.
#
# GitHub publishes no checksum for release assets, so unlike brave-origin this
# has to prefetch the AppImage to learn its hash. That only happens when the
# version actually moved.

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

if [ "$latest" = "$current" ]; then
  echo "t3code-app $current (current)"
  exit 0
fi

url="https://github.com/pingdotgg/t3code/releases/download/v${latest}/T3-Code-${latest}-x86_64.AppImage"
sri="$(nix store prefetch-file --json "$url" | jq -er '.hash')"

nixpin_set "$target" "$latest" "$sri"
echo "t3code-app $current -> $latest"
```

- [ ] **Step 7: Verify against the real API**

Run: `cd ~/nixos-config && bash updates/bump-t3code-app.sh --repo "$PWD"`
Expected: `t3code-app 0.0.32 (current)` — upstream was at 0.0.32 on 2026-08-09,
so this exercises the no-change path and downloads nothing. If a newer release
has appeared, expect a `0.0.32 -> …` line instead; then run
`git checkout pkgs/t3code-app.nix` before committing.

- [ ] **Step 8: Commit**

```bash
cd ~/nixos-config
git add updates/lib/t3code.sh updates/tests/t3code.bats updates/tests/fixtures/t3code-release.json updates/bump-t3code-app.sh
git commit -m "updates: bump de t3code-app desde los releases de GitHub"
```

---

### Task 5: `check-brave-vaapi`

The verification `pkgs/brave-origin.nix` currently asks for in a comment, run
automatically. Chromium renamed these once already and dropped the old names
without warning; the symptom was 80% of a CPU core and 92 °C, not an error.

**Files:**
- Create: `updates/check-brave-vaapi.sh`
- Create: `updates/tests/check-vaapi.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `check-brave-vaapi.sh <brave-binary>` — prints one `missing: <name>` line per feature name absent from the binary. **Always exits 0**: a Brave that lost hardware decoding is still an update the user may want, it just must not arrive unannounced.

The three names are listed in the script, and a test asserts that list still
matches `pkgs/brave-origin.nix` — parsing Nix from bash would be more fragile
than the drift it prevents, but drifting silently is exactly this component's
failure mode, so the test closes it. `Vulkan` is deliberately absent:
`enableVulkan` defaults to `false`, so it is not in `enableFeatures`.

- [ ] **Step 1: Write the failing test**

Create `updates/tests/check-vaapi.bats`:

```bash
#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check-brave-vaapi.sh"
  WORK="$(mktemp -d)"
  # A stand-in "binary": `strings` reads any file, so a text file works.
  printf 'AcceleratedVideoDecodeLinuxGL\nVaapiOnNvidiaGPUs\nVaapiIgnoreDriverChecks\n' \
    > "$WORK/good"
  printf 'AcceleratedVideoDecodeLinuxGL\nVaapiIgnoreDriverChecks\n' > "$WORK/missing-one"
}

teardown() {
  rm -rf "$WORK"
}

@test "reports nothing when every feature name is present" {
  run bash "$SCRIPT" "$WORK/good"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "reports the name that is absent" {
  run bash "$SCRIPT" "$WORK/missing-one"
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing: VaapiOnNvidiaGPUs"* ]]
}

@test "exits 0 even when names are missing, so it never blocks an update" {
  run bash "$SCRIPT" "$WORK/missing-one"
  [ "$status" -eq 0 ]
}

@test "fails loudly when the binary does not exist" {
  run bash "$SCRIPT" "$WORK/nope"
  [ "$status" -eq 1 ]
}

@test "the hardcoded name list still matches pkgs/brave-origin.nix" {
  nixfile="${BATS_TEST_DIRNAME}/../../pkgs/brave-origin.nix"
  for name in AcceleratedVideoDecodeLinuxGL VaapiOnNvidiaGPUs VaapiIgnoreDriverChecks; do
    grep -q "\"$name\"" "$nixfile"
  done
  # And the reverse: no feature was added to the derivation without being added
  # here, which would leave it unverified.
  count="$(sed -n '/enableFeatures =/,/++ lib.optional enableVulkan/p' "$nixfile" \
    | grep -cE '^\s+"[A-Za-z]+"')"
  [ "$count" -eq 3 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/check-vaapi.bats`
Expected: FAIL — the script does not exist.

- [ ] **Step 3: Write the implementation**

Create `updates/check-brave-vaapi.sh`:

```bash
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

for name in "${names[@]}"; do
  if ! strings "$binary" | grep -qx "$name"; then
    echo "missing: $name"
  fi
done
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/check-vaapi.bats`
Expected: 5 tests, all PASS.

- [ ] **Step 5: Verify against the real, currently-installed Brave**

Run:

```bash
bash ~/nixos-config/updates/check-brave-vaapi.sh \
  "$(readlink -f "$(command -v brave-origin)" | sed 's|/bin/brave-origin$||')/opt/brave.com/brave-origin/brave"
```

Expected: no output. All three names are present in 1.93.132 — that was
confirmed by hand on 2026-08-07, so silence here is the correct result and
proves the check is looking at the right thing.

- [ ] **Step 6: Commit**

```bash
cd ~/nixos-config
git add updates/check-brave-vaapi.sh updates/tests/check-vaapi.bats
git commit -m "updates: automatizar la verificacion de VA-API que era un comentario"
```

---

### Task 6: `status.json`

The contract between the engine and any future reader, including the phase-2
Noctalia plugin.

**Files:**
- Create: `updates/lib/status.sh`
- Create: `updates/tests/status.bats`

**Interfaces:**
- Consumes: nothing.
- Produces: `status_write <path> <state> <json_body>` where `json_body` is a JSON object merged into the envelope. Writes atomically (temp file in the same directory, then `mv`), so a reader never sees a half-written file. Exit 1 if `json_body` is not valid JSON — better no update than a corrupt status.

- [ ] **Step 1: Write the failing test**

Create `updates/tests/status.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/status.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "status_write produces valid json with the envelope fields" {
  run status_write "$WORK/s.json" "ready" '{"changes":[]}'
  [ "$status" -eq 0 ]
  jq -e '.schema == 1' "$WORK/s.json"
  jq -e '.state == "ready"' "$WORK/s.json"
  jq -e '.checked_at | type == "string"' "$WORK/s.json"
}

@test "status_write merges the body in" {
  status_write "$WORK/s.json" "ready" '{"changes":[{"name":"nixpkgs"}]}'
  jq -e '.changes[0].name == "nixpkgs"' "$WORK/s.json"
}

@test "status_write rejects an invalid body and writes nothing" {
  run status_write "$WORK/s.json" "ready" 'not json'
  [ "$status" -eq 1 ]
  [ ! -f "$WORK/s.json" ]
}

@test "status_write leaves no temp files behind" {
  status_write "$WORK/s.json" "current" '{}'
  [ "$(find "$WORK" -type f | wc -l)" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/status.bats`
Expected: FAIL — `updates/lib/status.sh` does not exist.

- [ ] **Step 3: Write the implementation**

Create `updates/lib/status.sh`:

```bash
# shellcheck shell=bash
#
# The engine's only output surface. `schema` is here so a future reader — the
# Noctalia bar plugin — can refuse a format it does not understand instead of
# rendering nonsense.
#
# Written to a temp file in the same directory and renamed, because a reader
# polling this file must never catch it half-written.

# $1 path, $2 state (ready|current|build_failed|check_failed), $3 JSON object.
status_write() {
  local path=$1 state=$2 body=$3 tmp

  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "status_write: body is not a JSON object" >&2
    return 1
  fi

  tmp="$(mktemp "$(dirname "$path")/.status.XXXXXX")"
  if ! jq -n \
      --argjson body "$body" \
      --arg state "$state" \
      --arg now "$(date -Iseconds)" \
      '{schema: 1, checked_at: $now, state: $state} + $body' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$path"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/nixos-config && nix run nixpkgs#bats -- updates/tests/status.bats`
Expected: 4 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/nixos-config
git add updates/lib/status.sh updates/tests/status.bats
git commit -m "updates: status.json atomico y versionado por schema"
```

---

### Task 7: The orchestrator

**Files:**
- Create: `updates/nixos-upd.sh`

**Interfaces:**
- Consumes: every script from Tasks 1–6.
- Produces: `nixos-upd` — the executable the timer runs. Writes `$STATE_DIR/status.json`, `$STATE_DIR/last.log`, and leaves a commit on branch `auto/update` in the worktree. Exit 0 always, so a failed check does not mark the systemd unit failed and start alarming the user.

The worktree is the safety boundary. `~/nixos-config` is read (as a git remote)
and never written.

- [ ] **Step 1: Write the implementation**

Create `updates/nixos-upd.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Prepare — but never apply — a system update.
#
# Everything happens in a worktree under $STATE_DIR. If this script bumped the
# flake.lock inside ~/nixos-config, the next `nh os switch` the user ran for an
# unrelated reason would silently carry an unreviewed nixpkgs with it. That is
# the failure this layout exists to prevent.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
source "$LIB_DIR/status.sh"

REPO="${REPO:-/home/daf3r/nixos-config}"
STATE_DIR="${STATE_DIR:-/var/lib/nixos-upd}"
FLAKE_ATTR="daf3r-starter"
WT="$STATE_DIR/wt"
LOG="$STATE_DIR/last.log"
STATUS="$STATE_DIR/status.json"

mkdir -p "$STATE_DIR"

# Wait rather than fail: a manual rebuild in progress is a reason to queue, not
# to skip a whole day.
exec 9>"$STATE_DIR/lock"
flock 9

fail() {
  status_write "$STATUS" "$1" "$(jq -n --arg m "$2" '{error: $m}')"
  echo "$2" >&2
  exit 0
}

# --- worktree, reset to committed main -------------------------------------
if [ ! -d "$WT/.git" ] && [ ! -f "$WT/.git" ]; then
  git -C "$REPO" worktree add --force "$WT" main >>"$LOG" 2>&1 \
    || fail check_failed "could not create the worktree"
fi
git -C "$WT" fetch "$REPO" main >>"$LOG" 2>&1 || fail check_failed "could not fetch main"
git -C "$WT" reset --hard FETCH_HEAD >>"$LOG" 2>&1 || fail check_failed "could not reset the worktree"

: > "$LOG"

# --- bump the two locally-packaged apps ------------------------------------
# A failing bump leaves that package where it is and does not stop the run.
brave_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-brave-origin.sh" --repo "$WT" 2>>"$LOG")" \
  || brave_line="brave-origin (bump failed)"
t3code_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-t3code-app.sh" --repo "$WT" 2>>"$LOG")" \
  || t3code_line="t3code-app (bump failed)"

# --- flake inputs -----------------------------------------------------------
nix flake update --flake "$WT" >>"$LOG" 2>&1 || fail check_failed "nix flake update failed"

# --- build ------------------------------------------------------------------
if ! nixos-rebuild build --flake "$WT#$FLAKE_ATTR" >>"$LOG" 2>&1; then
  status_write "$STATUS" "build_failed" "$(jq -n --arg log "$LOG" '{build: {ok: false, log: $log}}')"
  exit 0
fi

# --- nothing changed? -------------------------------------------------------
if [ "$(readlink -f "$WT/result")" = "$(readlink -f /run/current-system)" ]; then
  status_write "$STATUS" "current" '{}'
  exit 0
fi

# --- verify Brave kept its feature names ------------------------------------
# Brave comes in through home-manager, not environment.systemPackages, so it is
# not under result/sw. Ask the closure where it actually is.
warnings='[]'
brave_store="$(nix-store -qR "$WT/result" | grep -E 'brave-origin-[0-9]' | head -n1 || true)"
brave_bin=""
[ -n "$brave_store" ] && [ -f "$brave_store/opt/brave.com/brave-origin/brave" ] \
  && brave_bin="$brave_store/opt/brave.com/brave-origin/brave"
if [ -n "$brave_bin" ]; then
  while read -r line; do
    [ -n "$line" ] || continue
    warnings="$(jq -c --arg d "${line#missing: }" \
      '. + [{code: "brave_vaapi_feature_missing", detail: ($d + " not found in binary")}]' \
      <<<"$warnings")"
  done < <(bash "$SELF_DIR/check-brave-vaapi.sh" "$brave_bin" || true)
fi

# --- what changed -----------------------------------------------------------
diff_txt="$(nix store diff-closures /run/current-system "$WT/result" 2>>"$LOG" || true)"
printf '%s\n' "$diff_txt" > "$STATE_DIR/diff.txt"

# --- claude-code is reported, never touched ---------------------------------
# Read the installed version from its package.json rather than by running the
# binary: under systemd the PATH is minimal and ~/.npm-global/bin is not on it,
# so `claude --version` would silently find nothing and this would never report.
unmanaged='[]'
cc_pkg="$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/package.json"
cc_have="$(jq -r '.version' "$cc_pkg" 2>/dev/null || true)"
cc_want="$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
if [ -n "$cc_have" ] && [ -n "$cc_want" ] && [ "$cc_have" != "$cc_want" ]; then
  unmanaged="$(jq -c -n --arg f "$cc_have" --arg t "$cc_want" \
    '[{name: "claude-code", from: $f, to: $t,
       command: "npm update -g @anthropic-ai/claude-code"}]')"
fi

# --- record it --------------------------------------------------------------
git -C "$WT" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
  add -A >>"$LOG" 2>&1
git -C "$WT" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
  commit -q -m "auto: actualizacion preparada" >>"$LOG" 2>&1 || true
git -C "$WT" branch -f auto/update HEAD >>"$LOG" 2>&1

status_write "$STATUS" "ready" "$(jq -n \
  --arg brave "$brave_line" \
  --arg t3 "$t3code_line" \
  --arg log "$LOG" \
  --argjson warnings "$warnings" \
  --argjson unmanaged "$unmanaged" \
  '{build: {ok: true, log: $log},
    branch: "auto/update",
    local_pkgs: [$brave, $t3],
    warnings: $warnings,
    unmanaged: $unmanaged}')"
```

- [ ] **Step 2: Run it by hand against a temporary state directory**

Run:

```bash
cd ~/nixos-config && \
  STATE_DIR=/tmp/upd-test LIB_DIR="$PWD/updates/lib" \
  bash updates/nixos-upd.sh && jq . /tmp/upd-test/status.json
```

Expected: valid JSON with `"schema": 1` and a `state` of `ready`, `current` or
`build_failed`. On the first run this takes several minutes: it evaluates and
builds the whole system.

- [ ] **Step 3: Verify the safety property**

The single most important check in this plan:

```bash
cd ~/nixos-config && git status --short
```

Expected: **empty**. The run must not have touched the working tree. If
`flake.lock` or anything under `pkgs/` appears here, stop — the worktree
boundary is broken and the whole safety argument fails.

- [ ] **Step 4: Commit**

```bash
cd ~/nixos-config
git add updates/nixos-upd.sh
git commit -m "updates: orquestador; el worktree es la frontera de seguridad"
```

---

### Task 8: The `upd` command

**Files:**
- Create: `updates/upd.sh`

**Interfaces:**
- Consumes: `$STATE_DIR/status.json` (Task 7).
- Produces: `upd`, `upd diff`, `upd apply`, `upd check`.

- [ ] **Step 1: Write the implementation**

Create `updates/upd.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Read the prepared update, and apply it when asked.
#
# Applying goes through git — fast-forward main, then switch — so every
# automated change stays reviewable and revertible rather than appearing in the
# system out of nowhere.

REPO="${REPO:-/home/daf3r/nixos-config}"
STATE_DIR="${STATE_DIR:-/var/lib/nixos-upd}"
STATUS="$STATE_DIR/status.json"

cmd="${1:-show}"

case "$cmd" in
  show)
    [ -f "$STATUS" ] || { echo "no hay ninguna comprobacion todavia"; exit 0; }
    schema="$(jq -r '.schema' "$STATUS")"
    [ "$schema" = "1" ] || { echo "status.json de schema $schema, desconocido"; exit 1; }

    state="$(jq -r '.state' "$STATUS")"
    when="$(jq -r '.checked_at' "$STATUS")"
    echo "estado: $state   comprobado: $when"

    case "$state" in
      current)      echo "todo al dia" ;;
      build_failed) echo "la actualizacion preparada NO compila"
                    echo "  log: $(jq -r '.build.log' "$STATUS")" ;;
      check_failed) echo "la comprobacion fallo: $(jq -r '.error // "sin detalle"' "$STATUS")" ;;
      ready)
        jq -r '.local_pkgs[]?' "$STATUS" | sed 's/^/  /'
        jq -r '.warnings[]? | "  AVISO: " + .detail' "$STATUS"
        jq -r '.unmanaged[]? | "  fuera de nix: " + .name + " " + .from + " -> " + .to + "\n    " + .command' "$STATUS"
        echo
        echo "  aplicar:  upd apply"
        echo "  ver todo: upd diff"
        ;;
    esac
    ;;

  diff)
    [ -f "$STATE_DIR/diff.txt" ] || { echo "no hay diff guardado"; exit 0; }
    cat "$STATE_DIR/diff.txt"
    ;;

  apply)
    [ -f "$STATUS" ] || { echo "no hay nada preparado"; exit 1; }
    [ "$(jq -r '.state' "$STATUS")" = "ready" ] || { echo "no hay ninguna actualizacion lista"; exit 1; }

    # Never discard uncommitted work.
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
      echo "el arbol de trabajo tiene cambios sin commitear; no aplico" >&2
      git -C "$REPO" status --short >&2
      exit 1
    fi

    git -C "$REPO" fetch "$STATE_DIR/wt" auto/update
    git -C "$REPO" merge --ff-only FETCH_HEAD
    nh os switch
    ;;

  check)
    # Run the engine directly rather than through systemctl: the unit runs as
    # daf3r and StateDirectory leaves /var/lib/nixos-upd owned by daf3r, so
    # there is nothing here that needs root or a polkit prompt.
    exec nixos-upd
    ;;

  *)
    echo "uso: upd [show|diff|apply|check]" >&2
    exit 1
    ;;
esac
```

- [ ] **Step 2: Verify the refusal path, which is the one that protects work**

Run:

```bash
cd ~/nixos-config && touch SCRATCH-TEST && \
  STATE_DIR=/tmp/upd-test bash updates/upd.sh apply; \
  rm -f SCRATCH-TEST
```

Expected: it refuses with `el arbol de trabajo tiene cambios sin commitear` and
exit 1. It must NOT run `nh os switch`.

- [ ] **Step 3: Verify the report renders**

Run: `STATE_DIR=/tmp/upd-test bash ~/nixos-config/updates/upd.sh`
Expected: a readable report matching the state left by Task 7.

- [ ] **Step 4: Commit**

```bash
cd ~/nixos-config
git add updates/upd.sh
git commit -m "updates: comando upd; aplicar pasa por git y respeta el arbol sucio"
```

---

### Task 9: Package it and wire in the timer

**Files:**
- Create: `updates.nix`
- Modify: `configuration.nix` (the `imports` list, around line 11)

**Interfaces:**
- Consumes: everything above.
- Produces: `nixos-upd`, `upd`, `bump-brave-origin`, `bump-t3code-app` and `check-brave-vaapi` on `PATH`; `nixos-upd.timer` enabled.

- [ ] **Step 1: Write the module**

Create `updates.nix`:

```nix
{ config, lib, pkgs, ... }:

# Prepared-update engine. Design: docs/superpowers/specs/2026-08-09-actualizacion-automatica-design.md
#
# It prepares and reports; it never applies. Two silent failures on this machine
# are the reason: Chromium renaming Brave's VA-API feature names without warning
# (CPU decode at 92 °C, config looking correct), and nixpkgs here being unstable,
# carrying both the NVIDIA driver and niri.
#
# Runs as daf3r, not root: `nixos-rebuild build` only writes to the store, so
# privileges would buy nothing and risk plenty.
let
  runtimeDeps = with pkgs; [
    coreutils curl jq git gnused gawk gnugrep binutils
    util-linux nix nixos-rebuild nodejs
  ];

  nixos-upd = pkgs.stdenvNoCC.mkDerivation {
    name = "nixos-upd";
    src = ./updates;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    installPhase = ''
      mkdir -p $out/libexec/nixos-upd $out/bin
      cp -r ./* $out/libexec/nixos-upd/
      for s in nixos-upd upd bump-brave-origin bump-t3code-app check-brave-vaapi; do
        chmod +x $out/libexec/nixos-upd/$s.sh
        makeWrapper $out/libexec/nixos-upd/$s.sh $out/bin/$s \
          --set LIB_DIR $out/libexec/nixos-upd/lib \
          --prefix PATH : ${lib.makeBinPath runtimeDeps}
      done
    '';
  };
in
{
  environment.systemPackages = [ nixos-upd ];

  systemd.services.nixos-upd = {
    description = "Prepare a system update without applying it";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Skip on battery. A full system build is not what a laptop on its own
    # power should be doing unattended.
    unitConfig.ConditionACPower = true;

    serviceConfig = {
      Type = "oneshot";
      User = "daf3r";
      StateDirectory = "nixos-upd";
      ExecStart = "${nixos-upd}/bin/nixos-upd";
      # A full evaluation plus build of the system closure.
      TimeoutStartSec = "3h";
    };
  };

  systemd.timers.nixos-upd = {
    description = "Daily prepared-update check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      # The laptop is not on at a fixed hour, and nothing here is urgent.
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
}
```

- [ ] **Step 2: Add the import**

In `configuration.nix`, add `./updates.nix` to the `imports` list, after
`./wireguard.nix`:

```nix
    ./keyboard.nix
    ./wireguard.nix
    ./updates.nix
  ];
```

- [ ] **Step 3: Build, do not switch**

Run: `cd ~/nixos-config && git add -N updates.nix && nixos-rebuild build --flake .#daf3r-starter`
Expected: `Done. The new configuration is /nix/store/…`

New files are invisible to a flake until git knows about them — `git add -N` is
enough, and it does not stage the file for commit.

- [ ] **Step 4: Apply**

Run: `sudo nixos-rebuild switch --flake ~/nixos-config#daf3r-starter`
Expected: succeeds. (This needs the user's password; it cannot be run unattended.)

- [ ] **Step 5: Verify the timer and run it once for real**

Run:

```bash
systemctl list-timers nixos-upd.timer --all && sudo systemctl start --wait nixos-upd.service && upd
```

Expected: the timer is listed with a next elapse, the service completes, and
`upd` prints a report.

- [ ] **Step 6: Verify the safety property once more, now packaged**

Run: `cd ~/nixos-config && git status --short`
Expected: shows only `updates.nix` and the `configuration.nix` edit — **no
`flake.lock`, nothing under `pkgs/`**.

- [ ] **Step 7: Commit**

```bash
cd ~/nixos-config
git add updates.nix configuration.nix
git commit -m "updates: temporizador diario que prepara la actualizacion y no la aplica"
```

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Runs as `daf3r`, not root | 9 (`User = "daf3r"`) |
| Worktree as the safety boundary | 7 (steps 1, 3) |
| `flock` against a manual rebuild | 7 |
| AC power condition | 9 (`ConditionACPower`) |
| Bump `brave-origin` | 2, 3 |
| Bump `t3code-app` | 4 |
| `nix flake update` on the five inputs | 7 |
| Build to verify | 7 |
| Brave VA-API check, automated | 5 |
| `nix store diff-closures` | 7 |
| `status.json`, atomic, schema-versioned | 6 |
| Commit to `auto/update` | 7 |
| `upd` / `diff` / `apply` / `check` | 8 |
| `apply` refuses on a dirty tree | 8 (step 2) |
| `claude-code` reported, never run | 7 |
| Daily, `Persistent`, randomized | 9 |
| Failure table behaviours | 7 (`fail`), 9 |

No spec requirement is left without a task.

**Deferred by the spec, not by omission:** the Noctalia bar plugin is phase 2
and reads `status.json` unchanged.
