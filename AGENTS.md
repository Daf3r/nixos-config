# nixos-config — instrucciones del proyecto

Configuración de NixOS con Home Manager del ASUS ROG de daf3r (host y atributo
del flake `daf3r-starter`). Las reglas generales están en `~/AGENTS.md`; aquí
sólo lo propio de este repo.

## Regla crítica: siempre el flake

Nunca un rebuild ambiguo:

```bash
sudo nixos-rebuild switch
sudo nixos-rebuild switch --file /etc/nixos/configuration.nix
sudo nixos-rebuild switch -I nixos-config=/etc/nixos/configuration.nix
```

Aplican la configuración mínima del instalador y pueden sustituir el escritorio
entero. El comando correcto lleva siempre el flake y el host:

```bash
sudo env NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-rebuild switch --flake /home/daf3r/nixos-config#daf3r-starter
```

`hardware-configuration.nix` sí puede venir de `/etc/nixos` (describe discos y
hardware); `/etc/nixos/configuration.nix` nunca se copia encima del repo.

## Flujo de un cambio

1. `git status --short --branch` y `git diff --check`: hay trabajo sin commitear
   a menudo; no se pisa.
2. Validar el flake:

   ```bash
   nix --extra-experimental-features 'nix-command flakes' \
     flake check --no-build --all-systems
   ```

3. Construir la generación sin activarla:

   ```bash
   nix --extra-experimental-features 'nix-command flakes' \
     build --no-link \
     '.#nixosConfigurations.daf3r-starter.config.system.build.toplevel'
   ```

4. **El `switch` lo corre daf3r**, que necesita root. El agente le da el comando
   exacto de arriba y, para comprobar que surtió efecto:

   ```bash
   systemctl --failed
   systemctl is-system-running
   ```

   más la comprobación concreta de lo que cambió (el servicio, el binario, el
   fichero en `/run/current-system`).
5. Con check y build en verde y el cambio haciendo lo que debe, commit y push.

Ficheros nuevos: `git add` antes del check, o el flake no los ve.

Si una generación se rompe, no se borran generaciones ni se repara el store a
ciegas: se conserva el diagnóstico y se vuelve por el menú de systemd-boot o
`nixos-rebuild switch --rollback` desde una generación que funcione.

## Ramas y otras máquinas

- `main` es la configuración del ROG de daf3r.
- Otra máquina vive en su rama local (`local/<usuario>`), con su hardware, UUID
  y monitores; nada de eso sube a `main`. Guía y reglas de esa adaptación:
  `docs/instalacion-otro-usuario.md`.
- No se hacen commits como `root`: el repo pertenece al usuario normal.

## Zonas sensibles

- `updates.nix` y `updates/` (el widget y el motor de `upd`): si se tocan,
  además de check y build, correr sus pruebas (`updates/tests/*.bats` y
  `updates/dms-plugin/tests/`).
- Nunca en git: contraseñas, claves SSH privadas, tokens, `/etc/wireguard/*.conf`,
  `.env` ni credenciales.
- `git reset --hard`, `git checkout --`, `rm -rf`, `nix-store --repair` y
  limpiezas del store se confirman con el objetivo exacto antes.
- No se edita `/run/current-system`, `/nix/store` ni ficheros generados del
  sistema.
- Una petición de diagnóstico no autoriza activar una generación ni editar.

## Herramientas

- Globales de npm (Codex, Claude Code) en `~/.npm-global`, como usuario, nunca
  `sudo npm`; el prefijo está en `home.nix` y su `bin` en `PATH`.
- Las dependencias de proyecto no van globales: cada proyecto tiene su devShell
  (`remesafam` con pnpm, `gymnova` con npm y Rust).
- La autenticación de Codex y demás CLIs es interactiva y nunca se versiona.
