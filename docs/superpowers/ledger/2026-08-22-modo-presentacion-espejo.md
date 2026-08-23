# Modo presentación — duplicar el panel en un proyector

Trabajo directo sobre `main`, 2026-08-22. Petición: dejar el portátil listo para
exponer al día siguiente conectado a un proyector, duplicando pantalla. Sin
acceso a un proyector real para probar.

Todo lo que sigue está medido contra el sistema. El continuo de esto es
[2026-08-22-vmware-escala-xwayland.md](2026-08-22-vmware-escala-xwayland.md):
mismo hardware, misma presentación, y el modo VM aparece aquí como el escenario
que había que sostener.

## El hallazgo que no se buscaba: `vm-mode` estaba clavado al MSI

Antes de tocar nada del espejo. `pkgs/vm-mode.nix` localizaba la pantalla
externa así:

```
select(.value.model == "MSI MP243X")
```

Con un proyector enchufado al mismo HDMI, esa expresión devuelve vacío. El
script pasaba el panel a escala 1 —doblando su ancho lógico a 2560— y **no
movía la otra pantalla**, que seguía en x=1600: 960 px de solape. El fallo
aparecía exactamente al abrir VMware, que es la demo principal.

Arreglado matchando "lo que no sea el panel". De paso, la posición del externo
pasó a calcularse en vez de estar escrita: los literales `2560` y `360` solo son
correctos para un monitor de 1080 de alto. Verificado forzando la salida a
1280x720, donde el valor correcto es y=720:

| Salida externa | y calculada | y del código viejo |
|---|---|---|
| 1920x1080 | 360 | 360 (coincide) |
| 1280x720 | **720** | 360 (mal) |

## niri no sabe duplicar

Verificado contra niri 26.04: `niri msg output` ofrece `off`, `on`, `mode`,
`custom-mode`, `modeline`, `scale`, `transform`, `position` y `vrr`. No hay
acción de clonado. Superponer dos outputs en la misma posición lógica tampoco
vale, niri los separa.

Sí expone `zwlr_screencopy_manager_v1` v3, que es lo que necesita `wl-mirror`.
De ahí el diseño: un cliente que captura el panel y lo pinta en la otra salida.

## Tres fallos encadenados, todos invisibles desde fuera

El proceso arrancaba, el statefile era correcto, el modo bajaba a 60 Hz y **el
proyector no mostraba nada**. Ninguno de los tres se veía sin mirar la pantalla
externa de verdad, con `grim -o` y leyendo la imagen.

1. **`--fullscreen-output` no se honra.** wl-mirror lo pide (log:
   `configure_window(): fullscreening on target output`) pero niri ya le había
   dado tamaño de baldosa — `window resized to 945x1018` — y la ventana quedaba
   en una columna fuera de la vista del scroll. Se arregla con una `window-rule`
   con `open-fullscreen true`.
2. **Dos ventanas a pantalla completa en un workspace: se ve la activa.** El
   espejo abría sin foco, detrás de un terminal también fullscreen. Se arregla
   con un workspace propio (`workspace "espejo"`), que además es lo que
   sobrevive a que algo robe el foco después — activar el modo VM lo hacía.
3. **Devolver el foco podía tapar el espejo.** Si el atajo se pulsaba con el
   foco en una ventana *de la pantalla externa*, devolvérselo cambiaba esa
   pantalla de workspace. El mismo script funcionaba o fallaba según dónde
   estuviera el foco al pulsar. Se arregla mirando en qué salida vive la ventana
   previa: si está en el externo, el foco va al panel.

El log de wl-mirror iba a `/dev/null` en la primera versión, y eso es lo que
hizo falta cambiar para diagnosticar el primer fallo. Ahora va a
`$XDG_RUNTIME_DIR/present-mode.log`.

## Los 240 Hz bajan a 60 mientras dura

wl-mirror captura la salida de origen a la tasa a la que corra. A 240 Hz eso es
capturar y repintar cuatro fotogramas por cada uno que un proyector de 60 puede
mostrar, con VMware corriendo los invitados en la misma GPU. El modo anterior se
guarda y se restaura al salir; no está escrito en el script.

## Lo que quedó sin verificar

- **Ningún proyector real.** Lo validado es la mecánica, contra el MSI y contra
  una salida forzada a 1280x720. La legibilidad a distancia y el EDID del
  proyector del aula no se pudieron medir.
- **USB-C sin probar.** El script mueve el workspace del espejo a la salida que
  encuentre, así que debería valer, pero solo se ejecutó sobre HDMI.
- **Con dos pantallas externas** el `head -1` elige una sin criterio.

Procedimiento de uso en
[docs/runbooks/2026-08-23-presentacion-proyector.md](../../runbooks/2026-08-23-presentacion-proyector.md).
