#!/usr/bin/env bats
#
# `upd` is the only place the engine's findings reach a human, so what is
# tested here is mostly "does it stay quiet when it must not". Two of these
# tests exist specifically because a version without them passed everything
# else: the unknown-state arm (a reader that prints a heading and exits 0 for a
# state it does not know) and the warnings block (a `ready` with findings
# rendering identically to a clean one).

UPD="${BATS_TEST_DIRNAME}/../upd.sh"

setup() {
  WORK="$(mktemp -d)"
  STATE="$WORK/state"
  mkdir -p "$STATE"
  # A stub `nh`, so the apply tests can prove activation was NOT reached --
  # and, on the happy path, that it was reached with the right argument.
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/nh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$NH_MARKER"
EOF
  chmod +x "$WORK/bin/nh"
  export NH_MARKER="$WORK/nh-called"
  : > "$NH_MARKER"
  PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

status_json() { # $1 the JSON body, written as-is
  printf '%s\n' "$1" > "$STATE/status.json"
}

ready_status() {
  status_json '{"build":{"ok":true,"log":"/l"},"branch":"auto/update",
    "local_pkgs":["brave-origin sin cambios","t3code-app sin cambios"],
    "warnings":'"${1:-[]}"',"unmanaged":[],
    "schema":1,"checked_at":"2026-08-09T03:00:11+02:00","state":"ready"}'
}

# A throwaway $REPO plus the clone the engine would have left beside it: on
# auto/update, clean, with a `result` symlink and one prepared commit.
make_rig() {
  REPO="$WORK/repo"
  mkdir -p "$REPO"
  git init -q -b main "$REPO"
  printf 'v1\n' > "$REPO/flake.lock"
  printf 'result\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
  git clone -q --no-hardlinks "$REPO" "$STATE/wt"
  git -C "$STATE/wt" checkout -q -B auto/update
  printf 'v2\n' > "$STATE/wt/flake.lock"
  git -C "$STATE/wt" add -A
  git -C "$STATE/wt" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -qm "auto: actualizacion preparada"
  ln -s /run/current-system "$STATE/wt/result"
  ready_status
}

upd() { REPO="${REPO:-$WORK/repo}" STATE_DIR="$STATE" bash "$UPD" "$@"; }

# --- show -------------------------------------------------------------------

@test "show says so when no check has run yet" {
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hay ninguna comprobacion todavia"* ]]
}

@test "show refuses a status.json it cannot parse" {
  printf 'no soy json{' > "$STATE/status.json"
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es un objeto JSON legible"* ]]
}

@test "show refuses a schema it does not understand" {
  status_json '{"schema":2,"checked_at":"x","state":"ready","warnings":[]}'
  run upd
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema 2"* ]]
}

@test "an unrecognised state is loud and exits non-zero" {
  # The regression this file exists for. Without the default arm the reader
  # prints the heading, falls through the case, and exits 0 -- which reads
  # exactly like "nothing to do".
  status_json '{"schema":1,"checked_at":"x","state":"rolled_back","warnings":[]}'
  run upd
  [ "$status" -eq 2 ]
  [[ "$output" == *"estado desconocido"* ]]
  [[ "$output" == *"rolled_back"* ]]
}

@test "a ready with warnings looks different from a clean one" {
  ready_status
  run upd
  [ "$status" -eq 0 ]
  clean="$output"
  [[ "$clean" != *"AVISO"* ]]

  ready_status '[{"code":"local_bump_failed","detail":"brave-origin se quedo atras"}]'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" != "$clean" ]]
  [[ "$output" == *"AVISOS: 1"* ]]
  [[ "$output" == *"AVISO [local_bump_failed] brave-origin se quedo atras"* ]]
}

@test "warnings are shown on current too, not only on ready" {
  # `current` and a silently failed bump co-occur precisely when the failed
  # bump is what left the closure unchanged.
  status_json '{"schema":1,"checked_at":"x","state":"current",
    "warnings":[{"code":"local_bump_failed","detail":"t3code-app se quedo atras"}]}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"todo al dia"* ]]
  [[ "$output" == *"t3code-app se quedo atras"* ]]
}

@test "warnings are shown on build_failed too" {
  status_json '{"schema":1,"checked_at":"x","state":"build_failed",
    "build":{"ok":false,"log":"/var/lib/nixos-upd/last.log"},
    "warnings":[{"code":"local_bump_failed","detail":"brave-origin se quedo atras"}]}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"NO compila"* ]]
  [[ "$output" == *"/var/lib/nixos-upd/last.log"* ]]
  [[ "$output" == *"brave-origin se quedo atras"* ]]
}

@test "a body without the warnings key does not take the reader down" {
  # nixos-upd.sh's fail() has one fallback body, for a jq failure, that omits
  # `warnings` entirely. Effectively unreachable, which is exactly why nothing
  # would notice if this reader assumed the key were there.
  status_json '{"schema":1,"checked_at":"x","state":"check_failed",
    "error":"no se pudo codificar el mensaje"}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no se pudo codificar el mensaje"* ]]
}

@test "a warnings field that is not a list is reported, not skipped" {
  status_json '{"schema":1,"checked_at":"x","state":"current","warnings":"boom"}'
  run upd
  [ "$status" -eq 0 ]
  [[ "$output" == *"no es una lista"* ]]
}

@test "diff prints the saved closure diff, and says so when there is none" {
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"no hay diff guardado"* ]]

  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  ready_status
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"1.85.121 -> 1.86.2"* ]]
  [[ "$output" == *"comprobado: 2026-08-09T03:00:11+02:00"* ]]
  [[ "$output" != *"ANTERIOR"* ]]
}

@test "diff marks itself stale when the last check left no new diff" {
  # diff.txt is written only on the ready path, so after a failed run it
  # survives describing an older comparison while status.json has moved on.
  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  status_json '{"schema":1,"checked_at":"2026-08-05T03:00:11+02:00",
    "state":"check_failed","error":"nix flake update failed","warnings":[]}'
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"comprobacion ANTERIOR"* ]]
  [[ "$output" == *"check_failed"* ]]
  [[ "$output" == *"2026-08-05T03:00:11+02:00"* ]]
  [[ "$output" == *"1.85.121 -> 1.86.2"* ]]
}

@test "diff says so when it cannot date itself at all" {
  printf 'brave-origin: 1.85.121 -> 1.86.2\n' > "$STATE/diff.txt"
  run upd diff
  [ "$status" -eq 0 ]
  [[ "$output" == *"no se de cuando es este diff"* ]]
}

@test "an unknown subcommand prints usage and fails" {
  run upd frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"uso: upd"* ]]
}

# --- apply ------------------------------------------------------------------

@test "apply refuses a dirty target tree, prints it, and fetches nothing" {
  make_rig
  touch "$REPO/SCRATCH-TEST"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"cambios sin commitear; no aplico"* ]]
  [[ "$output" == *"?? SCRATCH-TEST"* ]]
  # Nothing was activated, and nothing was even written into the repository:
  # the refusal comes before the fetch.
  [ ! -s "$NH_MARKER" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
  [ "$(git -C "$REPO" log --oneline | wc -l)" -eq 1 ]
}

@test "apply refuses a modified tracked file as well as an untracked one" {
  make_rig
  printf 'editado a mano\n' >> "$REPO/flake.lock"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"M flake.lock"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a dirty tree even when the repo config hides it" {
  # status.showUntrackedFiles=no silences the untracked half of the check
  # entirely; the safety rule must not be switchable from a config file this
  # engine does not control.
  make_rig
  git -C "$REPO" config status.showUntrackedFiles no
  touch "$REPO/NOTAS.txt"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"cambios sin commitear; no aplico"* ]]
  [[ "$output" == *"?? NOTAS.txt"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses to fast-forward a branch that is not the engine's" {
  # Reproduced before the fix: with $REPO on `experimento`, an ancestor of main
  # with no commits of its own, apply moved *experimento* onto the prepared
  # commit and switched -- so the system ran a commit that is not on main, and
  # every later apply refused with advice that could not fix it.
  make_rig
  git -C "$REPO" branch experimento HEAD
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "trabajo en main"
  git -C "$STATE/wt" fetch -q "$REPO" main
  git -C "$STATE/wt" checkout -q -B auto/update FETCH_HEAD
  printf 'v3\n' > "$STATE/wt/flake.lock"
  git -C "$STATE/wt" add -A
  git -C "$STATE/wt" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -qm "auto: actualizacion preparada"
  git -C "$REPO" checkout -q experimento

  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"esta en la rama 'experimento'"* ]]
  [[ "$output" == *"prepara desde 'main'"* ]]
  [[ "$output" == *"switch main"* ]]
  # experimento must be exactly where it was, and nothing activated.
  [ "$(git -C "$REPO" rev-parse experimento)" = "$(git -C "$REPO" rev-parse main~1)" ]
  [ ! -s "$NH_MARKER" ]
  [ ! -f "$REPO/.git/FETCH_HEAD" ]
}

@test "apply honours BRANCH when the engine is pointed at another one" {
  make_rig
  git -C "$REPO" branch -m main produccion
  run env BRANCH=produccion REPO="$REPO" STATE_DIR="$STATE" bash "$UPD" apply
  [ "$status" -eq 0 ]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

@test "apply refuses when the state is not ready" {
  make_rig
  status_json '{"schema":1,"checked_at":"x","state":"build_failed","warnings":[]}'
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no hay ninguna actualizacion lista"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses while the engine holds the lock" {
  # status.json is written at the end of a run but auto/update is force-moved
  # near its start, so during a run the file on disk can describe a branch that
  # has already moved. Sharing the engine's lock is what closes that window.
  make_rig
  flock "$STATE/lock" -c 'sleep 3' &
  local locker=$!
  sleep 0.4
  run upd apply
  kill "$locker" 2>/dev/null || true
  wait "$locker" 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" == *"comprobacion en marcha"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a clone that is not this engine's clone of the repo" {
  make_rig
  git -C "$STATE/wt" remote set-url origin /tmp/otro-repo
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es de"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses a clone whose HEAD is not the prepared branch" {
  # A run killed midway leaves the clone somewhere else; the source that
  # produced result is then no longer on disk in a form anyone can name.
  make_rig
  git -C "$STATE/wt" checkout -q --detach HEAD~1
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es auto/update"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply refuses when the target branch moved past the prepared commit" {
  make_rig
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "trabajo del usuario"
  run upd apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"no es antecesor"* ]]
  [ ! -s "$NH_MARKER" ]
}

@test "apply fast-forwards and switches, naming what it applies" {
  make_rig
  prepared="$(git -C "$STATE/wt" rev-parse auto/update)"
  run upd apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"aplicando sobre main"* ]]
  [[ "$output" == *"auto: actualizacion preparada"* ]]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$prepared" ]
  [ "$(cat "$REPO/flake.lock")" = "v2" ]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

@test "apply warns, but proceeds, when the built closure is gone" {
  make_rig
  rm "$STATE/wt/result"
  run upd apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"ya no apunta a ningun closure"* ]]
  [ "$(cat "$NH_MARKER")" = "os switch $REPO" ]
}

# --- check ------------------------------------------------------------------

@test "check runs the engine directly, not through systemctl" {
  cat > "$WORK/bin/motor" <<'EOF'
#!/usr/bin/env bash
echo "motor ejecutado"
EOF
  chmod +x "$WORK/bin/motor"
  run env NIXOS_UPD="$WORK/bin/motor" STATE_DIR="$STATE" bash "$UPD" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"motor ejecutado"* ]]
  [[ "$output" != *"systemctl"* ]]
}
