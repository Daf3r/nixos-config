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
# shellcheck source=lib/closure.sh
source "$LIB_DIR/closure.sh"
# shellcheck source=lib/inputs.sh
source "$LIB_DIR/inputs.sh"

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
  # Writing the status is the one step that must not be interrupted halfway.
  # A signal arriving between status_write's temp file and its rename would
  # otherwise run the handler installed below, which calls fail() -- so the run
  # would try to write two different statuses at once. Ignoring the three
  # signals from here on costs nothing: every path through finish() ends in
  # `exit`, so there is no work left worth interrupting.
  trap '' TERM INT HUP
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
  # Not bare: fail() is also what the signal handler below calls, and a handler
  # that dies under errexit -- on a closed or full stderr, say -- would leave the
  # run with no status written at all, which is the outcome fail() exists to
  # prevent. The message is a courtesy; $STATUS is the result.
  echo "nixos-upd: $2" >&2 || true
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

# A run that is killed mid-flight must not leave the previous run's status
# behind. Reproduced: SIGTERM during the build left yesterday's
# {"state":"ready","checked_at":<old>} on disk while auto/update had already
# been force-moved to FETCH_HEAD near the start of the run -- so the prepared
# commit that `ready` describes no longer existed, and `upd apply` was still
# being offered for it. That is exactly the stale-and-ready this file's
# drop_status comment declares impossible, so the declaration has to be
# enforced rather than asserted. The triggers are routine, not exotic:
# TimeoutStartSec=3h against a night that builds Electron from source, a
# reboot, a shutdown -- systemd signals the whole cgroup in all three.
#
# Installed only now, and deliberately not earlier: before the lock this run
# owns nothing, and must not write into a file another run may be mid-write on.
# It cannot fire on the normal exit path either -- these are signals, and
# `exit` is not one; finish() disables all three before it writes, so the
# handler cannot interleave with a status write already under way.
#
# The handler must be unable to abort under errexit before it has written
# something: fail() -> finish() -> status_write is guarded end to end, every
# call in fail() either has an `|| ...` or is finish() itself, and finish()
# always ends in `exit`.
# shellcheck disable=SC2329  # invoked by the trap on the next line, not by name
on_signal() {
  # A second signal must not re-enter this handler and start a second status
  # write on top of the first.
  trap '' TERM INT HUP
  fail check_failed "the run was interrupted by a signal (systemd timeout, reboot or shutdown); nothing was applied and no prepared update should be trusted from this run"
}
trap on_signal TERM INT HUP

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
# but it must not be silent either. Both signals are needed and they are not
# the same one: the `warnings` entry is what a reader gates on (a clean `ready`
# used to hide a package quietly staying at its old version), and the fallback
# object is what keeps `changes[]` uniform so a reader never has to cope with a
# missing element. `from` and `to` are empty because there is nothing
# trustworthy to put in them, which is not the same as the package being known
# to have stayed put: the bump scripts call nixpin_set *before* they print
# their JSON, so a failure between those two leaves the pin rewritten -- and
# then committed by the staging further down -- while this entry says nothing
# moved. Nothing here can tell those apart, and the `warnings` entry is what
# covers it. That is the other half of why both signals exist rather than one.
# Same class as the VA-API check above: the check not running has to look
# different from the check passing.
if ! brave_json="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-brave-origin.sh" --repo "$WT" 2>>"$LOG")"; then
  brave_json='{"name":"brave-origin","kind":"local_pkg","from":"","to":"","error":"bump failed"}'
  warn local_bump_failed "brave-origin could not be bumped; it stays at the version pinned in pkgs/brave-origin.nix (see $LOG)"
fi
if ! t3code_json="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-t3code-app.sh" --repo "$WT" 2>>"$LOG")"; then
  t3code_json='{"name":"t3code-app","kind":"local_pkg","from":"","to":"","error":"bump failed"}'
  warn local_bump_failed "t3code-app could not be bumped; it stays at the version pinned in pkgs/t3code-app.nix (see $LOG)"
fi

# --- flake inputs -----------------------------------------------------------
# Snapshot the lock the update is measured *from*, and take it from FETCH_HEAD
# rather than from the working tree. The placement is the whole of it: on the
# second consecutive run without an apply, $WT still holds yesterday's already
# updated lock until the reset above rewrites it, so a snapshot taken any
# earlier reports what moved since *yesterday's prepared update* instead of
# what moved since the running system. That understates by exactly the part the
# user has not applied yet -- nixpkgs A->B on Monday, B->C on Tuesday, and the
# report says B->C to someone still running A -- and it is wrong in the
# quietest way available: a real input, a real short rev, a plausible row.
# Naming FETCH_HEAD instead of copying $WT/flake.lock makes the ordering
# structural: moved above the fetch, this fails loudly instead of lying.
#
# On failure the half-written file is removed rather than left: an empty
# lock.before is unparseable, and a stale one from an earlier run would be
# silently diffed against as if it were today's baseline.
if ! git -C "$WT" show FETCH_HEAD:flake.lock > "$STATE_DIR/lock.before" 2>>"$LOG"; then
  rm -f "$STATE_DIR/lock.before" || true
  warn lock_snapshot_failed "could not snapshot the previous flake.lock, so status.json will not name which inputs moved (see $LOG)"
fi

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

# --- claude-code is reported, never touched ---------------------------------
# Above the `current` check on purpose, and this placement is the whole point.
# claude-code updates on npm's clock, not on nixpkgs', so on the overwhelmingly
# common morning -- the one after the user applied yesterday's update, when the
# system closure has not moved -- this run ends at `current`. With the block
# below the `current` check, that morning reported nothing about claude-code at
# all, and kept reporting nothing until some unrelated system change happened to
# land. The design promises the report mentions a new version and the command;
# a promise that only holds on the rarer branch is not kept.
#
# It sits after the build rather than before it because a build_failed run has
# nothing to offer the user anyway, and this reaches the network.
#
# Read the installed version from its package.json rather than by running the
# binary: under systemd the PATH is minimal and ~/.npm-global/bin is not on it,
# so `claude --version` would silently find nothing and this would never report.
# $HOME gets the same treatment -- a unit without it would abort the whole run
# under `set -u`.
#
# Every way this check can fail to run is now a warning. It used to fall through
# in silence whenever $HOME was unset or the package.json was simply not there,
# which is the same "an unrun check looks exactly like a passed one" shape closed
# at the VA-API check and at the package bumps.
unmanaged='[]'
cc_have=""
cc_want=""
if [ -z "${HOME:-}" ]; then
  warn unmanaged_check_skipped \
    "\$HOME is not set in this unit's environment, so claude-code's installed version could not be located and it was NOT checked"
else
  cc_pkg="$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/package.json"
  if [ ! -f "$cc_pkg" ]; then
    warn unmanaged_check_skipped \
      "there is no $cc_pkg, so claude-code was NOT checked; either it is not installed globally under ~/.npm-global or npm's prefix moved, and this engine only knows how to look there"
  elif ! cc_have="$(jq -r '.version // empty' "$cc_pkg" 2>>"$LOG")" || [ -z "$cc_have" ]; then
    # `jq -r '.version'` on a package.json with no version prints the string
    # "null" and exits 0, which would then be compared against npm's answer and
    # reported as an update from a version that does not exist. `// empty`
    # collapses that into the same empty-and-warned path as a parse failure.
    cc_have=""
    warn unmanaged_check_failed \
      "$cc_pkg exists but no version could be read out of it, so claude-code was NOT checked; see $LOG"
  fi
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

# --- nothing changed? -------------------------------------------------------
if [ "$(readlink -f "$WT/result")" = "$(readlink -f /run/current-system)" ]; then
  # Carrying $warnings here is not decoration. The bumps run before the build,
  # so "nothing to update" and "a package silently stayed at its old pin"
  # co-occur precisely when the failed bump is what left the closure unchanged.
  # Dropping the array would recreate, on this state, the exact silence the
  # local_bump_failed warning was added to end.
  #
  # $unmanaged rides along for the same reason it is computed above the check:
  # `current` is the state this report spends most of its mornings in, and a
  # `current` that omits the one thing that did move says nothing true.
  cur_body="$(jq -n --argjson w "$warnings" --argjson u "$unmanaged" \
    '{warnings: $w, unmanaged: $u}')" \
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
# `diff_ok` exists so the two failures downstream stay told apart. Before
# schema 2 this text only ever reached a human through `upd diff`, and the
# prose below was the whole report of a failed diff-closures; now it is parsed,
# and feeding that sentence to closure_parse would come back as "the format
# moved under us" -- a warning pointing at the wrong thing entirely.
diff_ok=1
if ! diff_txt="$(nix store diff-closures /run/current-system "$WT/result" 2>>"$LOG")"; then
  diff_ok=0
  diff_txt="(nix store diff-closures failed; see $LOG)"
fi
# Not bare. diff.txt is a convenience for the reader; the build succeeded and
# the commit below is real. Aborting here under errexit would leave the previous
# run's status.json in place -- a stale `ready`, with an old checked_at, naming
# an auto/update commit this run never made. A status that is not the true one
# is the single outcome this file exists to make impossible, so this degrades to
# a warning and the run reports what actually happened.
if ! printf '%s\n' "$diff_txt" > "$STATE_DIR/diff.txt" 2>/dev/null; then
  warn diff_write_failed "could not write $STATE_DIR/diff.txt; the closure diff is unavailable to the reader"
fi

# --- the same diff, as data -------------------------------------------------
# Every branch here ends with a warning or with real data, and never with a
# quiet empty diff. An empty closure_diff renders as "nothing changes" in the
# panel, which is the one thing a run that just built a different closure must
# never say; the warning is what makes an unparsed diff look different from an
# identical one.
#
# closure_parse fails all-or-nothing -- one line of a shape it does not know,
# including a size unit some future nix invents, and it returns 1 with nothing
# on stdout. That 1 is emphatically not "no updates". Its own diagnostic goes
# to $LOG, which the warning points at.
closure_json='{"added":[],"removed":[],"changed":[],"size_delta_mb":0}'
if [ "$diff_ok" -ne 1 ]; then
  warn closure_diff_failed "\`nix store diff-closures\` failed, so status.json cannot say which packages this update moves (see $LOG)"
elif ! closure_json="$(printf '%s\n' "$diff_txt" | closure_parse 2>>"$LOG")"; then
  closure_json='{"added":[],"removed":[],"changed":[],"size_delta_mb":0}'
  warn closure_parse_failed "could not parse the closure diff, so the package list is empty; \`nix store diff-closures\` may have changed format (see $LOG)"
fi

# Not a bare assignment. closure_reboot lets jq's own status through (5 on
# input that is not an object) rather than mapping everything onto 1, so under
# `set -e` an unguarded call would take this run down after the build, with no
# status written at all. Whatever it answers, the warning goes with it: on its
# own, "no reboot needed" is exactly what a reboot check that never ran also
# looks like.
#
# The fallback asks closure_reboot itself what an empty diff means instead of
# spelling `{"reboot_recommended":false,"reboot_reason":[]}` out here. A
# literal would be a second place that knows those two key names, and a rename
# in closure.sh would walk straight past it without a sound -- the exact
# duplication the `+ $reboot` merge below exists to avoid. If even that call
# fails, the keys are left out rather than invented: `upd show` already reads
# `.reboot_recommended // false`, and an absent key sitting next to a warning
# says strictly more than a confident `false` sitting next to one.
if ! reboot_json="$(printf '%s' "$closure_json" | closure_reboot 2>>"$LOG")"; then
  warn reboot_check_failed "could not decide whether this update needs a reboot; treat \`upd apply\` as if it might (see $LOG)"
  reboot_json="$(printf '%s' '{"added":[],"removed":[],"changed":[]}' | closure_reboot 2>>"$LOG")" \
    || reboot_json='{}'
fi

# Which flake inputs moved. Absent lock.before means the snapshot above already
# warned, so this stays quiet rather than saying the same thing twice.
inputs_json='[]'
if [ -f "$STATE_DIR/lock.before" ]; then
  if ! inputs_json="$(inputs_diff "$STATE_DIR/lock.before" "$WT/flake.lock" 2>>"$LOG")"; then
    inputs_json='[]'
    warn inputs_diff_failed "could not read which flake inputs moved out of the two lock files, so status.json will not name them (see $LOG)"
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
  # Not "keeping the existing commit": there is no existing commit left to keep.
  # `checkout -B auto/update FETCH_HEAD` near the top of this run already threw
  # any previous run's prepared commit away, so what auto/update names here is
  # the freshly fetched tip of $BRANCH and nothing else. That is a real and
  # legitimate `ready` -- the user committed something to $BRANCH that the
  # running system has not been switched to, so the closure differs while the
  # inputs did not move -- and `upd apply` on it fast-forwards to a commit the
  # user wrote themselves.
  log "nothing staged: the inputs did not move, so auto/update is the fetched $BRANCH tip and no new commit is made"
else
  git -C "$WT" -c user.name=nixos-upd -c user.email=nixos-upd@localhost \
    commit -q -m "auto: actualizacion preparada" >>"$LOG" 2>&1 \
    || fail check_failed "could not commit the prepared update"
fi

# `$reboot` is merged with `+` rather than spelled out field by field, so the
# two keys are whatever closure_reboot decided they are and there is no second
# place that can disagree with it about their names.
ready_body="$(jq -n \
  --argjson brave "$brave_json" \
  --argjson t3 "$t3code_json" \
  --argjson inputs "$inputs_json" \
  --argjson closure "$closure_json" \
  --argjson reboot "$reboot_json" \
  --arg log "$LOG" \
  --argjson warnings "$warnings" \
  --argjson unmanaged "$unmanaged" \
  '{build: {ok: true, log: $log},
    branch: "auto/update",
    changes: ($inputs + [$brave, $t3]),
    closure_diff: $closure,
    warnings: $warnings,
    unmanaged: $unmanaged} + $reboot')" \
  || fail check_failed "the update is prepared but its status body could not be rendered"
finish "ready" "$ready_body"
