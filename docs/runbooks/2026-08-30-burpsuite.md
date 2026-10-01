# Burp Suite en NixOS

Esta configuración instala Burp Suite Community de forma declarativa para el
usuario `daf3r` en el host `daf3r-starter`. El paquete viene de `nixpkgs` y ya
incluye el JDK, el entorno FHS y el lanzador gráfico; no hace falta instalar
Java ni descargar un `.jar` manualmente.

## Aplicar la instalación

Primero valida la generación sin modificar el sistema:

```bash
cd /home/daf3r/nixos-config
nix --extra-experimental-features 'nix-command flakes' flake check --no-build --all-systems
nix --extra-experimental-features 'nix-command flakes' build --no-link \
  '.#nixosConfigurations.daf3r-starter.config.system.build.toplevel'
```

Cuando quieras activarla, usa el flake y el host explícitos:

```bash
sudo env NIX_CONFIG='experimental-features = nix-command flakes' \
  nixos-rebuild switch --flake /home/daf3r/nixos-config#daf3r-starter
```

Después del rebuild estarán disponibles:

```bash
burpsuite
```

También aparecerá como **Burp Suite Desktop** en el lanzador de aplicaciones.

## Primera ejecución

La configuración permite paquetes no libres porque el repositorio ya declara
`nixpkgs.config.allowUnfree = true`. La aceptación de la licencia de Burp no se
guarda en Nix: la primera ejecución debe mostrarla y aceptarse de forma
interactiva en el equipo.

Para un curso conviene seleccionar un proyecto temporal de Burp por taller. No
guardes el proyecto, la CA, cookies ni credenciales dentro de este repositorio.

## Navegador aislado y proxy local

No se configura un proxy global en NixOS. Usa un perfil separado para que una
sesión normal de Brave no intente enviar todo su tráfico a Burp.

Con Burp abierto y su proxy escuchando en `127.0.0.1:8080`, una forma práctica
de iniciar Brave Origin es:

```bash
brave-origin \
  --user-data-dir="$HOME/.local/share/burpsuite-browser" \
  --proxy-server="http=127.0.0.1:8080;https=127.0.0.1:8080"
```

En ese perfil configura el proxy HTTP y HTTPS a `127.0.0.1:8080` si el
navegador no conserva los argumentos de lanzamiento. No uses este perfil para
correo, banca, sesiones personales ni credenciales reales.

Para inspeccionar HTTPS en ese perfil:

1. Abre Burp y confirma que el listener local esté activo.
2. Visita `http://burp` desde el perfil aislado.
3. Descarga el certificado CA de Burp.
4. Instálalo como autoridad de confianza solamente en ese perfil.
5. Elimina el perfil o retira la autoridad cuando termines el taller.

No uses `--ignore-certificate-errors`. Si el navegador muestra errores TLS,
revisa primero que la CA esté instalada en el perfil correcto y que la fecha y
hora del sistema sean correctas.

## Taller D04 de CiberClass

El taller de proxy de Burp está en:

```text
/home/daf3r/Documents/ChatGPT/CiberClass/talleres-docker/04-burp-proxy
```

Levántalo con un destino local y autorizado:

```bash
cd /home/daf3r/Documents/ChatGPT/CiberClass/talleres-docker/04-burp-proxy
docker compose up -d --build
```

Usa como objetivo:

```text
http://127.0.0.1:8084
```

En Burp, limita el **Target scope** a ese host. Luego sigue la lista de
verificación del taller, especialmente la confirmación de que las solicitudes
aparecen en **Proxy → HTTP history** y de que el navegador funciona al
desactivar el proxy.

Al terminar:

```bash
cd /home/daf3r/Documents/ChatGPT/CiberClass/talleres-docker/04-burp-proxy
docker compose down --remove-orphans
```

## Diagnóstico rápido

### Burp no aparece en el lanzador

Confirma que el rebuild terminó y que el comando existe:

```bash
command -v burpsuite
burpsuite
```

Si el comando no existe, todavía estás usando la generación anterior o el
rebuild no terminó correctamente.

### No aparece tráfico HTTP

Comprueba que el listener sea `127.0.0.1:8080`, que el navegador use el perfil
aislado y que no haya otra aplicación ocupando el puerto:

```bash
ss -ltn | rg ':8080\b'
```

### HTTP funciona pero HTTPS falla

Revisa la instalación de la CA dentro del perfil aislado. No desactives la
verificación TLS del navegador ni cambies el proxy global del sistema.

### El laboratorio no abre

Comprueba el estado de Docker y que el puerto `8084` esté publicado por el
`docker compose` del taller:

```bash
docker compose ps
ss -ltn | rg ':8084\b'
```

## Límites de uso

Este procedimiento está pensado para `127.0.0.1`, CTFs y aplicaciones sobre las
que tengas autorización explícita. Apaga el proxy al terminar, evita datos
reales y no pruebes dominios externos sólo porque sean accesibles desde el
navegador.
