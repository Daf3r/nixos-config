# Diseño: Burp Suite declarativo en NixOS

## Objetivo

Incorporar Burp Suite Community a la configuración de usuario de `daf3r` para que
se instale y actualice junto con el resto del conjunto de aplicaciones del host
`daf3r-starter`, y dejar una guía reproducible para usarlo únicamente con
laboratorios autorizados.

## Decisiones

1. **Paquete:** usar `pkgs.burpsuite` desde el `nixpkgs` fijado por el flake.
   La expresión de `nixpkgs` empaqueta el JAR oficial de PortSwigger en un
   entorno FHS, proporciona su propio JDK y genera el lanzador de escritorio.
   No se descargará ni mantendrá un JAR manualmente dentro de este repositorio.
2. **Ubicación:** declarar `burpsuite` en `apps.nix`, junto a las aplicaciones
   gráficas del usuario. No hace falta declararlo en `home.nix` además, porque
   `home.nix` ya importa `apps.nix`.
3. **Licencia:** conservar `nixpkgs.config.allowUnfree = true`, que ya existe en
   esta configuración, pero no establecer `burpsuite.accept_license`. La primera
   ejecución debe mostrar y requerir la aceptación interactiva de la licencia.
4. **Proxy:** no configurar `networking.proxy`, variables globales ni un CA de
   Burp en NixOS. Burp se utilizará con un perfil de navegador aislado y un
   listener local (`127.0.0.1:8080`), evitando que el proxy intercepte el resto
   de la sesión.
5. **Laboratorio:** la guía documentará el taller D04 de CiberClass en
   `127.0.0.1:8084` como destino de verificación. La configuración de NixOS no
   levantará Docker ni modificará el repositorio del curso.

## Flujo previsto

```text
rebuild del flake
      ↓
Burp Suite Desktop + comando `burpsuite`
      ↓
perfil de navegador separado → proxy HTTP/HTTPS 127.0.0.1:8080
      ↓
taller Docker local autorizado → http://127.0.0.1:8084
```

## Criterios de aceptación

- `apps.nix` contiene `burpsuite` dentro de `home.packages`.
- El cambio no elimina ni reordena de forma innecesaria la entrada existente de
  Thunderbird.
- La documentación explica instalación, primera ejecución, proxy local,
  certificado CA por perfil y apagado del laboratorio.
- `git diff --check` no reporta errores.
- `nix flake check --no-build --all-systems` termina correctamente.
- La generación `daf3r-starter.config.system.build.toplevel` se puede construir
  sin aplicar un `nixos-rebuild switch` automáticamente.

## Fuera de alcance

- Probar objetivos externos o sitios sin autorización.
- Configurar un proxy global del sistema.
- Guardar certificados, credenciales, cookies o sesiones en el repositorio.
- Aceptar automáticamente la licencia de Burp.
- Instalar Burp Pro o gestionar una licencia comercial.
