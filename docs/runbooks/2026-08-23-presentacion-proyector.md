# Presentar con proyector — 2026-08-23

Procedimiento para conectar el portátil a un proyector y duplicar la pantalla.
Escrito para la defensa de FUNSOCIETY, pero sirve para cualquier proyector por
HDMI.

Lo que hay montado: `Mod+Shift+M` duplica el panel en la pantalla externa
(`pkgs/present-mode.nix`) y `Mod+Shift+V` deja el panel a escala 1 para que
VMware no se redimensione solo (`pkgs/vm-mode.nix`). Los dos son interruptores:
el mismo atajo enciende y apaga.

## Antes de salir de casa

El único paso que no está hecho, porque necesita root:

```fish
nh os switch
```

Y comprobar que surtió efecto — sin esto los atajos no existen:

```fish
command -v present-mode; and echo OK
```

Prueba en seco contra el monitor del escritorio, para llegar al aula con el
gesto ya hecho: `Mod+Shift+M`, mirar el MSI, `Mod+Shift+M` otra vez.

## En el aula

1. **Enchufar el HDMI antes de nada.** Conectar con la sesión ya arrancada
   funciona, pero da menos sorpresas hacerlo primero.
2. Confirmar que niri ve el proyector:

   ```fish
   niri msg outputs
   ```

   Tiene que aparecer una salida que no sea `eDP-2`. Si no aparece, el problema
   es el cable o la entrada del proyector, no el portátil.
3. **`Mod+Shift+M`** — duplica. Sale una notificación diciendo en qué salida.
4. Si toca demo de VMware: **`Mod+Shift+V`**. El espejo aguanta, está probado.
5. Al terminar: `Mod+Shift+V` y `Mod+Shift+M` otra vez, en cualquier orden.

## Qué esperar

- El panel baja a 60 Hz mientras dura el espejo, y vuelve a 240 Hz al salir.
  Es deliberado: capturar a 240 Hz para un proyector de 60 no aporta nada y
  gasta GPU que VMware necesita.
- **El teclado se queda en el portátil.** El espejo nunca roba el foco.
- Si el proyector es 4:3, el espejo sale con bandas negras arriba y abajo. Es
  inevitable con un panel 16:9, y es preferible a recortar los lados de la
  diapositiva.

## Si el espejo no aparece

Plan B, sin instalar ni configurar nada: **escritorio extendido**. Con
`Mod+Ctrl+Shift+→` se manda la ventana actual al proyector. El aula ve esa
ventana y el portátil sigue con el resto. Funciona siempre.

Para saber qué pasó, el log queda en:

```fish
cat $XDG_RUNTIME_DIR/present-mode.log
```

Si algo se queda a medias (el espejo colgado, el panel en 60 Hz), esto lo
devuelve todo a su sitio:

```fish
pkill -x wl-mirror
rm -f $XDG_RUNTIME_DIR/present-mode.state
niri msg output eDP-2 mode 2560x1440@240.002
```

## Audio

Solo si el proyector tiene altavoces y los vas a usar. No es automático:

```fish
wpctl status | grep -A5 Sinks
wpctl set-default <id-del-sink-HDMI>
```

## Límites conocidos

- **Con dos pantallas externas a la vez**, el espejo elige una de las dos sin
  criterio. En el aula no pasa (solo el proyector), pero en el escritorio con
  el MSI y algo más sí.
- **Por USB-C está sin probar.** El script mueve el workspace del espejo a la
  salida correcta, así que debería funcionar, pero lo verificado el 2026-08-22
  fue solo HDMI.
- **Sin proyector real no se pudo medir la legibilidad.** Lo que se validó fue
  la mecánica, contra el MSI y contra una salida forzada a 1280x720.
