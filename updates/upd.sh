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
# Applying goes through git -- fast-forward the checked-out branch, then switch
# -- so every automated change stays reviewable and revertible rather than
# appearing in the system out of nowhere.
#
# Exit codes:
#   0  the status was read and reported (including build_failed/check_failed:
#      those are outcomes, not reader errors), or the apply succeeded
#   1  this reader refuses to act: unreadable/unknown-schema status, a dirty
#      target tree, a clone it cannot vouch for, a missing tool
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
# message below can name both sides of the mismatch.
SCHEMA=1

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
    die "status.json declara schema $schema y este lector solo entiende $SCHEMA; actualiza el sistema para tener un upd al dia"
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
        jq -r '.local_pkgs[]?' "$STATUS" | sed 's/^/  /'
        jq -r '.unmanaged[]? | "  fuera de nix: " + .name + " " + .from + " -> " + .to + "\n    " + .command' "$STATUS"
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
        # that still happens to parse as an object with schema 1.
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
uso: upd [show|diff|apply|check]

  show    (por defecto) que dejo preparado la ultima comprobacion
  diff    el diff de closures guardado
  apply   aplica lo preparado: fast-forward y `nh os switch`
  check   lanza una comprobacion ahora, en primer plano
EOF
    exit 1
    ;;
esac
