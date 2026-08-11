# Widget de `upd` en la barra — registro de ejecución

Plan: `docs/superpowers/plans/2026-08-11-widget-upd-barra.md`
Spec: `docs/superpowers/specs/2026-08-11-widget-upd-barra-design.md`
Rama: `upd-barra`, desde `9864df3` en `main`. **Sin integrar.**

Estado al cerrar la sesión del 2026-08-11: **tareas 1 a 6 de 11 hechas**, más una
tarea 5b que no estaba en el plan. Cada una con revisión y sus rondas de arreglo
cerradas, salvo la última — ver «Dónde se paró exactamente».

**156 tests verdes**, shellcheck limpio, y build del sistema verde con la suite
corriendo dentro de la derivación.

## Dónde se paró exactamente

HEAD en **`02fe3c4`**, árbol limpio. La tarea 6 está implementada y **revisada
con veredicto de aprobación**; lo que quedó a medias es su **ronda 3**, que es de
pulido y no de comportamiento. El implementador se detuvo sin commitear nada, así
que no hay trabajo colgando en el árbol.

Los tres puntos de esa ronda, por orden de valor:

1. **Anclar el mensaje de `apply` en los cuatro contratos donde hoy ya es
   correcto** (árbol sucio, rama, motor en marcha, lock inabrible) —
   `updates/tests/upd.bats:1060-1139`, una aserción por test. La quinta pareja,
   la del repo ilegible, **no se ancla**: ahí `apply` culpa a un HEAD desprendido
   y anclar la redacción exigiría arreglar `apply`, que es de la tarea 7.
2. **Corregir la ficha C9 del informe** en `.superpowers/…/task-6-report.md`:
   describe como cascada un mensaje que sale de la guardia del clon
   (`upd.sh:529`), no de la que nombra. Medido: `|| cur_branch=""` sobrevive,
   pero borrar la guardia del todo **muere** con rc 128.
3. `updates/tests/upd.bats:107` — el ayudante `upd()` no exporta
   `GIT_CEILING_DIRECTORIES`, que sí exporta `upd_status()` (`:125`) por esta
   misma razón. El test del repo ilegible depende de que ningún antecesor de
   `$TMPDIR` sea un repo git.

## Lo que hace falta de daf3r

El sistema tiene `/var/lib/nixos-upd/status.json` en **schema 2** y el `upd`
instalado en **schema 1**, así que `upd show` rechaza el fichero. Es el
comportamiento diseñado, y en esta dirección su consejo acierta.

**No corre prisa**: el timer nocturno corre el `upd` instalado, que reescribe el
fichero en schema 1, y `upd show` vuelve solo. Lo que desbloquea la lectura sin
root es `upd check`.

Cuando la rama se integre, el switch que alinea todo:

```
nh os switch ~/nixos-config
```

Se comprueba con `upd status --json | jq .blockers`, que debe responder un objeto
en vez de rechazar el schema. **No aplica la actualización preparada**: construye
con el mismo nixpkgs fijado y solo activa el motor nuevo.

**`nh os boot` no lo ha ejecutado nadie de verdad**, solo el stub. Los tests
prueban con igualdad exacta que se invoca como `os boot` y no como `os switch`,
pero la primera ejecución real será en esta máquina.

## Qué hay hecho

| Tarea | Qué entra | Commits |
|---|---|---|
| 1 | `lib/closure.sh` — `closure_parse`, de la salida de `nix store diff-closures` a JSON | `67f24dc..2c14b74` |
| 2 | `closure_reboot` — decide si el cambio pide reinicio | `75e6693..58098f1` |
| 3 | `lib/inputs.sh` — `inputs_diff`, qué inputs movió el lock | `e64cdef..3fd6f35` |
| 4 | `status.json` a schema 2 y el motor componiendo el cuerpo nuevo | `5d59da9..9dd0ed6` |
| 5 | `upd status --json` con los bloqueos en vivo | `c53dc4d..47df65d` |
| 5b | `lib/blockers.sh` — el cálculo de bloqueos sale de `upd.sh` | `9f1289f..28f5154` |
| 6 | `apply --ff-only` y `apply --boot` | `bc4e06f..02fe3c4` |

**La tarea 5b no estaba en el plan.** Se intercaló por decisión de daf3r: la
tarea 6 reescribía `apply` entero, así que extraer después habría significado
tocar `apply` dos veces. Se descartó meterla dentro de la 6 porque una tarea que
extrae y reescribe a la vez deja sin saber cuál de los dos cambios rompió.

## Por qué no `system.autoUpgrade`

Es la primera pregunta que se hace cualquiera que lea este repo. Comprobado
contra el módulo real (`nixos/modules/tasks/auto-upgrade.nix`), no contra la
wiki.

**Lo que `autoUpgrade` sí hace y `upd` reimplementa**: el timer nocturno
(`dates`, `randomizedDelaySec`, `persistent`), actualizar el flake, y
`operation = "boot"`. Trae además tres cosas que `upd` **no** tiene:
`rebootWindow`, `runGarbageCollection` y `fixedRandomDelay`.

**Lo que decide la cuestión**: `operation` solo admite `switch` o `boot`, y **las
dos aplican** — el script es literalmente `nixos-rebuild boot ${flags}`. `boot`
no es «prepáralo y espera»: escribe el bootloader y deja la generación puesta
para el siguiente arranque. **No existe un modo «constrúyelo, dime qué cambia y
no toques nada».** Y no expone ningún estado legible por otro programa, así que
el widget no tendría de dónde leer. Tampoco hace los bumps propios ni tiene
guardias sobre el árbol de trabajo del usuario.

Dato que valida una decisión de este trabajo: el módulo oficial compara
`/run/booted-system/{initrd,kernel,kernel-modules}` contra
`/nix/var/nix/profiles/system/{…}` — **usa las dos rutas para preguntas
distintas**, que es exactamente por lo que aquí se renombró
`_UPD_BOOTED_SYSTEM` a `_UPD_SYSTEM_PROFILE`. El perfil no es lo que arrancó.

## Los defectos del plan que aparecieron al ejecutarlo

El plan lo escribió Claude y **los defectos los encontraron los
implementadores**, todos medidos contra datos reales:

1. **El regex del tamaño exigía una coma delante.** Las líneas `kitty: 51.2 KiB`
   contaban 0: se perdían 2,56 de 8,88 MB en cinco paquetes del diff real.
2. **La lista de paquetes de reinicio estaba a nivel de fichero**, y ahí no
   sobrevive al `export -f` de los tests. La función respondía **siempre «no hace
   falta reiniciar»**, con estado 0 y sin nada en stderr — justo en la
   actualización que mueve el driver NVIDIA.
3. **`.[0]` no resuelve un `follows` profundo.** Al arreglarlo apareció algo
   peor: con la base en el nodo actual la respuesta salía **invertida y en
   silencio**. Otra forma de la misma ruta daba recursión infinita dentro de la
   unidad de systemd — y esa forma (`dms.inputs.nixpkgs = ["nixpkgs"]`) ya está
   en este `flake.lock`.
4. **El snapshot del `flake.lock` previo se tomaba antes del `reset`.** En la
   segunda noche seguida sin aplicar, eso convierte cinco inputs en uno, con un
   `from` que el sistema nunca tuvo, estado 0 y sin avisos.
5. **El aviso mandaba a `upd apply --boot`** cuando ese flag no existía: `apply`
   lo aceptaba, lo ignoraba y activaba en caliente. El aviso que existe para
   evitar el switch en caliente durante un salto de driver dirigía al switch en
   caliente. La tarea 6 lo devolvió a `--boot`, ahora que el flag existe de
   verdad.
6. **El bloque `flock` del plan devolvía `engine_running` cuando `STATE_DIR` no
   existe o es de solo lectura**: bloqueo fantasma permanente, con el panel
   dibujando el botón muerto para siempre y culpando a un proceso inexistente.
7. **Los dos `git` fallaban callados en un `$REPO` que no es repositorio**: uno
   se leía como «árbol limpio» y el otro como «HEAD desprendido» — dos
   afirmaciones sobre algo que nunca se abrió.
8. **El plan mandaba añadir `status` al `--help`, y no existe ningún `--help`**
   en `upd.sh`. La instrucción partía de una premisa falsa.

## El patrón que se repitió, y lo que lo cierra

Casi todos los hallazgos bloqueantes fueron de la misma familia: **tests que no
sujetaban lo que su nombre decía**. Las formas concretas, que son distintas entre
sí y vale la pena conocer por separado:

- **La aserción mira el sitio equivocado.** «stdout vacío» comprobado sobre
  `$output`, que en bats es stdout **y** stderr fundidos.
- **La aserción se ancla en el texto de una herramienta ajena.** Se asertaba la
  ausencia de `integer expression`; bash 5.3.15 dice `integer expected`. Con la
  guardia entera borrada, las tres aserciones seguían pasando.
- **Dos fuentes para una aserción.** Al hacer que el pie de `show` nombrara
  `--boot`, la aserción del aviso pasó a poder satisfacerse desde dos sitios:
  borrar el flag del aviso la dejaba verde. **Dos fuentes para una aserción
  significa que no cubre ninguna.**
- **Un cambio en producción desactiva un test bueno sin tocarlo.** No es escribir
  un test malo; es que sigue verde mientras deja de cubrir.
- **Un stub no puede ocultar un binario que existe.** El test del `nh` ausente
  hacía `rm` del stub, lo que solo destapa el binario del sistema: llevaba tiempo
  ejecutando el `nh` real contra un repo de usar y tirar. El arreglo **afirma su
  premisa** (`command -v nh` falla) antes de apoyarse en ella.
- **El defecto está en la pantalla, no en el texto.** El pie de `show`
  contradecía al aviso cuatro líneas más arriba, y la instrucción peligrosa era
  la última. Cada texto era correcto por separado.

Lo único que ha funcionado contra esto es **mutar a propósito**: romper la línea
de producción que el test dice cubrir y confirmar que el test cae.

## Criterios de método que salieron de este trabajo

- **Toda promesa nueva de un contrato llega con su test, o no llega.** Redactar
  mejor la cabecera de `blockers.sh` no funcionó: tres rondas seguidas
  encontraron algo falso en ella. Lo que la sostiene es que cada cláusula muere
  bajo mutación.
- **La prosa que cuenta cosas caduca.** Ningún test puede pinchar «dice dos y son
  cuatro». Se escribe «the clauses below», no «the two clauses below».
- **«Ningún test los distingue» no es «son equivalentes».** Para retirar una
  mutación del arnés hay que poder decir que **ningún test posible** la
  distinguiría. Si la diferencia existe y simplemente nadie la observa, es un
  hueco de cobertura con el nombre cambiado.
- **Un arreglo propuesto en una revisión es una hipótesis, no una instrucción.**
  Dos arreglos de revisores resultaron falsos al medirlos: `integer expected` no
  es subcadena de `integer expression expected`, y **`$stdout` no existe en
  bats** — ese habría cambiado un test que no miraba stdout por otro que no mira
  nada, indetectable por cualquier mutación.
- **Se ancla el mensaje donde hoy es correcto, y se anota donde no lo es.** La
  regla «atamos que falla, no con qué palabras» deja la deriva abierta justo por
  donde se cuela.
- **El guardarraíl del arnés de mutación es obligatorio**: si la cadena a sustituir
  no aparece exactamente una vez, aborta. Actuó tres veces, y las tres el
  disparador fue el mismo — un arreglo previo reescribiendo la línea anclada.
  Sin él, mutaciones que **nunca se aplicaron** habrían entrado en la cuenta como
  muertas.
- **Una referencia `fichero:línea` sin comprobar es otra copia que miente.** En
  una sección del plan, cinco de seis estaban desplazadas.
- **Tachar, no borrar — pero solo en el informe.** Una afirmación falsa que llegó
  a circular se tacha con su corrección al lado. Eso vale para el informe, que es
  registro de lo que pasó; **no para el plan ni el spec**, que se leen como
  verdad presente y donde una línea tachada es ruido que alguien copiará.

## Hechos de la máquina que costó descubrir

- **`errexit` NO está activo dentro de una sustitución de comando que forma parte
  de una asignación** — ni con `||` ni sin él. Medido en bash 5.3.15:
  `f() { local a; a="$(false)"; echo SIGUIO; }` llamado como `y="$(f)"` **sigue**.
  Consecuencia: toda guardia que dependa de que `set -e` propague desde dentro de
  un `x="$(...)"` es decorativa. Y por el otro lado: una lectura dentro de
  `if [ "$(jq …)" ]` no aborta, pero **izarla a una asignación sí**, lo que dio a
  `show` un código de salida que su cabecera no documentaba.
- **`jq` sigue interpretando opciones después de `--args`.** Un valor que empiece
  por `-` da RC=2, y `--args` como valor da `detail: null` **en silencio**. Se
  cierra con un `--`. Y **es alcanzable**: `git -C` acepta una ruta que empieza
  por guion.
- **`${v:0:N}` cuenta bytes bajo locale C** y parte el carácter UTF-8. En el
  sandbox de nix `LANG` no suele estar puesto.
- **`git status --porcelain` con un directorio ilegible avisa, sale con 0 y no
  imprime nada** — las tres cosas a la vez. Un fallo invisible por los tres
  canales por los que se suele mirar.
- **`git branch -- -foo` rechaza el nombre con rc 128**, aunque
  `check-ref-format` lo acepte. Git lo prohíbe donde importa: al crearla.
- **`tr … | head -c N` bajo `pipefail` es una carrera**: reproducida a 38 KB en
  una pasada y no en otra del mismo tamaño. Las expansiones de bash la eliminan y
  ahorran dos procesos.

## Decisiones tomadas, con su porqué

- **`linux-firmware` no entra en la lista de reinicio.** El criterio es qué se
  desincroniza con el sistema en marcha; el firmware ya cargado no lo hace. Un
  aviso que salta siempre deja de leerse.
- **`local_pkgs` se elimina, no convive con `changes[]`.** Dos copias de los
  mismos hechos son dos fuentes que pueden discrepar.
- **`clone_unusable` se retira del diseño**, no se implementa. El panel sondea
  `status --json` en bucle y esas comprobaciones abren el clon de
  `/var/lib/nixos-upd`, mucho más caro que el `git status` del repo; un clon roto
  es raro y `apply` ya falla con su mensaje. **Coste asumido y dicho**: en ese
  caso raro el botón se dibuja activo sobre un `apply` que fallará.
- **`pending_reboot` desactiva el botón del panel pero no frena `upd apply` desde
  el terminal**, y está bien así. Los otros cinco bloqueos son «no puedo» —
  aplicar sería incorrecto y se perdería trabajo—; éste es «probablemente no
  quieras», que es caro pero válido. Bloquear el terminal obligaría a inventar un
  `--force`, **peor puerta trasera que la asimetría**.
  - El riesgo real no es la asimetría, es la **deriva**: cinco condiciones
    expresadas dos veces, en dos ficheros y con dos redacciones. La respuesta no
    es compartir el código —`blockers_live` es un informe sin efectos y `apply`
    **toma** el lock en vez de consultarlo— sino **fijar el acuerdo con tests**.
    Están en `upd.bats:1060-1139`, y ya pagaron: descubrieron que no existía
    ningún test de `apply` para un lock inabrible ni para un repo ilegible.
  - Si algún día se quiere simetría, **el sitio es `apply`, no `blockers_live`**.
- **El registro del proceso vive aquí, versionado.** El flujo de subagentes
  escribe en `.superpowers/`, que está en `.gitignore` porque el repo es público.

## Deuda aceptada, con su razón

- **Cambio de formato parcial sin detectar**: si todas las líneas del diff tienen
  forma conocida pero el significado cambia, `closure_parse` calla el resto.
- **El mutante `endswith()` sobrevive** en la comparación de nombres. Cerrarlo
  pide un paquete real que **termine** en una entrada de la lista, y hoy no se
  conoce ninguno.
- **`resolve()` no tiene guarda de profundidad**: un `flake.lock` corrompido a
  mano agota la memoria. El fallo es ruidoso, no silencioso, y nix no escribe
  self-follows.
- **Un input sin `rev`** (tipo `path:`) que se mueva no se reporta. Los catorce
  nodos del lock llevan rev.
- **`repo_uncheckable` cubre cuatro causas** (git ausente, repo no abrible, árbol
  no legible entero, avisos no capturables). Todas acaban en «no sé si el árbol
  está limpio» y el `detail` las distingue. **Si la tarea 8 quiere iconos por
  causa, ésa es la fila que se parte.**
- **La cabecera de `blockers.sh` va por 88 líneas para 150 de código.** La
  frontera está bien —una sola pregunta, una sola razón para cambiar—; lo que ha
  crecido es el **historial de incidentes**, que ya está escrito en el plan.
  Podarla a ~30 líneas es trabajo de la tarea 11, y **no se encarece por
  esperar**.
- **`mktemp` por llamada** en el camino que el panel sondeará en bucle.
  Irrelevante frente al `git status` que lo rodea; es lo primero que mirar si el
  sondeo acaba siendo cada segundo. Sin `trap` a propósito: un `trap` en una
  función *sourced* corre en el shell del llamador, y eso ya corrompió el
  teardown de bats en `lib/nixpin.sh`.
- **Tres tests de `chmod 000` fallan si se corre la suite como root.** El sandbox
  construye con `nixbld`, así que la puerta no se ve afectada.
- **`upd.sh:455`**: la apertura del lock filtra el diagnóstico de bash por encima
  de la frase propia. Preexistente.

## Lo que hay que saber para retomar

- **`closure_parse` falla todo o nada.** Nada aguas abajo puede tratar ese 1 como
  «no hay actualizaciones».
- **`closure_reboot` exige un objeto por stdin**: vacío → 1, no-objeto → 5. Hay
  que comprobar veracidad, no comparar con `-eq 1`.
- **Nix lista seis `Updated input` donde `inputs_diff` emite cinco, y es
  correcto**: la sexta es un nodo transitivo cuyo rev no se movió. El panel no
  cuadrará con el log de nix.
- **`changes[]` incluye entradas con `from == to`** y, si un bump falla, una con
  `from == to == ""` más un `error`. El filtro vive en `show`; `status --json`
  emite el objeto sin filtrar a propósito, porque el consumidor es una máquina.
  **El plugin tiene que mirar `warnings` siempre**, no deducir del array.
- **Tras un `--ff-only` sin activar, el motor sigue diciendo `ready`**, no
  `current`: compara la **closure construida** con `/run/current-system`
  (`nixos-upd.sh:469`), y ésas difieren. El estado colgado queda visible y un
  `upd apply` posterior lo cierra. Lo que sí queda: un `ready` cuyo `changes[]`
  visible viene vacío, porque los inputs se comparan contra `lock.before`.
- **No tocar el `ulimit -v` de `updates/tests/inputs.bats`**: convierte una
  regresión del recorrido de `follows` en un fallo de test en vez de en un
  cuelgue de la máquina.
- **La mutación deliberada se corre sobre código ya commiteado** o sobre copia
  fuera del repo. Un harness restauró con `git checkout --` y se llevó un arreglo
  sin commitear, dejando la suite verde sobre el código con el bug.
- **`git add` antes de creerse un build verde**: la evaluación del flake solo ve
  ficheros trackeados.
- **`updates.nix` no lleva lista explícita de libs** — `cp -r ./lib` copia el
  directorio entero. Cómodo para añadir, y también significa que **nadie se
  entera si un fichero de `lib/` desaparece**.

## Lo que queda

| Tarea | Qué falta | Necesita root |
|---|---|---|
| 6 | **la ronda 3, de pulido** — ver «Dónde se paró exactamente» | no |
| 7 | Unidad `nixos-upd-apply@` y reglas polkit | **sí**, paso 4 |
| 8 | `logic.js` del plugin y sus pruebas | no |
| 9 | `plugin.json`, `Daemon.qml`, `Widget.qml`, declaración en `dms.nix` | **sí**, paso 5 |
| 10 | `Popout.qml` y las acciones del daemon | **sí**, paso 4 |
| 11 | Retirar la fase 2 de la spec vieja, READMEs y pasada de verificación | no |

**La tarea 7 hereda dos cosas.** Que **haga visible el fallo del unit por su
cuenta** (estado del `systemctl start`), que es donde se cierra el lazo del
`--ff-only` que no llega a aplicarse. Y que `apply`, si pierde su guardia de
apertura del lock, diría «hay una comprobacion en marcha» siendo falso — hoy
inalcanzable porque la guardia está, y anclado por el test de contrato.

**La tarea 11 hereda**: podar la cabecera de `blockers.sh`, marcar las casillas
`- [ ]` de todas las tareas del plan a la vez, y **llevar a `updates/README.md`
la comparación con `system.autoUpgrade`** que está más arriba en este fichero.

Otra sesión de Claude Code espera a que esta rama se integre para empezar el
trabajo del `.deb` oficial de ChatGPT: su spec está en
`docs/superpowers/specs/2026-08-11-chatgpt-deb-oficial-design.md` y toca
`updates/lib/` y `updates/tests/`, por lo que no deben solaparse.
