# `upd` en build_failed y avisos falsos de VA-API — causas y arreglos

Trabajo directo sobre `main`, 2026-10-01. Síntoma reportado: `upd` «no sirve
prácticamente». Medido contra el sistema, no deducido.

## Estado de partida

`upd` mostraba `build_failed` desde la comprobación del 2026-09-30 y el motor
seguía terminando cada noche, así que el fallo no era que no arrancara.

## Causas

1. **El motor construye lo commiteado, no el working tree.** Hace
   `nix flake update` sobre `main` en `/var/lib/nixos-upd/wt`. Claude Desktop
   2.9939.4 ya no trae `share/applications/claude-desktop.desktop`, y el wrapper
   de `pkgs/claude-desktop-keyring.nix` lo nombraba a mano: `substitute` fallaba y
   con él todo el toplevel. El arreglo existía desde la actualización de apps del
   2026-09-29 (`2026-09-29-apps-upgrade.md`) pero estaba sin commitear, así que el
   motor seguía construyendo el wrapper roto.
2. **El blocker `dirty_tree` dejaba `upd apply` inutilizable.** Este repo está
   casi siempre sucio mientras se trabaja en él. El cambio que lo sustituye por el
   fast-forward de Git (que sólo se niega si pisaría una ruta) también estaba sin
   commitear.
3. **Los avisos `brave_vaapi_feature_missing` eran falsos.** Desde Brave 1.94 (no
   sólo en la 1.96) Chromium deja de embeber el nombre plano de las features y
   conserva sólo el identificador `k<Nombre>`. Medido entre 1.93.136 y 1.96.59:
   `SkiaGraphite`, `OverlayScrollbar`, `ParallelDownloading`,
   `WebAssemblyLazyCompilation` y las tres de VA-API pasan de `Nombre` a
   `kNombre`. `check-brave-vaapi.sh` sólo buscaba la forma plana y avisaba de las
   tres en cada comprobación desde entonces.

## Arreglos (cada uno en su commit)

- `claude-desktop-keyring`: reescribe todos los `.desktop` en vez de uno por nombre.
- `upd apply` conserva los cambios locales; `status` informa `prepared_conflict`
  por adelantado; el plugin llama al `upd` instalado.
- Bumps de Brave, ChatGPT y T3 Code, y actualización de inputs con DMS en v1.6.2.
- `check-brave-vaapi.sh` acepta `Nombre` o `kNombre`; sigue avisando si no está
  ninguna de las dos formas. Pruebas añadidas en `check-vaapi.bats`.

## Comprobado

- `HEAD` limpio (worktree aparte) construye el toplevel; `upd check` real pasa de
  `build_failed` a `ready`.
- La suite Bats del motor corre en el checkPhase del build y pasa; ShellCheck
  limpio; las 57 pruebas Node del plugin pasan.
- Mutación: con el script revertido a `grep -qx "$name"` fallan las dos pruebas
  nuevas. Contra los binarios reales 1.93.136, 1.96.59 y 1.96.60 el chequeo da
  cero avisos.

## Sin comprobar

- Que el hardware decode funcione de verdad con Brave 1.96.x: sólo se ha mirado el
  binario, no se ha reproducido vídeo ni medido CPU.

## Cuarto fallo, descubierto después: el commit automático arrastraba basura

Tras el primer `upd apply --boot` real, `main` hizo fast-forward a un commit
`auto: actualizacion preparada` que traía `noctalia.nix` (637 líneas) y su paleta,
muertos desde que se retiró el shell. Causa: el worktree privado del motor
conserva ese fichero sin trackear desde el 2026-08-21, `reset --hard` no borra
ficheros sin trackear y `git add -A` los metía en cada commit automático. Hasta
ahora no había llegado a `main` porque ningún `apply` había hecho el
fast-forward sobre uno de esos commits.

- El motor hace `git clean -fd` (sin `-x`, para no tocar el GC root `result`)
  tras el `reset --hard`. Prueba nueva en `nixos-upd.bats`; falla si se quita la
  línea. Suite completa: 175 pruebas.
- Los dos ficheros se quitan de `main` en un commit aparte.

## Decisiones sobre el trabajo pendiente del 29/09

- Se commitean `apps.nix` + `pkgs/curseforge.nix` (CurseForge, Burp Suite,
  Thunderbird) con su runbook, plan y diseño, y `storage.nix` (el segundo NVMe
  es hoy Windows con BitLocker y la partición btrfs `datos` quedó en 16 MB).
- **No** se commitea el parche de `claude-usage` (`usage-provider.patch`): sólo
  servía para ocultar Claude y se quiere ver Claude y Codex a la vez. Era además
  un parche sobre un plugin de terceros, que se rompe con cualquier cambio
  upstream de su `Daemon.qml`. Copia fuera del repo; quien lo quiera recuperar
  lo tiene en el commit de la sesión, no en `main`.
- `apply` reconstruye desde el working tree del repo, no desde la preparación:
  la generación dejada para el arranque ya llevaba Burp, CurseForge y Thunderbird
  aunque `main` aún no los declarase.
