#!/usr/bin/env bash
set -euo pipefail

# Prepare -- but never apply -- a system update.
#
# Everything happens in a private clone under $STATE_DIR. If this script bumped
# the flake.lock inside ~/nixos-config, the next `nh os switch` the user ran for
# an unrelated reason would silently carry an unreviewed nixpkgs with it. That
# is the failure this layout exists to prevent.
#
# ~/nixos-config is a read-only source here. Note that it is *cloned*, not
# `git worktree add`-ed: a linked worktree keeps its objects and refs inside the
# origin's .git directory, so `git commit` and `git branch -f auto/update` in
# the worktree would write into ~/nixos-config after all. A clone is the only
# form of "check out main somewhere else" that actually keeps the write boundary
# the rest of this file argues for. It also makes `git fetch "$REPO"` below mean
# what it says instead of being a no-op against a shared object store.
#
# Exit code: 0 for every outcome that reached status.json, including a failed
# build or a failed check -- a red systemd unit every morning trains the user to
# ignore it, and the state is in the file. Non-zero *only* when status.json
# itself could not be written, because at that point the unit's exit code is the
# last remaining channel to the user and silence is the one outcome this whole
# engine exists to prevent.

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)}"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
source "$LIB_DIR/status.sh"

REPO="${REPO:-/home/daf3r/nixos-config}"
BRANCH="${BRANCH:-main}"
STATE_DIR="${STATE_DIR:-/var/lib/nixos-upd}"
FLAKE_ATTR="${FLAKE_ATTR:-daf3r-starter}"
WT="$STATE_DIR/wt"
LOG="$STATE_DIR/last.log"
STATUS="$STATE_DIR/status.json"

# Before this point there is nowhere to write a status to, so a failure here can
# only be reported by exiting non-zero.
if ! mkdir -p "$STATE_DIR"; then
  echo "nixos-upd: cannot create $STATE_DIR; nothing can be reported" >&2
  exit 1
fi

# Truncate the log *first*. The obvious placement -- after the worktree setup --
# throws away the log of exactly the step most likely to have just failed.
: > "$LOG"

# Wait rather than fail: a manual rebuild in progress is a reason to queue, not
# to skip a whole day.
if ! exec 9>"$STATE_DIR/lock"; then
  echo "nixos-upd: cannot open $STATE_DIR/lock" >&2
  exit 1
fi
flock 9

log() { printf 'nixos-upd: %s\n' "$1" >>"$LOG"; }

# status_write returns 1 instead of aborting when it cannot write, precisely so
# that `set -e` here does not turn a reporting failure into a silent death
# halfway through the run. Every status write in this file goes through this one
# guarded call site.
finish() { # $1 state, $2 JSON object body
  if ! status_write "$STATUS" "$1" "$2"; then
    echo "nixos-upd: could not write $STATUS (state=$1); the exit code is the only channel left" >&2
    log "could not write $STATUS (state=$1)"
    exit 1
  fi
  exit 0
}

fail() { # $1 state, $2 message
  local body
  body="$(jq -n --arg m "$2" '{error: $m}')" \
    || body='{"error":"a failure occurred and its message could not be encoded"}'
  echo "nixos-upd: $2" >&2
  log "$2"
  finish "$1" "$body"
}

warnings='[]'
warn() { # $1 code, $2 detail
  local next
  # A jq failure here must not drop the warnings collected so far, and must not
  # leave $warnings holding jq's empty output either -- that would be invalid
  # JSON and would take the whole status write down with it.
  if next="$(jq -c --arg c "$1" --arg d "$2" '. + [{code: $c, detail: $d}]' <<<"$warnings")"; then
    warnings="$next"
  fi
  log "warning: $1: $2"
}

# --- private clone, reset to the committed branch ---------------------------
if [ ! -e "$WT/.git" ]; then
  rm -rf "$WT"
  git clone --no-hardlinks --quiet "$REPO" "$WT" >>"$LOG" 2>&1 \
    || fail check_failed "could not clone $REPO into $WT"
fi
git -C "$WT" fetch --quiet "$REPO" "$BRANCH" >>"$LOG" 2>&1 \
  || fail check_failed "could not fetch $BRANCH from $REPO"
# reset first: `checkout -B` refuses to move over conflicting local edits, and
# whatever is in this clone's working tree is by definition disposable.
git -C "$WT" reset --hard --quiet FETCH_HEAD >>"$LOG" 2>&1 \
  || fail check_failed "could not reset the worktree to FETCH_HEAD"
# Sit on auto/update from the start, so the commit at the end lands on the
# branch the reader is told to look at rather than on a copy of main that a
# side pointer is then dragged to.
git -C "$WT" checkout -q -B auto/update FETCH_HEAD >>"$LOG" 2>&1 \
  || fail check_failed "could not put the worktree on auto/update"

# --- bump the two locally-packaged apps ------------------------------------
# A failing bump leaves that package where it is and does not stop the run.
brave_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-brave-origin.sh" --repo "$WT" 2>>"$LOG")" \
  || brave_line="brave-origin (bump failed)"
t3code_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-t3code-app.sh" --repo "$WT" 2>>"$LOG")" \
  || t3code_line="t3code-app (bump failed)"

# --- flake inputs -----------------------------------------------------------
nix flake update --flake "$WT" >>"$LOG" 2>&1 || fail check_failed "nix flake update failed"

# --- build ------------------------------------------------------------------
# From inside $WT, because `nixos-rebuild build` drops its `result` symlink in
# the current directory and everything below reads "$WT/result".
if ! (cd "$WT" && nixos-rebuild build --flake "$WT#$FLAKE_ATTR") >>"$LOG" 2>&1; then
  finish "build_failed" "$(jq -n --arg log "$LOG" '{build: {ok: false, log: $log}}')"
fi

# --- nothing changed? -------------------------------------------------------
if [ "$(readlink -f "$WT/result")" = "$(readlink -f /run/current-system)" ]; then
  finish "current" '{}'
fi

# --- verify Brave kept its feature names ------------------------------------
# Brave comes in through home-manager, not environment.systemPackages, so it is
# not under result/sw. Ask the closure where it actually is.
#
# "No warnings" must mean "checked, and the names are there". A check that could
# not run at all -- no Brave in the closure, no `strings`, an unreadable binary
# -- produces zero missing-name lines too, and swallowing that with `|| true`
# would render it identical to a clean pass. Silence is the exact failure mode
# this check exists to catch: Chromium renamed these features without a word and
# the laptop decoded video on the CPU at 92 degrees for weeks with the config
# looking perfectly correct. So an unrunnable check is itself a warning.
brave_bin=""
closure="$(nix-store -qR "$WT/result" 2>>"$LOG")" || closure=""
if [ -n "$closure" ]; then
  # Not `head -n1`: the closure also holds brave-origin-<version>-fish-completions,
  # which matches the same pattern and contains no binary at all, and the order
  # nix-store prints a closure in is not something to bet a silent skip on. Take
  # the first candidate that actually has the binary.
  while read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p/opt/brave.com/brave-origin/brave" ]; then
      brave_bin="$p/opt/brave.com/brave-origin/brave"
      break
    fi
  done < <(printf '%s\n' "$closure" | grep -E 'brave-origin-[0-9]' || true)
fi

if [ -z "$brave_bin" ]; then
  warn brave_vaapi_check_skipped \
    "no brave-origin binary in the built closure, so the VA-API feature names were NOT checked"
else
  vaapi_rc=0
  vaapi_out="$(bash "$SELF_DIR/check-brave-vaapi.sh" "$brave_bin" 2>>"$LOG")" || vaapi_rc=$?
  if [ "$vaapi_rc" -ne 0 ]; then
    warn brave_vaapi_check_failed \
      "check-brave-vaapi.sh exited $vaapi_rc for $brave_bin, so the feature names were NOT checked; see $LOG"
  else
    while read -r line; do
      [ -n "$line" ] || continue
      warn brave_vaapi_feature_missing "${line#missing: } not found in the binary"
    done <<<"$vaapi_out"
  fi
fi

# --- what changed -----------------------------------------------------------
diff_txt="$(nix store diff-closures /run/current-system "$WT/result" 2>>"$LOG")" \
  || diff_txt="(nix store diff-closures failed; see $LOG)"
printf '%s\n' "$diff_txt" > "$STATE_DIR/diff.txt"

# --- claude-code is reported, never touched ---------------------------------
# Read the installed version from its package.json rather than by running the
# binary: under systemd the PATH is minimal and ~/.npm-global/bin is not on it,
# so `claude --version` would silently find nothing and this would never report.
# $HOME gets the same treatment -- a unit without it would abort the whole run
# under `set -u`.
unmanaged='[]'
cc_have=""
cc_want=""
if [ -n "${HOME:-}" ]; then
  cc_pkg="$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/package.json"
  cc_have="$(jq -r '.version' "$cc_pkg" 2>>"$LOG")" || cc_have=""
fi
if [ -n "$cc_have" ]; then
  # `npm view` reaches the network; a daily timer must not hang on it. And if it
  # cannot answer, say so rather than silently reporting "nothing to update" --
  # same reasoning as the Brave check above.
  cc_want="$(timeout 60 npm view @anthropic-ai/claude-code version 2>>"$LOG")" || cc_want=""
  if [ -z "$cc_want" ]; then
    warn unmanaged_check_failed \
      "claude-code is installed ($cc_have) but \`npm view\` could not report the latest version, so it was NOT checked; npm needs to be on this unit's PATH and the network reachable"
  elif [ "$cc_have" != "$cc_want" ]; then
    unmanaged="$(jq -c -n --arg f "$cc_have" --arg t "$cc_want" \
      '[{name: "claude-code", from: $f, to: $t,
         command: "npm update -g @anthropic-ai/claude-code"}]')" \
      || unmanaged='[]'
  fi
fi

# --- record it --------------------------------------------------------------
# nixpin_set writes `pkgs/<name>.nix.XXXXXX` and renames it into place; if it
# dies between the two (a bare `exit`, a signal -- bash runs no RETURN trap for
# either) the temp file survives in the repo. A plain `git add -A` would commit
# that half-written derivation onto auto/update, where it looks exactly like a
# reviewed change. Delete them, and exclude the pattern from staging as well so
# one that reappears between the two steps still cannot be committed.
find "$WT/pkgs" -maxdepth 1 -type f -name '*.nix.??????' -print -delete >>"$LOG" 2>&1 || true

git -C "$WT" add -A -- . ':(exclude,glob)pkgs/*.nix.??????' >>"$LOG" 2>&1 \
  || fail check_failed "could not stage the prepared update"

if git -C "$WT" diff --cached --quiet; then
  log "nothing staged: the inputs did not move, keeping the existing commit"
else
  git -C "$WT" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -q -m "auto: actualizacion preparada" >>"$LOG" 2>&1 \
    || fail check_failed "could not commit the prepared update"
fi

finish "ready" "$(jq -n \
  --arg brave "$brave_line" \
  --arg t3 "$t3code_line" \
  --arg log "$LOG" \
  --argjson warnings "$warnings" \
  --argjson unmanaged "$unmanaged" \
  '{build: {ok: true, log: $log},
    branch: "auto/update",
    local_pkgs: [$brave, $t3],
    warnings: $warnings,
    unmanaged: $unmanaged}')"
