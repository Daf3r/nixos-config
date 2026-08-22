# Extirpar Noctalia — revisión y arreglos

Rama: `dms-only-remove-noctalia`, desde `95bb6f9` en `main`. **Sin integrar.**

La extirpación de Noctalia la escribió otra IA (Codex) en el árbol de trabajo,
sin commitear. Esta sesión la revisó contra el sistema, arregló tres defectos
reales y limpió cuatro restos. Todo lo que sigue está verificado por ejecución,
no por lectura.

## Lo que estaba mal

### 1. `lock-media-pause` no pausaba nada, y lo hacía en verde

El servicio se declaraba, arrancaba y systemd lo reportaba `active`. Tres
fallos encadenados en una sola línea del bucle:

```bash
locked="…/dms ipc call lock isLocked 2>/dev/null | grep -q '\"…\":true' && echo true || echo false"
```

- Falta `$( )`: es una asignación de string literal, así que `$locked` nunca
  vale `true` y la rama del `if` es código muerto.
- `dms ipc call lock isLocked` devuelve `false` en texto plano, no un JSON con
  `sessionLockLocked`. Comprobado ejecutándolo.
- `\"` dentro de un string `''…''` de Nix no es un escape, así que el patrón de
  grep llevaba barras invertidas literales.

Coste del bucle mientras no hacía nada: 86 400 llamadas IPC al día.

**Reescrito sobre la señal de logind.** `Modules/Lock/Lock.qml` de DMS 1.5.3
llama a `notifyLockedHint()` en cada lock, que acaba en `loginctl
set-locked-hint`; logind emite entonces `PropertiesChanged` con `LockedHint`
sobre el objeto de la sesión. El servicio duerme en esa señal con `gdbus
monitor`: cero polling y reacción instantánea.

Depende de `loginctlLockIntegration`, que en `SettingsSpec.js` tiene
`{ def: true }` y está ausente de `settings.json`, así que aplica el default.
Apagar ese interruptor en Settings > Lock Screen convierte el servicio en un
no-op — es la única opción que lo rompe, y está documentada en el módulo.

Verificación de extremo a extremo, sin bloquear la pantalla: `SetLockedHint`
por D-Bus cambia el hint sin activar el lock, así que sirve de disparador de
prueba.

| Paso | Resultado |
|---|---|
| Antes | `brave.instance4554 Playing` |
| `SetLockedHint b true` | `brave.instance4554 Paused`, log: `session locked, pausing players` |
| Control negativo (`<false>`) | sigue `Playing`, el watcher no registra nada |

Falta un lock real para cerrar el círculo — ver "Pendiente" abajo.

### 2. `pkgs.dms-shell` no era el DMS que corre

nixpkgs también empaqueta `dms-shell`, a su propia versión. Los tres wrappers
(`screenshot-annotate`, `wallpaper-rotate`, `lock-media-pause`) lo pedían por
ese nombre, así que resolvían a una **segunda copia**: `+115 MiB` de closure y
scripts hablando con un binario distinto del shell en ejecución. Ambos eran
1.5.3 el día del cambio, que es justo por lo que no se notó.

Arreglado con un overlay en `flake.nix`, no editando los tres sitios: así
cualquier `pkgs.dms-shell` futuro es el input pineado. `useGlobalPkgs = true`
hace que alcance también a home-manager.

```
nix path-info -r /run/current-system | grep dms-shell   # una ruta + completions
```

Antes del arreglo: dos rutas. Después: una.

### 3. `services.geoclue2.enable = true` entraba disfrazado de limpieza

El comentario decía que los cuatro servicios llegaban implícitamente por los
`recommendedServices` de Noctalia. Para bluetooth, upower y power-profiles es
cierto; para geoclue no: `nix store diff-closures` contra el sistema anterior
lo muestra entrando como servicio **nuevo**, con dos units.

Encender geolocalización es una decisión sobre datos, no un efecto secundario
de quitar un shell. Queda apagado, con el comentario que explica qué se gana
encendiéndolo (el widget del tiempo y el horario de la luz nocturna) y la línea
lista para descomentar.

## Restos que quedaban

- **`screenshot-annotate` sin `--no-clipboard`.** El comentario prometía que
  nada llega al portapapeles hasta que satty termina; sin ese flag la captura
  cruda lo pisa al soltar el ratón, y una anotación abortada deja ahí la imagen
  sin anotar — lo único que el wrapper existe para evitar.
- **2112 líneas duplicadas.** `noctalia.tmTheme` y `yazi-noctalia-tmtheme.xml`
  eran byte-idénticos (mismo md5). yazi y bat quieren los dos un tema TextMate
  y Noctalia generaba uno solo: ahora es un fichero con dos rutas de despliegue.
- **README (es + en).** Seguía diciendo que "el JSON de la paleta se copia al
  store" cuando ese JSON se borra en esta misma rama, y "dos ficheros los
  escribe el shell" cuando ya solo queda uno.

## Lo que se revisó y estaba bien

Los nombres de fichero de matugen (`dank-colors.css`, `dank-theme.conf`,
`dank-tabs.conf`, `matugen.conf`) existen todos en `~/.config`. `dms ipc call
wallpaper set` repinta **y** regenera las paletas — medido por los timestamps
de `dank-colors.css` y `dank-theme.conf` tras una llamada. Los verbos `mpris
playPause/next/previous` y los flags `screenshot --stdout --no-file
--no-confirm` existen y funcionan. El `flake.lock` sale limpio. NetworkManager
nunca vino de Noctalia, así que no se pierde.

El hallazgo de `bat` es correcto y se confirmó ejecutándolo: construida la
caché con ese `tmTheme`, `bat --list-themes` lista `noctalia`.

## Pendiente

1. `sudo nixos-rebuild switch` (o `nh os switch`) — solo daf3r.
2. **Bloquear la pantalla de verdad** y confirmar que la música para. Es lo
   único del servicio que no se pudo probar sin bloquear la sesión:

   ```
   journalctl --user -u lock-media-pause -f
   ```

   Debe aparecer `session locked, pausing players`. Si no aparece, el sospechoso
   es `loginctlLockIntegration` en Settings > Lock Screen.
3. **Verificación visual**: kitty, GTK, zathura, btop, zellij y el flavor de
   yazi. Ese último es el único cuyo despliegue no se pudo probar por ejecución
   — la estructura coincide con la doc oficial de yazi
   (`flavors/<n>.yazi/{flavor.toml,tmtheme.xml}` + `[flavor] dark/light`), pero
   nadie lo ha visto pintado.
4. **Borrar los restos mutables**, que el switch no toca:

   ```
   rm ~/.config/gtk-3.0/noctalia.css ~/.config/gtk-4.0/noctalia.css
   rm ~/.config/qt5ct/colors/noctalia.conf ~/.config/qt6ct/colors/noctalia.conf
   rm -r ~/.config/kitty/themes
   ```

5. **Decisión abierta**: `settings = { }` en `dms.nix`. Volcar el
   `settings.json` de la GUI ahí lo hace declarativo y le quita la propiedad a
   la GUI; dejarlo vacío mantiene el ajuste en vivo y fuera del repo. Es una
   decisión de contenido, no de limpieza, y sigue sin tomarse.

## Defecto conocido, no arreglado

`wallpaper-rotate` llama a `apply` al arrancar y, si DMS todavía no responde,
falla en silencio y no reintenta hasta 900 s después. No es visible porque DMS
recuerda el último fondo, así que lo peor que pasa es empezar la sesión con el
fondo anterior durante quince minutos. Venía de la versión con Noctalia y se
deja tal cual: arreglarlo es alcance nuevo, no un resto de la migración.
