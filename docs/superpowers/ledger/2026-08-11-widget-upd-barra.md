# Widget de `upd` en la barra — registro de ejecución

Plan: `docs/superpowers/plans/2026-08-11-widget-upd-barra.md`
Spec: `docs/superpowers/specs/2026-08-11-widget-upd-barra-design.md`
Rama: `upd-barra`, desde `9864df3` en `main`. **Sin integrar.**

Estado al cerrar la sesión del 2026-08-11: **tareas 1 a 4 de 11 hechas**, cada
una con revisión y sus rondas de arreglo cerradas. Las tareas 5 a 11 no se han
empezado.

## Lo que hace falta de daf3r antes de seguir

El sistema quedó con `/var/lib/nixos-upd/status.json` en **schema 2** y el `upd`
instalado todavía en **schema 1**, así que `upd show` rechaza el fichero. Es el
comportamiento diseñado —un lector viejo no debe renderizar un formato que no
entiende— pero deja el motor inservible hasta activar el código nuevo:

```
nh os switch ~/nixos-config
```

Se comprueba con `upd show`, que debe listar los cambios estructurados en vez
del rechazo. **No aplica la actualización preparada**: construye con el mismo
nixpkgs fijado y solo activa el motor nuevo.

## Qué hay hecho

| Tarea | Qué entra | Commits |
|---|---|---|
| 1 | `lib/closure.sh` — `closure_parse`, de la salida de `nix store diff-closures` a JSON | `67f24dc..2c14b74` |
| 2 | `closure_reboot` — decide si el cambio pide reinicio | `75e6693..58098f1` |
| 3 | `lib/inputs.sh` — `inputs_diff`, qué inputs movió el lock | `e64cdef..3fd6f35` |
| 4 | `status.json` a schema 2 y el motor componiendo el cuerpo nuevo | `5d59da9..8c37916` |

120 tests verdes al cerrar (103 al empezar la tarea 4), shellcheck limpio y
build del sistema verde con la suite dentro de la derivación.

## Los defectos del plan que aparecieron al ejecutarlo

El plan lo escribí yo y **los cinco defectos los encontraron los
implementadores**, todos medidos contra datos reales. Vale la pena tenerlos
juntos porque dicen dónde falla escribir un plan sin ejecutar nada:

1. **El regex del tamaño exigía una coma delante.** Las líneas `kitty: 51.2 KiB`
   contaban 0: se perdían 2,56 de 8,88 MB en cinco paquetes del diff real.
2. **La lista de paquetes de reinicio estaba a nivel de fichero**, y ahí no
   sobrevive al `export -f` de los tests. Llegaba vacía al shell hijo, así que
   la función respondía **siempre «no hace falta reiniciar»**, con estado 0 y
   sin nada en stderr — justo en la actualización que mueve el driver NVIDIA.
3. **`.[0]` no resuelve un `follows` profundo.** Al arreglarlo apareció algo
   peor: con la base en el nodo actual la respuesta salía **invertida y en
   silencio**, omitiendo el input al que la ruta apunta y reportando el que no
   le corresponde. Otra forma de la misma ruta daba recursión infinita y
   agotamiento de memoria dentro de la unidad de systemd — y esa forma
   (`dms.inputs.nixpkgs = ["nixpkgs"]`) ya está en este `flake.lock`.
4. **El snapshot del `flake.lock` previo se tomaba antes del `reset`.** En la
   segunda noche seguida sin aplicar, eso convierte cinco inputs en uno, con un
   `from` que el sistema nunca tuvo, estado 0 y sin avisos.
5. **El aviso mandaba a `upd apply --boot`**, y `apply` aceptaba ese flag, lo
   ignoraba y activaba en caliente. El aviso que existe para evitar el switch en
   caliente durante un salto de driver dirigía al switch en caliente. Ahora
   `apply` rechaza los argumentos que no conoce.

## Lo que encontraron las revisiones

Todos los hallazgos bloqueantes de las cuatro tareas fueron de la misma
familia: **tests que no sujetaban lo que su nombre decía**.

- El test del «nombre exacto, no subcadena» sobrevivía al mutante de subcadena:
  `nvidia-settings` no contiene ninguna entrada de la lista, así que no probaba
  el criterio. Se cerró añadiendo `mesa-demos`, que sí es supercadena.
- `.added` y `.removed` se podían borrar de la función con la suite entera en
  verde.
- Ningún test cubría el filtrado de códigos ANSI: sustituir el `sed` por `cat`
  dejaba los ocho tests verdes.
- **`nixos-upd.sh`, el motor entero, no tenía ni un test.** Se descubrió porque
  la mutación dejó tres mutantes vivos, todos ahí. Ahora tiene
  `updates/tests/nixos-upd.bats`, end-to-end con `nix`, `nixos-rebuild`, `curl`
  y `npm` stubbed, cubriendo el camino `ready`.
- **Y una vez más en la última ronda de la tarea 4**: el test que decía sujetar
  la guardia numérica del rechazo por schema asertaba la ausencia de `integer
  expression`, una redacción que bash 5.3.15 no usa — el suyo es `integer
  expected`. Con la guardia entera borrada, el lector filtraba el error del
  shell y las tres aserciones seguían pasando. El ancla pasó a ser el mensaje
  propio del lector; de paso se cerró el mismo hueco por el otro lado (una tira
  de dígitos de cualquier longitud volvía a romper `[`) y se ejercitó por fin la
  rama de recuperación del veredicto de reinicio, inyectando el fallo por
  `$LIB_DIR` como el resto del fichero hace con `nix` y `curl`.

## Decisiones tomadas, con su porqué

- **`linux-firmware` no entra en la lista de reinicio**, aunque aparezca en el
  diff entre generaciones. El criterio es qué se desincroniza con el sistema en
  marcha; el firmware ya cargado no lo hace, y el nuevo espera al siguiente
  arranque. Meterlo haría saltar el aviso en actualizaciones que no lo
  necesitan, y un aviso que salta siempre deja de leerse.
- **`local_pkgs` se elimina, no convive con `changes[]`.** Motor y lector se
  instalan juntos y no pueden desincronizarse dentro de una generación; el único
  caso real, un `upd` viejo en el `$PATH`, ya lo cubre el rechazo por schema.
  Dos copias de los mismos hechos son dos fuentes que pueden discrepar.
- **El registro del proceso vive aquí, versionado.** El flujo de subagentes
  escribe en `.superpowers/`, que está en `.gitignore` porque el repo es
  público; este fichero es lo que sobrevive.

## Deuda aceptada, con su razón

- **Cambio de formato parcial sin detectar**: si todas las líneas del diff
  tienen forma conocida pero el significado cambia, `closure_parse` parsea lo
  que reconoce y calla el resto. Detectarlo pediría contar líneas contra
  entradas, y sin saber qué ruido legítimo puede aparecer daría falsos
  positivos.
- **El mutante `endswith()` sobrevive** en la comparación de nombres. El
  `contains()` muere, que era el nombrado, pero una regla de sufijo tampoco es
  «nombre exacto». Cerrarlo pide un paquete real que **termine** en una entrada
  de la lista, y hoy no se conoce ninguno en esta máquina.
- **`resolve()` no tiene guarda de profundidad**: un `flake.lock` corrompido a
  mano con `root.inputs.pin = ["pin"]` agota la memoria. Se acepta porque el
  fallo es ruidoso, no silencioso, y nix no escribe self-follows.
- **Un input sin `rev`** (tipo `path:`) que se mueva no se reporta. Hoy no
  aplica: los catorce nodos del lock llevan rev.

## Lo que hay que saber para retomar

- **`closure_parse` falla todo o nada.** El día que nix emita una unidad de
  tamaño nueva, devuelve 1 y no hay diff en vez de un total mal contado. Nada
  aguas abajo puede tratar ese 1 como «no hay actualizaciones».
- **`closure_reboot` exige un objeto por stdin**: vacío → 1, no-objeto → 5, que
  es el estado de jq. Hay que comprobar veracidad, no comparar con `-eq 1`.
- **Nix lista seis `Updated input` donde `inputs_diff` emite cinco, y es
  correcto**: la sexta es un nodo transitivo cuyo rev no se movió, solo cambió
  `.tar.xz` por `.tar.zst`. El panel no cuadrará con el log de nix.
- **No tocar el `ulimit -v` de `updates/tests/inputs.bats`**: es lo que
  convierte una regresión del recorrido de `follows` en un fallo de test en vez
  de en un cuelgue de la máquina.
- **La mutación deliberada se corre sobre código ya commiteado.** En la tarea 3
  un harness restauró con `git checkout --` y se llevó un arreglo sin
  commitear, dejando la suite verde sobre el código con el bug.
- **`git add` antes de creerse un build verde**: la evaluación del flake solo ve
  ficheros trackeados, así que un fichero nuevo sin añadir no entra y el build
  pasa sin haber probado nada.

## Lo que queda

| Tarea | Qué falta | Necesita root |
|---|---|---|
| 5 | `upd status --json` con los bloqueos en vivo | no |
| 6 | `apply --ff-only` y `apply --boot` | no |
| 7 | Unidad `nixos-upd-apply@` y reglas polkit | **sí**, paso 4 |
| 8 | `logic.js` del plugin y sus pruebas | no |
| 9 | `plugin.json`, `Daemon.qml`, `Widget.qml`, declaración en `dms.nix` | **sí**, paso 5 |
| 10 | `Popout.qml` y las acciones del daemon | **sí**, paso 4 |
| 11 | Retirar la fase 2 de la spec vieja, READMEs y pasada de verificación | no |

La tarea 6 tiene un enganche con lo hecho: la tarea 4 endureció `apply` para que
rechace argumentos desconocidos, así que al añadir `--boot` y `--ff-only` hay que
comprobar que la lista de flags aceptados se amplía y que el aviso del motor
sigue apuntando a un comando que existe y hace lo que promete.
