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
        # It does NOT say "aplicar con `upd apply --boot`", which is what the
        # plan wrote here: that flag does not exist yet, and measured today
        # `upd apply --boot` fast-forwards and runs `nh os switch` all the same
        # -- the hot activation the advice is trying to avoid. Pointing a user
        # at a flag that silently does the opposite is worse than no advice.
        # When Task 6 splits apply into switch and boot, this is where the
        # wording changes.
        if [ "$(jq -r '.reboot_recommended // false' "$STATUS")" = "true" ]; then
          echo
          echo "  ESTO PIDE REINICIO: $(jq -r '(.reboot_reason // []) | join(", ")' "$STATUS")"
          echo "  \`upd apply\` activa en caliente y el modulo ya cargado deja de cuadrar"
          echo "  con las librerias nuevas: reinicia en cuanto lo apliques."
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
      echo "  aplicar:  upd apply"
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

    blockers='[]'
    # jq rather than splicing the strings together: a detail carries a branch
    # name, which is user input, and one quote in it would hand the consumer a
    # document it cannot parse.
    add_blocker() { # $1 code, $2 detail
      blockers="$(printf '%s' "$blockers" \
        | jq -c --arg c "$1" --arg d "$2" '. + [{code: $c, detail: $d}]')"
    }

    # --- the two live git facts, and the admission when there are none -------
    # Both git calls fail silently in the same way: `git status` in a directory
    # that is not a repository prints nothing on stdout, so a reader taking that
    # at face value reports a clean tree, and `symbolic-ref` failing there is
    # indistinguishable from a real detached HEAD. That pair is two confident
    # statements about a repository that was never opened, and the second one
    # sends the reader off to `git switch` something that does not exist. So the
    # opening is checked first and, when it fails, that is what gets reported.
    if ! command -v git >/dev/null 2>&1; then
      add_blocker repo_uncheckable "git no esta en el PATH: no puedo mirar ni el arbol ni la rama de $REPO, y \`upd apply\` se negara por lo mismo"
    elif ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      add_blocker repo_uncheckable "no puedo leer $REPO como repositorio git; sin eso no se si el arbol esta limpio ni en que rama esta"
    else
      # The same two flags `apply` spells out, for the same reason:
      # status.showUntrackedFiles=no and submodule.<name>.ignore=all each
      # silence half of this check from a config file this engine does not own.
      if [ -n "$(git -C "$REPO" status --porcelain --untracked-files=normal --ignore-submodules=none)" ]; then
        add_blocker dirty_tree "el arbol de trabajo en $REPO tiene cambios sin commitear; no se aplica encima de ellos"
      fi

      cur_branch="$(git -C "$REPO" symbolic-ref --quiet --short HEAD)" || cur_branch=""
      if [ -z "$cur_branch" ]; then
        add_blocker wrong_branch "$REPO esta con el HEAD desprendido; ponlo en una rama antes de aplicar"
      elif [ "$cur_branch" != "$BRANCH" ]; then
        add_blocker wrong_branch "$REPO esta en la rama '$cur_branch' y el motor prepara desde '$BRANCH'; haz \`git -C $REPO switch $BRANCH\`"
      fi
    fi

    # --- the engine's own lock ----------------------------------------------
    # Three outcomes, not two, and the plan's version of this arm had two: a
    # single `! (exec 9>"$STATE_DIR/lock" && flock -n 9)` cannot tell "the
    # engine holds it" from "I could not open it at all" and answers the first
    # for both. Measured on that version with a $STATE_DIR that does not exist,
    # and again with one that is read-only: `engine_running`, both times. That
    # state is permanent -- a lock file left owned by root after a change of
    # User= in the unit is the live way to reach it -- so the panel would keep a
    # dead button and a message naming a check that is not running, with nothing
    # ever clearing it. `apply` already separates the two cases; so does this.
    #
    # Both probes below open $STATE_DIR/lock for writing, which creates it and
    # truncates it, and this is the one subcommand a desktop panel is going to
    # poll on a timer -- so the truncation happens over and over. That is safe
    # today and stays safe only under one invariant: **the lock file carries no
    # content**. It is a rendezvous inode for flock(2) and nothing else. The
    # engine (nixos-upd.sh) and `apply` open it exactly the same way, so a run
    # that started writing a PID or a timestamp into it would already be racing
    # them; what this arm adds is a reader that would wipe it every few seconds.
    # If the lock ever needs to carry something, it needs a second file, not a
    # read-only probe that opens this one for writing.
    if ! command -v flock >/dev/null 2>&1; then
      add_blocker lock_uncheckable "flock no esta en el PATH: no puedo descartar una comprobacion en marcha, y \`upd apply\` se negara por lo mismo"
    elif ! (exec 9>"$STATE_DIR/lock") 2>/dev/null; then
      add_blocker lock_uncheckable "no puedo abrir $STATE_DIR/lock: no se si hay una comprobacion en marcha, y \`upd apply\` se negara por lo mismo"
    elif ! (exec 9>"$STATE_DIR/lock" && flock -n 9) 2>/dev/null; then
      add_blocker engine_running "hay una comprobacion en marcha ahora mismo; espera a que termine"
    fi

    # --- the profile and the running system have parted ways -----------------
    # The case this is for: an apply that only writes the profile leaves
    # /run/current-system where it was, so the next nightly check measures
    # against the *old* system, finds the update missing from it and reports
    # `ready` all over again -- and a panel offering that update a second time
    # is describing work that is already done.
    #
    # The two variables are named after what they point at, which is not a
    # detail. /nix/var/nix/profiles/system is the *profile*: the generation that
    # will be activated at boot. It is emphatically not "the booted system" --
    # NixOS spells that /run/booted-system -- and a reader who took the earlier
    # name at face value and "fixed" the default to match would compare
    # /run/booted-system against /run/current-system, which differ after any
    # plain switch onto a new kernel. That is a permanent blocker for a
    # condition `reboot_recommended` already reports from the closure diff.
    #
    # Read from the environment so this is testable without a second generation
    # on disk; nothing else sets either variable.
    profile="$(readlink -f "${_UPD_SYSTEM_PROFILE:-/nix/var/nix/profiles/system}" 2>/dev/null)" || profile=""
    current="$(readlink -f "${_UPD_CURRENT_SYSTEM:-/run/current-system}" 2>/dev/null)" || current=""
    if [ -n "$profile" ] && [ -n "$current" ] && [ "$profile" != "$current" ]; then
      # Deliberately not "there is a generation staged for the next boot":
      # that is one of the two ways to get here and the wording would be false
      # in the other. `nixos-rebuild test` and `nh os test` activate without
      # touching the profile, so they leave it on the *older* generation and
      # /run/current-system on the newer -- the same inequality pointing the
      # other way. Blocking is right for both; naming only one of them is not.
      add_blocker pending_reboot "el perfil del sistema y el sistema en marcha no son la misma generacion (un apply sin reiniciar, o un \`test\` sin fijar); resuelvelo antes de apilar otra actualizacion encima"
    fi

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
    if [ "$#" -gt 1 ]; then
      die "\`upd apply\` todavia no acepta argumentos y he recibido: ${*:2}. No aplico: hoy solo hay activacion en caliente, asi que si el aviso pide reinicio, aplica con \`upd apply\` a secas y reinicia despues"
    fi

    # Preflight the tools *before* touching $REPO. Discovering that `nh` is
    # missing after the fast-forward leaves the repository moved and the system
    # not switched, which is the one half-applied state worth avoiding.
    command -v git >/dev/null 2>&1 || die "git no esta en el PATH; no aplico"
    command -v nh  >/dev/null 2>&1 || die "nh no esta en el PATH; no aplico"
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
    state="$(jq -r '.state // "ausente"' "$STATUS")"
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
    if [ -n "$(git -C "$REPO" status "${dirty_flags[@]}")" ]; then
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
    nh os switch "$REPO"
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
  check   lanza una comprobacion ahora, en primer plano
EOF
    exit 1
    ;;
esac
