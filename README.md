# daf3r's NixOS

Hyprland + [Noctalia v5](https://docs.noctalia.dev/v5/) on an ASUS ROG Strix G17 (G713PV).

Rebuild:

```
sudo nixos-rebuild switch --flake ~/nixos-config
```

(`nrs` is the fish abbreviation for that. `flakeup` = `nix flake update`, `ns` = nix search.)

The flake output is named after `networking.hostName`, so `--flake ~/nixos-config`
resolves `daf3r-starter` without spelling out the attribute.

## Layout

| File | What it holds |
|---|---|
| `configuration.nix` | Host basics, zram, users, Nix settings + Noctalia's binary cache |
| `desktops.nix` | Hyprland, SDDM, xdg portals, Noctalia's NixOS module |
| `gpu.nix` | NVIDIA RTX 4060 as primary GPU (see the note below) |
| `asus.nix` | asusd: fan profiles, keyboard RGB, ROG key, battery limit |
| `gaming.nix` | Steam, gamescope, gamemode, Proton-GE |
| `noctalia.nix` | Noctalia v5 settings, declarative (home-manager) |
| `wallpaper.nix` | swww + `wallpaper-rotate`, replacing Noctalia's wallpaper module |
| `gtk.nix` | Cursor theme, GTK theme/icons/font |
| `home.nix` | home-manager entrypoint, out-of-store symlinks |
| `apps.nix`, `terminal.nix`, `fontsAndNeeds.nix` | Packages |
| `terminal/` | kitty, fish, fastfetch, nvim |
| `pkgs/brave-origin.nix` | Brave Origin, packaged from Brave's own `.deb` |
| `config/hypr/hyprland.conf` | Live-editable Hyprland config |
| `config/nvim/` | LazyVim |
| `config/starship.toml` | Prompt; holds a generated palette block, see below |
| `config/noctalia/palettes/` | Local colour palette, copied into the store |

`config/hypr` and `config/nvim` are symlinked out of the Nix store, so edits there
apply without a rebuild. The rest of `config/` is not: `starship.toml` is read
through `$STARSHIP_CONFIG`, and the palette JSON is copied in by `noctalia.nix`,
so changing it does need a rebuild.

Two files in here are written to by Noctalia's theme templates rather than by
hand — `config/starship.toml` gets a palette block between `NOCTALIA` markers,
and `config/hypr/noctalia.conf` is generated wholesale and gitignored.

## Keybinds

| Keys | Action |
|---|---|
| `SUPER + D` / `SUPER + Space` | App launcher |
| `SUPER + F1` | Control Center |
| `SUPER + F2` | Noctalia Settings |
| `SUPER + F3` | Clipboard history |
| `SUPER + F4` | Session menu |
| `SUPER + W` | Shuffle wallpaper (swww) — not a picker; Noctalia's is disabled |
| `SUPER + L` | Lock screen |
| `ALT + Tab` | Window switcher |
| `Print` / `SHIFT + Print` | Screenshot region / fullscreen |
| `SUPER + Return` | kitty |
| `SUPER + B` | Brave Origin |
| `SUPER + E` | Dolphin |
| `SUPER + K` | Kate |
| `SUPER + Q` | Close window |

All the Noctalia binds go through `noctalia msg <verb>`. Run `noctalia msg --help`
for the full verb list — this is the v5 syntax and it replaced v4's
`noctalia-shell ipc call <panel> <verb>`.

## Noctalia settings are declarative

`~/.config/noctalia/config.toml` is a read-only symlink into the Nix store,
generated from `programs.noctalia.settings` in `noctalia.nix` and validated on
every rebuild by `noctalia config validate`.

**But that file is not the whole story.** Noctalia merges it with a second,
mutable one at `~/.local/state/noctalia/settings.toml`, which is what the
Settings GUI writes to — and precedence is *per setting*, not global. A theme
picked in the GUI has been observed to survive a full rebuild and win over
`noctalia.nix`. The state file is also written *from* the Nix config in some
cases, so the two are not simply adversaries.

Practically: use the GUI to try things, then write what you keep into
`noctalia.nix`. If a setting there seems to be ignored, look for it in the state
file before assuming the Nix side is wrong, and prefer `noctalia msg <verb>`
(e.g. `color-scheme-set`) to hand-editing state — hand edits do not reliably
take effect.

`noctalia config export full` dumps every key with its default, which is the
fastest way to find options; `noctalia theme --list-templates` lists the app
theming templates.

### App theming

`theme.templates.builtin_ids` and `community_ids` are both **opt-in and empty by
default** — `enable_builtin_templates = true` on its own themes nothing. Several
templates append an include line to a config that home-manager owns as a
read-only symlink, and they either fail or replace the symlink when they cannot
write. Where that applies, the include is written into the home-manager file up
front so the template's own idempotence check short-circuits; see the comments
in `terminal/kitty.nix` and `gtk.nix` before changing those strings.

## Displays

Both are pinned explicitly in `config/hypr/hyprland.conf`; `preferred`/`auto`
picked the wrong refresh rates and put the external monitor on the wrong side.

| Output | Mode | Scale | Logical size |
|---|---|---|---|
| `eDP-1` (laptop, left) | 2560x1440@240 | 1.6 | 1600x900 |
| `HDMI-A-1` (MSI, right) | 1920x1080@100 | 1 | 1920x1080 |

Scale 1.6 was chosen because 2560/1.6 and 1440/1.6 are both integers, so there
is no fractional-scaling blur.

Two things follow from it, and both have already caused bugs:

- **The laptop is the narrow screen, not the wide one.** Anything laid out
  horizontally — the Noctalia bar especially — has 1600 logical pixels there
  against the MSI's 1920. Overflow is invisible from the MSI, and Noctalia drops
  overflowing bar widgets silently.
- **Noctalia v5.0.0 mis-sizes its wallpaper surface at fractional scales**,
  which is why `wallpaper.nix` disables that module and draws the background
  with swww instead. The full write-up is in that file.

## GPU note

This laptop's internal panel (`card1-eDP-1`) and `card1-HDMI-A-1` are both wired
to the NVIDIA RTX 4060; every connector on the AMD iGPU reads `disconnected`.
Mind the card number when checking `/sys/class/drm`: both GPUs expose an eDP
connector, and `card2-eDP-2` is the iGPU's unused one, not the panel. The
display MUX is in discrete mode, so NVIDIA is the primary GPU and PRIME offload
does not apply. `supergfxd` is deliberately disabled — see `asus.nix` for why.
Switch GPU modes in the BIOS.

## CS2

Steam is installed with the 32-bit runtime, gamescope and gamemode. Set CS2's
launch options to:

```
gamemoderun %command%
```

Tearing is enabled for CS2 only, via a `windowrule` matching `class:^(cs2)$`.

## Bumping Brave Origin

Brave Origin is not in nixpkgs. Get the new version and hash from
<https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages>,
then update `version` and `hash` in `pkgs/brave-origin.nix`
(`nix hash convert --hash-algo sha256 --to sri <sha256 from the index>`).
