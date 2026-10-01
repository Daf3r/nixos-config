# Full NixOS and Applications Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Actualizar y aplicar todas las fuentes de software verificables del host NixOS `daf3r-starter`, desde Discord y el resto de apps declarativas hasta Flatpak, perfiles Nix y npm global.

**Architecture:** Primero se actualizan las fuentes declarativas y los pins de paquetes locales, después se validan con `flake check` y una construcción completa. Solo una generación que compile se activa con el flake explícito; las fuentes fuera de Nix se actualizan con su propio gestor y se comprueban después.

**Tech Stack:** Nix flakes, NixOS, Home Manager, systemd, Flatpak y npm.

**Spec:** `docs/superpowers/specs/2026-08-31-full-upgrade-nixos.md`

## Global Constraints

- Target repo: `/home/daf3r/nixos-config`; flake attribute: `daf3r-starter`.
- Preserve existing local changes in `README.*`, `apps.nix`, `pkgs/curseforge.nix` and documentation.
- Do not use an ambiguous `nixos-rebuild`; activation must use `--flake /home/daf3r/nixos-config#daf3r-starter`.
- Do not commit, push, garbage-collect or delete generations.
- Do not use `sudo npm`; npm runs as user `daf3r`.
- A source that cannot be queried or verified remains explicitly pending.

## File Structure

- Create: `docs/superpowers/specs/2026-08-31-full-upgrade-nixos.md` — scope and completion criteria.
- Create: `docs/superpowers/plans/2026-08-31-full-upgrade-nixos.md` — execution record and checkpoints.
- Modify if an upstream source moved: `flake.lock` — resolved flake inputs only.
- Modify if a local detector finds drift: `pkgs/brave-origin.nix`, `pkgs/t3code-app.nix`, `pkgs/chatgpt-desktop.nix`, or `pkgs/minecraft-launcher.nix`.
- Runtime-only state: Nix profiles, Flatpak installations, npm global prefix, and `/run/current-system`.

### Task 1: Inventory and capture the baseline

**Files:**
- Read: `/home/daf3r/nixos-config/flake.lock`, local package pins, Nix profile, Flatpak and npm state.
- Modify: this plan's checkboxes with observed baseline.

- [x] Confirmed branch `main`, active generation `26.11.20260819.ffb3c9b`, no failed systemd units, Nix profile entries `appimage-run`/`python3`, Flatpak runtime updates, and npm `claude-code` drift.
- [x] Recorded that the installed Discord path is `discord-1.0.153`; `nixos-unstable` exposes `discord-1.0.155`.
- [x] Recorded the existing `upd` report: `home-manager`, `nixpkgs`, Brave Origin, T3 Code and ChatGPT Desktop were already prepared for update; it also reported a reboot requirement.

### Task 2: Update declarative sources and local package pins

**Files:**
- Modify: `flake.lock` through `nix flake update`.
- Modify conditionally: local package files through the existing `updates/bump-*.sh` detectors.

- [x] Ran `nix --extra-experimental-features 'nix-command flakes' flake update`; `nixpkgs` moved to `d2f6794` and `home-manager` to `82c265f`. The pinned DMS tag and unchanged external inputs did not move.
- [x] Ran all four local detectors. Brave Origin moved to `1.94.117`, T3 Code to `0.0.37`, ChatGPT Desktop to `26.825.51511` with a refreshed hash, and Minecraft's bootstrap hash was already current.
- [x] `git diff --check` passes; only `flake.lock` and the three changed local package pins were modified by this task so far.

### Task 3: Validate and build the complete generation

**Files:**
- Read: flake and module evaluation results.
- Runtime output: temporary Nix store paths only.

- [x] `flake check --no-build --all-systems` terminó con `all checks passed!`.
- [x] La construcción del toplevel terminó correctamente y produjo la generación `nixos-system-daf3r-starter-26.11.20260829.d2f6794`.
- [x] No hubo fallos de validación ni de construcción que reportar.

### Task 4: Upgrade non-flake user software

**Files:**
- Runtime-only: Nix profile, Flatpak installations and `/home/daf3r/.npm-global`.

- [x] `nix profile upgrade --all` terminó correctamente; `python3` quedó en Python 3.14.7 y `appimage-run` no tenía cambio.
- [x] `flatpak update -y` instaló los tres runtimes pendientes; las comprobaciones separadas de apps del sistema y de usuario reportan `Nothing to update`.
- [x] `npm update --global` actualizó el árbol; `claude-code` requirió una segunda instalación explícita con `--allow-scripts=@anthropic-ai/claude-code` y `claude --version` reporta `2.1.251`. `npm outdated --global` quedó vacío.
- [x] `org.vinegarhq.Sober2` pertenece al remoto local `sober-local`, sin metadatos AppStream ni canal online; no tiene una actualización remota comprobable.

### Task 5: Activate and verify the NixOS generation

**Files:**
- Runtime-only: `/run/current-system`, system profile and systemd units.

- [ ] Activar requiere autenticación `sudo` interactiva; esta sesión no puede introducir la contraseña.
- [ ] Run `sudo env NIX_CONFIG='experimental-features = nix-command flakes' nixos-rebuild boot --flake /home/daf3r/nixos-config#daf3r-starter` because the validated closure changes kernel/NVIDIA/Mesa.
- [ ] Verify `readlink -f /run/current-system`, `nixos-version`, `systemctl is-system-running`, `systemctl --failed`, Discord's running store path and all package-manager inventories.
- [ ] Update this plan to mark only evidenced checks complete and list real pending items.
