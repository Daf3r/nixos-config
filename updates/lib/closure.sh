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

# stdin: diff text. stdout: one JSON object. Returns 1 if nothing parsed.
closure_parse() {
  local out
  local raw
  raw="$(cat)"
  out="$(
    printf '%s\n' "$raw" \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | awk -F': ' '
        function bytes(s,   n, u) {
          n = s; u = s
          sub(/ .*$/, "", n)
          sub(/^[^ ]* /, "", u)
          if (u == "B")   return n
          if (u == "KiB") return n * 1024
          if (u == "MiB") return n * 1024 * 1024
          if (u == "GiB") return n * 1024 * 1024 * 1024
          return 0
        }
        NF < 2 { next }
        {
          name = $1
          rest = $0
          sub(/^[^:]*: /, "", rest)

          size = 0
          only_size = 0
          # A trailing ", <number> <unit>" is the size field. Anchored at the
          # end so a version containing a space could never be eaten by it.
          if (match(rest, /, -?[0-9]+(\.[0-9]+)? (B|KiB|MiB|GiB)$/)) {
            size = bytes(substr(rest, RSTART + 2))
            rest = substr(rest, 1, RSTART - 1)
          } else if (rest ~ /^-?[0-9]+(\.[0-9]+)? (B|KiB|MiB|GiB)$/) {
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
      ' \
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
  local parsed
  parsed="$(printf '%s' "$out" | jq -r '(.added | length) + (.removed | length) + (.changed | length)')"
  if [ "$parsed" -eq 0 ] && [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ]; then
    return 1
  fi

  printf '%s' "$out"
}
