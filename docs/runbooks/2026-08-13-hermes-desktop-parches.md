# Hermes Desktop: los dos parches que lo hacen abrir desde el menú

**Fecha**: 2026-08-13 · **Versión afectada**: Hermes Agent 0.20.0 (2026.8.3)
**Dónde viven**: `~/.hermes/hermes-agent`, que es un checkout git que
`hermes update` actualiza solo.

Sin estos dos cambios, `hermes desktop` **funciona desde la terminal y no abre
desde el icono**, que es justo el modo en que no se ve ningún error: la entrada
`.desktop` lleva `Terminal=false`.

Ninguno es específico de NixOS en su causa, aunque aquí fallan siempre.

## 1. La entrada del menú apuntaba a un intérprete sin dependencias

`resolve_exec_command()` (`hermes_cli/linux_desktop_entry.py`) construye el
`Exec=` a partir de `resolve_hermes_bin()`, cuya primera prioridad es
`sys.argv[0]`. Pero bajo el shim instalado en `~/.local/bin/hermes` —un script
bash que hace `exec venv/bin/python <checkout>/hermes`— ese `argv[0]` es **el
entrypoint del checkout**, no el shim. El entrypoint lleva
`#!/usr/bin/env python3`, así que el lanzador lo ejecuta con el Python del
sistema y muere antes de pintar nada:

```
ModuleNotFoundError: No module named 'yaml'
```

El arreglo prefiere el shim, que sí arrastra el intérprete del venv. **No basta
con `shutil.which("hermes")`**, que fue el primer intento y volvió a fallar el
mismo día: si la sesión gráfica arrancó antes del switch que puso
`~/.local/bin` en `home.sessionPath`, las apps lanzadas desde ella heredan el
PATH viejo y `which` no encuentra nada. Por eso `_installed_shim()` mira la
ruta de instalación **directamente** cuando el PATH falla.

Ese fue el fallo real del 2026-08-13: el PATH ya estaba declarado y aplicado
(switch de las 08:07), pero la sesión de niri era de las 07:03, y la entrada
que Hermes regeneró a las 08:16 volvió a salir rota.

## 2. El helper del sandbox pedía sudo en cada lanzamiento

`_desktop_linux_sandbox_fixup()` (`hermes_cli/main.py`) exige que
`chrome-sandbox` sea `root:root 4755` y, si no lo es, lanza `sudo chown/chmod`.
Su único escape es leer
`/proc/sys/kernel/apparmor_restrict_unprivileged_userns`, un fichero de Ubuntu
23.10+ que aquí **no existe**. Desde un icono no hay TTY ni askpass:

```
sudo: a terminal is required to read the password
✗ Failed to configure Electron's Linux sandbox helper
```

Y no basta con arreglar los permisos una vez a mano: **cada rebuild del desktop
recrea el helper** como `daf3r:daf3r 0755`, así que volvería en la siguiente
actualización.

El arreglo salta el fixup cuando el sandbox por user namespaces funciona, que es
el caso de esta máquina. Chromium solo recurre al helper SUID cuando no puede
crear el namespace, así que aquí sobra. El probe **tiene que anidar**
(`unshare --user --map-root-user unshare --user true`): el gate real de Chromium
es `Credentials::CanCreateProcessInNewUserNS()`, que prueba un namespace
interno, y un `unshare -U` suelto da falsos positivos.

## Cómo se comprobó que abre

No basta con que el comando no dé error: hay que ver la ventana. Se lanza con el
entorno del lanzador —no con el de la terminal, que tiene un PATH más rico— y se
le pregunta al compositor:

```fish
env -i HOME=/home/daf3r USER=daf3r \
  PATH=(systemctl --user show-environment | sed -n 's/^PATH=//p') \
  XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 DISPLAY=:0 \
  XDG_CURRENT_DESKTOP=niri DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  /home/daf3r/.local/bin/hermes desktop

niri msg windows | grep Hermes   # debe listar App ID "Hermes"
```

## El blindaje: la entrada ya no la escribe Hermes

Los parches viven en un checkout que se actualiza solo, así que no son defensa
suficiente. Desde el 2026-08-13 `hermes.desktop` está declarado en `home.nix`
(`xdg.dataFile."applications/hermes.desktop"`) y es un **symlink de solo lectura
al store**.

**Tiene que ser `xdg.dataFile`, no `xdg.desktopEntries`.** El primer intento usó
`xdg.desktopEntries` y no blindó nada: esa opción construye un paquete y lo
instala por `home.packages`, así que la entrada aterriza en
`/etc/profiles/per-user/daf3r/share/applications/` mientras Hermes sigue
reescribiendo la de `~/.local/share/applications/` — que `XDG_DATA_DIRS` ordena
**por delante**, de modo que la rota seguía ganando y además salía un icono
duplicado en el menú. Solo un fichero en la ruta exacta que Hermes escribe lo
detiene. El switch salió verde y el servicio de home-manager también: el fallo
solo se vio mirando si el fichero era symlink.

Hermes sigue intentando reescribirlo en cada lanzamiento y falla con `OSError`,
que su propio código ya trata como no fatal —"a convenience, never a reason to
fail a launch"—, así que la app arranca igual y la entrada correcta sobrevive.
El parche 1 pasa a ser red de seguridad para si algún día se quita la
declaración.

Consecuencia práctica: **editar `~/.local/share/applications/hermes.desktop` a
mano ya no sirve de nada**. Se cambia en `home.nix` y se aplica con un switch.
El fichero que había antes queda como `hermes.desktop.backup`
(`backupFileExtension` del flake).

## Si un `hermes update` los pierde

`hermes update` hace stash de los cambios locales y los reaplica, así que lo
normal es que sobrevivan. Si upstream toca esas mismas líneas habrá conflicto y
el propio CLI imprime la guía del stash. Para reponerlos:

```fish
cd ~/.hermes/hermes-agent
git apply ~/nixos-config/docs/runbooks/2026-08-13-hermes-desktop.patch
hermes desktop --force-build
```

El síntoma de que se perdió el parche 1 **ya no es visible**: con la entrada
declarada en `home.nix`, el icono sigue abriendo aunque el parche desaparezca.
Se comprueba a mano:

```fish
cd ~/.hermes/hermes-agent
git diff --stat hermes_cli/          # vacío = se perdieron los dos
git stash list                       # ahí estarán si hubo conflicto
```

El del parche 2 sí se ve: `✗ Failed to configure Electron's Linux sandbox
helper`, pero solo desde la terminal.

El parche 1 trae su propio test de regresión
(`test_exec_prefers_local_bin_shim_when_it_is_not_on_path`). Para correrlo hace
falta pytest, que el venv de Hermes no trae:

```fish
cd ~/.hermes/hermes-agent
~/.hermes/bin/uv pip install --python venv/bin/python pytest
venv/bin/python -m pytest tests/hermes_cli/test_linux_desktop_entry.py -q
```

## Lo que corresponde hacer con esto

Los dos son defectos de upstream y ninguno depende de NixOS para existir: el
primero rompe la entrada del menú en cualquier instalación con venv, y el
segundo pide sudo en cualquier host sin la restricción de AppArmor de Ubuntu.
Son candidatos a PR en `NousResearch/hermes-agent` — pequeños, reproducibles y
con la causa aislada. Ojo: el área del `chrome-sandbox` ya estaba saturada en
2026-08 (ocho PRs abiertos solapados, ninguno mergeado), así que el primero es
mejor apuesta que el segundo.

**Decidido el 2026-08-13: no se manda nada upstream por ahora.** El blindaje de
`home.nix` quita la urgencia, y los parches quedan documentados aquí. Si algún
día se reabre, el diff ya está listo en el `.patch` de al lado.
