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

## Fuera de alcance de este registro

Sin commitear a la espera de decisión de daf3r: `storage.nix` (quita el montaje
de `/mnt/datos`), `apps.nix` + `pkgs/curseforge.nix` (CurseForge, Burp Suite,
Thunderbird), el parche de `claude-usage` y la documentación asociada.
