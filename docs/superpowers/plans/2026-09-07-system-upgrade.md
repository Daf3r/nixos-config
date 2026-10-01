# Actualización del sistema — 2026-09-07

Autorizada por daf3r después de aplicar el rice a su perfil. Conservar cambios locales de main y la rama rice/desktop-polish; sin commits ni merge. Baseline activo: 26.11.20260829.d2f6794; no unidades fallidas. Copia del diff y lock anterior fuera del repositorio, en el workspace de Codex.

1. Actualizar flake y detectores de paquetes locales; comprobar release estable DMS sin adoptar betas.
2. Validar flake y construir el toplevel de daf3r-starter. Ejecutar pruebas del actualizador ya modificado antes de incluirlo en la generación.
3. Actualizar perfil Nix, Flatpak y npm global del usuario.
4. Comparar el cierre con el activo. Si cambian kernel/gráficos, usar nixos-rebuild boot con flake explícito. Autenticación sudo interactiva pendiente; no reiniciar automáticamente.
5. Verificar cada fuente y registrar generación preparada/activa, excepciones y estado del rice.

## Resultado

- Flake actualizado: nixpkgs c043004, Home Manager 2c0350c. DMS revisado y fijado a v1.6.0 estable, publicado el 3 de septiembre; sus opciones del rice siguen presentes. Los demás inputs no cambiaron.
- Brave Origin 1.94.121, T3 Code 0.0.39, ChatGPT Desktop 26.901.51231; bootstrap Minecraft sin cambios.
- Flake check sin build/all-systems correcto. 168 pruebas Bats del actualizador y 54 del plugin Node correctas. Build toplevel y diff check correctos.
- Perfil Nix actualizado contra el mismo nixpkgs c043004, sobreponiendo la resolución anterior del registro. npm actualizado: Claude Code 2.1.263; outdated vacío. Flatpak actualizado (Sober 1.7.1 y NVIDIA runtime actual); instalado además org.freedesktop.Platform.GL.nvidia-595-99-02 para el nuevo driver. remote-ls --updates vacío. El remoto local sober-local carece de AppStream/canal online comprobable para Sober2: excepción mantenida, no eliminado.
- Autenticación sudo realizada por el usuario en Kitty. nixos-rebuild boot --flake /home/daf3r/nixos-config#daf3r-starter terminó con código 0. Perfil de sistema apunta a /nix/store/9pjpxdb86x8pdi2sw9dhnqcq5hiix8gm-nixos-system-daf3r-starter-26.11.20260905.c043004.
- Incluye Xanmod 7.1.13, NVIDIA 595.99.02, Mesa 26.2.2, DMS 1.6.0, Discord 1.0.156. El sistema en ejecución sigue en 26.11.20260829.d2f6794 hasta reiniciar. No se reinició ni se hizo switch en caliente.
- systemctl is-system-running=running; sin unidades fallidas del sistema ni del usuario. bootctl list no pudo leer loader.conf sin privilegios; instalación del bootloader finalizó correctamente según nixos-rebuild. La activación y QA de DMS 1.6 después del reinicio quedan pendientes.
- Paquete de rice recompilado con nixpkgs actualizado, GC root ~/.local/state/nixos-rice/current. Wrappers y desktop entry actualizados sin reescribir ajustes DMS ni dolphinrc. Dolphin 26.08.0 confirmado. El manifiesto del backup original de rice mantiene los nuevos destinos aplicados para conservar su rollback único.
- Sin commits, merge, push ni limpieza de generaciones. Logs y comparación del cierre en el workspace de Codex work/system-update.

## Correcciones de paneles tras la actualización

Solicitud: retirar el aviso de sesión Claude caducada al usar Codex y corregir el estado del actualizador después de boot.

- Parche local del input claude-usage en config/dms/usage-provider.patch. Nuevo ajuste claude_enabled (true por defecto; false en este usuario); omite lectura/consulta de Claude y limpia sus datos publicados, conservando Codex. Toggle añadido en ajustes. 203 tests JS pasan; los dos nuevos fallan contra Daemon.qml original. El repositorio externo dms-plugins permanece intacto.
- upd status publica activation.pendingBoot solo cuando perfil != actual y actual == booted. Así no etiqueta un nixos-rebuild test como instalación lista. Protección de apply conservada. Clasificación QML muestra Actualización instalada · reinicia y omite cambios/avisos históricos de ese informe mientras espera reinicio. 56 tests JS pasan, incluyendo regresión rojo-verde. Test Bats adicional para distinguir boot de test; build del paquete ejecuta la suite y checks.
- Plugin nixos-upd vinculado a su lector absoluto en el store mediante dms.nix, evitando mezclar versiones vía PATH. Flake check y build toplevel correctos; diff check limpio.
- Se movieron las dos copias antiguas claude-usage.* fuera del directorio escaneado a ~/.local/state/nixos-rice/plugin-backup-20260907. Enlaces canónicos apuntan a home-manager-files de la generación corregida, sin copias duplicadas. Se activó claude_enabled=false tras las operaciones de carga.
- Recarga individual conservaba QML cacheado; reinicio únicamente de dms.service con servicio sano. La barra muestra el texto corregido, verificado visualmente. No se logró mantener el popout abierto durante captura con el juego en pantalla completa; la supresión de Claude se verifica por pruebas, preferencia activa y código cargado.
- Terminal de sudo abierta para nixos-rebuild boot con la generación corregida; verificar su código de salida antes de afirmar persistencia en el siguiente arranque.

Confirmación final: el usuario completó sudo en la terminal reabierta. install-boot.exit=0; perfil de sistema y generación corregida coinciden en /nix/store/j2pcnq82b929s024p20jzwgiszafqkw9-nixos-system-daf3r-starter-26.11.20260905.c043004. Sistema running, sin unidades fallidas del sistema ni del usuario. Correcciones instaladas para el próximo arranque; reinicio pendiente del usuario.
