# Prepared-update engine

**Status:** design approved 2026-08-09, not implemented.

Written in English to match the rest of this repo; the conversation that produced
it was in Spanish.

## Problem

Nothing on this machine updates itself. There is no `system.autoUpgrade`, the
only timer is `nh-clean` (garbage collection, not updates), and every version is
pinned in `flake.lock`. Two applications do not even move when that lock does:
`brave-origin` and `t3code-app` are packaged locally from upstream's `.deb` and
AppImage, so `nix flake update` never touches them.

The goal is that updating stops being manual work — without ever waking up to a
broken desktop.

## Why unattended `switch` is not the answer

Two failures on this machine argue against applying updates while nobody is
watching, and both were silent:

- **Brave's VA-API feature names.** Chromium renamed them; the config kept the
  old spelling. Unknown `--enable-features` entries are dropped without warning,
  so the flag looked applied and hardware decoding never happened — Brave burned
  80% of a CPU core on a 1080p video with the laptop at 92 °C. Fixed 2026-08-07.
  A blind version bump reintroduces exactly this, invisibly.
- **`nixpkgs` is `nixos-unstable`**, carrying the NVIDIA driver and niri. A bad
  roll lands on the two components whose failure ends the graphical session.

So the engine **prepares and reports; it never applies.** Applying stays a
deliberate command.

## Goals

- Every update path automated up to the point of applying: the five flake inputs
  and the two locally-packaged applications.
- Verify a prepared update actually builds before it is offered.
- Detect the Brave VA-API regression automatically instead of thermally.
- Never modify `~/nixos-config` on its own.
- Emit a stable machine-readable status so a Noctalia bar plugin can render it
  later without the engine changing.

## Non-goals

- Applying updates unattended. Explicitly rejected above.
- Updating `claude-code`. It lives outside nix (npm, in `~/.npm-global`), it is
  the user's primary tool, and npm 12's blocking of install scripts already left
  that binary half-installed once. NixOS cannot roll it back with a generation.
  **The report mentions a new version and the command; it does not run it.**
- The Noctalia bar plugin itself. Phase 2, see the end.

## Architecture

One systemd timer drives one script. The script runs **as `daf3r`, not root** —
`nixos-rebuild build` needs no privileges, since building only writes to the nix
store. The unit is a system unit with `User=daf3r` so it can still use
`ConditionACPower` and order itself after `network-online.target`.

All state lives in `StateDirectory=nixos-upd` → `/var/lib/nixos-upd`, created by
systemd with the right owner.

```
nixos-upd.timer  (daily, Persistent, RandomizedDelaySec=1h)
   └─ nixos-upd.service  (User=daf3r, ConditionACPower=true)
        └─ nixos-upd  (writeShellApplication)
             1. flock /var/lib/nixos-upd/lock
             2. sync worktree      /var/lib/nixos-upd/wt  ←  ~/nixos-config @ main
             3. bump-brave-origin  →  version + hash
             4. bump-t3code-app    →  version + hash
             5. nix flake update
             6. nixos-rebuild build --flake .#daf3r-starter
             7. check-brave-vaapi  →  strings | grep -x
             8. nix store diff-closures /run/current-system ./result
             9. write status.json; commit worktree to branch auto/update
```

### The worktree is the safety boundary

The engine works in a git worktree at `/var/lib/nixos-upd/wt`, hard-reset to
whatever `main` holds. It never writes to `~/nixos-config`.

This is not tidiness, it closes the one way this design could break the system:
if the timer bumped `flake.lock` in the working copy, then the next `nh os
switch` the user ran for an unrelated reason — changing a package, adjusting niri
— would silently carry an unreviewed `nixpkgs` with it. The user would be
applying an update they never saw. With the worktree, `~/nixos-config` only
changes when the user changes it.

Resetting to committed `main` also means the engine tests the committed config,
not whatever half-finished edit is in the working tree. That is the right thing
to test.

## Components

Each is a separate script with one job, so each can be run by hand and checked in
isolation.

### `bump-brave-origin`

**Does:** finds the newest `brave-origin` version and writes `version` and `hash`
into `pkgs/brave-origin.nix`.

**How:** the version list comes from Brave's own apt index —
`https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages`
— filtered to the `brave-origin` stanza, which is the source the file's own
comment already names. The hash comes from `nix store prefetch-file` on
`https://brave-browser-apt-release.s3.brave.com/pool/main/b/brave-origin/brave-origin_<version>_amd64.deb`.

**Contract:** writes both fields or neither. Exits non-zero and touches nothing if
the index cannot be parsed or the `.deb` does not exist — a half-written pair
(new version, old hash) is a build failure with a confusing message.

**Idempotent:** no-op when already current.

### `bump-t3code-app`

Same contract, against `pingdotgg/t3code` GitHub releases, prefetching
`T3-Code-<version>-x86_64.AppImage`.

### `check-brave-vaapi`

**Does:** the verification `pkgs/brave-origin.nix` already asks for in a comment,
run automatically instead of remembered.

For each name in `enableFeatures` — currently `AcceleratedVideoDecodeLinuxGL`,
`VaapiOnNvidiaGPUs` and `VaapiIgnoreDriverChecks`; `Vulkan` is not among them
because `enableVulkan` defaults to `false` — greps the built binary:

```
strings <store>/opt/brave.com/brave-origin/brave | grep -x <name>
```

A name absent from the binary means Chromium renamed or removed it and the flag
is now silently inert.

**Contract:** never fails the run. It reports. A Brave update that loses hardware
decoding is still a valid update the user may want; it just must not arrive
unannounced. Missing names go into `status.json` as warnings, and `upd` shows
them in red.

### `upd`

The user-facing command.

- `upd` — print the report: what changed, the closure diff, warnings, whether the
  build succeeded, and how old the check is.
- `upd diff` — the full `nix store diff-closures` output.
- `upd apply` — fast-forward `main` to `auto/update` in `~/nixos-config`, then
  `nh os switch`. Refuses if the working tree is dirty, so it can never discard
  uncommitted work.
- `upd check` — run the whole cycle now, ignoring the timer.

Applying through git keeps every automated change reviewable and revertible, and
matches the existing workflow of verifying a rebuild before committing to `main`.

### `status.json`

The contract between the engine and any future UI. Written atomically (temp file
+ rename), so a reader never sees it half-written.

```json
{
  "schema": 1,
  "checked_at": "2026-08-09T04:00:00-06:00",
  "state": "ready",
  "build": { "ok": true, "log": "/var/lib/nixos-upd/last.log" },
  "branch": "auto/update",
  "changes": [
    { "name": "nixpkgs",      "kind": "input", "from": "25.11.20260808", "to": "25.11.20260810" },
    { "name": "brave-origin", "kind": "local", "from": "1.93.132",       "to": "1.94.14" }
  ],
  "closure_diff": { "added": 4, "removed": 2, "changed": 18, "size_delta_mb": 37 },
  "warnings": [
    { "code": "brave_vaapi_feature_missing", "detail": "VaapiOnNvidiaGPUs not found in binary" }
  ],
  "unmanaged": [
    { "name": "claude-code", "from": "2.1.4", "to": "2.2.0",
      "command": "npm update -g @anthropic-ai/claude-code" }
  ]
}
```

`state` is one of `ready`, `current`, `build_failed`, `check_failed`. `schema`
exists so the phase-2 plugin can refuse a format it does not understand rather
than render nonsense.

## Failure handling

| Failure | Behaviour |
|---|---|
| Build fails | `state: build_failed`, log path recorded, nothing offered. Retried next day. |
| A bump script fails | That package stays at its current version; the run continues with the rest. |
| On battery | `ConditionACPower=true` skips the run. `Persistent=true` catches it up later. |
| No network | Ordering after `network-online.target` delays the start; if it still fails, `nix flake update` errors and the run ends as `check_failed`, changing nothing. |
| A manual rebuild is running | `flock` makes the run wait, then proceed. |
| Brave VA-API name missing | Warning in the report. Does not block the update. |
| `upd apply` with a dirty tree | Refuses, prints `git status`. |

## Why this cannot break the running system

No step writes outside the nix store until the user runs `upd apply`. Building
does not touch `/etc`, does not restart services, does not write boot entries.
The worst outcome of a bad night is disk usage, which the existing weekly
`nh-clean` already reclaims.

And if an applied update does turn out bad, it is one generation in the boot menu
away from being undone — which is the reason `switch` stays manual but stays
cheap.

## Testing

- Each bump script: run by hand against a pinned old version, confirm it writes
  both fields, and confirm that re-running is a no-op.
- `check-brave-vaapi`: run against the current build, where all three names are
  known present; then against a deliberately misspelled name, which must produce
  a warning and still exit zero.
- `upd apply`: with a dirty tree, must refuse.
- End-to-end: `upd check` on a machine already up to date must report `current`,
  not `ready`.
- `status.json`: validate against the schema above after a real run.

## Phase 2 — the Noctalia bar plugin

Deferred deliberately. The plugin only reads `status.json`; the engine does not
change. That also lets it be written alongside `claude-usage`, which is still
unstarted, so the Noctalia plugin API is learned once rather than twice.
