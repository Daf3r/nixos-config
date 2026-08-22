# Grow the wallpaper collection from wallhaven, one batch at a time.
#
# The rotator in ../wallpaper.nix picks a random file from
# ~/Pictures/Wallpapers every 900s. With 19 files that is the same handful of
# images several times a day, so the fix is more images rather than a cleverer
# rotator. This fetches them.
#
# Every run only downloads what is missing, which is what makes running it again
# next week the way the collection grows. Nothing here is scheduled: it is run
# by hand, on purpose, because a timer quietly filling a disk with 4K images is
# a worse failure than forgetting to run a command.
#
# WHY THE COLOUR FILTER. The desktop is Ayu — #39bae6 cyan, #0f1419 and #1f2430
# backgrounds, #ffb454 amber — and kitty runs at 0.85 opacity with a 24px blur,
# so whatever hangs behind the terminal washes into its background. A saturated
# red wallpaper turns an Ayu terminal warm. wallhaven can filter by dominant
# colour, so the collection is kept coherent at download time instead of being
# corrected later.
#
# The colour list is NOT free-form: wallhaven only accepts values from its own
# fixed palette and silently returns zero results for anything else. Measured on
# 2026-08-22 — `223344` and `336699` both return 0 hits, while the four below
# return between 7.6k and 160k at 2560x1440 or larger. Do not "improve" these to
# the exact Ayu hex values; they will match nothing.
#
# Amber (`996633`, 80k hits) is deliberately not in the default set. It is
# legitimate Ayu, but browns and ochres are exactly what fights the terminal when
# they bleed through the blur. `--warm` adds it for when that is wanted.
{ writeShellApplication, curl, jq, imagemagick, coreutils, findutils, gnused, gnugrep }:

writeShellApplication {
  name = "wallget";
  runtimeInputs = [ curl jq imagemagick coreutils findutils gnused gnugrep ];
  text = ''
    dir="$HOME/Pictures/Wallpapers"
    api="https://wallhaven.cc/api/v1/search"

    # The laptop panel. Anything smaller gets upscaled by the compositor and
    # looks soft on a 2560x1440 screen.
    atleast="2560x1440"

    # `atleast` bounds size, NOT shape, and leaving shape unbounded turned out to
    # be a real mistake rather than a theoretical one: the first test run pulled a
    # 2700x3800 portrait and a 3000x2500 near-square, both of which a 16:9 output
    # can only crop or letterbox. Both screens here are 16:9. 16x10 is included
    # because it crops to 16:9 losing only a strip, and it nearly doubles the pool
    # — 60k against 77k on a sample query. `landscape` was rejected as too loose:
    # it lets 21:9 ultrawides in, and those lose a third of their width.
    ratios="16x9,16x10"

    # wallhaven allows 45 requests per minute. 1.5s between calls leaves room
    # for the downloads themselves, which count against the same budget.
    pause=1.5

    target=40
    warm=false

    for arg in "$@"; do
      case "$arg" in
        --warm) warm=true ;;
        ""|*[!0-9]*)
          echo "uso: wallget [N] [--warm]" >&2
          exit 1
          ;;
        *) target="$arg" ;;
      esac
    done

    colours=(424153 000000 66cccc 0066cc)
    if [ "$warm" = true ]; then
      colours+=(996633)
    fi

    # categories is a three-bit mask: general, anime, people. Anime art lives in
    # its own category rather than behind a search term, which is why it is the
    # only entry here that does not carry a query.
    themes=(
      "010|"
      "100|cyberpunk"
      "100|landscape"
      "100|abstract"
    )

    mkdir -p "$dir"

    # Which ids are already on disk. The existing files are named
    # `wallhaven-1qgwz9_3840x2160.png` and `wallhaven_k7k9j7.jpg` — the
    # resolution suffix and the underscore variant both appear — so the id is
    # matched by pattern instead of by whole filename. Getting this wrong would
    # re-download everything already there on every run.
    #
    # find rather than ls: shellcheck rejects parsing ls output, and a filename
    # with a space in it would split into two bogus ids.
    have=$(find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null |
      grep -oE 'wallhaven[-_][a-zA-Z0-9]{6}' |
      sed -E 's/wallhaven[-_]//' |
      sort -u) || have=""

    count_files() { find "$dir" -maxdepth 1 -type f | wc -l; }

    echo "En la carpeta: $(printf '%s' "$have" | grep -c . || true) de wallhaven, $(count_files) ficheros en total"
    echo "Objetivo: $target nuevos"

    got=0
    seen="$have"

    # One page of one theme+colour pair. Downloads whatever is new until the
    # target is reached, then returns so the caller can stop.
    harvest() {
      local cats="$1" query="$2" colour="$3" page="$4"
      local json

      json=$(curl -sS --max-time 30 -G "$api" \
        --data-urlencode "categories=$cats" \
        --data-urlencode "purity=100" \
        --data-urlencode "atleast=$atleast" \
        --data-urlencode "ratios=$ratios" \
        --data-urlencode "sorting=random" \
        --data-urlencode "colors=$colour" \
        --data-urlencode "q=$query" \
        --data-urlencode "page=$page" 2>/dev/null) || return 0

      sleep "$pause"

      # A rate-limit or error response is valid JSON without .data, so this
      # asks for the field rather than assuming it: `// empty` turns a missing
      # key into no output instead of the string "null".
      local rows
      rows=$(printf '%s' "$json" | jq -r '.data[]? | "\(.id) \(.path)"' 2>/dev/null) || return 0
      [ -n "$rows" ] || return 0

      local id url ext tmp out
      while read -r id url; do
        [ -n "$id" ] || continue
        [ "$got" -ge "$target" ] && return 0

        # printf keeps the id anchored to a whole line; a bare grep would match
        # an id that merely contains this one as a substring.
        printf '%s\n' "$seen" | grep -qx "$id" && continue

        ext="''${url##*.}"
        out="$dir/wallhaven-$id.$ext"
        tmp="$dir/.wallget-$id.part"

        # Downloaded to a dotfile and renamed only on success. The rotator runs
        # every 900s against this same directory, and handing it a half-written
        # JPEG would paint a torn wallpaper.
        if ! curl -sS --max-time 120 -L -o "$tmp" "$url" 2>/dev/null; then
          rm -f "$tmp"
          continue
        fi

        # An HTTP error body is a small file that curl reports as a success.
        # identify is what separates an image from an error page.
        if ! magick identify -ping "$tmp" >/dev/null 2>&1; then
          rm -f "$tmp"
          continue
        fi

        mv "$tmp" "$out"
        seen="$seen"$'\n'"$id"
        got=$((got + 1))
        printf '\r  %d/%d  %s' "$got" "$target" "$id"
      done <<< "$rows"
    }

    # Themes are walked in the outer loop so an interrupted run still leaves a
    # mix rather than 40 images of one subject.
    page=1
    while [ "$got" -lt "$target" ] && [ "$page" -le 12 ]; do
      for theme in "''${themes[@]}"; do
        cats="''${theme%%|*}"
        query="''${theme#*|}"
        for colour in "''${colours[@]}"; do
          [ "$got" -ge "$target" ] && break 3
          harvest "$cats" "$query" "$colour" "$page"
        done
      done
      page=$((page + 1))
    done

    printf '\r%*s\r' 60 ""

    if [ "$got" -eq 0 ]; then
      echo "Nada nuevo. O ya tienes todo lo que dan estos filtros, o no hay red."
      exit 0
    fi

    echo "Bajados $got. Ahora hay $(count_files) ficheros en $dir"
  '';
}
