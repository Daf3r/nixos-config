# Actualización completa de NixOS y aplicaciones

**Fecha:** 2026-08-31

**Objetivo:** actualizar todas las fuentes de software administradas por este
equipo y dejar la generación activa sincronizada con el estado validado.

## Alcance

- Entradas del flake: `nixpkgs`, `home-manager`, `dms-plugins` y
  `claude-desktop`; revisar por separado `dms`, que está fijado a un tag.
- Paquetes locales con detector: Brave Origin, T3 Code, ChatGPT Desktop y
  Minecraft Launcher.
- Perfil Nix del usuario `daf3r`.
- Aplicaciones y runtimes Flatpak de los remotos configurados.
- Paquetes npm globales del usuario, sin usar `sudo npm`.
- Validación y activación mediante el host
  `nixosConfigurations.daf3r-starter`.

## Límites de seguridad

- No borrar generaciones, ejecutar garbage collection ni usar operaciones
  destructivas.
- No sobrescribir los cambios locales ya presentes en el repositorio.
- No publicar ni crear commits sin una petición separada del usuario.
- No actualizar manualmente aplicaciones que no estén instaladas o que no
  tengan una fuente verificable.
- Si una fuente no puede comprobarse o una compilación falla, conservar el
  estado anterior y reportarlo como pendiente, no declararlo actualizado.

## Criterio de terminado

La tarea solo se considera terminada cuando cada fuente comprobable reporta
que está al día, la generación construida coincide con la configuración
actualizada, `nixos-rebuild switch` termina correctamente y las verificaciones
post-activación no muestran servicios fallidos. Las excepciones se enumeran
con su causa y el comando exacto para resolverlas.
