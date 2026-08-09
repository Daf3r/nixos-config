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

# Every path that gives up without writing a fresh status must first remove the
# old one. Leaving yesterday's file behind is worse than leaving none: a reader
# has no way to tell a current `ready` from one describing a build that no
# longer exists, so it would offer the user an `upd apply` for a commit this run
# never made. Absent is honest, and a reader that finds no status.json knows it
# has nothing to say. This is best-effort by design -- if $STATUS cannot even be
# unlinked it is not a file a reader could parse anyway.
drop_status() { rm -f "$STATUS" 2>/dev/null || true; }

# Before this point there is nowhere to write a status to, so a failure here can
# only be reported by exiting non-zero.
if ! mkdir -p "$STATE_DIR"; then
  echo "nixos-upd: cannot create $STATE_DIR; nothing can be reported" >&2
  drop_status
  exit 1
fi

# Logging must never be able to abort the run: $LOG is a diagnostic, not a
# result, and an unwritable one is not a reason to leave the reader with no
# status at all. Every writer of $LOG below is non-fatal for the same reason.
# The braces matter: with the redirection on the inner command only, bash still
# reports its own "Is a directory" to the real stderr on every single call.
log() { { printf 'nixos-upd: %s\n' "$1" >>"$LOG"; } 2>/dev/null || true; }

# status_write returns 1 instead of aborting when it cannot write, precisely so
# that `set -e` here does not turn a reporting failure into a silent death
# halfway through the run. Every status write in this file goes through this one
# guarded call site.
finish() { # $1 state, $2 JSON object body
  if ! status_write "$STATUS" "$1" "$2"; then
    echo "nixos-upd: could not write $STATUS (state=$1); the exit code is the only channel left" >&2
    log "could not write $STATUS (state=$1)"
    # This is the jq-missing case among others: status_write validates the body
    # with jq, so without it every path lands here and the previous run's file
    # would otherwise survive intact.
    drop_status
    exit 1
  fi
  exit 0
}

fail() { # $1 state, $2 message
  local body
  body="$(jq -n --arg m "$2" --argjson w "${warnings:-[]}" '{error: $m, warnings: $w}')" \
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

# --- serialise, then take over the log --------------------------------------
# Wait rather than fail: a manual rebuild in progress is a reason to queue, not
# to skip a whole day.
if ! exec 9>"$STATE_DIR/lock"; then
  echo "nixos-upd: cannot open $STATE_DIR/lock" >&2
  # $STATUS may well be perfectly writable here, but this run holds no lock, so
  # it must not write into a file another run could be mid-write on. Removing it
  # is the one honest move available.
  drop_status
  exit 1
fi
# Not bare: `flock` missing from a minimal systemd PATH exits 127 and would kill
# the run under errexit with no status file written at all -- the likeliest
# first-boot failure and the one that leaves nothing behind to explain itself.
if ! flock 9; then
  fail check_failed "could not acquire $STATE_DIR/lock (is flock on PATH?)"
fi

# Truncating belongs *after* the lock, and only after. Before it, a run that
# arrives while another is mid-build wipes the running run's log while that
# run's status.json still points a reader at it. After it, the log still gets
# truncated before anything appends, so the record of the worktree setup -- the
# step most likely to have just failed -- survives.
if ! : > "$LOG"; then
  fail check_failed "could not truncate $LOG"
fi

# Collect scaffolding orphaned by an earlier run that died between cloning and
# the swap below. Nothing traps those, and a whole clone left behind every time
# would grow $STATE_DIR without bound. Safe here and only here: the lock is
# held, so no other run owns one, and this run has not created its own yet.
wt_base="$(basename "$WT")"
find "$STATE_DIR" -maxdepth 1 -name "$wt_base.new.*" -exec rm -rf {} + >>"$LOG" 2>&1 || true

# The .old.* half is different, and only reapable when $WT is actually there. A
# run killed between the swap's two renames leaves no $WT and a .old.* holding
# the only copy of the prepared commit; sweeping it here would destroy the very
# thing the swap was written to protect. Note it does NOT still pin the built
# closure: an indirect GC root is keyed on the *path* of the result symlink, so
# renaming the directory aside drops the root even though the symlink survives
# (measured: one root naming $WT/result before the rename, none naming either
# path after). What a .old.* preserves is the commit, not the closure.
#
# With $WT present, a .old.* is genuinely superseded. When it is absent the
# leftover simply survives this run and is collected by the next one, which will
# have a $WT again.
if [ -e "$WT" ] || [ -L "$WT" ]; then
  find "$STATE_DIR" -maxdepth 1 -name "$wt_base.old.*" -exec rm -rf {} + >>"$LOG" 2>&1 || true
fi

# --- private clone, reset to the committed branch ---------------------------
# $WT is used only when it is demonstrably this engine's own, structurally
# intact clone of $REPO. Four conditions, each closing a hole that was
# reproduced rather than imagined:
#
#   not a symlink       a $WT symlinked at another repository used to be
#                       accepted and then handed to `reset --hard`, which
#                       deleted uncommitted work there and left an auto/update
#                       branch behind.
#   git dir IS $WT/.git the git directory git would actually use has to be the
#                       one inside $WT, not merely something reachable through
#                       a path called `$WT/.git`. Asking git where it resolved
#                       to covers every way that indirection happens at once:
#                       `-d` follows symlinks, so a `$WT/.git` symlinked at
#                       `$REPO/.git` passed it and put refs/heads/auto/update
#                       in the origin and moved the origin's HEAD onto it; a
#                       linked worktree resolves to $REPO/.git/worktrees/<name>;
#                       and --separate-git-dir resolves somewhere else entirely.
#                       Writing into the origin's `.git` is the single thing
#                       this whole file exists to prevent.
#   HEAD's commit reads refs or objects that cannot be read mean the clone is
#                       broken, which is a different thing from out of date and
#                       is the only condition that justifies deleting it.
#   origin is $REPO     it is ours, and ours for this source.
#
# The asymmetry in that comparison is deliberate and load-bearing: the $WT side
# is canonicalized, `/.git` is then appended literally, and the result is
# compared against what git reports. Do not "tidy" this into
# `readlink -f "$WT/.git"`.
#
#   why canonicalize $WT      `--absolute-git-dir` returns a resolved path.
#                             Comparing it against a literal "$WT/.git" rejects
#                             a perfectly healthy clone whenever $STATE_DIR is
#                             reached through a symlink or merely carries a
#                             trailing slash -- re-cloning every single day and
#                             destroying the prepared commit each time. Not
#                             hypothetical for long: a unit using
#                             DynamicUser=yes with StateDirectory=nixos-upd gets
#                             /var/lib/nixos-upd as a symlink into private/, and
#                             Task 8 writes that unit next. Safe because
#                             [ ! -L "$WT" ] has already rejected a $WT that is
#                             itself a symlink.
#   why NOT canonicalize      the whole point is that the git directory must
#   the ".git" component      *be* at $WT/.git, not merely reachable through a
#                             path spelled that way. For a $WT/.git symlinked at
#                             $REPO/.git, both `--absolute-git-dir` and
#                             `readlink -f` return $REPO/.git, so resolving both
#                             sides would compare equal, readmit a worktree
#                             backed by the origin, and put refs/heads/auto/update
#                             inside the origin again.
wt_is_ours=0
if [ ! -L "$WT" ] \
  && [ "$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" = "$(readlink -f "$WT")/.git" ] \
  && git -C "$WT" cat-file -e 'HEAD^{commit}' 2>/dev/null; then
  wt_origin="$(git -C "$WT" remote get-url origin 2>/dev/null)" || wt_origin=""
  if [ -n "$wt_origin" ] \
    && [ "$(readlink -f "$wt_origin" 2>/dev/null || printf '%s' "$wt_origin")" \
       = "$(readlink -f "$REPO" 2>/dev/null || printf '%s' "$REPO")" ]; then
    wt_is_ours=1
  else
    log "$WT is not this engine's clone of $REPO (origin=${wt_origin:-none}); re-cloning"
  fi
else
  # Without this branch the outer probe fails silently, and every cause of that
  # -- not just the canonicalization bug fixed above -- re-clones daily, throws
  # away the prepared commit and still reports a plain `ready`, with nothing
  # anywhere to say why. Live causes remain: git's dubious-ownership refusal if
  # the unit's uid ever changes (plausible the first time Task 8 turns on
  # DynamicUser=yes over an existing state directory), an unreadable .git, or
  # `readlink` missing from a minimal PATH. The two cases are separated because
  # one of them is completely routine and the other never is.
  if [ -e "$WT" ] || [ -L "$WT" ]; then
    log "$WT exists but failed the ownership and integrity probe (symlink, git directory not at $WT/.git, or HEAD unreadable); re-cloning and discarding whatever it held"
  else
    log "no clone at $WT yet; cloning"
  fi
fi

if [ "$wt_is_ours" -ne 1 ]; then
  # Clone beside $WT and swap, rather than deleting first and cloning into the
  # gap. Deleting first means a clone that then fails -- $REPO unreadable, disk
  # full -- has destroyed whatever was there for nothing, including a prepared
  # auto/update commit and the result GC root, and left no clone at all for the
  # next run to fall back on. This way a failed clone changes nothing.
  wt_new="$WT.new.$$"
  wt_old="$WT.old.$$"
  rm -rf "$wt_new" || fail check_failed "could not clear $wt_new"
  if ! git clone --no-hardlinks --quiet "$REPO" "$wt_new" >>"$LOG" 2>&1; then
    rm -rf "$wt_new" || true
    fail check_failed "could not clone $REPO into $WT; the existing $WT was left untouched"
  fi
  # Rename the old one aside instead of deleting it in place. `rm -rf` is not
  # atomic: one undeletable entry leaves $WT half gone -- `.git` and `result`
  # already unlinked, so the prepared commit is destroyed and the built closure
  # loses its GC root -- and the fresh clone was then discarded too, so the run
  # achieved nothing.
  # `mv` within a directory is a single rename that either happens or does not.
  # A symlinked $WT is moved as the link, never followed.
  if [ -e "$WT" ] || [ -L "$WT" ]; then
    if ! mv "$WT" "$wt_old"; then
      rm -rf "$wt_new" || true
      fail check_failed "could not move $WT aside; it was left untouched"
    fi
  fi
  if ! mv "$wt_new" "$WT"; then
    # Put the old one back rather than leaving nothing at $WT.
    mv "$wt_old" "$WT" 2>/dev/null || true
    rm -rf "$wt_new" || true
    fail check_failed "could not move the fresh clone into $WT"
  fi
  # Only now is the old one genuinely superseded, and only now may it go. A
  # failure here is untidy, not dangerous: the sweep above collects it next run.
  rm -rf "$wt_old" || true
fi

# Clear the two kinds of debris a half-finished git command leaves behind, both
# of which pass every structural probe above -- those read a ref and an object,
# neither the index nor any lock -- and both of which wedge the engine on
# check_failed forever with no way back.
#
#   a corrupt index      makes `git fetch` exit 128.
#   a stale *.lock       makes `reset --hard` fail. index.lock, HEAD.lock and
#                        refs/heads/auto/update.lock were each confirmed to
#                        wedge runs 2 and 3 and every run after.
#
# This engine authors both: `git add -A` below writes the index under
# index.lock, so a systemd timeout or a reboot mid-command leaves one or the
# other. Removing them is non-destructive -- `reset --hard FETCH_HEAD` rewrites
# the index wholesale two commands later, and a lock whose owning process is
# gone protects nothing. Safe to clear unconditionally because $WT is private to
# this engine and the flock above means no other run holds them.
rm -f "$WT/.git/index" "$WT/.git/index.lock" "$WT/.git/HEAD.lock" || true
find "$WT/.git/refs" -name '*.lock' -delete 2>/dev/null || true

# A failed fetch is NOT evidence that the clone is damaged, and must never
# delete anything. A wrong $BRANCH, an unreachable $REPO and a permissions blip
# all land here. An earlier version re-cloned on any of them, which threw away a
# healthy clone together with the prepared auto/update commit and the
# $WT/result symlink -- the GC root pinning the built closure that Task 8's
# `upd apply` is about to switch to. A network hiccup between the nightly run
# and the user typing `upd apply` would have silently discarded the update they
# were about to install. Structural damage is caught above, where it can be told
# apart from this; here, report and keep everything.
git -C "$WT" fetch --quiet "$REPO" "$BRANCH" >>"$LOG" 2>&1 \
  || fail check_failed "could not fetch $BRANCH from $REPO; the prepared clone at $WT was left untouched"
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
# A failing bump leaves that package where it is and does not stop the run --
# but it must not be silent either. local_pkgs is free-form prose meant for a
# human, so the only machine-detectable signal a failure used to leave was a
# substring match on "(bump failed)", which is no contract for a reader to gate
# on. A reader watching `warnings` -- which is what Task 8's `upd` does -- saw a
# clean `ready` while a package quietly stayed behind at its old version. Same
# class as the VA-API check above: the check not running has to look different
# from the check passing.
if ! brave_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-brave-origin.sh" --repo "$WT" 2>>"$LOG")"; then
  brave_line="brave-origin (bump failed)"
  warn local_bump_failed "brave-origin could not be bumped; it stays at the version pinned in pkgs/brave-origin.nix (see $LOG)"
fi
if ! t3code_line="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-t3code-app.sh" --repo "$WT" 2>>"$LOG")"; then
  t3code_line="t3code-app (bump failed)"
  warn local_bump_failed "t3code-app could not be bumped; it stays at the version pinned in pkgs/t3code-app.nix (see $LOG)"
fi

# --- flake inputs -----------------------------------------------------------
nix flake update --flake "$WT" >>"$LOG" 2>&1 || fail check_failed "nix flake update failed"

# --- build ------------------------------------------------------------------
# From inside $WT, because `nixos-rebuild build` drops its `result` symlink in
# the current directory and everything below reads "$WT/result".
if ! (cd "$WT" && nixos-rebuild build --flake "$WT#$FLAKE_ATTR") >>"$LOG" 2>&1; then
  bf_body="$(jq -n --arg log "$LOG" --argjson w "$warnings" \
    '{build: {ok: false, log: $log}, warnings: $w}')" \
    || fail check_failed "the build failed and its status body could not be rendered"
  finish "build_failed" "$bf_body"
fi

# --- nothing changed? -------------------------------------------------------
if [ "$(readlink -f "$WT/result")" = "$(readlink -f /run/current-system)" ]; then
  # Carrying $warnings here is not decoration. The bumps run before the build,
  # so "nothing to update" and "a package silently stayed at its old pin"
  # co-occur precisely when the failed bump is what left the closure unchanged.
  # Dropping the array would recreate, on this state, the exact silence the
  # local_bump_failed warning was added to end.
  cur_body="$(jq -n --argjson w "$warnings" '{warnings: $w}')" \
    || fail check_failed "the closure is unchanged but the status body could not be rendered"
  finish "current" "$cur_body"
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
# Not bare. diff.txt is a convenience for the reader; the build succeeded and
# the commit below is real. Aborting here under errexit would leave the previous
# run's status.json in place -- a stale `ready`, with an old checked_at, naming
# an auto/update commit this run never made. A status that is not the true one
# is the single outcome this file exists to make impossible, so this degrades to
# a warning and the run reports what actually happened.
if ! printf '%s\n' "$diff_txt" > "$STATE_DIR/diff.txt" 2>/dev/null; then
  warn diff_write_failed "could not write $STATE_DIR/diff.txt; the closure diff is unavailable to the reader"
fi

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

ready_body="$(jq -n \
  --arg brave "$brave_line" \
  --arg t3 "$t3code_line" \
  --arg log "$LOG" \
  --argjson warnings "$warnings" \
  --argjson unmanaged "$unmanaged" \
  '{build: {ok: true, log: $log},
    branch: "auto/update",
    local_pkgs: [$brave, $t3],
    warnings: $warnings,
    unmanaged: $unmanaged}')" \
  || fail check_failed "the update is prepared but its status body could not be rendered"
finish "ready" "$ready_body"
