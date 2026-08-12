# ChatGPT/Codex Desktop oficial para Linux — plan de migración

Fecha: 2026-08-12  
Rama: `codex/chatgpt-official-deb`  
Base: `main` en `51efe51`

## Objetivo

Reemplazar la conversión comunitaria de `codex-desktop-linux`, que transforma el
DMG de macOS, por el artefacto Linux `.deb` publicado oficialmente para x86_64
en `openai.com/codex/`. El resultado debe seguir siendo declarativo, reproducible
y compatible con NixOS/niri.

## Estado y límites

- La página oficial muestra `x64 .deb`, `arm64 .deb`, `x64 .rpm` y `arm64 .rpm`.
- Esta máquina es `x86_64`; se implementará primero el `.deb` x64.
- No se instalará el `.deb` con `dpkg`: Nix extraerá el artefacto y controlará
  launcher, desktop entry y dependencias.
- Se conservará el wrapper `--password-store=gnome-libsecret` hasta demostrar
  que el cliente oficial resuelve correctamente las credenciales bajo niri.
- El wrapper aplica `--force-device-scale-factor=1.25` para compensar la escala
  reducida observada en la pantalla del usuario.
- No se habilitará ningún updater imperativo dentro de `/nix/store`.
- El stash `trabajo local previo a upd-barra` no forma parte de este trabajo.

## Fases

### 1. Fuente verificable — completada

- URL x64 obtenida del botón oficial: `https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb`.
- Artefacto verificado: versión `26.803.81509`, arquitectura `amd64`, SHA-256
  `a9bf91a368f9f7c4eea38082a9fb8fb46b8d005b719a6d7715d2e5a1982c38eb`, SRI
  `sha256-qb+Ro2j598Tuo4CCqfuPtGuNAFtxmm13FdLloZgsOOs=`.
- El artefacto procede del dominio de distribución de OpenAI y no
  de un mirror comunitario.
- El enlace funciona sin sesión y se fija junto con el hash; se debe revisar
  el hash cuando OpenAI publique una nueva build.

### 2. Paquete Nix — completada

- Crear `pkgs/chatgpt-desktop.nix` con `stdenv.mkDerivation` y extracción con
  `ar`/`tar`, sin ejecutar `dpkg`.
- Instalar el binario y recursos bajo `/nix/store`, preservando launcher,
  desktop entry e icono.
- Añadir wrapper de keyring, sin updater de terceros.
- Dependencias ELF glibc resueltas con `autoPatchelfHook`; los módulos Qt y
  musl alternativos que el artefacto incluye se marcan como opcionales.

### 3. Integración — completada

- Eliminar `codex-desktop-linux` de `flake.nix` y del lock.
- Sustituir la llamada al paquete comunitario en `home.nix`.
- Mantener el CLI `codex` separado del cliente gráfico.

### 4. Regresiones — parcialmente completada

- Test de metadata: arquitectura, nombre, versión y desktop entry.
- Test del wrapper: `--password-store=gnome-libsecret` llega al proceso.
- Test de que no se conserva updater imperativo.
- Build del paquete y del sistema completo completado; el desktop entry apunta
  al wrapper Nix y no quedan referencias de código al input comunitario.
- Falta ejecutar la aplicación en la sesión gráfica real.

### 5. Aceptación en la máquina — pendiente del usuario

- `nh os switch` desde este worktree.
- Arranque del cliente oficial y login.
- Confirmar Codex, Chat/Work si están incluidos en la build, tray, URI handlers
  y persistencia de sesión después de cerrar y reabrir.
- Comparar el comportamiento con la instalación actual antes de retirar el
  fallback.

## Decisiones abiertas

1. Si el cliente oficial Linux ya contiene su propio manejo de keyring y si el
   wrapper sigue siendo necesario.
2. Si OpenAI publica releases con versionado semántico o timestamps.

## Criterio de terminado

El paquete comunitario deja de aparecer en `flake.nix`, `flake.lock` y `home.nix`;
el build declarativo instala el `.deb` oficial con hash fijo; el cliente arranca
en niri, conserva la sesión y el sistema pasa las verificaciones pertinentes.

No incluye commit, push ni switch de producción: se entregan preparados para
revisión explícita.
