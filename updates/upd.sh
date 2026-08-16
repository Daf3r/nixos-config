#!/usr/bin/env bash
set -euo pipefail

# Read what the nightly engine prepared, and apply it when asked.
#
# This script is the *only* thing the user ever runs, so it is also the only
# place the engine's findings become visible. Every silent-failure fix in
# nixos-upd.sh -- the skipped VA-API check, the failed package bump, the
# unwritable diff -- lands in status.json as a `warnings` entry and reaches a
# human only if this file prints it. So it prints all of them, on every state,
# and a `ready` carrying warnings is made to look different from a clean one.
# A reader that renders an incomplete check exactly like a passed one recreates,
# at the last step, the failure mode the whole engine exists to remove.
#
# Applying goes through git -- fast-forward $BRANCH, then switch -- so every
# automated change stays reviewable and revertible rather than appearing in the
# system out of nowhere. Not "the checked-out branch", which is what this said
# before the branch gate landed and is now precisely what apply refuses to do:
# if $REPO has some other branch checked out, apply stops and says to switch
# rather than dragging that branch onto the prepared commit and leaving $BRANCH
# behind.
#
# `status --json` is the same reading for a program instead of a person: the
# file as the engine wrote it plus the live reasons an apply would refuse right
# now, which is the one thing status.json cannot carry.
#
# Exit codes:
#   0  the status was read and reported (including build_failed/check_failed:
#      those are outcomes, not reader errors), or the apply succeeded, or
#      `status --json` produced its object -- blockers and all
#   1  this reader has no answer to give: a status file that is missing,
#      unparseable or of an unknown schema. And, for `apply` alone, the
#      refusals to act: a dirty target tree, a clone it cannot vouch for, a
#      missing tool. Those last three are exit 1 when they stop an apply and
#      exit 0 with a `blockers[]` entry when `status --json` reports them --
#      refusing to act and reporting that acting would be refused are different
#      answers, and the panel needs the second one to be an answer at all.
#   2  status.json carries a `state` this reader does not know

REPO="${REPO:-/home/daf3r/nixos-config}"
# The branch the engine prepares *from*, and therefore the only branch it makes
# sense to fast-forward. Same name and same default as in nixos-upd.sh: the two
# must agree, and a divergence between them is exactly what the check further
# down refuses to paper over.
BRANCH="${BRANCH:-main}"
STATE_DIR="${STATE_DIR:-/var/lib/nixos-upd}"
STATUS="$STATE_DIR/status.json"
WT="$STATE_DIR/wt"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same resolution order as nixos-upd.sh and the two bump scripts: $LIB_DIR when
# the store wrapper sets it, the sibling directory when this runs from a
# checkout. Sourced unconditionally, like they do -- the file only defines
# functions, so the cost to `show` is a read.
LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
# shellcheck source=lib/blockers.sh
source "$LIB_DIR/blockers.sh"
# shellcheck source=lib/status.sh
source "$LIB_DIR/status.sh"

# The one schema this reader understands. Kept as a variable so the refusal
# message below can name both sides of the mismatch. Schema 2 dropped the prose
# `local_pkgs` array for the structured `changes[]`, `closure_diff`,
# `reboot_recommended` and `reboot_reason`; the two formats share no field this
# reader could fall back on, which is why the gate refuses rather than degrades.
SCHEMA=2

die() { # $1 message, $2 exit code (default 1)
  echo "upd: $1" >&2
  exit "${2:-1}"
}

# Both `show` and `apply` read status.json, and they must not drift on what
# counts as a file worth acting on. A half-written or hand-edited status is a
# refusal, never something to render optimistically: `jq -r '.state'` on garbage
# prints `null` and a reader that did not check would go on to print a heading
# for it.
require_readable_status() {
  if ! jq -e 'type == "object"' "$STATUS" >/dev/null 2>&1; then
    die "$STATUS no es un objeto JSON legible; el motor lo dejo a medias o alguien lo edito a mano"
  fi
  local schema
  schema="$(jq -r '.schema // "ausente"' "$STATUS")"
  if [ "$schema" != "$SCHEMA" ]; then
    # Which side is stale decides the advice, and until schema 2 there was only
    # one side it could be: with SCHEMA=1 nothing older than 1 existed, so a
    # mismatch always meant the file was newer and "update the system" was
    # always right. Schema 2 opens the other direction, and it is not the
    # exotic one -- the nightly timer runs the *installed* engine, so a system
    # that has not been switched yet keeps rewriting status.json in schema 1,
    # and the switch that follows leaves this reader looking at an old file on
    # an up-to-date system. Telling that user to update the system sends them
    # to do nothing; what rewrites the file is `upd check`. Same rule as the
    # reboot advice below: pointing someone at something that does not do what
    # it says is worse than saying nothing.
    #
    # The numeric comparison is guarded because `$schema` is whatever was in
    # the file, including the string "ausente" this very line puts there when
    # the key is missing. `[ ausente -lt 2 ]` is not false, it is a bash error
    # on stderr and a status of 2, so an unguarded version would answer the
    # hand-edited case with a line about test operators.
    #
    # The third pattern is the length cap, and it is not belt and braces: a
    # string of digits alone passes `*[!0-9]*` at any length, and `[` parses it
    # with strtoimax, so a value past 2^63 lands in the very same bash error the
    # first two patterns exist to avoid -- measured on this file before the cap
    # with `"schema": 99999999999999999999`, which leaked
    # `[: 99999999999999999999: integer expected` and then advised updating the
    # system. Ten characters or more is well past any schema this reader will
    # ever meet (they are counted 1, 2, 3) and comfortably short of where bash
    # overflows, so nothing legitimate is caught by it.
    local advice
    case "$schema" in
      '' | *[!0-9]* | ??????????*)
        advice="y eso no es un numero de schema que este lector pueda comparar: el fichero esta corrupto o editado a mano, miralo tu" ;;
      *)
        if [ "$schema" -lt "$SCHEMA" ]; then
          advice="el viejo es el fichero, no este lector: lanza \`upd check\` para que el motor lo reescriba"
        else
          advice="el viejo es este lector: actualiza el sistema para tener un upd al dia"
        fi ;;
    esac
    die "status.json declara schema $schema y este lector solo entiende $SCHEMA; $advice"
  fi
}

# A successful hot apply has consumed the prepared update. Keep the status file
# as a `current` report rather than deleting it: the DMS plugin can then render
# "todo al dia" instead of mistaking a missing file for an unreadable engine.
# The saved closure diff belongs only to the prepared comparison, so it is
# removed after the atomic status replacement succeeds. If either cleanup step
# fails, the applied system is not rolled back; the non-zero result tells the
# caller that the status needs attention instead of claiming a clean handoff.
clear_prepared_state() {
  local body

  body="$(jq -c '{warnings: (.warnings // []), unmanaged: (.unmanaged // [])}' "$STATUS")" \
    || die "el sistema se aplico, pero no pude leer sus avisos para limpiar el estado preparado"
  if ! status_write "$STATUS" current "$body"; then
    die "el sistema se aplico, pero no pude escribir el estado current; no limpio el diff"
  fi
  if ! rm -f "$STATE_DIR/diff.txt"; then
    die "el sistema se aplico, pero no pude eliminar $STATE_DIR/diff.txt"
  fi
  echo "estado preparado limpiado; el sistema ya esta aplicado"
}

# The DMS apply is split in two processes: `upd apply --ff-only` moves the
# user's branch, and the privileged systemd unit activates it. The latter calls
# this subcommand after `nh` succeeds, so it must verify that the prepared clone
# still names the commit now checked out before discarding the status. A nightly
# check that raced into the gap would otherwise have its newer update erased.
finalize_switch() {
  local state prepared repo_head

  [ -f "$STATUS" ] || die "el sistema se aplico, pero no hay status.json que limpiar"
  require_readable_status
  state="$(jq -r '.state // "ausente"' "$STATUS")" \
    || die "el sistema se aplico, pero no pude leer el estado preparado"

  if [ "$state" = "current" ]; then
    rm -f "$STATE_DIR/diff.txt" \
      || die "el sistema se aplico, pero no pude eliminar $STATE_DIR/diff.txt"
    return 0
  fi
  [ "$state" = "ready" ] \
    || die "el sistema se aplico, pero el estado cambio a '$state'; no limpio nada"

  [ -d "$WT/.git" ] \
    || die "el sistema se aplico, pero no hay clon preparado en $WT; no limpio nada"
  prepared="$(git -c "safe.directory=$WT" -C "$WT" rev-parse --verify --quiet 'auto/update^{commit}')" \
    || die "el sistema se aplico, pero no pude leer el commit preparado en $WT"
  repo_head="$(git -c "safe.directory=$REPO" -C "$REPO" rev-parse --verify --quiet 'HEAD^{commit}')" \
    || die "el sistema se aplico, pero no pude leer HEAD de $REPO"
  [ "$prepared" = "$repo_head" ] \
    || die "el sistema se aplico, pero $WT ya prepara otro commit; no borro ese cambio"

  clear_prepared_state
}

# `warnings` is an array on all four terminal states -- populated or empty,
# never absent, never null. The one exception is nixos-upd.sh's jq-failure
# fallback body inside fail(), which is effectively unreachable but does omit
# the key; hence `// []` rather than trusting it to be there. Anything that is
# present but not an array is a producer bug, and this says so out loud instead
# of printing nothing.
warn_count() {
  jq -r '(.warnings // []) | if type == "array" then length else 1 end' "$STATUS"
}

# Things the engine reports but never touches -- today only claude-code, which
# npm owns. Shared by `ready` and `current` because the engine now fills the
# field on both: a reader that printed it on one state only would put the field
# back out of reach on the state the user sees most mornings.
print_unmanaged() {
  jq -r '.unmanaged[]? | "  fuera de nix: " + .name + " " + .from + " -> " + .to + "\n    " + .command' "$STATUS"
}

warn_lines() {
  jq -r '
    (.warnings // []) as $w
    | if ($w | type) != "array"
      then "  AVISO [lector] el campo warnings no es una lista sino "
           + ($w | type) + "; este status.json es sospechoso"
      else $w[]
           | "  AVISO [" + (.code // "sin codigo") + "] " + (.detail // "sin detalle")
      end
  ' "$STATUS"
}

cmd="${1:-show}"

case "$cmd" in
  show)
    [ -f "$STATUS" ] || { echo "no hay ninguna comprobacion todavia"; exit 0; }
    require_readable_status

    state="$(jq -r '.state // "ausente"' "$STATUS")"
    when="$(jq -r '.checked_at // "fecha desconocida"' "$STATUS")"
    nwarn="$(warn_count)"
    # Read once, used twice: the reboot advisory and the footer under it, which
    # have to agree about whether this update wants a reboot. The bug that
    # pairing fixed *was* two sources for one screen, and one read is the
    # cheapest way to keep it that way.
    #
    # Read up here, before a single line is printed, and not down in the `ready`
    # arm where it lived for one round. Moving it out of the `if [ "$(jq …)" ]`
    # condition and into an assignment moved it into a context where errexit
    # acts, and `show` started dying with jq's own exit code after printing its
    # heading -- measured at RC=5 with half a report on screen and a code its
    # own header does not document. Up here the refusal happens before any
    # output exists, so a reader gets either a whole report or a refusal.
    #
    # `|| die`, not `|| reboot_rec=false`: swallowing the failure would silently
    # drop the reboot advisory, which is the one line on this screen that
    # changes what the user types. The cost is one jq on the states that do not
    # need it, which is a process on a command a human runs once a morning.
    reboot_rec="$(jq -r '.reboot_recommended // false' "$STATUS")" \
      || die "no pude leer si esta actualizacion pide reinicio; no imprimo un informe a medias"

    # The heading is where a clean run and a run with findings visibly part
    # ways. Without this, a `ready` with three warnings and a `ready` with none
    # open with the identical line, and whether the user reads on is left to
    # chance.
    if [ "$nwarn" -gt 0 ]; then
      echo "estado: $state   comprobado: $when   AVISOS: $nwarn"
    else
      echo "estado: $state   comprobado: $when"
    fi

    rc=0
    case "$state" in
      current)
        echo "todo al dia"
        # `unmanaged` is not a ready-only field. claude-code moves on npm's
        # clock, so the morning after an update is applied -- the state this
        # report spends most of its life in -- is exactly when the engine has a
        # new claude-code to mention and nothing else to say. Printing it only
        # under `ready` meant "todo al dia" while something was in fact not.
        print_unmanaged
        ;;
      build_failed)
        echo "la actualizacion preparada NO compila"
        echo "  log: $(jq -r '.build.log // "sin log"' "$STATUS")"
        ;;
      check_failed)
        echo "la comprobacion fallo: $(jq -r '.error // "sin detalle"' "$STATUS")"
        ;;
      ready)
        echo "hay una actualizacion preparada en la rama $(jq -r '.branch // "auto/update"' "$STATUS")"
        # `changes[]` carries every input and every hand-packaged app the run
        # looked at, moved or not, so the "did not move" rows are filtered out
        # here rather than left out there: the engine reporting that it checked
        # brave-origin and found nothing is information, printing
        # "brave-origin 1.93.134 -> 1.93.134" is noise. An entry with an empty
        # side is a package that appeared or went away, and saying so beats a
        # row with a blank in it.
        jq -r '.changes[]? | select(type == "object") | select(.from != .to)
               | "  " + (.name // "sin nombre")
                 + " " + (if (.from // "") == "" then "(nuevo)" else .from end)
                 + " -> " + (if (.to // "") == "" then "(fuera)" else .to end)' "$STATUS"
        # One line for the closure, because the per-package detail is what
        # `upd diff` is for. The `// []` fallbacks are not producer paths --
        # the engine always writes all four keys -- but a truncated or
        # hand-edited file must not make jq error out and hand `upd show` an
        # exit code its own header does not document.
        jq -r '.closure_diff? | select(type == "object")
               | "  " + ((.changed // [] | length) | tostring) + " paquetes cambian, "
                 + ((.added // [] | length) | tostring) + " entran, "
                 + ((.removed // [] | length) | tostring) + " salen ("
                 + ((.size_delta_mb // 0) | tostring) + " MB)"' "$STATUS"
        # The one finding that changes what the user must type. `nh os switch`
        # activates in place, and a kernel or NVIDIA module that moved leaves
        # the loaded module out of step with the new userspace until a reboot.
        #
        # This wording has now been wrong in both directions, which is why it
        # says what it says. It pointed at `upd apply --boot` before that flag
        # existed, and `apply` accepted it, ignored it and activated hot -- the
        # advice sending the user into precisely what it was warning about. So
        # Task 4 removed the flag from the advice. Task 6 makes the flag real,
        # and leaving the advice as it was would be the same defect inverted:
        # telling someone to activate hot and reboot afterwards when a mode
        # that avoids the hot activation is one word away. The rule behind both
        # rounds: advice may name a flag exactly as long as the flag behaves,
        # and the two move in the same commit.
        if [ "$reboot_rec" = "true" ]; then
          echo
          echo "  ESTO PIDE REINICIO: $(jq -r '(.reboot_reason // []) | join(", ")' "$STATUS")"
          echo "  aplicalo con \`upd apply --boot\`: deja la generacion lista para el"
          echo "  proximo arranque en vez de activarla en caliente, que es lo que deja"
          echo "  el modulo ya cargado sin cuadrar con las librerias nuevas."
          echo "  Despues, reinicia cuando te venga bien."
        fi
        print_unmanaged
        ;;
      *)
        # A state this reader does not recognise is the exact shape of failure
        # this project keeps closing: a contract documented and then not
        # enforced. Without this arm the heading above prints, the case falls
        # through, and the user gets a report that says nothing and exits 0 --
        # indistinguishable from "nothing to do". Live causes: an upd older
        # than the engine that wrote the file (they are packaged together, but
        # a stale copy on $PATH or a hand-run script from a checkout is not
        # exotic), a future state added to the producer, or a corrupted file
        # that still happens to parse as an object carrying the right schema.
        echo "upd: estado desconocido: '$state'" >&2
        echo "upd: este lector solo entiende ready, current, build_failed y check_failed" >&2
        echo "upd: probablemente upd es mas viejo que el motor que escribio $STATUS; mira el fichero a mano" >&2
        rc=2
        ;;
    esac

    # Printed for every state, known or not, and after the state's own detail:
    # `current` and `build_failed` carry warnings too (a bump that failed is
    # precisely what can leave the closure unchanged), and an unknown state may
    # be explained by one.
    if [ "$nwarn" -gt 0 ]; then
      echo
      warn_lines
    fi

    if [ "$state" = "ready" ]; then
      echo
      if [ "$nwarn" -gt 0 ]; then
        echo "  hay $nwarn aviso(s): algo no se comprobo o no se pudo actualizar."
        echo "  la actualizacion se puede aplicar igual, pero leelos antes."
      fi
      # The footer has to agree with the reboot advice above it, or the same
      # screen gives two different instructions and the one at the bottom wins
      # by being last. Measured live the moment `--boot` landed: the advisory
      # said `upd apply --boot` and four lines below it this printed
      # `aplicar: upd apply`, which is the hot activation the advisory exists
      # to avoid.
      if [ "$reboot_rec" = "true" ]; then
        echo "  aplicar:  upd apply --boot   (por lo de arriba)"
      else
        echo "  aplicar:  upd apply"
      fi
      echo "  ver todo: upd diff"
    fi

    exit "$rc"
    ;;

  status)
    # The desktop panel's only entry point, and the reason it is a subcommand
    # rather than the plugin reading status.json for itself: two of the
    # conditions that stop an apply are not in that file and cannot be -- the
    # state of the user's working tree, and the branch it has checked out. Both
    # change long after the nightly run wrote its status, and today they surface
    # only as an exit 1 from `apply`. That is fine for a command and useless for
    # a button, which would be drawn enabled and already doomed.
    #
    # The contract, and the reason for the exit codes below: 0 whenever there is
    # an object to emit, blockers or not, and 1 only when there is none. A
    # consumer has nothing else to tell "nothing to apply" from "no answer", and
    # a half-built object -- blockers filled in, the engine's own fields missing
    # -- would be read as the first.
    if [ "$#" -ne 2 ] || [ "$2" != "--json" ]; then
      # Naming what arrived, and only when something did: `upd status` on its
      # own is a typo and does not need to be told what it typed.
      if [ "$#" -gt 1 ]; then
        die "uso: upd status --json; hoy no hay otro formato y he recibido: ${*:2}"
      fi
      die "uso: upd status --json; hoy no hay otro formato"
    fi
    [ -f "$STATUS" ] || die "no hay ninguna comprobacion todavia"
    require_readable_status

    # Everything that could stop an apply right now, from lib/blockers.sh. The
    # defaults for the two system paths live here rather than there because
    # they are this machine's layout, not a property of the question being
    # asked; the variables exist so the comparison is testable without a second
    # generation on disk, and nothing but the tests sets them.
    # The `|| die` is the seam between that function's contract and this one's.
    # It promises 0 on every path it can foresee, and this covers the one it
    # cannot: a `jq` that fails at the bottom of it, which is the only failure
    # whose status still reaches here.
    #
    # Not "any failure inside it", which is what this comment claimed for one
    # round: errexit does not act inside a command substitution that is part of
    # an assignment, so a command failing halfway through `blockers_live` never
    # aborted it in the first place -- measured, and now stated at the top of
    # that file, which is why every failure it can foresee has a branch there
    # instead of being left to `set -e`.
    #
    # What this buys is the exit code. Without it a non-zero from that function
    # would kill the subcommand carrying its own status -- 3, 5, 127 -- and this
    # file's header assigns meanings to 1 and 2 that such a code does not have.
    # With it, a non-zero exit always means "no answer", never "an answer with
    # something missing".
    blockers="$(blockers_live "$REPO" "$BRANCH" "$STATE_DIR/lock" \
      "${_UPD_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}" \
      "${_UPD_CURRENT_SYSTEM:-/run/current-system}")" \
      || die "no pude calcular los bloqueos en vivo; no emito un objeto sin ellos"

    # The file exactly as the engine wrote it, with `blockers` beside it, and
    # deliberately not the filtered view `show` builds: there the `from == to`
    # rows are dropped because a human does not need them, here the consumer
    # counts and groups on its own. Two differently-filtered readings of one
    # file is how the two come to disagree about what the engine found.
    jq --argjson b "$blockers" '. + {blockers: $b}' "$STATUS"
    ;;

  diff)
    [ -f "$STATE_DIR/diff.txt" ] || { echo "no hay diff guardado"; exit 0; }
    # The engine writes diff.txt only on the `ready` path. After a build_failed
    # or a check_failed run the file survives untouched, describing the closure
    # comparison of some earlier day while status.json has long moved on --
    # printed bare, a days-old diff is indistinguishable from today's. That is
    # the same "an incomplete run looks exactly like a passed one" shape the
    # rest of this file exists to remove, so every diff is stamped with the
    # state and timestamp it actually belongs to, and anything other than
    # `ready` says out loud that the diff is older than the last check.
    if [ -f "$STATUS" ] && jq -e 'type == "object"' "$STATUS" >/dev/null 2>&1; then
      d_state="$(jq -r '.state // "ausente"' "$STATUS")"
      d_when="$(jq -r '.checked_at // "fecha desconocida"' "$STATUS")"
      if [ "$d_state" = "ready" ]; then
        echo "# diff de la actualizacion preparada (comprobado: $d_when)"
      else
        echo "# ATENCION: este diff es de una comprobacion ANTERIOR."
        echo "# la ultima (estado: $d_state, comprobado: $d_when) no dejo ningun diff nuevo."
      fi
    else
      echo "# ATENCION: sin un status.json legible no se de cuando es este diff."
    fi
    echo
    cat "$STATE_DIR/diff.txt"
    ;;

  apply)
    # `apply` takes no arguments today, and accepting one silently is how an
    # option that does nothing comes to look like an option that worked.
    # Measured before this guard: `upd apply --boot` fast-forwarded $REPO and
    # ran `nh os switch` with the flag ignored, so someone following advice
    # written for the split that Task 6 has not landed yet would get the hot
    # activation they were told to avoid, and nothing anywhere would say so.
    #
    # Widening it to take a flag must not widen it to take anything: one
    # argument, from a closed list. `--ff` is not `--ff-only`, and `--boot
    # --ff-only` is neither of the two things they mean.
    # Each argument is quoted in the refusals below, and the count is named.
    # `${*:2}` renders an empty argument as nothing at all, so `upd apply --boot
    # ""` used to be refused with "he recibido: --boot" -- telling the user they
    # were rejected for something that on its own is legal.
    if [ "$#" -gt 2 ]; then
      die "uso: upd apply [--boot|--ff-only]: un modo como mucho, y he recibido $(($# - 1)): $(printf "'%s' " "${@:2}")"
    fi
    # `$#` decides whether a mode was given, and `$2` decides which one. Not
    # `${2:-}` alone with an empty branch: that reads "no argument" and "an
    # empty argument" as the same thing, so `upd apply "$FLAG"` with an unset
    # FLAG activated hot in silence -- measured, it went straight past the guard
    # into `switch`. An empty string is not a mode; it is a variable somebody
    # forgot to set, and this arm exists to refuse exactly that class of thing.
    mode="switch"
    if [ "$#" -eq 2 ]; then
      case "$2" in
        --boot)    mode="boot" ;;
        --ff-only) mode="ff-only" ;;
        *)         die "uso: upd apply [--boot|--ff-only]; no entiendo: '$2'" ;;
      esac
    fi

    # Preflight the tools *before* touching $REPO. Discovering that `nh` is
    # missing after the fast-forward leaves the repository moved and the system
    # not switched, which is the one half-applied state worth avoiding.
    #
    # Except under --ff-only, where that "half-applied state" is the entire
    # point: it moves the repository and stops. Demanding a tool it will never
    # run would be a requirement invented out of symmetry, and it would bite
    # exactly where this mode is meant to be used -- the bar plugin, whose half
    # of the work is the repository one and which has no reason to carry `nh`
    # on its PATH.
    command -v git >/dev/null 2>&1 || die "git no esta en el PATH; no aplico"
    if [ "$mode" != "ff-only" ]; then
      command -v nh >/dev/null 2>&1 || die "nh no esta en el PATH; no aplico"
    fi
    command -v flock >/dev/null 2>&1 || die "flock no esta en el PATH; no puedo descartar que el motor este corriendo ahora mismo"

    [ -f "$STATUS" ] || die "no hay nada preparado"

    # Take the engine's own lock, and take it before reading anything. status.json
    # is written at the *end* of a run, but the branch this subcommand is about to
    # apply is force-moved near the *start* of one (`checkout -B auto/update
    # FETCH_HEAD`). So during a run there is a real window where yesterday's
    # `ready` sits on disk next to a branch that has already moved on to whatever
    # main happens to be, with $WT/result still pinning yesterday's closure.
    # Sharing the engine's lock closes that window instead of narrowing it.
    # Non-blocking on purpose: a nightly build can take many minutes and hanging
    # a terminal command on it teaches nothing.
    if ! exec 9>"$STATE_DIR/lock"; then
      die "no puedo abrir $STATE_DIR/lock; sin el no puedo descartar una comprobacion en marcha"
    fi
    if ! flock -n 9; then
      die "hay una comprobacion en marcha ahora mismo; espera a que termine y vuelve a mirar \`upd\`"
    fi

    # Re-read only now that the lock is held: whatever was on disk a moment ago
    # may have been mid-rewrite.
    require_readable_status
    # The one assignment in this arm that used to have no guard, while the six
    # below it do. It is at the top level, where errexit *does* act -- unlike
    # inside the command substitutions lib/blockers.sh is called from -- so a
    # failing jq here killed apply with jq's own status and jq's own message.
    # Measured with a jq that fails only on `.state`: exit 5, and the only line
    # printed was jq's.
    #
    # Not `|| state=""`, which is what the six below do: that would fall into
    # the branch under it and say "no hay ninguna actualizacion lista (estado:
    # )", which names the wrong problem. And not left alone either -- the
    # tempting argument is that require_readable_status just ran two jq calls
    # on this same file with the lock held, so a third cannot fail. That covers
    # a broken or missing jq (it dies there, with a sentence) but not an
    # environmental failure of one invocation: ENOMEM or an ulimit hits the
    # third call as easily as the first. And `--ff-only` now has a machine
    # consumer, so an opaque exit code is the same defect this file already
    # closed once in `status --json`.
    state="$(jq -r '.state // "ausente"' "$STATUS")" \
      || die "no pude leer el estado de $STATUS aunque el fichero es legible; no aplico a ciegas"
    if [ "$state" != "ready" ]; then
      die "no hay ninguna actualizacion lista (estado: $state); mira \`upd\`"
    fi

    # --- do not take the branch's word for it -------------------------------
    # `state == ready` and "auto/update names the commit that was built" are two
    # separate facts and they can disagree. Measured: a check_failed raised at or
    # after `nix flake update` has already force-moved auto/update to FETCH_HEAD,
    # so the branch can point at a tree that was never built while $WT/result
    # still points at the previous run's closure. Gating on `ready` covers that
    # case only because such a run also rewrites status.json -- which it does at
    # the end, hence the lock above. Beyond the lock, three things are checked
    # here, all cheap and all about the clone actually being the one the last
    # completed run left behind:
    #
    #   origin is $REPO         never fetch into the user's repository from a
    #                           directory that is not this engine's own clone of
    #                           it.
    #   auto/update resolves    to a real commit.
    #   HEAD == auto/update
    #   and the tree is clean   the shape a finished run leaves: it checks out
    #                           auto/update, edits, builds, then commits. A dirty
    #                           tree or a detached/other HEAD means the clone was
    #                           interrupted or touched by hand, and the source
    #                           that produced $WT/result is no longer on disk in
    #                           a form anyone can point at.
    #
    # What is NOT checkable: nothing records the source revision *inside* the
    # built closure, so the link between "this commit" and "that closure" stays
    # an inference from the facts above rather than a proof. Stating that is the
    # point -- it is also why the residual risk is bounded: `nh os switch`
    # rebuilds from $REPO, so a mismatch costs a foreground rebuild, never an
    # activation of something unbuilt.
    [ -d "$WT/.git" ] || die "no hay ningun clon preparado en $WT"
    wt_origin="$(git -C "$WT" remote get-url origin 2>/dev/null)" || wt_origin=""
    if [ "$(readlink -f "$wt_origin" 2>/dev/null || printf '%s' "$wt_origin")" \
       != "$(readlink -f "$REPO" 2>/dev/null || printf '%s' "$REPO")" ]; then
      die "el clon en $WT no es de $REPO (origin=${wt_origin:-ninguno}); no traigo nada de ahi"
    fi
    prepared="$(git -C "$WT" rev-parse --verify --quiet 'auto/update^{commit}')" \
      || die "el clon en $WT no tiene la rama auto/update; el motor no llego a preparar nada"
    wt_head="$(git -C "$WT" rev-parse --verify --quiet 'HEAD^{commit}')" || wt_head=""
    if [ "$wt_head" != "$prepared" ]; then
      die "en $WT el HEAD ($wt_head) no es auto/update ($prepared); el clon quedo a medias, no me fio de lo que se construyo"
    fi
    if [ -n "$(git -C "$WT" status --porcelain --untracked-files=normal --ignore-submodules=none)" ]; then
      die "el clon en $WT tiene cambios sin commitear; lo construido no coincide con el commit preparado"
    fi

    # A missing closure is a warning, not a refusal: the GC may have collected it
    # (the root is the $WT/result symlink) and `nh os switch` will simply build
    # it again. Saying so beats letting the user wonder why a "prepared" update
    # suddenly compiles for twenty minutes.
    closure="$(readlink -f "$WT/result" 2>/dev/null)" || closure=""
    if [ -z "$closure" ] || [ ! -e "$closure" ]; then
      echo "upd: aviso: $WT/result ya no apunta a ningun closure; nh tendra que construirlo otra vez" >&2
      closure=""
    fi

    # --- is $REPO a repository at all ---------------------------------------
    # This has to come before the two guards below, because both of them fail
    # *silently* on a $REPO git cannot open, and both fail into a confident
    # wrong answer rather than into an error:
    #
    #   `git status` prints its complaint on stderr and leaves stdout empty, so
    #   the dirty-tree guard reads no porcelain lines and concludes the tree is
    #   clean -- about a repository that was never opened.
    #
    #   `symbolic-ref` failing there is indistinguishable from a real detached
    #   HEAD, so the guard under it blamed one. Measured with $REPO/.git
    #   removed: `esta con el HEAD desprendido; ponlo en una rama antes de
    #   aplicar`, which is advice for a repository that is not there, and the
    #   only sentence apply gave for that situation.
    #
    # lib/blockers.sh opens with this same check, for this same pair of silent
    # failures and in the same order; this is that guard on the terminal side,
    # which is what makes the two surfaces say compatible things about an
    # unreadable repository instead of one naming it and the other blaming the
    # HEAD.
    #
    # The answer is *compared*, not merely awaited, and that is the whole point
    # of the line. `--is-inside-work-tree` reports by printing, not by failing:
    # in a bare repository it prints `false` and **exits 0**. A first version of
    # this guard threw stdout away and only looked at the exit status, so a bare
    # $REPO sailed straight past it into the dirty-tree check -- where
    # `git status` exits 128 with `fatal: this operation must be run in a work
    # tree` on stderr and nothing on stdout, and the guard announces a clean
    # tree. The exact false conclusion this block exists to prevent, reached
    # through the block itself. Measured on git 2.55.0, and the mutation
    # `--is-inside-work-tree` -> `--git-dir` survived the whole suite while it
    # was written that way.
    if [ "$(git -C "$REPO" rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
      die "no puedo leer $REPO como repositorio git con arbol de trabajo; sin eso no se si el arbol esta limpio ni en que rama esta, y no aplico a ciegas"
    fi

    # --- never discard uncommitted work -------------------------------------
    # Before any fetch, and before anything at all is written into $REPO.
    # --porcelain covers untracked files too, which is the common case: a
    # scratch file the user has not decided about yet is still their work.
    #
    # The two flags are not decoration. `status.showUntrackedFiles=no` in the
    # repository's own config silences the untracked half of this check
    # completely, and `submodule.<name>.ignore=all` silences the submodule half
    # -- both reproduced, with apply proceeding past a stray NOTAS.txt. Nothing
    # was lost in that reproduction (git refuses to clobber untracked files on
    # merge, and a fast-forward does not touch submodule worktrees), but the one
    # safety rule this subcommand exists to enforce must not be switchable from
    # a config file this engine does not control. Asking explicitly for what the
    # rule means takes the config out of the loop.
    dirty_flags=(--porcelain --untracked-files=normal --ignore-submodules=none)
    # `git status` can exit 0 with empty stdout after failing to read a
    # subdirectory, while printing the warning on stderr. Treat that as an
    # unreadable repository, not as a clean tree: the apply guard must never
    # guess that it is safe to fast-forward over a filesystem it could not
    # inspect.
    tree_err_file="$(mktemp 2>/dev/null)" \
      || die "no pude crear un fichero temporal para recoger los avisos de git; no aplico a ciegas"
    tree_out=""
    tree_rc=0
    tree_out="$(git -C "$REPO" status "${dirty_flags[@]}" 2>"$tree_err_file")" \
      || tree_rc=$?
    tree_err="$(< "$tree_err_file")"
    rm -f "$tree_err_file"
    tree_err="${tree_err//$'\n'/ }"
    tree_err="${tree_err:0:200}"
    if [ "$tree_rc" -ne 0 ] || [ -n "$tree_err" ]; then
      die "no puedo leer entero el arbol de $REPO (${tree_err:-fallo sin mensaje, codigo $tree_rc}); no se si hay cambios sin commitear, asi que no aplico a ciegas"
    fi
    if [ -n "$tree_out" ]; then
      echo "el arbol de trabajo tiene cambios sin commitear; no aplico" >&2
      git -C "$REPO" status --short --untracked-files=normal --ignore-submodules=none >&2
      exit 1
    fi

    cur_branch="$(git -C "$REPO" symbolic-ref --quiet --short HEAD)" \
      || die "$REPO esta con el HEAD desprendido; ponlo en una rama antes de aplicar"

    # Fast-forwarding *whatever* happens to be checked out is not the same thing
    # as applying the prepared update, and the difference is not recoverable by
    # the user on their own. Reproduced: with $REPO on a branch `experimento`
    # that is an ancestor of main and carries no commits of its own, apply moved
    # `experimento` onto the prepared commit, left `main` where it was, and
    # switched -- so the running system is a commit that is not on main. The
    # engine keeps preparing from $BRANCH, so from then on every `upd apply`
    # refuses with "experimento no es antecesor del commit preparado ... lanza
    # `upd check`", advice that cannot fix the situation it describes. Refusing
    # up front costs one `git switch`; not refusing costs an afternoon.
    if [ "$cur_branch" != "$BRANCH" ]; then
      die "$REPO esta en la rama '$cur_branch' y el motor prepara desde '$BRANCH'; haz \`git -C $REPO switch $BRANCH\` y vuelve a lanzar \`upd apply\`"
    fi

    git -C "$REPO" fetch --quiet "$WT" auto/update \
      || die "no pude traer auto/update desde $WT"
    target="$(git -C "$REPO" rev-parse --verify --quiet 'FETCH_HEAD^{commit}')" \
      || die "el fetch no dejo ningun commit utilizable en FETCH_HEAD"
    if [ "$target" != "$prepared" ]; then
      die "lo que traje ($target) no es el commit preparado ($prepared); algo cambio bajo los pies"
    fi
    # `merge --ff-only` would refuse on its own, but with a message about merge
    # strategies rather than about what actually happened: the branch moved on
    # after the update was prepared.
    if ! git -C "$REPO" merge-base --is-ancestor HEAD "$target"; then
      die "$cur_branch no es antecesor del commit preparado; $REPO avanzo despues de prepararlo, lanza \`upd check\` y vuelve a mirar"
    fi

    # Say out loud what is about to happen, naming the commit and the closure.
    echo "aplicando sobre $cur_branch en $REPO:"
    git -C "$REPO" --no-pager log --oneline -1 "$target" | sed 's/^/  /'
    echo "  closure preparado: ${closure:-desconocido, se reconstruira}"

    git -C "$REPO" merge --ff-only "$target"

    # --ff-only stops here, and the split exists for the bar plugin: the
    # repository half has to run as daf3r, because a merge done as root leaves
    # root-owned objects in .git and breaks the next commit made by hand, while
    # the activation half is a root systemd unit started separately. Splitting
    # them at this line is what lets each run as whoever it has to be.
    #
    # It says what it did and what it did not do. A command that quietly
    # performs half of what its name suggests is the shape of failure the rest
    # of this file exists to remove.
    if [ "$mode" = "ff-only" ]; then
      echo "fast-forward hecho; no activo nada (--ff-only)"
      exit 0
    fi

    # `switch` or `boot`, and the difference is the whole reason `--boot`
    # exists: `switch` activates in place, `boot` writes the profile and leaves
    # /run/current-system alone. The reboot advice in `show` points here.
    nh os "$mode" "$REPO"
    if [ "$mode" = "switch" ]; then
      clear_prepared_state
    fi
    ;;

  finalize)
    if [ "$#" -ne 2 ]; then
      die "uso: upd finalize switch|boot"
    fi
    case "$2" in
      switch)
        # The systemd activation unit calls this after a successful `nh os
        # switch`. It owns the lock while it waits so a concurrent nightly check
        # cannot replace the prepared clone between the activation and cleanup.
        if ! exec 9>"$STATE_DIR/lock"; then
          die "no puedo abrir $STATE_DIR/lock; no limpio el estado preparado"
        fi
        flock 9 || die "no pude tomar $STATE_DIR/lock; no limpio el estado preparado"
        finalize_switch
        ;;
      boot)
        # `nh os boot` only selects the next generation. The running system is
        # still the old one, so retaining `ready` is intentional: status --json
        # exposes the pending-reboot blocker and the panel must not claim that
        # the running system is already current.
        echo "se conserva el estado preparado: --boot aun espera un reinicio"
        ;;
      *)
        die "uso: upd finalize switch|boot; no entiendo: '$2'"
        ;;
    esac
    ;;

  check)
    # Run the engine directly rather than through `systemctl start --wait
    # nixos-upd.service`: the unit runs as daf3r and StateDirectory leaves
    # /var/lib/nixos-upd owned by daf3r, so nothing here needs root or a polkit
    # prompt. Going through systemd would also bury the engine's output in the
    # journal, where a user who just asked for a check will not look.
    #
    # $NIXOS_UPD first so this is testable without installing anything; then the
    # packaged binary; then the sibling script, which is how it runs from a
    # checkout of this repository.
    if [ -n "${NIXOS_UPD:-}" ]; then
      exec "$NIXOS_UPD"
    elif command -v nixos-upd >/dev/null 2>&1; then
      exec nixos-upd
    elif [ -f "$SELF_DIR/nixos-upd.sh" ]; then
      exec bash "$SELF_DIR/nixos-upd.sh"
    else
      die "no encuentro el motor (ni nixos-upd en el PATH ni $SELF_DIR/nixos-upd.sh)"
    fi
    ;;

  *)
    cat >&2 <<'EOF'
uso: upd [show|status|diff|apply|check]

  show    (por defecto) que dejo preparado la ultima comprobacion
  status  `upd status --json`: lo mismo en JSON y con los bloqueos de ahora
          mismo (arbol sucio, rama, motor en marcha, reinicio pendiente), que
          es lo que lee el widget de la barra
  diff    el diff de closures guardado
  apply   aplica lo preparado: fast-forward y `nh os switch`
          --boot     igual, pero para el proximo arranque (`nh os boot`), que
                     es lo que pide el aviso de reinicio
          --ff-only  solo el fast-forward, sin activar nada
  finalize switch|boot
          limpia el estado despues de una activacion exitosa; `boot` conserva
          lo preparado hasta que se reinicie
  check   lanza una comprobacion ahora, en primer plano
EOF
    exit 1
    ;;
esac
