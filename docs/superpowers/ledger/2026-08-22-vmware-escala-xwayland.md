# VMware redimensionándose solo — causa raíz y modo VM

Trabajo directo sobre `main`, 2026-08-22. Síntoma reportado: al abrir una VM la
ventana de Workstation se ajusta al tamaño del invitado, la resolución de dentro
baila, el fullscreen no encaja y cruzar al MSI lo descuadra. En Windows no pasa.

Todo lo que sigue está medido contra el sistema, no deducido.

## La causa raíz es una sola

VMware Workstation es X11 y llega al compositor por `xwayland-satellite`, que
**no tiene noción de escala fraccional por output**: entrega a los clientes X11
los píxeles *físicos* del panel mientras niri coloca la ventana en el espacio
*lógico* que produce `scale 1.6`.

Medido con el invitado AD abierto y el panel a 1.6:

| Quién mide la misma ventana | Resultado |
|---|---|
| `niri msg windows` | 1600 x 900 |
| `xwininfo -root -tree` | **2560 x 1440** |

Factor 1,6 exacto. VMware dimensiona su ventana y pilota la resolución del
invitado desde el número de X11, así que el autofit persigue un objetivo 1,6
veces mayor que los píxeles que hay en pantalla, y el bucle no converge.

Lo mismo rompía la geometría global. Con el panel a 1.6, `xrandr` reportaba:

```
0: +eDP-2    2560/380x1440/210 +0+180     <- tamaño físico...
1: +HDMI-A-1 1920/530x1080/290 +1600+0    <- ...pero posición lógica
```

El eDP dice ocupar x 0..2560 y el MSI empezar en x=1600: **960 px de solape** en
una geometría que para niri no se solapa. De ahí que fullscreen y el cambio de
monitor fallen.

## No hay ajuste que lo arregle a 1.6

Comprobado, no supuesto:

- **`xwayland-satellite` no acepta ninguna opción de escala.** Cualquier
  argumento que no sea el número de display le hace `panic` en `src/main.rs:241`
  — `--help` y `--version` incluidos.
- **niri no expone escala para XWayland.** No hay opción de config ni de
  `window-rule`.

Igualar el tamaño lógico al físico es lo único que hace cuadrar la aritmética de
X11. De ahí `pkgs/vm-mode.nix`.

## `vm-mode` (Mod+Shift+V)

Toggle que baja el panel a `scale 1` y reubica el MSI a x=2560 y=360 (a 1.6 el
MSI vive en x=1600, que es donde acaba el ancho *lógico* del panel; a escala 1 el
panel mide 2560 y se solaparían 960 px).

Verificado el ciclo completo:

| | Panel | MSI | Ventana de VMware en X11 vs niri |
|---|---|---|---|
| Antes | 1.6, `0,180`, 1600x900 | `1600,0` | 2560x1440 vs 1600x900 |
| Modo VM | 1.0, `0,0`, 2560x1440 | `2560,360` | **2560x1440 vs 2560x1440** |
| Tras apagar | 1.6, `0,180`, 1600x900 | `1600,0` | — |

Y en modo VM `xrandr` da `+0+0` y `+2560+360`: sin solape.

### El primer diseño del "off" no funcionaba

La idea era que salir del modo llamara a `niri msg action load-config-file` y
dejara que el config reaplicara escala y posiciones. **No lo hace.** Verificado
dos veces el 2026-08-22: tras `niri msg output eDP-2 scale 1`, ni
`load-config-file` ni tocar el `mtime` del `config.kdl` devuelven la escala a
1.6. Un override temporal de `niri msg output` sobrevive a la recarga.

El script guarda ahora escala y posiciones previas en
`$XDG_RUNTIME_DIR/vm-mode.state` **antes** de tocar nada, y las restaura al
salir. De paso deja de duplicar el `1.6` del config, así que no se desincroniza
si el `config.kdl` cambia.

### Dos cosas más que salieron por el camino

- **El flake no ve un fichero sin `git add`.** El primer build falló con
  `Path 'pkgs/vm-mode.nix' ... is not tracked by Git`. Falló ruidosamente, que es
  el caso bueno; el peligroso es el de 2026-08-11, donde el build salió *verde*
  sin mirar lo recién escrito.
- **`niri msg output ... position` es posicional**, `position set X Y`, no
  `x=0 y=0`. La forma con `x=` da `unrecognized subcommand` y, con `set -e`, dejó
  el escritorio a medio aplicar en la primera prueba.

## Autofit de VMware

Las claves salen de `strings` sobre `libvmwareui.so`, no de memoria:
`pref.autoFit`, `pref.autoFitFullScreen`, `pref.autoFitGuestToWindow` en
`~/.vmware/preferences`, y `gui.perVMWindowAutofitMode` /
`gui.perVMFullscreenAutofitMode` por VM en el `.vmx`, con valores `none`,
`stretch`, `fitGuestToHost`, `stretchGuestToHost`.

Escrito en `~/.vmware/preferences` (hay que hacerlo con la GUI cerrada o la pisa
al salir):

```
pref.autoFit = "FALSE"
pref.autoFitGuestToWindow = "TRUE"
pref.autoFitFullScreen = "TRUE"
```

VMware las conservó tras un ciclo abrir/cerrar, así que las reconoce.

**Lo que NO está verificado**: la semántica exacta de `pref.autoFit`. Se asume
que es *Autofit Window* (la ventana persigue al invitado), que es la queja
literal. Si al abrir una VM el invitado se queda con resolución fija y barras de
scroll en vez de adaptarse a la ventana, la clave era el maestro de ambos modos
y hay que probar `pref.autoFit = "TRUE"` con `pref.autoFitGuestToWindow = "TRUE"`.
Respaldo del fichero original en el scratchpad de la sesión.

Este fichero no está gestionado por Nix: es estado mutable de la aplicación.

## Pendiente

`nh os switch`, que lo corre daf3r. Hasta entonces `vm-mode` no está en PATH y
**Mod+Shift+V no hace nada**, aunque el keybind ya esté activo — `config.kdl` es
el fichero real que lee niri y recarga solo.
