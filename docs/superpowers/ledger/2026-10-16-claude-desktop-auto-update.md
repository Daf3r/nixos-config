# Claude Desktop: versión al día y actualización automática

Trabajo en la rama `claude/claude-desktop-auto-update-f09e16`, 2026-10-16.

## Estado de partida

- El override `pkgs/claude-desktop-newer.nix` fijaba 2.37337.1.
- El índice apt de Anthropic (`dists/stable/main/binary-amd64/Packages`) tiene
  2.42304.0 como versión más reciente.
- El motor `nixos-upd` no vigilaba este paquete: sólo llamaba a los `bump-*` de
  brave, t3code, chatgpt, minecraft y discord. Una versión nueva de Claude
  Desktop no llegaba a `upd` nunca.

## Hecho

- `pkgs/claude-desktop-newer.nix`: 2.42304.0. El hash del `.deb` descargado
  coincide con el SHA256 del índice (`nix store prefetch-file` frente a
  `nix hash convert`).
- `updates/bump-claude-desktop.sh`: lee el índice, toma la stanza
  `claude-desktop` con la versión más alta, descarga el `.deb` y exige que su
  hash coincida con el del índice antes de escribir. Nunca baja la versión fijada
  aunque el índice vaya por detrás.
- `updates/nixos-upd.sh` y `updates.nix`: el motor llama al nuevo script junto a
  los demás `bump-*`, y el comando queda en el `PATH`.
- `updates/tests/claude-desktop.bats`: 5 casos (versión más alta, sólo dos líneas
  cambian, índice atrasado, hash distinto, índice sin el paquete). Se probó
  quitando a propósito la guarda de no-bajada y la de hash: el caso
  correspondiente falla en cada mutación.
- README.md y README.es.md: fila nueva en la tabla de `pkgs/`.

## Verificado

- `nix flake check --no-build --all-systems`: pasa.
- `nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel`:
  construye. Se compiló `claude-desktop-2.42304.0` y su wrapper de keyring.
- `bats updates/tests/` (suite completa de `updates/`): 202 pruebas, ninguna
  fallida.

## No verificado

- La GUI de 2.42304.0 no se ha arrancado. Sólo se ha comprobado que el paquete
  se construye.
- El `switch` no se ha hecho: lo corre daf3r con root.
- La primera pasada nocturna real del motor con el script nuevo no ha corrido.

## Decisiones

- Se usa el índice apt, no el flake de `poeck`. El flake no se ha actualizado
  desde su pin de 2.9939.4, así que seguir su versión no daba la versión nueva.
- Un `.deb` cuyo hash no coincide con el índice no se escribe. Así se evita
  fijar un fichero que Anthropic no publicó.
- La actualización no se aplica sola. El motor la prepara cada noche y `upd`
  la muestra; `upd apply` hace el fast-forward y el `nh os switch`, y lo ejecuta
  daf3r.

## Para aplicar ahora

Desde `main` ya fusionado en `/home/daf3r/nixos-config`:

```bash
sudo env NIX_CONFIG='experimental-features = nix-command flakes' nixos-rebuild switch --flake /home/daf3r/nixos-config#daf3r-starter
```

Después, comprobar:

```bash
systemctl --failed
```

```bash
readlink -f "$(which claude-desktop)"
```

La segunda debe terminar en `claude-desktop-keyring-2.42304.0/bin/claude-desktop`.
