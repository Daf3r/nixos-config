# Instalar la configuración con otro usuario

Esta guía adapta el clon para una cuenta distinta de `daf3r`. El ejemplo usa el usuario
`mel`, pero puedes sustituirlo por otro nombre. Los cambios son locales a la nueva PC:
**no los subas a `main`**, porque `main` sigue siendo la configuración de la máquina
original.

## 1. Instala NixOS y crea el usuario

Durante la instalación crea la cuenta normal `mel` y conéctate a Internet. Si ya instalaste
NixOS con otro nombre, sustituye `mel` por ese nombre en todos los comandos siguientes.

Esta configuración está escrita para `x86_64-linux`. También da por hecho que el repo estará
en `/home/mel/nixos-config`.

## 2. Clona el repositorio en la ruta esperada

Desde la instalación nueva:

```bash
nix-shell -p git
git clone https://github.com/Daf3r/nixos-config /home/mel/nixos-config
cd /home/mel/nixos-config
git switch -c local/mel
```

Mantén abierta esa shell de Nix mientras ejecutas los comandos que usen `git`; al escribir
`exit`, Git deja de estar disponible hasta volver a ejecutar `nix-shell -p git`. La rama local
evita que un ajuste específico de esta PC termine publicado en `main`.

## 3. Copia la configuración de hardware de esta PC

El archivo está ignorado por Git porque contiene UUID de discos. Copia el que generó el
instalador:

```bash
sudo cp /etc/nixos/hardware-configuration.nix /home/mel/nixos-config/
sudo chown mel:users /home/mel/nixos-config/hardware-configuration.nix
```

Si aún estás trabajando desde la ISO y la instalación está montada en `/mnt`, el origen
normalmente es `/mnt/etc/nixos/hardware-configuration.nix`; el destino debe ser el repo
montado de la instalación, por ejemplo `/mnt/home/mel/nixos-config/`.

## 4. Cambia las referencias del usuario

Ejecuta estos comandos desde `/home/mel/nixos-config`. Solo cambian las rutas y atributos
que hacen que NixOS, home-manager y el motor de actualizaciones funcionen con `mel`:

```bash
cd /home/mel/nixos-config

sed -i 's/users\.daf3r/users.mel/' flake.nix

sed -i \
  -e 's#/home/daf3r/nixos-config#/home/mel/nixos-config#g' \
  -e 's/users\.users\.daf3r/users.users.mel/' \
  -e 's/description = "daf3r"/description = "mel"/' \
  configuration.nix

sed -i \
  -e 's/home.username = "daf3r"/home.username = "mel"/' \
  -e 's#home.homeDirectory = "/home/daf3r"#home.homeDirectory = "/home/mel"#' \
  home.nix

sed -i 's/user = "daf3r"/user = "mel"/' updates.nix

sed -i 's#/home/daf3r/nixos-config#/home/mel/nixos-config#g' \
  updates/nixos-upd.sh updates/upd.sh

sed -i 's#/home/daf3r/Pictures/Screenshots#/home/mel/Pictures/Screenshots#g' \
  config/niri/config.kdl
```

Comprueba qué referencias quedan. Las que aparezcan en comentarios o documentación no
necesitan cambiarse:

```bash
rg -n 'daf3r|/home/daf3r' flake.nix configuration.nix home.nix updates.nix \
  updates config/niri terminal
```

## 5. Adapta el hardware antes de compilar

La configuración original es para un ASUS ROG Strix G17 con NVIDIA. Si `mel` usa otra PC:

- En `configuration.nix`, elimina o adapta las importaciones `./asus.nix` y `./gpu.nix` si
  no hay hardware ASUS ROG o NVIDIA.
- Revisa `./gaming.nix` si no quieres instalar Steam, gamemode y el resto del stack gaming.
- Deja para después del primer arranque gráfico la sustitución de los bloques `output` en
  `config/niri/config.kdl`; los valores correctos salen de `niri msg outputs`.
- Si cambias el hostname, actualiza `networking.hostName` en `configuration.nix`, el
  atributo `nixosConfigurations.<nombre>` en `flake.nix` y `FLAKE_ATTR` en
  `updates/nixos-upd.sh`.

También cambia la identidad Git en `terminal/tools.nix`:

```bash
nano terminal/tools.nix
```

Busca `programs.git.settings.user` y coloca el nombre y correo de GitHub de `mel`.

## 6. Valida y haz el primer build

```bash
git diff --check
nix flake check
sudo nixos-rebuild switch \
  --extra-experimental-features 'nix-command flakes' \
  --flake /home/mel/nixos-config#daf3r-starter
```

El atributo `daf3r-starter` puede conservarse aunque el usuario sea `mel`; es el nombre del
host, no el nombre de la cuenta. Si también lo cambiaste, usa el nuevo atributo en el
comando.

## 7. Después del primer arranque

Cierra sesión y vuelve a entrar para recibir los grupos declarados por la configuración.
Comprueba que la cuenta tiene los grupos esperados:

```bash
groups
```

Después de confirmar que el escritorio inicia, los comandos normales serán:

```bash
nh os switch
upd check
upd status --json
```

Si GitHub publica cambios nuevos, actualiza la rama local sin tocar `main`:

```bash
git fetch origin
git rebase origin/main
```

Resuelve cualquier conflicto conservando las adaptaciones de `mel` y vuelve a ejecutar
`nix flake check` antes de activar otra generación.
