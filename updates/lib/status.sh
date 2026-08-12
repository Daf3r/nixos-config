# shellcheck shell=bash
#
# The engine's only output surface: `status.json`. Its one reader today is
# `upd.sh` in a terminal; the DMS bar plugin meant to poll it is not written
# yet. `schema` is here so a reader can refuse a format it does not understand
# instead of rendering nonsense, and it has already earned that: schema 2
# replaced the prose `local_pkgs` array with the structured `changes[]`,
# `closure_diff` and `reboot_recommended`. The two share no field, so a schema 1
# reader let loose on a schema 2 file would print an empty change list for an
# update that moves six flake inputs. Engine and readers are installed together
# and cannot drift within a generation; a stale `upd` earlier on $PATH can, and
# this is what stops it.
#
# Written to a temp file *in the same directory as the target* and renamed,
# because a reader polling this file must never catch it half-written. A
# temp file under $TMPDIR would sit on a different filesystem from the
# target on this machine (/tmp and /home are different devices, confirmed
# with strace), and `mv` across filesystems cannot do a real `renameat` —
# it falls back to copy, which unlinks the destination and recreates it
# empty before streaming any content in. That is exactly the half-written
# window this function exists to prevent. Same-directory temp is what
# makes the rename atomic.
#
# The temp file is cleaned up on every return via a self-clearing RETURN
# trap, the same pattern used in nixpin.sh and for the same reason: an EXIT
# trap here would fight with whatever the caller (or bats itself) already
# has installed on EXIT. This does not cover an untrapped fatal signal or a
# bare `exit` between mktemp and mv — bash does not run RETURN traps in
# either case — so a temp file can still be left behind if the process dies
# there. That gap is left undefended rather than "fixed" by grabbing the
# EXIT trap. If the target happens to be a symlink, the rename replaces it
# with a regular file (the link is unlinked, not followed and written
# through) — the correct outcome for an atomic write, just worth flagging
# since it is a one-way change to whatever the symlink pointed at.
#
# The temp file is created with mktemp's default 0600, and nothing widens
# it afterward — unlike nixpin.sh, which does `chmod --reference` to
# preserve a pre-existing tracked file's mode. That call has no equivalent
# here: on the very first write the target does not exist yet, so there is
# no mode to preserve, and this machine is single-user, so 0600 costs
# nothing today. If a future reader runs as a different uid (or user),
# this needs to change to an explicit `chmod`.

# $1 path, $2 state (ready|current|build_failed|check_failed), $3 JSON
# object merged into the envelope. Exits 1 without writing anything if $3
# is not a JSON object, if $1 already exists as a directory, or if the temp
# file cannot be created — better no update than a corrupt status file, and
# better a clean `return 1` than an unguarded `mktemp` failure tripping
# `errexit` in a `set -e` caller (Task 7 runs under `set -euo pipefail` and
# needs `status_write` to fail as an ordinary, catchable error, never by
# taking the whole script down).
status_write() {
  local path=$1 state=$2 body=$3 tmp

  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "status_write: body is not a JSON object" >&2
    return 1
  fi

  # A directory at $path would make mktemp's sibling-temp-file trick land
  # *inside* it (mktemp only requires the parent of its template to exist,
  # and dirname of a path that is itself a directory is that directory's
  # parent... but the rename target `$path` being a directory makes `mv`
  # move $tmp *into* it instead of replacing it) — silent "success" with
  # nothing at the path a reader is polling. Reject it up front.
  if [ -d "$path" ]; then
    echo "status_write: $path is a directory" >&2
    return 1
  fi

  if ! tmp="$(mktemp "$(dirname "$path")/.status.XXXXXX")"; then
    echo "status_write: could not create a temp file beside $path" >&2
    return 1
  fi
  trap 'rm -f "$tmp"; trap - RETURN' RETURN

  # The envelope goes on the *right* of `+`: jq gives the right operand's
  # keys precedence, so if $body were on the right, a body key named
  # schema, state, or checked_at would silently override the envelope
  # instead of being merged alongside it. The envelope is the only thing a
  # future reader can trust to gate on (schema for "do I understand this
  # format", state for "is there anything to do") — it must win, not be
  # forgeable by whatever a check happened to put in its body.
  if ! jq -n \
      --argjson body "$body" \
      --arg state "$state" \
      --arg now "$(date -Iseconds)" \
      '$body + {schema: 2, checked_at: $now, state: $state}' > "$tmp"; then
    echo "status_write: failed to render envelope" >&2
    return 1
  fi

  mv "$tmp" "$path"
}
