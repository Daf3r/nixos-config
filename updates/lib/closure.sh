# shellcheck shell=bash
#
# Turn `nix store diff-closures` output into structured data.
#
# It has no --json (verified against nix on 2026-08-11: `unrecognised flag`),
# so this parses the human format. That format is a stability bet, and the bet
# is hedged rather than hidden: input that produces no entries at all is a hard
# failure, so a future nix that changes the layout surfaces as a warning in
# status.json instead of as an empty diff that reads like "nothing changed".
#
# Line shapes, all real:
#   name: 1.0 → 2.0                    version change, no size reported
#   name: 1.0 → 2.0, 25.3 KiB          with size
#   name: 1.0, 1.0-fish → 2.0, 2.0-fish, 5.9 MiB   multiple versions per side
#   name: 1.0 → ∅, -788.9 KiB          removed
#   name: ∅ → 1.0                      added
#   name: 52.3 KiB                     same version string, different closure
#
# The size, when present, is always the last comma-separated field and always
# matches a number followed by a unit. Versions are comma-separated too, which
# is why the size is identified by shape and stripped from the end rather than
# by splitting on commas.
#
# Output contract: one JSON object followed by a trailing newline, so that
# `closure_parse > file` produces a well-formed text file and not one that ends
# mid-line. Callers capturing it with $(...) get the newline stripped for them
# and are unaffected either way; callers redirecting to disk are not, which is
# why this is stated rather than left to whichever printf happened to be used.

# stdin: diff text. stdout: one JSON object. Returns 1 if nothing parsed.
closure_parse() {
  local out
  local raw
  local table
  raw="$(cat)"

  # awk is the last command of this substitution on purpose. A command
  # substitution reports the status of its last command, so awk exiting on an
  # unknown unit is caught right here without the caller having to have set
  # pipefail -- and it must not depend on that, since a caller is free not to,
  # and the tests run this through a plain `bash -c`. Feeding jq from the same
  # pipeline would have hidden that status behind jq succeeding on the partial
  # table awk had already written.
  table="$(
    printf '%s\n' "$raw" \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | awk -F': ' '
        # The one place that knows the units. The patterns below deliberately
        # accept any alphabetic unit and leave the judgement here, so that a
        # unit this cannot convert is impossible to introduce by editing one
        # site and not the other -- there is no other site.
        #
        # Unknown means stop, not zero. A zero is indistinguishable from a
        # package whose size did not move, so a TiB arriving in some future
        # nix would quietly shrink every total that contained one. Exiting
        # non-zero here fails closure_parse as a whole, which is the same
        # treatment any other unparseable input gets.
        function bytes(s,   n, u) {
          n = s; u = s
          sub(/ .*$/, "", n)
          sub(/^[^ ]* /, "", u)
          if (u == "B")   return n
          if (u == "KiB") return n * 1024
          if (u == "MiB") return n * 1024 * 1024
          if (u == "GiB") return n * 1024 * 1024 * 1024
          printf "closure_parse: unknown size unit %s in %s\n", u, $0 > "/dev/stderr"
          exit 1
        }
        NF < 2 { next }
        {
          name = $1
          # Cut where FS already cut, rather than re-finding the separator with
          # a regex that disagrees with it: `foo:bar: 1.0 → 2.0` splits on the
          # `: ` after foo:bar, but /^[^:]*: / would stop at the first colon and
          # leave the rest of the name inside `from`. +3 skips the name plus the
          # two characters of ": ".
          rest = substr($0, length($1) + 3)

          size = 0
          only_size = 0
          # A trailing ", <number> <unit>" is the size field. Anchored at the
          # end so a version containing a space could never be eaten by it.
          # The unit is matched as letters rather than as a list: bytes() is
          # the one place that decides which units exist, and it refuses the
          # ones it cannot convert.
          if (match(rest, /, -?[0-9]+(\.[0-9]+)? [A-Za-z]+$/)) {
            size = bytes(substr(rest, RSTART + 2))
            rest = substr(rest, 1, RSTART - 1)
          } else if (rest ~ /^-?[0-9]+(\.[0-9]+)? [A-Za-z]+$/) {
            # `name: 52.3 KiB` -- same version string, different closure. Here
            # the size is the whole field and there is no comma in front of it,
            # so the branch above never sees it. Measured on the 2026-08-11
            # diff, requiring that comma dropped 2.56 of 8.88 MB across five
            # packages, including the 2.1 MiB of wireplumber.
            #
            # No apostrophes anywhere in this awk program: it is a single-quoted
            # shell string, and one would end it mid-parser.
            size = bytes(rest)
            rest = ""
            only_size = 1
          }

          from = ""; to = ""
          if (index(rest, " → ") > 0) {
            split(rest, halves, " → ")
            from = halves[1]
            to = halves[2]
          } else if (! only_size) {
            # Everything reaching here has a colon and nothing else in common
            # with a diff entry: no arrow, and not a bare size either. A colon
            # alone must not count as parsed, or the guard at the bottom of
            # this file is disarmed by the very thing it watches for -- a
            # `warning:` reaching stdout, or an error message mixed into the
            # output, would be enough to make an otherwise empty result look
            # like a successful parse and report "nothing changed".
            next
          }

          kind = "changed"
          if (from == "∅") { kind = "added"; from = "" }
          else if (to == "∅") { kind = "removed"; to = "" }

          printf "%s\t%s\t%s\t%s\t%.0f\n", kind, name, from, to, size
        }
      '
  )" || return 1

  out="$(
    printf '%s\n' "$table" \
      | jq -R -s '
          split("\n") | map(select(length > 0) | split("\t"))
          | {
              added:   [ .[] | select(.[0] == "added")   | {name: .[1], to: .[3]} ],
              removed: [ .[] | select(.[0] == "removed") | {name: .[1], from: .[2]} ],
              changed: [ .[] | select(.[0] == "changed") | {name: .[1], from: .[2], to: .[3]} ],
              size_delta_mb: ( [ .[] | (.[4] | tonumber) ] | add // 0 | . / 1048576 | . * 100 | round | . / 100 )
            }'
  )" || return 1

  # Empty input is a legitimate empty diff. Non-empty input that yielded
  # nothing is the format having moved under us, and that must not be
  # indistinguishable from "nothing changed".
  #
  # `|| return 1` and not a bare assignment: the callers run under
  # `set -euo pipefail`, so an exploding jq here would take the whole calling
  # script down instead of returning the failure this function promises.
  local parsed
  parsed="$(printf '%s' "$out" | jq -r '(.added | length) + (.removed | length) + (.changed | length)')" \
    || return 1
  if [ "$parsed" -eq 0 ] && [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ]; then
    return 1
  fi

  printf '%s\n' "$out"
}
