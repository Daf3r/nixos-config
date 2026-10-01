# Actualización de todas las aplicaciones — 2026-09-29

**Objetivo:** actualizar las fuentes verificables de aplicaciones de
`daf3r-starter`, el perfil Nix del usuario, Flatpak y npm global, y preparar una
generación NixOS validada.

**Base activa:** `26.11.20260922.6774f7b`, sistema `running`, sin unidades
fallidas. Se conserva el trabajo local preexistente. Esta ejecución no crea
commits ni hace push.

## Registro

- [x] `nix flake update`: Nixpkgs pasó a `7a0f122f5090` (28-09), Home Manager
  a `7b4c5ec` (25-09) y Claude Desktop a `55ba585` (28-09). DMS se fijó
  explícitamente en v1.6.2 (17-09), la última versión estable revisada; el
  input `dms-plugins` no cambió.
- [x] Detectores de paquetes locales: Brave Origin `1.95.104 → 1.96.59`;
  ChatGPT Desktop `26.917.62051 → 26.924.51851` con hash actualizado. T3 Code
  `0.0.42` y el hash del bootstrap de Minecraft ya estaban al día. El hash de
  CurseForge coincide con el AppImage publicado en su URL oficial `latest`.
- [x] `flake check --no-build --all-systems`: correcto.
- [x] Build del toplevel: correcto, salida
  `/nix/store/cg409qlwhc0gxx14d0hcf4y1jf83b8wc-nixos-system-daf3r-starter-26.11.20260928.7a0f122`.
- [x] El checkPhase de `nixos-upd` corrió sus 172 pruebas Bats y ShellCheck; la
  suite Node del plugin pasó `57/57`.
- [x] Perfil Nix actualizado contra el mismo input Nixpkgs del flake. Python
  continúa en `3.14.7`; `appimage-run` quedó actualizado.
- [x] npm global actualizado: Claude Code `2.1.282 → 2.1.284` y Codex
  `0.156.1 → 0.159.0`. Se permitió el postinstall solo para
  `@anthropic-ai/claude-code`; ambos comandos informan su versión y
  `npm outdated --global` queda vacío.
- [x] Flatpak del sistema actualizado desde Flathub; se instaló también
  `org.freedesktop.Platform.GL.nvidia-595-104-02` para la generación nueva.
  La consulta de actualizaciones de Flathub quedó vacía.
- [ ] `org.vinegarhq.Sober2` sigue sin fuente de actualización comprobable:
  `sober-local` es un remoto local sin summary/AppStream. Se conserva instalado.
- [ ] daf3r debe preparar la generación con el comando de activación de abajo y
  reiniciar cuando le convenga. La generación cambia Xanmod `7.2.6 → 7.2.8` y
  NVIDIA `595.99.02 → 595.104.02`, así que se usa `boot` y no se activa en
  caliente desde esta sesión.

## Activación y comprobación pendiente

```bash
sudo env NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-rebuild boot --flake /home/daf3r/nixos-config#daf3r-starter
```

Después del reinicio, comprobar:

```bash
readlink -f /run/current-system
nixos-version
nvidia-smi
systemctl is-system-running
systemctl --failed
```

El cierre preparado actualiza, entre otros, DMS `1.6.0 → 1.6.2`, Claude
Desktop `2.7032.0 → 2.9939.4`, Brave Origin `1.95.104 → 1.96.59`, ChatGPT
Desktop `26.917.62051 → 26.924.51851` y Thunderbird `156.0 → 156.0.1`.
