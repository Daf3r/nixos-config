# NixOS de daf3r

[English](README.md) · **Español**

Un flake de NixOS para una sola máquina: **[niri](https://github.com/YaLTeR/niri)** con
tiling desplazable y **[DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)**
como shell, sobre un ASUS ROG Strix G17 (G713PV) con una RTX 4060 y un panel de 240 Hz.

| | |
|---|---|
| **Compositor** | niri 25.11 — tiling desplazable, sesión única |
| **Shell** | DMS (DankMaterialShell) v1.5.3, pineado a tag |
| **Gestor de sesión** | SDDM (Wayland) + sddm-astronaut |
| **Terminal** | kitty + fish + starship |
| **Navegador** | Brave Origin, empaquetado aquí desde el `.deb` de Brave |
| **Hardware** | Ryzen 9 7845HX · RTX 4060 · panel 2560x1440@240 · MSI MP243X |

---

## Reconstruir

Este repositorio es una configuración completa del host, no un módulo genérico de NixOS.
Si lo vas a instalar en otra máquina, empieza por [Instalar esto desde cero](#instalar-esto-desde-cero)
antes de ejecutar cualquier rebuild.

```fish
nh os switch          # el del día a día — muestra un diff de qué cambia exactamente
nrs                   # sudo nixos-rebuild switch --flake ~/nixos-config
flakeup               # nix flake update
```

`NH_FLAKE` está definida a nivel de sistema, así que `nh` no necesita ruta. El output del
flake se llama como `networking.hostName`, y por eso `--flake ~/nixos-config` resuelve
`daf3r-starter` sin escribir el atributo.

### Motor de actualizaciones y barra DMS

`upd check` prepara una actualización sin aplicarla. El estado legible por programas es
`upd status --json`; incluye los cambios preparados y los bloqueos calculados en vivo.
`upd apply --ff-only` adelanta la rama del motor y `upd apply --boot` deja la generación
preparada para el próximo arranque. El plugin `nixos-upd` de DankMaterialShell muestra
ese estado en la barra y ofrece comprobarlo o aplicarlo mediante polkit.

El chequeo cubre los inputs de Nix y las aplicaciones empaquetadas localmente: Brave
Origin, T3 Code, el paquete oficial de ChatGPT para Linux y, cuando existe su declaración,
Minecraft Launcher. Para las URLs mutables compara también el hash de la fuente además de
la versión, así detecta un `latest` republicado antes de que rompa la siguiente compilación.
Claude Code se reporta como actualización gestionada por npm; Hermes, Grok y Kimi conservan
sus propios mecanismos de autoactualización y el motor de Nix no los modifica.

---

## Lo que hay que saber antes de tocar nada

> **Este stack de escritorio falla en silencio mucho más de lo que da errores.**

No es un cuelgue ni una línea roja en un log: es un `ok` que no hizo nada. Todos estos
pasaron de verdad, y cada uno costó horas hasta que alguien se dio cuenta:

- Templates del shell escribiendo colores en ficheros que no leía nadie
- gamemode informando *"gamemode is active"* mientras polkit denegaba todos sus helpers
- La barra del shell descartando widgets que se salían de la pantalla estrecha, sin avisar
- niri ignorando un bloque de monitor *entero* porque la frecuencia estaba redondeada
- Symlinks del starter apuntando a rutas que nunca existieron

El hábito que funciona: **medir antes de teorizar.** Una GPU clavada en 2490 MHz de 3105
disponibles dijo más sobre un juego que iba a tirones que cualquier hipótesis. Donde hay
una trampa conocida, está escrita en un comentario junto al ajuste que la causa, no aquí —
los comentarios de este repo son largos a propósito.

---

## Estructura

| Fichero | Qué contiene |
|---|---|
| `configuration.nix` | Básicos del host, zram, usuarios, ajustes de Nix |
| `hardware-configuration.nix` | Generado, gitignorado |
| `desktops.nix` | niri, SDDM, portales xdg, los servicios que DMS necesita |
| `gpu.nix` | NVIDIA RTX 4060 como GPU principal — ver [GPU](#gpu) |
| `asus.nix` | asusd: perfiles de ventilador, RGB del teclado, tecla ROG, límite de batería |
| `gaming.nix` | Steam, gamemode, Proton-GE, las reglas de polkit que gamemode necesita |
| `gamemode.nix` | El comando `game-mode` (escala del panel + VRR) |
| `keyboard.nix` | keyd — hace que un toque seco de `SUPER` abra el lanzador |
| `dms.nix` | Ajustes y plugins de DankMaterialShell |
| `lock-media-pause.nix` | Pausa la reproducción MPRIS al bloquear la sesión |
| `wallpaper.nix` | `wallpaper-rotate`, que rota el fondo por el IPC de DMS |
| `gtk.nix` / `qt.nix` | Cursor, temas, iconos, fuentes — mantenidos en sintonía entre sí |
| `home.nix` | Punto de entrada de home-manager, symlinks fuera del store |
| `apps.nix`, `terminal.nix`, `fontsAndNeeds.nix` | Paquetes |
| `terminal/` | kitty, fish, fastfetch, nvim, herramientas de CLI |
| `pkgs/brave-origin.nix` | Brave Origin, empaquetado desde el `.deb` de Brave |
| `pkgs/chatgpt-desktop.nix` | `.deb` oficial de ChatGPT para Linux |
| `pkgs/t3code-app.nix` | AppImage de T3 Code |
| `pkgs/minecraft-launcher.nix` | Bootstrap del launcher de Mojang, cuando está activado |
| `devshells/` | Toolchains por proyecto — ver [Entornos de desarrollo](#entornos-de-desarrollo) |
| `config/niri/config.kdl` | Config de niri, editable en vivo |
| `config/nvim/` | Starter de LazyVim — de terceros, ver abajo |
| `config/starship.toml` | El prompt; lleva un bloque de paleta congelado |
| `config/themes/` | Paletas congeladas de la era Noctalia para las herramientas que matugen no cubre |

### Qué se aplica en vivo y qué necesita rebuild

`config/niri` y `config/nvim` están enlazados **fuera** del store de Nix, así que editarlos
surte efecto al momento — `~/.config/niri/config.kdl` resuelve de vuelta a este repo.

Todo lo demás necesita `nh os switch`. `starship.toml` se lee vía `$STARSHIP_CONFIG` y las
paletas de `config/themes/` se copian al store, así que nada de eso es en vivo pese a estar
bajo `config/`.

Un solo directorio de aquí lo escribe el shell y no una mano: `config/niri/dms/`, que DMS
genera entero en cada ejecución y está gitignorado. El bloque de paleta de
`config/starship.toml` lo escribía Noctalia y hoy está congelado — se edita a mano o no
cambia nadie.

### Lo que no es mío

**Esta config partió de [TimothyBear11/nixtalia](https://github.com/TimothyBear11/nixtalia)**,
un starter para probar Noctalia sobre niri, Hyprland y Mango. Casi nada de aquello
sobrevive — Mango, Plasma y Hyprland ya no están, todos los módulos se reescribieron, y lo
que `git blame` todavía hace coincidir es sintaxis Nix que no se puede escribir de otra
forma: `{ pkgs, ... }:`, llaves, y nombres de opción como `boot.loader.systemd-boot.enable`.
Los commits del starter no están en este historial, así que esta línea es la atribución.

`config/nvim/` es el [starter de LazyVim](https://github.com/LazyVim/starter), incluido tal
cual y redistribuido bajo la licencia Apache-2.0 que lleva en `config/nvim/LICENSE`.

`config/fastfetch/config.jsonc` está adaptado de
[israrkhan-cys/Arch-\_hyprland\_rice](https://github.com/israrkhan-cys/Arch-_hyprland_rice);
los cambios respecto al original están listados arriba de `terminal/fastfetch.nix`.

**Los fondos de pantalla y las imágenes de fastfetch no están en este repo, a propósito.**
Viven en `~/Pictures/Wallpapers` y `~/Pictures/Fastfetch` porque son obra de otra gente y
este repo es público — clónalo y tendrás una rotación vacía, no un problema de copyright.
`wallpaper.nix` crea el primer directorio para que nada se rompa en un clon nuevo.

---

## Atajos de teclado

| Teclas | Acción |
|---|---|
| `SUPER` (toque) / `SUPER + Espacio` | Lanzador de aplicaciones |
| `SUPER + F1` … `F4` | Centro de control · Ajustes · Portapapeles · Sesión |
| `SUPER + L` | Bloquear pantalla |
| `ALT + Tab` | Cambiador de ventanas |
| `Impr` / `SHIFT + Impr` | Captura de región / pantalla completa |
| `SUPER + Impr` | Captura de región y anotarla en satty |
| `SUPER + Intro` | kitty |
| `SUPER + B` / `SUPER + W` | Brave Origin |
| `SUPER + E` / `SUPER + K` / `SUPER + D` | Dolphin · Kate · Discord |
| `SUPER + SHIFT + W` | Cambiar el fondo de pantalla |
| `SUPER + Q` | Cerrar ventana |
| `SUPER + F` | Pantalla completa |
| `SUPER + O` | Vista general — todos los escritorios y ventanas, en pequeño |
| `SUPER + R` | Cambiar el ancho de la columna |
| `SUPER + G` | Columna en pestañas |
| `SUPER + ←/→` | Cambiar de columna · `SUPER + ,` / `.` meter o sacar una ventana |

> `SUPER + SHIFT + /` abre la chuleta de atajos del propio niri. Se genera de la config en
> vivo, así que, a diferencia de esta tabla, no puede quedarse desfasada.

El toque seco de `SUPER` no es un atajo del compositor — niri rechaza de plano los binds
que son solo un modificador. `keyboard.nix` lo resuelve una capa más abajo, en evdev, con
keyd: si lo mantienes pulsado sigue siendo el modificador; si lo pulsas y sueltas solo,
emite un acorde que niri tiene asignado al lanzador.

---

## Pantallas

| Pantalla | Modo | Escala | Tamaño lógico |
|---|---|---|---|
| Panel del portátil, **izquierda** | `2560x1440@240.002` | 1.6 | 1600x900 |
| MSI MP243X, **derecha** | `1920x1080@99.999` | 1 | 1920x1080 |

Ambas están fijadas explícitamente en `config/niri/config.kdl`. `preferred` / `auto`
elegían frecuencias equivocadas y ponían el monitor externo en el lado que no era.

> **Identifica los monitores por EDID, nunca por el nombre del conector.**
> El panel ha aparecido como `eDP-1` y como `eDP-2` entre reinicios de esta máquina sin
> cambiar nada: el driver de NVIDIA numera su conector eDP de forma distinta, y un segundo
> eDP en la iGPU de AMD hace el índice ambiguo.

Cuando el nombre no coincide, las reglas se ignoran *por completo* — el panel de 240 Hz va
a 60 y acaba colocado a la derecha del MSI, lo que parece que los monitores se han
intercambiado. Usa la cadena entrecomillada `"marca modelo serie"` que imprime
`niri msg outputs`.

> **La frecuencia debe coincidir con tres decimales.**
> `2560x1440@240` no se encuentra; `2560x1440@240.002` sí. niri hace fallback en silencio y
> luego limita los vblanks a la frecuencia que se cree, mientras el panel escanea a otra.
> Saca los números de `niri msg outputs` y no los redondees nunca a mano.

Se eligió escala 1.6 porque 2560/1.6 y 1440/1.6 son ambos enteros, así que no hay borrosidad
por escalado fraccional. Dos consecuencias, y las dos ya han causado bugs:

- **El portátil es la pantalla estrecha, no la ancha.** Todo lo que se dispone en
  horizontal — la barra del shell sobre todo — tiene ahí 1600 píxeles lógicos frente a los
  1920 del MSI. El desbordamiento es invisible desde el MSI, y los widgets se salen sin
  decir nada.
- **Noctalia v5.0.0 (el shell anterior) dimensionaba mal su superficie de fondo con escalas
  fraccionales**; DMS no tiene ese bug, así que pinta el fondo él mismo y awww desapareció.

---

## GPU

El panel interno (`card1-eDP-1`) y `card1-HDMI-A-1` cuelgan los dos de la NVIDIA RTX 4060;
todos los conectores de la iGPU de AMD dan `disconnected`. El MUX de vídeo está en modo
discreto, así que NVIDIA es la GPU principal y PRIME offload no aplica — los modos se
cambian en la BIOS. `supergfxd` está desactivado a propósito; `asus.nix` explica por qué.

Ojo con el número de tarjeta al leer `/sys/class/drm`: las dos GPUs exponen un conector eDP,
y `card2-eDP-2` es el de la iGPU, sin usar, no el panel.

---

## Ajustes del shell: en la GUI, a propósito

DMS guarda sus ajustes en `~/.config/DankMaterialShell/settings.json`. Mientras
`settings = { }` en `dms.nix` siga vacío, ese fichero es mutable y lo posee la GUI de
ajustes — un rebuild nunca lo toca.

**En la práctica:** usa la GUI para probar, y luego decide: o lo dejas así (GUI-owned), o
pegas el JSON en `programs.dank-material-shell.settings` dentro de `dms.nix` para volverlo
declarativo (el fichero pasa a ser un symlink de solo lectura al store y la GUI deja de
poder guardar). Uno u otro: quien escribe el fichero, lo controla.

---

## Juegos

Steam viene con el runtime de 32 bits, Proton-GE, gamemode y gamescope. Opciones de
lanzamiento de CS2:

```
gamemoderun mangohud %command%
```

> **No envuelvas CS2 en gamescope.** Es el consejo estándar para un compositor no apilable y
> aquí rompe el juego: CS2 inicializa Vulkan y nunca presenta una ventana, porque gamescope
> sobre NVIDIA recibe cero modificadores de formato DRM para los formatos en los que asigna
> sus buffers de salida. Reproducible sin Steam con `gamescope -- sleep 3`; `--backend sdl`
> lo esquiva si alguna vez hace falta gamescope de verdad.

gamescope sigue instalado (`gaming.nix` mantiene `programs.gamescope` y la sesión gamescope
de Steam) para el resto de la biblioteca — es solo CS2 lo que no debe pasar por él.

`config/niri/config.kdl` gestiona CS2 con una `window-rule` en su lugar: pantalla completa
al abrir y frecuencia variable bajo demanda.

**La política de polkit de gamemode viene con todas las acciones denegadas.** Upstream deja
al administrador decidir quién puede cambiar gobernadores y relojes, y nixpkgs no rellena
esa parte — así que gamemode no hizo absolutamente nada durante semanas mientras informaba
de éxito. `gaming.nix` concede esas acciones al grupo `gamemode`; entrar en el grupo exige
**cerrar sesión** para surtir efecto.

```fish
gamemoded -t    # la comprobación honesta: ejercita el gobernador de CPU de verdad
gamemoded -s    # dice "active" incluso cuando todos sus helpers están siendo denegados
```

`game-mode` (de `gamemode.nix`) es un interruptor manual aparte: baja el panel a escala 1 y
fuerza el VRR, para que un juego a pantalla completa consiga direct scanout en vez de ser
reescalado desde 1600x900 en cada fotograma. Manual a propósito — atarlo a una regla de
ventana reescalaría el panel cada vez que apareciera una ventana que encaje, incluido
alt-tabear al navegador entre rondas.

El perfil de plataforma de ASUS se queda en `balanced` deliberadamente. `performance`
desbloquea el resto del reloj de la GPU pero dispara los ventiladores, y este portátil se
usa en silencio.

---

## Entornos de desarrollo

`devshells/` contiene un toolchain por proyecto en `~/Projects`, activado automáticamente
por direnv. Cada proyecto lleva un `.envrc` de una línea:

```
use flake ~/nixos-config#remesafam
```

Viven aquí y no dentro de los proyectos por dos razones: Nix exige que los ficheros de flake
estén versionados en git, y uno de los proyectos pertenece a una organización, donde un
`flake.nix` commiteado impondría Nix a todo el mundo y uno ignorado no se podría evaluar
siquiera. Tenerlos aquí también hace que ambos shells compartan el nixpkgs de este flake:
una sola descarga, un solo juego de versiones, consistente con el sistema.

Por proyecto y no global porque los toolchains difieren de verdad: uno usa pnpm y otro npm,
y solo uno necesita Rust. Instalar la unión globalmente pondría un toolchain de Rust de
1,5 GB en el PATH mientras trabajas en una app Next.js, y facilitaría ejecutar el gestor de
paquetes equivocado en el repo equivocado y reescribir un lockfile.

---

## Instalar esto desde cero

Dos públicos: quien reconstruya este portátil exacto, y quien quiera la config en otro
hardware. Los pasos son los mismos; lo que cambia es cuánto aplica, y eso está
[detallado abajo](#lo-que-no-viaja).

Los valores por defecto suponen que el usuario de inicio de sesión es `daf3r`, que el repo
está en `/home/daf3r/nixos-config` y que el host se llama `daf3r-starter`. Mantener esos
tres valores durante la instalación permite clonar y compilar directamente. Si cambia el
usuario, el hostname, la GPU o las pantallas, hay que adaptar la configuración en el paso
de abajo antes de la primera compilación.

### 0. Antes de reinstalar, prueba el menú de arranque

Si esta máquina todavía arranca, casi nunca merece la pena reinstalar por un rebuild roto.
systemd-boot lista **todas las generaciones anteriores** al arrancar; elige la última que
funcionaba y ya estás de vuelta, con la generación rota aún en disco para inspeccionarla.

```fish
nixos-rebuild list-generations       # qué hay disponible
sudo nixos-rebuild switch --rollback # retroceder una, desde una sesión que funcione
```

Lo que sigue es solo para un disco realmente muerto o una máquina nueva.

### 1. Instala NixOS de la forma normal

Arranca el instalador oficial y particiona como quieras — esta config no depende del
esquema. Como referencia, esta máquina usa:

| Punto de montaje | Sistema de ficheros | Notas |
|---|---|---|
| `/boot` | vfat, 1 GB | Partición EFI |
| `/` | btrfs | Subvolumen raíz (`subvolid=5`) |
| `/home` | btrfs | `subvol=home`, misma partición |
| `/nix` | btrfs | `subvol=nix`, misma partición |

Sin partición de swap — `configuration.nix` activa zram en su lugar. UEFI y systemd-boot,
así que Secure Boot debe estar desactivado.

> **Pon `daf3r-starter` como hostname.** El output del flake se llama como
> `networking.hostName`, así que otro hostname significa que `--flake ~/nixos-config` no
> encuentra la configuración. En otro hardware, renómbralo en `flake.nix` y
> `configuration.nix` en vez de eso.

### 2. Clona el repo

```fish
nix-shell -p git --run 'git clone https://github.com/Daf3r/nixos-config ~/nixos-config'
```

Tiene que estar en `~/nixos-config`. Varias rutas están escritas enteras — los symlinks
fuera del store en `home.nix`, las referencias a los devshells en cada `.envrc` — y ninguna
resuelve desde otro sitio.

### 3. Genera la config de hardware

> **Este es el paso que pilla a la gente.** `hardware-configuration.nix` está
> **gitignorado**, porque lleva los UUID de los sistemas de ficheros de un disco concreto.
> No está en el clon, y `configuration.nix` lo importa, así que la compilación falla hasta
> que exista.

El instalador ya escribió uno correcto para tus particiones. Cópialo:

```fish
sudo cp /etc/nixos/hardware-configuration.nix ~/nixos-config/
sudo chown $USER ~/nixos-config/hardware-configuration.nix
```

Si lo haces desde una ISO en vivo antes del primer arranque, está en
`/mnt/etc/nixos/hardware-configuration.nix`. Para regenerarlo más adelante — al añadir un
disco, por ejemplo — `sudo nixos-generate-config --show-hardware-config` imprime uno nuevo
a partir de los sistemas de ficheros montados.

### 4. Adapta la configuración para otra máquina

Omite esta sección solo si estás instalando el ASUS ROG Strix G17 original. En otra
máquina, este repositorio debe tratarse como punto de partida: contiene los supuestos de
este portátil sobre NVIDIA, ASUS, monitores y gaming, así que un clon directo puede fallar
o activar drivers equivocados.

- Si el usuario no es `daf3r`, crea ese mismo usuario o cambia todas las referencias activas
  a `daf3r`/`/home/daf3r` antes de compilar. Encuéntralas con
  `rg -n 'daf3r|/home/daf3r'`. Los ficheros importantes son `flake.nix`,
  `configuration.nix`, `home.nix`, `updates.nix`, `updates/nixos-upd.sh`, `updates/upd.sh`,
  `terminal/tools.nix` y `config/niri/config.kdl`.
- Si el hostname es distinto, cambia `networking.hostName` en `configuration.nix` y el
  atributo `nixosConfigurations.<nombre>` correspondiente en `flake.nix`; usa ese
  atributo explícitamente en el primer rebuild.
- Si la máquina no es ASUS ROG o no usa GPU NVIDIA, elimina o adapta las importaciones
  `./asus.nix` y `./gpu.nix` en `configuration.nix`. Revisa también `./gaming.nix` si no
  es una máquina para jugar.
- Sustituye las reglas de monitores por EDID de `config/niri/config.kdl` y la regla del
  panel en `gamemode.nix` con los valores que dé `niri msg outputs` tras el primer arranque
  gráfico.

Para una secuencia completa de comandos usando, por ejemplo, el usuario `mel`, consulta la
[guía para instalar con otro usuario](docs/instalacion-otro-usuario.md). Incluye la rama
local, la copia de `hardware-configuration.nix`, las sustituciones necesarias y la
validación antes del primer build.

Conserva `hardware-configuration.nix` del paso 3 incluso después de editar lo demás:
describe los sistemas de ficheros de la máquina nueva y está ignorado por Git a propósito.

### 5. Compila

```fish
sudo nixos-rebuild switch --flake ~/nixos-config#daf3r-starter
```

La primera compilación descarga mucho. El shell en sí es un binario Go pequeño más QML, así
que incluso sin caché binaria compila rápido.

Si el entorno del instalador todavía no tiene flakes activado, añade
`--extra-experimental-features 'nix-command flakes'` a ese comando. La configuración activa
ambas funciones para los comandos siguientes.

### 6. Cierra sesión — no es opcional

`daf3r` pertenece a `networkmanager`, `wheel`, `video`, `i2c`, `docker` y `gamemode`, y **la
pertenencia a grupos se hereda al iniciar sesión**. Hasta un login nuevo, tres cosas están
rotas en silencio:

| Grupo | Qué sigue roto |
|---|---|
| `gamemode` | polkit deniega todos los helpers privilegiados. `gamemoded -s` sigue diciendo "active" |
| `i2c` | Las teclas de brillo solo mueven el panel del portátil; `ddcutil detect` no encuentra nada |
| `docker` | Todos los comandos necesitan sudo |

Compruébalo con `groups` tras volver a entrar, y luego `gamemoded -t` para la prueba honesta
de gamemode.

### 7. Lo que el repo no te puede dar

- **Fondos de pantalla.** No están en el repo, [a propósito](#lo-que-no-es-mío). Suelta
  imágenes en `~/Pictures/Wallpapers` — `wallpaper.nix` crea el directorio y
  `wallpaper-rotate` las recoge sin rebuild. Lo mismo para `~/Pictures/Fastfetch`.
- **El tematizado de las apps que matugen no cubre.** GTK, Qt, kitty, vesktop y niri siguen
  el fondo automáticamente vía matugen de DMS. bat, zellij, btop, lazygit, zathura y yazi
  mantienen paletas congeladas desde `config/themes/` — ya no cambian con el fondo.
- **Secretos.** Aquí no hay nada cifrado porque aquí no hay nada secreto. Las claves SSH, el
  túnel WireGuard y el llavero de GNOME están todos fuera de este repo y se restauran a mano.

### Lo que no viaja

Aproximadamente la mitad de esto es específico de este portátil y habrá que editarlo en otro
hardware:

| Fichero | Por qué es específico |
|---|---|
| `terminal/tools.nix` | **Cambia `programs.git.settings.user` lo primero.** Fija un nombre y una dirección noreply de GitHub, así que cada commit que hagas se atribuiría a otra persona hasta que lo cambies |
| `configuration.nix` | `users.users.daf3r`, el hostname, la zona horaria y el locale |
| `config/niri/config.kdl` | Los bloques `output` identifican por las cadenas EDID de *estos* dos monitores |
| `gamemode.nix` | El panel se nombra con esa misma cadena EDID |
| `gpu.nix` | Da por hecho una dGPU NVIDIA con todos los conectores, MUX en modo discreto |
| `asus.nix` | asusd — solo hardware ROG |
| `hardware-configuration.nix` | Se regenera por máquina, como arriba |
| `devshells/` | Toolchains para dos proyectos concretos |

Todo lo demás — el shell, la terminal, el tematizado, el conjunto de aplicaciones — es
portable.

## Mantenimiento

**Actualizar Brave Origin.** No está en nixpkgs: se distribuye solo por el repositorio
apt/rpm de Brave, así que `pkgs/brave-origin.nix` desempaqueta el `.deb` original. Saca la
versión y el hash nuevos del
[índice de paquetes](https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages),
y actualiza `version` y `hash`:

```fish
nix hash convert --hash-algo sha256 --to sri <sha256 del índice>
```

El motor de actualizaciones comprueba automáticamente el `.deb` mutable de ChatGPT y el
bootstrap de Minecraft: `bump-chatgpt-desktop` lee la versión y el hash Debian, mientras
`bump-minecraft-launcher` sigue el hash del bootstrap. Ambos se ejecutan dentro de `upd
check`, así que una instalación nueva no necesita actualizar esos pins a mano.

**Validar antes de aplicar.**

```fish
nh os build                                        # compilar sin activar
niri validate -c ~/.config/niri/config.kdl         # solo la config de niri
```
