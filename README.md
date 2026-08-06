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
| `home.nix` | home-manager entrypoint, out-of-store symlinks |
| `apps.nix`, `terminal.nix`, `fontsAndNeeds.nix` | Packages |
| `pkgs/brave-origin.nix` | Brave Origin, packaged from Brave's own `.deb` |
| `config/hypr/hyprland.conf` | Live-editable Hyprland config |
| `config/nvim/` | LazyVim |

`config/` is symlinked out of the Nix store, so edits there apply without a rebuild.
Noctalia is the exception — it is fully declarative, see below.

## Keybinds

| Keys | Action |
|---|---|
| `SUPER + D` / `SUPER + Space` | App launcher |
| `SUPER + F1` | Control Center |
| `SUPER + F2` | Noctalia Settings |
| `SUPER + F3` | Clipboard history |
| `SUPER + F4` | Session menu |
| `SUPER + W` | Wallpaper picker |
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

**Changes made in Noctalia's own Settings GUI do not survive a rebuild.** Use the
GUI to find what you like, then write it back into `noctalia.nix`. The full set
of keys with defaults is in the upstream `example.toml`.

## GPU note

This laptop's internal panel (`eDP-2`) and `HDMI-A-1` are both wired to the
NVIDIA RTX 4060; every connector on the AMD iGPU reads `disconnected`. The
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
