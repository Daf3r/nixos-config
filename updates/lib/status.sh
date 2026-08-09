# shellcheck shell=bash
#
# The engine's only output surface: `status.json`, polled by a future
# reader (the phase-2 Noctalia bar plugin). `schema` is here so that reader
# can refuse a format it does not understand instead of rendering nonsense.
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
# EXIT trap.

# $1 path, $2 state (ready|current|build_failed|check_failed), $3 JSON
# object merged into the envelope. Exits 1 without writing anything if $3
# is not a JSON object — better no update than a corrupt status file.
status_write() {
  local path=$1 state=$2 body=$3 tmp

  if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "status_write: body is not a JSON object" >&2
    return 1
  fi

  tmp="$(mktemp "$(dirname "$path")/.status.XXXXXX")"
  trap 'rm -f "$tmp"; trap - RETURN' RETURN

  if ! jq -n \
      --argjson body "$body" \
      --arg state "$state" \
      --arg now "$(date -Iseconds)" \
      '{schema: 1, checked_at: $now, state: $state} + $body' > "$tmp"; then
    echo "status_write: failed to render envelope" >&2
    return 1
  fi

  mv "$tmp" "$path"
}
