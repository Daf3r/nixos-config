# Burp Suite on NixOS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrar Burp Suite Community en el host NixOS `daf3r-starter` de forma declarativa y dejar un procedimiento seguro y reproducible para usarlo con laboratorios web locales.

**Architecture:** Declarar `pkgs.burpsuite` en el conjunto de paquetes gráficos de `apps.nix`; reutilizar el JDK, el entorno FHS y el `.desktop` que ya provee `nixpkgs`; documentar el proxy únicamente en un perfil de navegador aislado y apuntar las prácticas al taller Docker D04 de CiberClass.

**Tech Stack:** Nix flakes, NixOS, Home Manager, `nixpkgs` unstable fijado por el flake, Burp Suite Community, Docker Compose y navegador Chromium/Brave.

**Spec:** docs/superpowers/specs/2026-08-30-burpsuite-nixos-design.md

## Global Constraints

- Trabajar en `/home/daf3r/nixos-config` y preservar cambios existentes del usuario.
- Mantener la declaración de Thunderbird ya presente en `apps.nix`.
- No introducir secretos, certificados CA, cookies, credenciales ni perfiles de navegador en Git.
- No configurar un proxy global ni aplicar `nixos-rebuild switch` durante esta tarea.
- Validar siempre usando el flake y el host `daf3r-starter`.

---

## Task 1: Registrar la decisión de empaquetado

- [x] Confirmar que el flake usa `nixpkgs` con `allowUnfree = true`.
- [x] Confirmar que `pkgs.burpsuite` existe y que la expresión incluye JDK, FHS y un lanzador de escritorio.
- [x] Documentar licencia interactiva, proxy local y alcance del laboratorio.

## Task 2: Añadir Burp Suite a Home Manager

- [x] Editar `apps.nix` y añadir `burpsuite` dentro de `home.packages` junto a las aplicaciones gráficas.
- [x] Dejar un comentario breve que indique que la actualización proviene de `nixpkgs` y que no se acepta la licencia automáticamente.
- [x] Verificar que la modificación conserva la entrada `thunderbird` y no toca configuraciones no relacionadas.

## Task 3: Crear la guía operativa del laboratorio

- [x] Crear `docs/runbooks/2026-08-30-burpsuite.md` en español.
- [x] Documentar rebuild, primera ejecución y comandos de lanzamiento.
- [x] Documentar listener local `127.0.0.1:8080`, perfil de navegador separado y CA de Burp únicamente dentro de ese perfil.
- [x] Documentar el ciclo de ejecución del taller D04 en `/home/daf3r/Documents/ChatGPT/CiberClass/talleres-docker/04-burp-proxy`, destino `http://127.0.0.1:8084` y apagado con `docker compose down --remove-orphans`.
- [x] Incluir límites de uso y una sección corta de diagnóstico.

## Task 4: Actualizar la documentación del repositorio

- [x] Añadir Burp Suite al inventario de paquetes de `README.md` y `README.es.md`.
- [x] Añadir un enlace a la guía en la sección correspondiente de ambos README.
- [x] Mantener sincronizadas las versiones inglesa y española sin cambiar el alcance del repositorio.

## Task 5: Verificar sin aplicar cambios al sistema

- [x] Ejecutar `git diff --check`.
- [x] Ejecutar `nix --extra-experimental-features 'nix-command flakes' flake check --no-build --all-systems`.
- [x] Ejecutar `nix --extra-experimental-features 'nix-command flakes' build --no-link '.#nixosConfigurations.daf3r-starter.config.system.build.toplevel'`.
- [x] Inspeccionar el diff final y confirmar que sólo contiene la integración de Burp y la documentación solicitada, además de cambios preexistentes sin modificar.
- [x] Informar el comando exacto para aplicar el cambio cuando el usuario decida hacerlo.

## Testing Notes

Esta tarea modifica principalmente configuración declarativa y documentación; no añade lógica de aplicación que requiera una suite unitaria. La evidencia de verificación será la evaluación completa del flake, la construcción de la generación del host y la revisión del diff. La prueba funcional de Burp contra el taller Docker queda descrita en el runbook para ejecutarse cuando el usuario aplique la generación y levante el laboratorio.
