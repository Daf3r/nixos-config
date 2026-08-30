# Instrucciones para Codex

Este repositorio es una configuración completa de NixOS con Home Manager para un
host principal (`daf3r-starter`) y adaptaciones locales para otros equipos. Estas
reglas aplican a todo el repositorio.

## Regla crítica: siempre usar el flake

No ejecutes nunca un rebuild ambiguo:

```bash
sudo nixos-rebuild switch
sudo nixos-rebuild switch --file /etc/nixos/configuration.nix
sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix
```

Esos comandos aplican la configuración mínima generada por el instalador y pueden
reemplazar el escritorio completo de este repositorio. El comando correcto incluye
siempre el flake y el atributo del host:

```bash
sudo env NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-rebuild switch \
  --flake /home/<usuario>/nixos-config#daf3r-starter
```

Sustituye `<usuario>` por el usuario real. En la adaptación actual es `mel`, por lo
que la ruta es `/home/mel/nixos-config`. `daf3r-starter` es el nombre del host y del
atributo del flake; no lo cambies solo porque la cuenta se llame `mel`.

`hardware-configuration.nix` sí puede copiarse desde `/etc/nixos`, porque es el
archivo generado por el instalador que describe discos y hardware. No copies
`/etc/nixos/configuration.nix` encima de la configuración del repositorio.

## Flujo obligatorio antes de aplicar cambios

1. Inspecciona el estado y no sobrescribas cambios del usuario:

   ```bash
   git status --short --branch
   git diff --check
   ```

2. Valida el flake:

   ```bash
   nix --extra-experimental-features 'nix-command flakes' \
     flake check --no-build --all-systems
   ```

3. Construye la generación sin activarla:

   ```bash
   nix --extra-experimental-features 'nix-command flakes' \
     build --no-link \
     '.#nixosConfigurations.daf3r-starter.config.system.build.toplevel'
   ```

4. Solo después aplica el cambio con `nixos-rebuild switch --flake ...`. Si el
   comando necesita contraseña, deja que `sudo` la solicite en la terminal; nunca
   pidas, guardes ni escribas contraseñas en archivos, comandos o commits.

Después de un switch comprueba:

```bash
systemctl --failed
systemctl is-system-running
```

Si se rompe una generación, no borres generaciones ni repares el store a ciegas.
Primero conserva el diagnóstico y usa el menú de systemd-boot o `nixos-rebuild
switch --rollback` desde una generación que funcione.

## Ramas y máquinas

- `main` es la configuración canónica del ASUS ROG de `daf3r`.
- Las adaptaciones de otra máquina deben vivir en una rama local como
  `local/mel`; no subas UUID, hardware, monitores o decisiones específicas de esa
  máquina a `main`.
- En el equipo de `mel`, conserva `local/mel` y adapta el hardware allí. El host
  sigue siendo `daf3r-starter` salvo que se renombre de forma consistente en
  `flake.nix`, `configuration.nix` y `updates/nixos-upd.sh`.
- Antes de rebasar una rama local sobre `origin/main`, revisa los conflictos y
  conserva las adaptaciones de hardware del equipo destino.
- No hagas commits como `root`; el repositorio debe pertenecer a su usuario normal.

## Reglas específicas de la adaptación de `mel`

- `home.username` y `home.homeDirectory` deben apuntar a `mel` y `/home/mel`.
- No reintroduzcas `./wireguard.nix` ni `./virtualisation.nix` en `configuration.nix`:
  ese equipo no usa el túnel WireGuard netcup ni VMware.
- La GPU del escritorio es una NVIDIA GTX 1660 SUPER. No reutilices la configuración
  ASUS/PRIME del portátil ni bloques de monitores del panel del ASUS.
- Las instalaciones globales de npm van a `~/.npm-global`. Usa `npm` como el usuario
  normal, nunca `sudo npm`; el prefijo está declarado en `home.nix` y su `bin` está
  en `PATH`.
- Las dependencias de proyectos no van globales: `remesafam` usa su devshell con
  pnpm y `gymnova` su devshell con npm/Rust.

## Edición, secretos y comandos peligrosos

- Edita archivos del repositorio con cambios revisables y valida el diff. No edites
  `/run/current-system`, `/nix/store` ni archivos generados del sistema.
- No pongas contraseñas, claves SSH privadas, tokens, `/etc/wireguard/*.conf`,
  archivos `.env` ni credenciales en Git.
- No uses `git reset --hard`, `git checkout --`, `rm -rf`, `nix-store --repair` ni
  limpiezas destructivas sin confirmar el objetivo exacto con el usuario.
- Los módulos `updates.nix` y `updates/` son sensibles: si se modifican, ejecuta
  las pruebas existentes además de `flake check` y el build.
- Si una solicitud es solo de diagnóstico, no actives una nueva generación ni
  modifiques archivos sin autorización explícita.

## Herramientas CLI

Codex se instala como usuario mediante npm:

```bash
npm config get prefix
npm install --global @openai/codex
codex
```

Claude Code, si se necesita, usa el mismo prefijo. La autenticación de Codex y de
otras herramientas siempre se realiza de forma interactiva y nunca se versiona.
