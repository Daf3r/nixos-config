# daf3r's NixOS

**English** · [Español](README.es.md)

A single-machine NixOS flake: **[niri](https://github.com/YaLTeR/niri)** scrollable tiling,
**[Noctalia v5](https://docs.noctalia.dev/v5/)** as the shell, on an ASUS ROG Strix G17 (G713PV)
with an RTX 4060 and a 240 Hz panel.

| | |
|---|---|
| **Compositor** | niri 25.11 — scrollable tiling, sole session |
| **Shell** | Noctalia v5, fully declarative |
| **Display manager** | SDDM (Wayland) + sddm-astronaut |
| **Terminal** | kitty + fish + starship |
| **Browser** | Brave Origin, packaged here from Brave's own `.deb` |
| **Hardware** | Ryzen 9 7845HX · RTX 4060 · 2560x1440@240 panel · MSI MP243X |

---

## Rebuild

```fish
nh os switch          # daily driver — shows a diff of exactly what changes
nrs                   # sudo nixos-rebuild switch --flake ~/nixos-config
flakeup               # nix flake update
```

`NH_FLAKE` is set system-wide, so `nh` needs no path. The flake output is named after
`networking.hostName`, which is why `--flake ~/nixos-config` resolves `daf3r-starter`
without spelling out the attribute.

---

## The thing to know before changing anything

> **This desktop stack fails silently far more often than it errors.**

Not a crash, not a red line in a log — an `ok` that did nothing. Every one of these was
real, and each cost hours before it was noticed:

- Noctalia theme templates writing colours into files that nothing read
- gamemode reporting *"gamemode is active"* while every helper behind it was denied by polkit
- Noctalia's bar dropping widgets that overflowed the narrow screen, without a word
- niri ignoring a monitor block *entirely* because a refresh rate was rounded
- Symlinks from the starter config pointing at paths that never existed

The habit that works: **measure before theorising.** A GPU pinned at 2490 MHz of 3105
available said more about a stuttering game than any hypothesis did. Where a trap is known,
it is written down in a comment next to the setting rather than here — the comments in this
repo are long on purpose.

---

## Layout

| File | What it holds |
|---|---|
| `configuration.nix` | Host basics, zram, users, Nix settings + Noctalia's binary cache |
| `hardware-configuration.nix` | Generated, gitignored |
| `desktops.nix` | niri, SDDM, xdg portals, Noctalia's NixOS module |
| `gpu.nix` | NVIDIA RTX 4060 as primary GPU — see [GPU](#gpu) |
| `asus.nix` | asusd: fan profiles, keyboard RGB, ROG key, battery limit |
| `gaming.nix` | Steam, gamemode, Proton-GE, the polkit rules gamemode needs |
| `gamemode.nix` | The `game-mode` command (panel scale + VRR toggle) |
| `keyboard.nix` | keyd — makes a bare `SUPER` tap open the launcher |
| `noctalia.nix` | Noctalia v5 settings, declarative |
| `wallpaper.nix` | swww + `wallpaper-rotate`, replacing Noctalia's wallpaper module |
| `gtk.nix` / `qt.nix` | Cursor, themes, icons, fonts — kept in step with each other |
| `home.nix` | home-manager entrypoint, out-of-store symlinks |
| `apps.nix`, `terminal.nix`, `fontsAndNeeds.nix` | Packages |
| `terminal/` | kitty, fish, fastfetch, nvim, CLI tools |
| `pkgs/brave-origin.nix` | Brave Origin, packaged from Brave's own `.deb` |
| `devshells/` | Per-project toolchains — see [Dev shells](#dev-shells) |
| `config/niri/config.kdl` | Live-editable niri config |
| `config/nvim/` | LazyVim starter — third party, see below |
| `config/starship.toml` | Prompt; holds a generated palette block |
| `config/noctalia/palettes/` | Local colour palette, copied into the store |

### What applies live, and what needs a rebuild

`config/niri` and `config/nvim` are symlinked **out of** the Nix store, so edits there take
effect immediately — `~/.config/niri/config.kdl` resolves back to this repo.

Everything else needs `nh os switch`. `starship.toml` is read through `$STARSHIP_CONFIG`
and the palette JSON is copied into the store, so neither is live despite living under
`config/`.

Two files here are written *by* Noctalia's theme templates rather than by hand:
`config/starship.toml` gets a palette block between `NOCTALIA` markers, and
`config/niri/noctalia.kdl` is generated wholesale and gitignored.

### What is not mine

**This config started from [TimothyBear11/nixtalia](https://github.com/TimothyBear11/nixtalia)**,
a starter for trying Noctalia on niri, Hyprland and Mango. Almost nothing of it survives —
Mango, Plasma and Hyprland are gone, every module has been rewritten, and what `git blame`
still matches is Nix syntax that cannot be written any other way: `{ pkgs, ... }:`, braces,
and option names like `boot.loader.systemd-boot.enable`. The starter's own commits are not
in this history, so this line is the attribution.

`config/nvim/` is the [LazyVim starter](https://github.com/LazyVim/starter), vendored
as-is and redistributed under the Apache-2.0 licence it carries in
`config/nvim/LICENSE`.

`config/fastfetch/config.jsonc` is adapted from
[israrkhan-cys/Arch-\_hyprland\_rice](https://github.com/israrkhan-cys/Arch-_hyprland_rice);
the changes made to it are listed at the top of `terminal/fastfetch.nix`.

**Wallpapers and fastfetch images are deliberately not in this repo.** They live in
`~/Pictures/Wallpapers` and `~/Pictures/Fastfetch` because they are other people's work
and this repo is public — clone it and you get an empty rotation, not a copyright problem.
`wallpaper.nix` creates the first directory so nothing breaks on a fresh checkout.

---

## Keybinds

| Keys | Action |
|---|---|
| `SUPER` (tap) / `SUPER + Space` | App launcher |
| `SUPER + F1` … `F4` | Control Center · Settings · Clipboard · Session |
| `SUPER + L` | Lock screen |
| `ALT + Tab` | Window switcher |
| `Print` / `SHIFT + Print` | Screenshot region / fullscreen |
| `SUPER + Print` | Screenshot region, then annotate in satty |
| `SUPER + Return` | kitty |
| `SUPER + B` / `SUPER + W` | Brave Origin |
| `SUPER + E` / `SUPER + K` / `SUPER + D` | Dolphin · Kate · Discord |
| `SUPER + SHIFT + W` | Shuffle wallpaper (swww) |
| `SUPER + Q` | Close window |
| `SUPER + F` | Fullscreen |
| `SUPER + O` | Overview — every workspace and window, zoomed out |
| `SUPER + R` | Cycle column width |
| `SUPER + G` | Tabbed column |
| `SUPER + ←/→` | Focus column · `SUPER + ,` / `.` consume or expel a window |

> `SUPER + SHIFT + /` opens niri's own hotkey overlay. It is generated from the live
> config, so unlike this table it cannot go stale.

The bare-`SUPER` tap is not a compositor binding — niri rejects modifier-only binds
outright. `keyboard.nix` solves it at evdev with keyd, below the compositor: hold `SUPER`
and it is still the modifier, tap and release it alone and it emits a chord that niri binds
to the launcher.

---

## Displays

| Display | Mode | Scale | Logical size |
|---|---|---|---|
| Laptop panel, **left** | `2560x1440@240.002` | 1.6 | 1600x900 |
| MSI MP243X, **right** | `1920x1080@99.999` | 1 | 1920x1080 |

Both are pinned explicitly in `config/niri/config.kdl`. `preferred` / `auto` picked the
wrong refresh rates and put the external monitor on the wrong side.

> **Match monitors by EDID, never by connector name.**
> The panel has come up as both `eDP-1` and `eDP-2` across reboots of this machine with
> nothing changed: the NVIDIA driver numbers its eDP connector differently, and a second
> eDP on the AMD iGPU makes the index ambiguous.

When the name does not match, the rules are ignored *entirely* — the 240 Hz panel runs at
60 and gets auto-placed to the right of the MSI, which looks like the monitors swapping
sides. Match on the quoted `"make model serial"` string that `niri msg outputs` prints.

> **The refresh rate must match to three decimals.**
> `2560x1440@240` is not found; `2560x1440@240.002` is. niri falls back silently and then
> throttles vblanks to the rate it believes in while the panel scans out at another. Take
> the numbers from `niri msg outputs` and never round them by hand.

Scale 1.6 was chosen because 2560/1.6 and 1440/1.6 are both integers, so there is no
fractional-scaling blur. Two consequences, both of which have already caused bugs:

- **The laptop is the narrow screen, not the wide one.** Anything laid out horizontally —
  the Noctalia bar especially — has 1600 logical pixels there against the MSI's 1920.
  Overflow is invisible from the MSI, and Noctalia drops overflowing bar widgets silently.
- **Noctalia v5.0.0 mis-sizes its wallpaper surface at fractional scales**, which is why
  `wallpaper.nix` disables that module and draws the background with swww instead.

---

## GPU

The internal panel (`card1-eDP-1`) and `card1-HDMI-A-1` are both wired to the NVIDIA
RTX 4060; every connector on the AMD iGPU reads `disconnected`. The display MUX is in
discrete mode, so NVIDIA is the primary GPU and PRIME offload does not apply — switch modes
in the BIOS. `supergfxd` is deliberately disabled; `asus.nix` says why.

Mind the card number when reading `/sys/class/drm`: both GPUs expose an eDP connector, and
`card2-eDP-2` is the iGPU's unused one, not the panel.

---

## Noctalia is declarative — with one asterisk

`~/.config/noctalia/config.toml` is a read-only symlink into the Nix store, generated from
`programs.noctalia.settings` in `noctalia.nix` and validated on every rebuild by
`noctalia config validate`, so a bad key fails the build instead of breaking the shell.

**But that file is not the whole story.** Noctalia merges it with a second, mutable one at
`~/.local/state/noctalia/settings.toml` — what the Settings GUI writes — and precedence is
*per setting*, not global. A theme picked in the GUI has been observed to survive a full
rebuild and win over `noctalia.nix`. The state file is also written *from* the Nix config in
some cases, so the two are not simply adversaries.

**In practice:** use the GUI to try things, then write what you keep into `noctalia.nix`.
If a setting there seems ignored, look for it in the state file before assuming the Nix side
is wrong, and prefer `noctalia msg <verb>` (e.g. `color-scheme-set`) over hand-editing
state — hand edits do not reliably take effect.

```fish
noctalia config export full      # every key with its default — fastest way to find options
noctalia theme --list-templates  # the app-theming templates
noctalia msg --help              # v5 IPC verbs (replaced v4's `noctalia-shell ipc call`)
```

### App theming

`theme.templates.builtin_ids` and `community_ids` are both **opt-in and empty by default** —
`enable_builtin_templates = true` on its own themes nothing.

Several templates append an include line to a config that home-manager owns as a read-only
symlink, and they either fail or replace the symlink when they cannot write. Where that
applies, the include is written into the home-manager file *up front* so the template's own
idempotence check short-circuits. Read the comments in `terminal/kitty.nix` and `gtk.nix`
before changing those strings.

Only templates whose app is actually installed are enabled. The ones left out are listed in
`noctalia.nix` **with the reason**, so the decision does not get re-litigated.

---

## Gaming

Steam ships with the 32-bit runtime, Proton-GE, gamemode and gamescope. CS2 launch options:

```
gamemoderun mangohud %command%
```

> **Do not wrap CS2 in gamescope.** It is the standard advice for a non-stacking compositor
> and it breaks the game here: CS2 initialises Vulkan and never presents a window, because
> gamescope on NVIDIA gets zero DRM format modifiers for the formats it allocates its
> output buffers in. Reproducible without Steam via `gamescope -- sleep 3`; `--backend sdl`
> gets past it if gamescope is ever genuinely needed.

gamescope stays installed (`gaming.nix` keeps `programs.gamescope` and the Steam gamescope
session) for the rest of the library — it is only CS2 that must not go through it.

`config/niri/config.kdl` handles CS2 with a `window-rule` instead — fullscreen on open,
variable refresh rate on demand.

**gamemode's polkit policy ships with every action denied.** Upstream leaves it to the
administrator to decide who may change governors and clocks, and nixpkgs does not fill it
in — so gamemode did nothing at all for weeks while reporting success. `gaming.nix` grants
those actions to the `gamemode` group; joining the group needs a **logout** to take effect.

```fish
gamemoded -t    # the honest check: exercises the CPU governor for real
gamemoded -s    # reports "active" even when every helper behind it is refused
```

`game-mode` (from `gamemode.nix`) is a separate manual toggle: it drops the panel to scale 1
and forces VRR on, so a fullscreen game gets direct scanout instead of being rescaled from
1600x900 every frame. Manual on purpose — tying it to a window rule would rescale the panel
whenever a matching window appeared, including alt-tabbing to a browser between rounds.

The ASUS platform profile stays on `balanced` deliberately. `performance` unlocks the rest
of the GPU clock but spins the fans up, and this laptop gets used in silence.

---

## Dev shells

`devshells/` holds one toolchain per project in `~/Projects`, entered automatically by
direnv. Each project carries a one-line `.envrc`:

```
use flake ~/nixos-config#remesafam
```

They live here rather than inside the projects for two reasons: Nix requires flake files to
be git-tracked, and one of the projects belongs to an organisation, where a committed
`flake.nix` would impose Nix on everyone and an ignored one could not be evaluated at all.
Keeping them here also means both shells share this flake's nixpkgs — one download, one set
of versions, consistent with the system.

Per project rather than global because the toolchains genuinely differ: one uses pnpm and
one uses npm, and only one needs Rust. Installing the union globally would put a 1.5 GB
Rust toolchain on the PATH while working on a Next.js app, and make it easy to run the
wrong package manager in the wrong repo and rewrite a lockfile.

---

## Installing this from scratch

Two audiences here: someone rebuilding this exact laptop, and someone who wants the config
on different hardware. The steps are the same; the difference is how much of it applies,
which is [spelled out below](#what-does-not-travel).

### 0. Before reinstalling — try the boot menu first

If this machine still boots at all, a broken rebuild is almost never worth reinstalling
over. systemd-boot lists **every previous generation** at startup; pick the last one that
worked and you are back, with the broken generation still on disk to inspect.

```fish
nixos-rebuild list-generations       # what is available
sudo nixos-rebuild switch --rollback # step back one, from a working session
```

Only what follows is for a genuinely dead disk or a new machine.

### 1. Install NixOS normally

Boot the official installer and partition however you like — this config does not depend on
the layout. For reference, this machine uses:

| Mount | Filesystem | Notes |
|---|---|---|
| `/boot` | vfat, 1 GB | EFI system partition |
| `/` | btrfs | top-level subvolume (`subvolid=5`) |
| `/home` | btrfs | `subvol=home`, same partition |
| `/nix` | btrfs | `subvol=nix`, same partition |

No swap partition — `configuration.nix` enables zram instead. UEFI and systemd-boot, so
Secure Boot must be off.

> **Set the hostname to `daf3r-starter`.** The flake output is named after
> `networking.hostName`, so a different hostname means `--flake ~/nixos-config` cannot find
> the configuration. On other hardware, rename it in both `flake.nix` and
> `configuration.nix` instead.

### 2. Clone the repo

```fish
nix-shell -p git --run 'git clone https://github.com/Daf3r/nixos-config ~/nixos-config'
```

It has to be at `~/nixos-config`. Several paths are written out in full — the out-of-store
symlinks in `home.nix`, the devshell references in each project's `.envrc` — and none of
them resolve from anywhere else.

### 3. Generate the hardware config

> **This is the step that catches people.** `hardware-configuration.nix` is **gitignored**,
> because it holds the filesystem UUIDs of one specific disk. It is not in the clone, and
> `configuration.nix` imports it, so the build fails until it exists.

The installer already wrote a correct one for your partitions. Copy it in:

```fish
sudo cp /etc/nixos/hardware-configuration.nix ~/nixos-config/
sudo chown $USER ~/nixos-config/hardware-configuration.nix
```

If you are doing this from a live ISO before the first boot, it is at
`/mnt/etc/nixos/hardware-configuration.nix`. To regenerate it later — after adding a disk,
say — `sudo nixos-generate-config --show-hardware-config` prints a fresh one from the
currently mounted filesystems.

### 4. Build

```fish
sudo nixos-rebuild switch --flake ~/nixos-config
```

First build pulls a lot. Noctalia's binary cache is declared in `configuration.nix`, so the
shell itself comes down prebuilt rather than compiling.

### 5. Log out — not optional

`daf3r` belongs to `networkmanager`, `wheel`, `video`, `i2c`, `docker` and `gamemode`, and
**group membership is inherited when a session starts**. Until a fresh login, three things
are quietly broken:

| Group | What stays broken |
|---|---|
| `gamemode` | Every privileged helper is refused by polkit. `gamemoded -s` still says "active" |
| `i2c` | Brightness keys only move the laptop panel; `ddcutil detect` finds nothing |
| `docker` | Every command needs sudo |

Check with `groups` after logging back in, then `gamemoded -t` for the honest gamemode test.

### 6. What the repo cannot give you

- **Wallpapers.** Not in the repo, [on purpose](#what-is-not-mine). Drop images into
  `~/Pictures/Wallpapers` — `wallpaper.nix` creates the directory, and `wallpaper-rotate`
  picks them up with no rebuild. Same for `~/Pictures/Fastfetch`.
- **Noctalia's app theming.** Run `noctalia msg templates-apply` once so the templates
  render the palette into kitty, GTK, Qt and niri. They **fail silently** when they cannot
  write — check that each target file actually changed rather than trusting the exit code.
- **Secrets.** Nothing in here is encrypted because nothing in here is a secret. SSH keys,
  the WireGuard tunnel and the GNOME keyring are all outside this repo and restored by hand.

### What does not travel

Roughly half of this is this-laptop-specific and will need editing on other hardware:

| File | Why it is specific |
|---|---|
| `terminal/tools.nix` | **Change `programs.git.settings.user` first.** It hardcodes a name and a GitHub noreply address, so every commit you make would be attributed to someone else until you do |
| `configuration.nix` | `users.users.daf3r`, the hostname, the timezone and the locale |
| `config/niri/config.kdl` | `output` blocks match by EDID strings from *these* two monitors |
| `gamemode.nix` | The panel is named by the same EDID string |
| `gpu.nix` | Assumes an NVIDIA dGPU driving every connector, MUX in discrete mode |
| `asus.nix` | asusd — ROG hardware only |
| `hardware-configuration.nix` | Regenerated per machine, as above |
| `devshells/` | Toolchains for two specific projects |

Everything else — the shell, the terminal, the theming, the app set — is portable.

## Maintenance

**Bumping Brave Origin.** Not in nixpkgs — it ships only through Brave's own apt/rpm
repository, so `pkgs/brave-origin.nix` unpacks the upstream `.deb`. Get the new version and
hash from the
[package index](https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages),
then update `version` and `hash`:

```fish
nix hash convert --hash-algo sha256 --to sri <sha256 from the index>
```

**Validating before switching.**

```fish
nh os build                                        # build without activating
niri validate -c ~/.config/niri/config.kdl         # niri config only
```
