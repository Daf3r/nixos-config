# Applying a prepared update from the bar — design

Date: 2026-08-11
Status: approved, unimplemented
Continues: `2026-08-09-actualizacion-automatica-design.md` (its Phase 2)

## The problem

The engine prepares an update every night and refuses to apply it. Applying is
`upd apply`, typed in a terminal. That was the right call for the engine and it
is the wrong call for the last step: the operator has to remember to look, open
a terminal, read four subcommands' worth of output, and know that `switch` is
the wrong verb across a driver jump. On 2026-08-11 the prepared update had sat
`ready` since 06:21 and would have been applied blind.

This design puts the whole loop in the DankMaterialShell bar: what is prepared,
what changes, whether it can be applied right now, and the button that applies
it — with the password prompt DMS already knows how to draw.

## What exists today, measured not assumed

- **DMS runs its own polkit agent.** `PolkitService.qml`, `PolkitAgentInstance.qml`
  and `PolkitAuthModal.qml` ship with 1.5.3, and the running shell logged
  `[PolkitService:25] Initialized successfully` at 06:15 on 2026-08-11. No
  external agent is installed on this machine and none is needed.
- **DMS plugin `permissions` are decorative.** `PluginService.qml:295-302` reads
  the manifest field and stores it; the only consumers are three settings
  screens that display it. There is no sandbox. A plugin importing
  `Quickshell.Io` can start processes exactly like the shell does.
- **The native `sysupdate` backend cannot help.** The Go daemon does advertise
  the capability (`Ready! Capabilities: [... sysupdate]`) and implements it under
  `core/internal/server/sysupdate`, but its backends are pacman, apt, dnf,
  zypper, xbps, emerge and flatpak. The only NixOS-aware string in the binary
  points the other way — *"disabled on NixOS because the greeter is managed
  declaratively"*. So: a plugin of our own, alongside `claude-usage`.
- **`status.json` is 0600 and owned by daf3r**, so the shell — which runs as
  daf3r — can read it directly. It will not, for the reason in the next section.

## Non-goals

- Replacing `upd` on the command line. Every subcommand keeps working, and the
  terminal stays the fallback when the shell is not running.
- Making the engine apply anything on its own. The nightly timer still only
  prepares; a human still presses the button.
- Rendering the ANSI closure diff. `diff.txt` stays a convenience for `upd diff`
  in a terminal, and the plugin never parses it.

## Architecture

Three pieces with three owners. They are separate because they fail separately.

### 1. `upd status --json` — the only machine-facing surface

The plugin never reads `status.json`. It calls a new subcommand that merges the
file with facts only knowable at call time.

The reason is concrete. Two of the conditions that stop an apply do not live in
`status.json` and cannot: whether the working tree is dirty, and which branch
`$REPO` has checked out. Both can change minutes after the nightly check. Today
they surface only as an `exit 1` from `upd apply` — acceptable for a command,
useless for a panel, because a button that is doomed to fail is worse than no
button. On 2026-08-11 both were true at once: the repository sat on branch `dms`
with three modified files.

It also preserves the rule `upd.sh` states in its own header — that it is the
single place where the engine's findings become visible to a human. The plugin
becomes a second reader of that same surface rather than a third path that
routes around the warnings.

Output: the `status.json` v2 object below, plus a `blockers` array. `blockers`
is computed live and never written to disk.

| blocker | meaning |
|---|---|
| `dirty_tree` | `$REPO` has uncommitted or untracked changes |
| `wrong_branch` | `$REPO` is not on `$BRANCH` |
| `engine_running` | the engine holds its lock right now |
| `clone_unusable` | `$WT` fails one of the four integrity checks `apply` already makes |
| `pending_reboot` | `/nix/var/nix/profiles/system` and `/run/current-system` resolve to different store paths — something was applied with `boot` and has not been rebooted into |

Each carries the same literal message `upd apply` would have printed. The panel
displays it verbatim.

### 2. `nixos-upd-apply@.service` — the root half

A template unit with two instances, `@switch` and `@boot`, each a `oneshot`
running as root and doing exactly one thing: `nh os switch` or `nh os boot`
against `$REPO`. The plugin starts it with `systemctl start --no-block`.

**The git fast-forward does not go in this unit.** It stays in `upd apply
--ff-only`, running as daf3r before the unit is started. If root performed the
merge, `.git` would end up with root-owned objects and daf3r's next commit would
fail.

Running the switch under systemd rather than as a child of the shell is what
makes `dms restart` mid-apply survivable: the unit keeps going, and its state is
still queryable afterwards.

### 3. The plugin — `updates/dms-plugin/`

Lives in this repository, next to the engine, declared as
`plugins.nixos-upd.src = ./updates/dms-plugin`. A path relative to the flake's
own tree is fine under pure evaluation — what fails is an absolute path, which
is why `claude-usage` needed an input. Keeping it here means the engine and its
reader change in the same commit, and iterating costs one `nh os switch` with no
push and no `nix flake update`.

`composite` type, manifest id `nixosUpd`:

| File | Responsibility |
|---|---|
| `Daemon.qml` | polls `upd status --json`, holds state, watches the apply unit |
| `Widget.qml` | the bar item: icon and state, nothing else |
| `Popout.qml` | the panel: changes, blockers, buttons |
| `logic.js` | pure functions — parse, classify, decide which button — unit tested |

Four files rather than the two 50 KB monoliths `claude-usage` grew into. The
split is what lets `logic.js` be tested with `node --test` without a running
shell, which is the only part of a QML plugin that can be tested at all.

## The v2 contract

`status.json` goes to `schema: 2`. `upd.sh` already refuses a schema it does not
recognise and says so; that refusal now earns its keep.

| Field | Shape | Source |
|---|---|---|
| `changes[]` | `{name, kind: "input"\|"local_pkg", from, to}` | The flake inputs the run moved, plus the hand-packaged ones. On the first real run six inputs moved and the report named none of them. |
| `closure_diff` | `{added[], removed[], changed[], size_delta_mb}` | Parsed from the `nix store diff-closures` already run at `nixos-upd.sh:500` |
| `reboot_recommended` | bool | True when `closure_diff` touches the kernel, `nvidia-*` or `mesa` |
| `reboot_reason[]` | package names that set the flag | Same diff, so the panel can say *why* |

`local_pkgs` (an array of human prose) is what `changes[]` replaces, and it is
removed rather than kept alongside. Engine and reader are packaged and installed
together, so they cannot drift within a generation, and the one case that does
happen — a stale `upd` earlier on `$PATH` — is already handled: it sees
`schema: 2`, refuses, and says which side is old. Keeping a second, prose-shaped
copy of the same facts would give a reader two sources that can disagree, which
is the problem this contract exists to remove.

Everything already in the file — `state`, `checked_at`, `warnings`, `unmanaged`,
`build`, `branch` — is unchanged.

## Flow

1. The user presses the button. Its label is *Apply* or *Apply at next boot*,
   decided by `reboot_recommended`, never by the user.
2. `upd apply --ff-only` runs as daf3r: takes the engine lock, verifies the
   clone's origin, that `auto/update` resolves, that its HEAD matches and its
   tree is clean, that `$REPO` is clean and on `$BRANCH`, fetches, checks the
   fetched commit is the prepared one and is a descendant, and fast-forwards.
   It stops there and touches nothing else.
3. On failure the panel shows the engine's message **verbatim** — no rewording,
   no summarising.
4. On success: `systemctl start --no-block nixos-upd-apply@switch.service`, or
   `@boot`.
5. polkit raises the DMS modal and asks for the password.
6. The daemon follows the unit with `systemctl show -p ActiveState,Result` and
   notifies on completion.
7. After a `@boot` apply the panel offers to reboot. It never reboots on its own.

### polkit, at two levels

- `nixos-upd.service` — the check. daf3r may start it **without a password**: it
  builds and never applies, and a credential prompt there is friction without
  security.
- `nixos-upd-apply@*.service` — `auth_admin`. A password every time, and
  deliberately **not** `auth_admin_keep`: a five-minute grace period on the
  action that changes the system is exactly what we do not want.

Both go in `updates.nix` under `security.polkit.extraConfig`, matched on unit
name. A polkit rule can be written, evaluate cleanly and silently do nothing —
that already happened on this machine with gamemode. So the acceptance test is
starting the unit and seeing the modal, not reading the `.nix`.

## What the panel is forbidden to do

If `upd status --json` fails, times out, or returns a schema this plugin does not
know, the widget says **unknown**. Never "up to date". That is the exact failure
the engine exists to prevent — an incomplete run rendering identically to a clean
one — and it would be reintroduced at the last step, in the most visible place.

For the same reason `ready` with warnings and `ready` without them are
distinguishable **in the bar**, not only inside the panel. `upd.sh` makes the
same distinction in its heading and for the same stated reason.

Blockers disable the button and are printed next to it. They are never hidden: a
missing button teaches nothing, a disabled one with `dms is not main` next to it
says what to do.

## Testing

**`logic.js`, `node --test`** — the pattern `claude-usage` already uses, 189
cases run by `tests/run-js.fish`:

- each `state` maps to its icon and its button
- `ready` with warnings ≠ `ready` without
- an unknown `schema` maps to unknown, never to a healthy state
- `reboot_recommended` derived from a diff touching nvidia, and from one not

**`bats`, alongside the 61 the derivation already runs at build time** — a red
suite cannot be activated, which is the property worth keeping:

- `changes[]` and `closure_diff` against fixtures captured from real
  `nix store diff-closures` output
- `upd status --json` with a dirty tree, with the wrong branch, and with the
  engine lock held

**By hand, because no test covers it** — the modal actually appears; a wrong
password applies nothing and the panel says so; the panel's final state matches
what the system did. Verified against the machine, not by reading code.

The engine's own lesson from its first build applies here too: the reviews that
found things ran the code — `strace`, deliberate mutations to see whether the
tests caught them — rather than reading it.

## Phases

Each lands when the previous one is still green.

| | Contents | Verifiable without the next phase by |
|---|---|---|
| A | v2 contract, `upd status --json` | `upd` in a terminal; bats in the build |
| B | `nixos-upd-apply@.service`, polkit rules | `systemctl start` by hand, watching for the modal |
| C | The plugin | Against an A and B already verified |

## Risks

- **The store path of a prepared closure is not recorded inside it.** `upd apply`
  already documents this: the link between "this commit" and "that closure" is an
  inference. The panel inherits the inference and its bound — a mismatch costs a
  foreground rebuild, never the activation of something unbuilt.
- **`nh os boot` leaves the running system stale until reboot.** The panel says
  so and offers the reboot; if the user declines, the `pending_reboot` blocker
  keeps saying it on every poll. Without that blocker the bar would report
  `ready` again the next morning — the engine diffs against `/run/current-system`,
  which a `boot` apply does not move — and the user would apply the same update
  twice.
- **DMS 1.5.3 is pinned by tag.** A DMS upgrade that changes the plugin API
  breaks the widget, not the engine — the terminal path is unaffected. That
  separation is why the engine keeps no knowledge of the plugin.
