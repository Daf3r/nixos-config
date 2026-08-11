# shellcheck shell=bash
#
# The reasons an apply would refuse *right now*, as data.
#
# This exists because status.json cannot carry them and never will: two of the
# conditions that stop an apply are facts about the machine at the moment
# somebody asks -- the state of the working tree and the branch it has checked
# out -- and they change long after the nightly run wrote its file. `upd apply`
# discovers them by refusing; a desktop panel needs them before it draws a
# button, or it draws one that was doomed already.
#
# It lives here rather than inside upd.sh's `status` arm, where it was written,
# for two reasons. It is the one part of that arm that can be named in a
# sentence and asked a question -- "what would stop an apply?" -- while the rest
# of the arm is about the shape of a subcommand: which arguments it takes, which
# file it reads, what it prints. And Task 6 rewrites `apply` in the same file;
# keeping the two apart means that rewrite cannot disturb this by accident, and
# that both can be worked on at once.
#
# The function takes everything it needs and reads no globals, which is the
# whole point of the move: the caller resolves `$REPO`, `$BRANCH`, where the
# lock lives and which two system paths to compare, and this decides. It writes
# a JSON array to stdout and nothing to stderr, and it never fails: an error it
# cannot resolve is itself a blocker, because "I could not check" and "there is
# nothing to report" are different answers and the panel must not confuse them.
#
# The blocker vocabulary, and the contract for whoever renders it:
#
#   dirty_tree        $REPO has uncommitted or untracked changes
#   wrong_branch      $REPO is on another branch, or on a detached HEAD
#   engine_running    the engine holds the lock right now
#   pending_reboot    the system profile and the running system are different
#                     generations, in either direction
#   lock_uncheckable  the lock could not be opened at all, or flock is missing
#   repo_uncheckable  $REPO could not be opened as a git repository, or git is
#                     missing
#
# A consumer must treat an unknown `code` as a blocker and show its `detail`
# rather than skipping it: this list grew from four to six while the subcommand
# was being written, and it can grow again. The `detail` is the whole message
# for a human -- it is what the panel puts next to the disabled button -- so
# every one of them says what is wrong *and* what would resolve it.

# $1 repo, $2 branch the engine prepares from, $3 lock file, $4 system profile,
# $5 running system. stdout: a JSON array of {code, detail}, `[]` when there is
# nothing in the way. Always returns 0.
blockers_live() {
  local repo=$1 branch=$2 lock=$3 profile_path=$4 current_path=$5
  local cur_branch profile current
  # Flat pairs -- code, detail, code, detail -- rather than a JSON string grown
  # one jq call at a time, which is what this did in upd.sh. One jq at the end
  # instead of one per blocker, and no string splicing anywhere: a detail
  # carries a branch name, which is user input, and a single quote in it would
  # otherwise hand the consumer a document it cannot parse.
  local -a found=()

  # --- the two live git facts, and the admission when there are none ---------
  # Both git calls fail silently in the same way: `git status` in a directory
  # that is not a repository prints nothing on stdout, so a reader taking that
  # at face value reports a clean tree, and `symbolic-ref` failing there is
  # indistinguishable from a real detached HEAD. That pair is two confident
  # statements about a repository that was never opened, and the second one
  # sends the reader off to `git switch` something that does not exist. So the
  # opening is checked first and, when it fails, that is what gets reported.
  if ! command -v git >/dev/null 2>&1; then
    found+=(repo_uncheckable "git no esta en el PATH: no puedo mirar ni el arbol ni la rama de $repo, y \`upd apply\` se negara por lo mismo")
  elif ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    found+=(repo_uncheckable "no puedo leer $repo como repositorio git; sin eso no se si el arbol esta limpio ni en que rama esta")
  else
    # The same two flags `apply` spells out, for the same reason:
    # status.showUntrackedFiles=no and submodule.<name>.ignore=all each silence
    # half of this check from a config file this engine does not own.
    if [ -n "$(git -C "$repo" status --porcelain --untracked-files=normal --ignore-submodules=none)" ]; then
      found+=(dirty_tree "el arbol de trabajo en $repo tiene cambios sin commitear; no se aplica encima de ellos")
    fi

    cur_branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD)" || cur_branch=""
    if [ -z "$cur_branch" ]; then
      found+=(wrong_branch "$repo esta con el HEAD desprendido; ponlo en una rama antes de aplicar")
    elif [ "$cur_branch" != "$branch" ]; then
      found+=(wrong_branch "$repo esta en la rama '$cur_branch' y el motor prepara desde '$branch'; haz \`git -C $repo switch $branch\`")
    fi
  fi

  # --- the engine's own lock -------------------------------------------------
  # Three outcomes, not two, and the version this was written from had two: a
  # single `! (exec 9>"$lock" && flock -n 9)` cannot tell "the engine holds it"
  # from "I could not open it at all" and answers the first for both. Measured
  # with a lock directory that does not exist, and again with one that is
  # read-only: `engine_running`, both times. That state is permanent -- a lock
  # file left owned by root after a change of User= in the unit is the live way
  # to reach it -- so the panel would keep a dead button and a message naming a
  # check that is not running, with nothing ever clearing it. `apply` already
  # separates the two cases; so does this.
  #
  # Both probes below open the lock for writing, which creates it and truncates
  # it, and this is the one code path a desktop panel is going to poll on a
  # timer -- so the truncation happens over and over. That is safe today and
  # stays safe only under one invariant: **the lock file carries no content**.
  # It is a rendezvous inode for flock(2) and nothing else. The engine
  # (nixos-upd.sh) and `apply` open it exactly the same way, so a run that
  # started writing a PID or a timestamp into it would already be racing them;
  # what this adds is a reader that would wipe it every few seconds. If the lock
  # ever needs to carry something, it needs a second file, not a read-only probe
  # that opens this one for writing.
  if ! command -v flock >/dev/null 2>&1; then
    found+=(lock_uncheckable "flock no esta en el PATH: no puedo descartar una comprobacion en marcha, y \`upd apply\` se negara por lo mismo")
  elif ! (exec 9>"$lock") 2>/dev/null; then
    found+=(lock_uncheckable "no puedo abrir $lock: no se si hay una comprobacion en marcha, y \`upd apply\` se negara por lo mismo")
  elif ! (exec 9>"$lock" && flock -n 9) 2>/dev/null; then
    found+=(engine_running "hay una comprobacion en marcha ahora mismo; espera a que termine")
  fi

  # --- the profile and the running system have parted ways -------------------
  # The case this is for: an apply that only writes the profile leaves
  # /run/current-system where it was, so the next nightly check measures against
  # the *old* system, finds the update missing from it and reports `ready` all
  # over again -- and a panel offering that update a second time is describing
  # work that is already done.
  #
  # Both paths are arguments, and the caller's defaults are named after what
  # they point at, which is not a detail. /nix/var/nix/profiles/system is the
  # *profile*: the generation that will be activated at boot. It is emphatically
  # not "the booted system" -- NixOS spells that /run/booted-system -- and a
  # caller who passed that instead would compare it against /run/current-system,
  # which differ after any plain switch onto a new kernel. That is a permanent
  # blocker for a condition `reboot_recommended` already reports from the
  # closure diff.
  profile="$(readlink -f "$profile_path" 2>/dev/null)" || profile=""
  current="$(readlink -f "$current_path" 2>/dev/null)" || current=""
  if [ -n "$profile" ] && [ -n "$current" ] && [ "$profile" != "$current" ]; then
    # Deliberately not "there is a generation staged for the next boot": that is
    # one of the two ways to get here and the wording would be false in the
    # other. `nixos-rebuild test` and `nh os test` activate without touching the
    # profile, so they leave it on the *older* generation and /run/current-system
    # on the newer -- the same inequality pointing the other way. Blocking is
    # right for both; naming only one of them is not.
    found+=(pending_reboot "el perfil del sistema y el sistema en marcha no son la misma generacion (un apply sin reiniciar, o un \`test\` sin fijar); resuelvelo antes de apilar otra actualizacion encima")
  fi

  # The empty case is its own branch rather than a jq call on an empty array:
  # `"${found[@]}"` on an empty array is a bash-4.4-or-later courtesy under
  # `set -u`, and the callers here run with -u on. Printing the literal also
  # keeps the common case -- nothing in the way -- from spawning a process.
  if [ "${#found[@]}" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi

  jq -n --args '[ range(0; ($ARGS.positional | length); 2)
                  | { code: $ARGS.positional[.], detail: $ARGS.positional[. + 1] } ]' \
    "${found[@]}"
}
