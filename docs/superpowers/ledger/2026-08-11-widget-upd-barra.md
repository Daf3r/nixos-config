# Widget de `upd` en la barra — registro de ejecución

Plan: `docs/superpowers/plans/2026-08-11-widget-upd-barra.md`
Spec: `docs/superpowers/specs/2026-08-11-widget-upd-barra-design.md`
Rama: `upd-barra`, desde `9864df3` en `main`. **Sin integrar.**

Estado al cerrar la sesión del 2026-08-11: **tareas 1 a 8 de 11 hechas**, más una
tarea 5b que no estaba en el plan. Cada una con revisión y sus rondas de arreglo
cerradas, la 6 incluida — su ronda 3, de pulido, cerró en `f45e029`.

**Lo único sin verificar al cerrar: la ronda 3 de la tarea 8** (`6dd10a2`). Su
re-revisión se lanzó y la sesión se acabó antes de que volviera, así que **el
implementador la declara hecha y nadie la ha comprobado**. Lo que sí está
confirmado a mano: **159 bats + 35 node, cero fallos**. Los tres puntos que esa
ronda tocaba son de texto y de una aserción —corregir una afirmación falsa en el
nombre y el comentario de un test, impedir que ese test se auto-desactive, y
añadir la columna de pasados a una tabla del informe—, así que el riesgo es bajo;
pero **es lo primero que hay que cerrar mañana**, antes de empezar la tarea 9.

**159 tests bats verdes** y la suite de node del plugin, shellcheck limpio, y
build del sistema verde con la suite corriendo dentro de la derivación y con el
chequeo de la unidad de apply también dentro.

**Ojo al historial: otra sesión mergeó `main` dentro de esta rama** (`3e187dc`,
que trae `a15768d`: los workers de KIO para que Dolphin vea el teléfono por MTP).
Toca **solo `apps.nix`, +11 líneas**, nada de `updates/` ni del plugin, y entró
sin conflictos — pero la rama del widget lleva ahora un commit que no es suyo, y
al integrar aparecerá dos veces en el historial.

**La tarea 7 está aceptada en la máquina.** Su prueba falló a la primera —la
unidad murió en 48 ms porque `nh` se niega a correr como root, ver «Ronda 1»— y
tras el arreglo pasó entera: polkit deniega al cancelar y permite al autenticar,
y la unidad terminó con `Result=success` y `Adding configuration to bootloader`.

## Dónde se paró exactamente

HEAD en la ronda 1 de la tarea 7, sobre `af6552c`. Árbol limpio salvo la spec del
`.deb` de ChatGPT, que es de otra sesión. La tarea 7 está implementada,
construida y **con su primera prueba de aceptación ya corrida** — falló, se
arregló, y falta volver a correrla (más abajo, «Lo que hace falta de daf3r»).

Qué entró en la tarea 7:

1. **`nixos-upd-apply@switch` y `@boot`** (`updates.nix`), oneshots de root que
   solo activan, con el modo validado dentro de la unidad y no solo en polkit.
2. **Las reglas polkit**, `YES` para `nixos-upd.service` y `AUTH_ADMIN` —nunca
   `AUTH_ADMIN_KEEP`— para las dos instancias del apply.
3. **`apply` deja de culpar al HEAD de un repositorio que no puede abrir**
   (`updates/upd.sh`), con test propio para la guardia del HEAD desprendido y la
   **quinta pareja del contrato anclada** por fin.
4. **El `--no-block` de la tarea 10 corregido contra medición**, en el plan y en
   la spec.

### Ronda 1: la unidad murió en la máquina, y por qué no lo vio nadie

La primera versión **falló en la prueba de aceptación**, en 48 ms:

```
nixos-upd-apply[…]: 0: Don't run nh os as root. It will escalate its
                       privileges internally as needed.
nixos-upd-apply@boot.service: Main process exited, code=exited, status=1
```

`nh` **se niega a ser root a propósito**, porque espera que lo lance un usuario y
elevarse él. En la unidad ya es root y no hay nada que elevar, que es exactamente
lo que dice `--elevation-strategy none`. Es el arreglo, y no
`--bypass-root-check`: ése también pasa la negativa —medido, con un aviso
`! Bypassing root check; running nix as root`— pero deja la estrategia en `auto`,
así que `nh` seguiría buscando doas/sudo/run0/pkexec siendo ya root y sin TTY.
Uno describe la situación; el otro solo calla la queja.

**La parte de polkit sí funcionó** y no hay que rehacerla: entre el
`systemctl start` y el arranque de la unidad pasaron ~55 s, que es el modal
esperando autenticación. Un arranque no autenticado es instantáneo.

**Y `--elevation-strategy none` hace el `safe.directory` más necesario, no menos**
—comprobado, no supuesto—: sin elevación `nh` ya no pasa por `sudo`, que era lo
que ponía `$SUDO_UID` y lo único que dejaba contento a libgit2 por accidente.
Medido a través de `nh` mismo, con euid 0 y un repositorio de otro dueño: sin la
exención muere con `is not owned by current user`; con ella pasa del fetch.

**Nada de la suite podía atrapar esto**, y ése es el hallazgo que queda: bats
stubbea `nh`, y un stub acepta lo que le den. Lo único que sabe que `nh` rechaza
esa línea de comandos es `nh`. Ahora hay un **chequeo en tiempo de build** que lo
corre de verdad —`updates.nix`, `applyCommand`— sin root, sin daemon y sin
activar nada: `unshare -Ur` da euid 0 dentro de un espacio de nombres de usuario,
que es lo único que mira `nh`, y **los espacios de nombres sin privilegios anidan
dentro del sandbox de nix** (verificado). La ruta del repositorio no existe
dentro del sandbox, así que la ejecución muere en la resolución del flake, que es
*después* del chequeo de root — y esa diferencia es la que distingue los dos
casos. El script comprobado **es** el que ejecuta la unidad: no hay forma de
meterlo en el sistema sin que el chequeo haya pasado.

**Ese chequeo se equivocó tres veces en tres rondas, siempre igual: afirmando más
de lo que miraba.** Vale la pena la lista, porque es el patrón de toda la rama:

| Ronda | Qué afirmaba de más | Qué lo destapó |
|---|---|---|
| 1 | el control salía del propio script quitándole el flag, así que desaparecía con él | revertir el arreglo fallaba culpando al control |
| 2 | todas las aserciones sobre `nh` eran negativas: un log que `nh` nunca escribió las cumple todas | un `nh` inexistente y un `case` sin `boot`, los dos con build verde |
| 3 | «corrió los dos modos» sin mirar qué modo recibía `nh`, y sin ejercitar ningún modo inválido | fijar `nh os boot`, y borrar el brazo `*)`, los dos con build verde |

Lo que corrige la 3: se lee el **vector de argumentos** que recibiría `nh` (copia
del script con la ruta de `nh` sustituida por un grabador), y se ejercitan cuatro
modos inválidos —la cadena vacía entre ellos— exigiendo que se rechacen antes de
que `nh` los vea. **Descartado por medición**: comprobar el *texto* del script
probaría que la línea dice `os "$mode"`, no que `nh` reciba el modo.

### Lo que había dejado la ronda 3 de la tarea 6, y qué queda de ello

1. **El mensaje de `apply` anclado en los cuatro contratos donde entonces ya era
   correcto** (árbol sucio, rama, motor en marcha, lock inabrible), una aserción
   por test. La quinta, la del repo ilegible, quedó sin anclar con la razón
   escrita en el bloque: `apply` culpaba a un HEAD desprendido, y anclar esa
   redacción habría fijado el defecto. **La tarea 7 la arregló y la ancló**, así
   que las cinco están.
   Las cuatro se mataron mutando; **una de esas mutaciones es el mutante C10 que
   sobrevivió en la ronda 2** —borrar la guardia `exec 9>`—, así que ese hueco
   queda cerrado.
2. **Ficha C9 del informe reescrita contra medición.** Su conclusión aguantaba y
   su evidencia no: la frase que citaba sale de la guardia del clon
   (`upd.sh:529-530`), que corre **antes** que la del HEAD desprendido, así que
   la cascada que describía no existe. Lo medido: `|| cur_branch=""` sobrevive y
   entonces habla la guardia **de rama** con el nombre vacío; borrar la guardia
   del todo **muere** con rc 128, porque errexit se lleva `apply`.
3. **`upd()` exporta ya `GIT_CEILING_DIRECTORIES`**, como `upd_status()`.
   Demostrado con un `$TMPDIR` dentro de un repo git: sin el techo el test
   **seguía diciendo `ok`** mientras `apply` se iba a operar sobre el repositorio
   de fuera y le hacía un `git fetch` de verdad (`FETCH_HEAD` escrito). Misma
   familia que el `nh` real de la ronda 1.

El informe completo de las tres rondas está en
`.superpowers/sdd/2026-08-11-widget-upd-barra/task-6-report.md`, que **no está
versionado** — de ahí que lo que importa se resuma aquí.

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

### La prueba de aceptación de la tarea 7: **PASADA**

Corrida en la máquina, y las dos mitades quedaron demostradas:

- **polkit, las dos direcciones.** Al cancelar el modal, la unidad **no arrancó**
  — cero entradas en el journal, que es la prueba de la denegación. Tras
  autenticar, arrancó.
- **La activación.** `Result=success`, `ExecMainStatus=0`, sin
  `Don't run nh os as root` y sin `is not owned by current user`, y con
  `> Adding configuration to bootloader` en el journal.

Con eso **la mitad de libgit2 que declaré no demostrable queda demostrada**: root
leyó `~/nixos-config` a través del fetcher de git de nix y la exención
`safe.directory` hizo su trabajo. Era lo único que no se podía comprobar en un
sandbox, porque un sandbox no tiene ni ese repositorio ni un dueño distinto.

**Corrección de un criterio que yo di y que no probaba nada.** Escribí que
`readlink /nix/var/nix/profiles/system` «debe haber cambiado». **Es falso como
prueba de esta acción**: la generación que apareció la había creado el
`nh os switch` del paso anterior, no el apply. Lo que demuestra que el apply hizo
algo es **`Adding configuration to bootloader`** en el journal de la unidad. Un
criterio de aceptación que se cumple por el paso anterior no es un criterio de
aceptación — es la misma clase de defecto que esta rama lleva persiguiendo, esta
vez en mi propia lista de comprobación.

Si hubiera que repetirla algún día, los comandos son:

```
systemctl reset-failed nixos-upd-apply@boot.service
systemctl start nixos-upd-apply@boot.service     # sale el modal
systemctl show nixos-upd-apply@boot.service -p Result -p ExecMainStatus
journalctl -u nixos-upd-apply@boot.service -b --no-pager | grep -i bootloader
```

## Qué hay hecho

| Tarea | Qué entra | Commits |
|---|---|---|
| 1 | `lib/closure.sh` — `closure_parse`, de la salida de `nix store diff-closures` a JSON | `67f24dc..2c14b74` |
| 2 | `closure_reboot` — decide si el cambio pide reinicio | `75e6693..58098f1` |
| 3 | `lib/inputs.sh` — `inputs_diff`, qué inputs movió el lock | `e64cdef..3fd6f35` |
| 4 | `status.json` a schema 2 y el motor componiendo el cuerpo nuevo | `5d59da9..9dd0ed6` |
| 5 | `upd status --json` con los bloqueos en vivo | `c53dc4d..47df65d` |
| 5b | `lib/blockers.sh` — el cálculo de bloqueos sale de `upd.sh` | `9f1289f..28f5154` |
| 6 | `apply --ff-only` y `apply --boot` | `bc4e06f..f45e029` |

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

0. **El plan trataba «bloqueos ausentes» igual que «sin bloqueos»** — el
   `buttonFor` del brief hacía `Array.isArray(status.blockers) ? … : []`. Como el
   fichero de disco no lleva esa clave y nunca la llevará, la versión del plan,
   **corrida verbatim contra el fichero real de esta máquina**, dibujaba
   `[ACTIVO] "Aplicar al arrancar"` sobre un repo con el árbol sucio y en la rama
   equivocada: un botón que `upd apply` iba a rechazar. Lo que lo hace
   concluyente es que **sobre el objeto de ejemplo del propio plan —que sí trae
   `blockers: []`— el agujero es invisible**. Es el defecto de esta tanda que más
   se habría visto en pantalla, y el que justifica la regla de medir el contrato
   contra la fuente viva en vez de contra el plan.
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
- **La mutación siempre encuentra supervivientes, así que hace falta un criterio
  de parada — y el criterio no puede ser el cansancio.** En la tarea 8 se
  lanzaron 17 mutantes propios y sobrevivieron los 17; con 40 habrían salido más.
  El criterio que se usó, y que se recomienda reutilizar: **se ancla lo que el
  usuario ve y puede ser mentira.** Entró el resumen que decía «todo al dia»
  sobre algo que no compila, el `tone` invertible, el icono —lo único visible sin
  abrir el panel— y la etiqueta que describe la acción. Quedaron fuera, **por
  escrito y como hueco declarado**, las etiquetas decorativas y un separador.
  Declarar el hueco es la parte que hace honesto el criterio.
- **Probar decisiones no es probar lo que se dice.** La suite de la tarea 8
  anclaba qué acción se ofrece y si está activa, y dejaba libre **el texto que el
  panel escribe**. Un módulo que decide bien y dice algo falso tiene el mismo
  fallo desde el único asiento que importa, que es el del usuario.
- **Un recuento con cero tests pasados no es una mutación muerta: es un fichero
  que no parsea.** Ocurrió una vez, con un mutante que rompía un template
  literal; `node --test` lo presentaba como un test fallando y se lee igual que
  una muerte legítima. Se caza poniendo `node --check` delante, y la señal a la
  que hay que mirar en la tabla es el número de **pasados**, no el de fallos.
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
- **Una ruta pelada de flake es un repositorio git para nix.**
  `nix flake metadata ~/nixos-config` responde
  `git+file:///home/daf3r/nixos-config`. Todo lo que aplique desde ahí pasa por
  el fetcher de git, no lee un directorio.
- **libgit2 se niega ante un repositorio cuyo dueño no es el euid que llama**, y
  nix no puede desactivarlo: importa `git_libgit2_init` y **no**
  `git_libgit2_opts`. Reproducido: `repository path '...' is not owned by current
  user (libgit2 error code = 7)`. **`sudo` es lo que lo tapa** —libgit2 acepta el
  dueño si coincide con `$SUDO_UID`—, así que el fallo aparece justo donde no hay
  sudo: en una unidad de systemd. Se arregla con `safe.directory`, y **solo por
  `HOME` o `XDG_CONFIG_HOME`**: `GIT_CONFIG_GLOBAL` es de git(1) y libgit2 lo
  ignora, medido.
- **`Type=oneshot` desactiva el timeout de arranque.** Todos los oneshot de esta
  máquina que no fijan `TimeoutStartSec` dicen `TimeoutStartUSec=infinity`. Un
  switch de veinte minutos no necesita salvaguarda; añadirla lo haría *más*
  estricto, no menos. (`nixos-upd.service` fija 3h, que es exactamente eso.)
- **`systemctl start` de un oneshot devuelve el resultado; `--no-block` no.**
  Medido: bloqueando, RC=1 y `Job for … failed`; con `--no-block`, RC=0 antes de
  que la unidad haya corrido. Y el sondeo posterior **no lo recupera**: una
  unidad que **nunca ha corrido** y una que **terminó bien** dicen las dos
  `inactive`/`success`. Solo el fallo es legible por ahí.
- **Dos `Environment=PATH=` en la misma unidad: gana la última.** NixOS pone la
  suya siempre, así que la de uno va después y la sustituye. Comprobado con una
  unidad de usuario de usar y tirar, no deducido del manual.
- **`nh` se niega a correr como root** y hay dos escapes que **no** son
  equivalentes: `--elevation-strategy none` le dice que no hay nada que elevar y
  retorna antes del chequeo; `--bypass-root-check` solo salta el `bail!` y deja
  la estrategia en `auto`, con un aviso `! Bypassing root check`. Comprobado
  contra el binario de 4.4.2, no solo contra el fuente.
- **`git rev-parse --is-inside-work-tree` en un repo bare imprime `false` y sale
  con 0.** Una guardia que solo mire el código de salida **no salta**, y detrás
  `git status` sale 128 con stdout vacío, así que la guardia siguiente anuncia
  «limpio». Hay que **comparar la salida**, no esperar un fallo.
- **Los espacios de nombres de usuario sin privilegios anidan dentro del sandbox
  de nix**: `unshare -Ur id -u` da 0 en un `runCommand`. Es lo que hace posible
  probar en tiempo de build un binario que se comporta distinto siendo root.
  Coste: `nh` sondea `nix --version` y `nix config show experimental-features`
  antes de mirar el uid, así que el chequeo necesita `nix` en el PATH y
  `NIX_CONFIG = "experimental-features = nix-command flakes"`.

- **Que `nh` llegue a resolver el flake no dice con qué verbo lo llamaron.** Muere
  en la ruta del flake antes de que el subcomando importe, y la queja es idéntica
  para `switch` y para `boot`. Así que fijar `nh os boot` sin propagar el modo
  deja el build verde: hay que **leer el vector de argumentos**, no inferirlo de
  que la ejecución llegó lejos. El truco barato es una copia del script con la
  ruta de `nh` sustituida por un grabador de argumentos.
- **En un builder de nixpkgs, `out` es el path de salida.** Usarla como variable
  de bucle deja `install` sin destino (`install: target "''": No such file or
  directory`). Lo encontró el propio build.

  **Y de ahí cuelga la portabilidad del chequeo de `applyCommand`**: si algún día
  el kernel, el nix o la máquina de build no permiten anidar espacios de nombres,
  el chequeo **no puede correr**. No se degrada en silencio — su control positivo
  falla y el build para diciendo que no pudo comprobar nada —, que es la elección
  deliberada: un build que se detiene con una explicación antes que un chequeo
  que deja de comprobar sin avisar. Pero conviene saberlo antes de mover este
  repo a un builder remoto o a CI.

- **Las dos superficies ya no dicen la misma frase sobre un repositorio que no se
  puede abrir, y hoy son compatibles pero no iguales**: `upd.sh` dice «no puedo
  leer … como repositorio git **con arbol de trabajo**» y `lib/blockers.sh:113`
  sigue diciendo «no puedo leer … como repositorio git». La divergencia nació al
  arreglar lo del repo bare, que es exactamente la distinción que la frase larga
  añade. El test de contrato del repo ilegible ancla la de `apply` por
  subcadena, así que la divergencia **no la rompe nadie sin querer** — pero el
  comentario de esa guardia justifica su existencia hablando de que las dos
  superficies digan cosas compatibles, y eso es ya una afirmación que hay que
  releer si alguien vuelve a tocar cualquiera de las dos.

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
| 9 | `plugin.json`, `Daemon.qml`, `Widget.qml`, declaración en `dms.nix` | **sí**, paso 5 |
| 10 | `Popout.qml` y las acciones del daemon | **sí**, paso 4 |
| 11 | Retirar la fase 2 de la spec vieja, READMEs y pasada de verificación | no |

**La tarea 9 hereda tres cosas, y la primera es dura:**

1. **Tiene que sondear `upd status --json`, nunca el fichero de disco.** Los dos
   documentos son idénticos byte a byte salvo por una clave: el fichero **no
   lleva `blockers` y nunca lo llevará** (`lib/blockers.sh:5-10` — el árbol
   sucio y la rama sacada son hechos del momento, y la pasada nocturna los
   escribiría con horas de antelación). Si el widget lee el fichero, el panel
   **nunca ofrecerá aplicar**: correcto, pero inútil.
2. **`engine_running` no apaga «Comprobar ahora».** Con `state: current` y ese
   bloqueo el botón sale activo, y el motor lo rechazaría por el lock.
   `blockers_live` se calcula en todos los estados, pero `buttonFor` solo lo
   consulta en la rama `ready`. El brief tiene la misma forma, así que no era
   defecto de la tarea 8: hay que decidirlo aquí.
3. `unmanaged[]`, `kind` y `size_delta_mb` viajan en los datos y **nadie los
   pinta todavía**.

**De las tres cosas que heredaba la tarea 7, dos están cerradas y una sigue
abierta a propósito.** La guardia del HEAD desprendido, cerrada: frase corregida,
test propio, y la mutación `|| cur_branch=""` que sobrevivía a los 156 mata hoy
exactamente ese test. El lazo del `systemctl start`, cerrado donde se podía —
medido que `--no-block` tira el resultado y que el sondeo no lo recupera, y el
plan y la spec de la tarea 10 corregidos; **el código es de la tarea 10**, y esa
es la línea que hay que respetar al implementarla. Y sigue abierta la tercera:
`apply`, si pierde su guardia de apertura del lock, diría «hay una comprobacion
en marcha» siendo falso — inalcanzable porque la guardia está, y anclado por el
test de contrato.

**Lo que la tarea 7 deja abierto, y no arregló porque no es suyo:** la guardia de
árbol sucio de `apply` concluye «limpio» sobre un árbol que git no pudo leer
entero. Reproducido con un subdirectorio en modo 000: `warning: could not open
directory 'secreto/'`, **rc 0 y stdout vacío**, así que `apply` pasa de largo. Es
el mismo defecto que `blockers_live` ya cerró en el lado del panel —con captura
de stderr y fichero temporal— y que en `apply` sigue vivo. La tarea 7 sí cerró la
mitad de al lado (un repositorio que no se abre), que era la que tenía dueño.

**La tarea 11 hereda**: **el reenganche tras un `dms restart` a mitad de apply**
(paso 0 de su sección en el plan), podar la cabecera de `blockers.sh`, marcar las
casillas `- [ ]` de todas las tareas del plan a la vez, y **llevar a
`updates/README.md` la comparación con `system.autoUpgrade`** que está más arriba
en este fichero.

Lo del reenganche se nombra aquí porque durante una ronda **no fue de nadie**: la
tarea 7 lo sacó de la tarea 10 diciendo que era de la 11, la spec siguió
prometiéndolo, y ni los pasos de la 11 ni esta lista lo mencionaban. Un
comportamiento diseñado sin dueño es como la spec y el árbol se separan. **La
regla de lectura, medida y no negociable**: `inactive` + `success` significa «no
está corriendo», nunca «salió bien» — una unidad que jamás ha corrido dice
exactamente lo mismo que una que terminó hace una hora.

**Anotado, no arreglado, y con dueño pendiente:** el mismo punto ciego del repo
bare que se arregló en `apply` sigue en `lib/blockers.sh:112` — ahí
`--is-inside-work-tree` tampoco se compara con nada. La diferencia es que el
panel **acaba acertando por otro camino**: su captura de stderr y del código de
salida alrededor de `git status` convierte el repo bare en `repo_uncheckable`
con la frase de git dentro (`fatal: this operation must be run in a work tree`).
Medido. Por eso no se tocó `blockers.sh` —además de que la sesión del `.deb` de
ChatGPT trabaja en `updates/lib/`—, pero el test nuevo del repo bare **fija las
dos mitades**, así que si ese camino de repuesto se rompe, se entera alguien.

Otra sesión de Claude Code espera a que esta rama se integre para empezar el
trabajo del `.deb` oficial de ChatGPT: su spec está en
`docs/superpowers/specs/2026-08-11-chatgpt-deb-oficial-design.md` y toca
`updates/lib/` y `updates/tests/`, por lo que no deben solaparse.
