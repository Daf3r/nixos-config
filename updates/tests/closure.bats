#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/closure.sh"
  # Every case below drives the function through `run bash -c`, to pin stdin
  # and the exit status independently of the bats shell. A child bash does not
  # inherit shell functions, so it has to be exported -- same as brave.bats
  # and t3code.bats.
  export -f closure_parse
  export -f closure_reboot
  FIX="${BATS_TEST_DIRNAME}/fixtures/diff-closures.txt"
}

@test "closure_parse classifies an addition" {
  run bash -c "closure_parse < '$FIX' | jq -e '.added[] | select(.name==\"somethingnew\") | .to == \"1.2.3\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse classifies a removal" {
  # A removal is the shape that matters most: it is how the 2026-08-11 diff
  # announced that applying would delete dms-shell. If it were misfiled as a
  # change, the panel would show a version bump where a package disappears.
  printf 'gone: 1.0 → \xe2\x88\x85, -1.0 MiB\n' > "$BATS_TMPDIR/one.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/one.txt' | jq -e '.removed[0].name == \"gone\" and .removed[0].from == \"1.0\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse keeps the last comma field as size, not as a version" {
  # `multiver: 1.0, 1.0-fish → 2.0, 2.0-fish, 1.5 MiB` — versions are comma
  # separated and so is the size. Treating the trailing size as a version is
  # the obvious wrong parse.
  run bash -c "closure_parse < '$FIX' | jq -e '.changed[] | select(.name==\"multiver\") | .to == \"2.0, 2.0-fish\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse handles a line with a size and no versions" {
  run bash -c "closure_parse < '$FIX' | jq -e '.changed[] | select(.name==\"kitty\") | .from == \"\" and .to == \"\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse strips the colour codes nix writes around sizes" {
  # The fixture is a verbatim copy of a real /var/lib/nixos-upd/diff.txt, and
  # nix wraps every size in ANSI. Left in, they do two things at once: the
  # size no longer matches at the end of the line so it is counted as 0, and
  # the escape bytes ride into `to` and out to the bar. Nothing else in this
  # file fails when the stripping is removed, which is why this asserts on the
  # raw JSON rather than on one field.
  # Grepped for the escaped spelling jq emits, not for a raw ESC byte: jq
  # escapes control characters on output, so a search for the byte itself
  # would find nothing even against unstripped input and would prove nothing.
  #
  # There is real output before anything is grepped for two reasons. `grep -c`
  # prints 0 and exits 1 on empty input just as it does on output with no
  # match, so a closure_parse that had started failing outright would satisfy
  # a bare "grep found nothing" and this test would go on passing while
  # checking nothing at all.
  run bash -c "closure_parse < '$FIX'"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash -c "closure_parse < '$FIX' | grep -c 'u001b'"
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
  run bash -c "closure_parse < '$FIX' | jq -e '.changed[] | select(.name==\"codex-desktop\") | .to == \"26.803.81509\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse counts the size of a line that has no versions" {
  # `kitty: 51.2 KiB` -- same version string, different closure -- is a real
  # shape and carries a real size. Identifying the size only by a leading
  # comma silently drops every one of them. Measured on the 19 lines of the
  # 2026-08-11 production diff, whose true total is 8.88 MB: five entries of
  # this shape carry 2.56 MB between them, and dropping those made the same
  # diff report 6.33 as though it were the whole delta.
  printf 'kitty: 1024.0 KiB\n' > "$BATS_TMPDIR/nover.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/nover.txt' | jq -e '.size_delta_mb == 1'"
  [ "$status" -eq 0 ]
}

@test "closure_parse totals the whole fixture at 1239.18 MB" {
  # The aggregate, which is where the comma bug actually showed itself. Over
  # the 19 lines copied from the real diff the sum is 8.88, and it was 6.33
  # while the five entries written as a bare size were each counted as zero.
  # The number here is larger because the fixture also carries the three
  # hand-written lines: 8.88 + 1.5 MiB + 1.2 GiB = 1239.18.
  #
  # The synthetic one-line tests above pin the branches; only this pins the
  # sum they feed. It doubles as a tripwire for double counting, and for
  # anyone regenerating the fixture from a later diff.txt -- if this number
  # moves, the input moved with it and the hand-written lines need checking.
  run bash -c "closure_parse < '$FIX' | jq -e '.size_delta_mb == 1239.18'"
  [ "$status" -eq 0 ]
}

@test "closure_parse cuts the name where the field separator did" {
  # No package on this machine is named with a colon, but the two ways this
  # parser located the separator used to disagree, and only one of them was
  # the one awk had already applied. The wrong one leaves the tail of the name
  # sitting inside `from`.
  printf 'foo:bar: 1.0 → 2.0\n' > "$BATS_TMPDIR/colon.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/colon.txt' | jq -e '.changed[0].name == \"foo:bar\" and .changed[0].from == \"1.0\" and .changed[0].to == \"2.0\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse ends its output with a newline" {
  # Stated in the header as part of the contract, so it gets an assertion:
  # `closure_parse > file` has to leave a well-formed text file. bats strips
  # the trailing newline from $output, so this has to look at the byte.
  run bash -c "closure_parse < '$FIX' | tail -c 1 | od -An -c | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" = '\n' ]
}

@test "closure_parse refuses a size unit it does not know instead of counting zero" {
  # The half-edit this guards against: some future nix grows a TiB, whoever
  # meets it teaches the line patterns about the new unit and forgets the
  # conversion. A zero size reads exactly like a package that did not change
  # size, so nothing would ever say the parser had gone half-blind.
  #
  # stderr is redirected inside the bash -c so that $output is stdout alone:
  # the property under test is that nothing is emitted, and a diagnostic
  # landing in $output would hide that.
  printf 'huge: 1.0 → 2.0, 1.0 TiB\n' > "$BATS_TMPDIR/tib.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/tib.txt' 2> '$BATS_TMPDIR/tib-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'TiB' "$BATS_TMPDIR/tib-err.txt"
}

@test "closure_parse refuses the whole diff when a later line has an unknown unit" {
  # The dangerous half of the case above, and the one that says why awk has to
  # be the last command of its substitution. Here the good line is emitted
  # before awk reaches the bad one, so the table is not empty, the entry-count
  # guard at the end is satisfied, and every other signal says success. Only
  # the exit status of awk itself knows the diff was cut short.
  #
  # Reporting the survivors would be worse than reporting nothing: the bar
  # would show a smaller update than the one about to be applied.
  printf 'gcc: 16.1.0 → 16.2.0\nhuge: 1.0 → 2.0, 1.0 TiB\n' > "$BATS_TMPDIR/mixed-tib.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/mixed-tib.txt' 2>/dev/null"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "closure_parse sums sizes across units into MB" {
  printf 'a: 1 → 2, 1.0 MiB\nb: 1 → 2, 1024.0 KiB\nc: 1 → 2, -0.5 MiB\n' > "$BATS_TMPDIR/sizes.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/sizes.txt' | jq -e '.size_delta_mb > 1.49 and .size_delta_mb < 1.51'"
  [ "$status" -eq 0 ]
}

@test "closure_parse refuses input it could not parse at all" {
  # Silence is the failure mode this whole engine exists to remove. If a future
  # nix changes the format, an empty closure_diff would render as "nothing
  # changed" in the bar. It must be an error the caller can turn into a warning.
  printf 'this is not a diff\nnor is this\n' > "$BATS_TMPDIR/junk.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/junk.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "closure_parse refuses a line that merely has a colon in it" {
  # A colon is not a diff entry. Counting one as parsed would disarm the guard
  # above at the worst possible moment: a `warning:` on stdout, or an error
  # message mixed into the output, and the engine would report an empty
  # closure_diff as though nothing had changed.
  printf 'warning: something odd happened\n' > "$BATS_TMPDIR/warn.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/warn.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "closure_parse drops a stray warning without dropping real entries" {
  # The other half of the rule: rejecting the noise must not reject the diff
  # it came wrapped in, and the noise must not surface as an entry named
  # "warning" either.
  printf 'warning: something odd happened\ngcc: 16.1.0 → 16.2.0\n' > "$BATS_TMPDIR/mixed.txt"
  run bash -c "closure_parse < '$BATS_TMPDIR/mixed.txt' | jq -e '(.changed | length) == 1 and .changed[0].name == \"gcc\"'"
  [ "$status" -eq 0 ]
}

@test "closure_parse fails loudly when the guard jq does, instead of returning 0" {
  # The guard at the end of closure.sh runs a second jq, and that call used to
  # be the one external command whose exit status nobody looked at. Measured
  # with this same stub: the failure left `parsed` empty, `[ "" -eq 0 ]` died
  # with "integer expected", the if was therefore false, the guard was skipped
  # and the function returned 0. A false success out of the guard whose whole
  # job is to refuse to report a diff it cannot vouch for.
  #
  # jq is stubbed to work once and fail after that, so the pipeline succeeds
  # and only the guard call breaks. Same trick as status.bats.
  export JQ_CALLS="$BATS_TMPDIR/jq-calls"
  echo 0 > "$JQ_CALLS"
  jq() {
    local n
    n=$(cat "$JQ_CALLS")
    n=$((n + 1))
    echo "$n" > "$JQ_CALLS"
    if [ "$n" -ge 2 ]; then return 1; fi
    command jq "$@"
  }
  export -f jq

  run bash -c "closure_parse < '$FIX'"
  [ "$status" -eq 1 ]
  # The status is half of it. The property that matters is that nothing is
  # emitted: a diff nobody can vouch for must not reach the bar at all. Folded
  # into a single jq call some day, the status alone could go on passing while
  # a partial object was already on stdout.
  [ -z "$output" ]
}

@test "closure_parse on empty input is an empty diff, not an error" {
  run bash -c ": | closure_parse | jq -e '.added == [] and .removed == [] and .changed == [] and .size_delta_mb == 0'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot flags an nvidia driver change" {
  # The 2026-08-11 prepared update: same kernel, nvidia-open 595.84 → 595.91.07.
  # Applying that with `switch` leaves the loaded module out of step with the
  # new userspace libraries until reboot.
  run bash -c "echo '{\"changed\":[{\"name\":\"nvidia-open\",\"from\":\"595.84-7.1.6\",\"to\":\"595.91.07-7.1.6\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == true and (.reboot_reason | index(\"nvidia-open\"))'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot flags a kernel change" {
  run bash -c "echo '{\"changed\":[{\"name\":\"linux-xanmod\",\"from\":\"6.17.12\",\"to\":\"7.1.6\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == true'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot flags mesa" {
  run bash -c "echo '{\"changed\":[{\"name\":\"mesa\",\"from\":\"25.3.1\",\"to\":\"26.2.0\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == true'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot does not flag ordinary userspace" {
  run bash -c "echo '{\"changed\":[{\"name\":\"samba\",\"from\":\"4.23.8\",\"to\":\"4.23.10\"},{\"name\":\"kitty\",\"from\":\"\",\"to\":\"\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == false and (.reboot_reason == [])'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot does not match a package that merely contains a keyword" {
  # `nvidia-settings` is a GUI tool and moves with the driver, but on its own it
  # is not a reason to reboot. Matching on substrings alone would make almost
  # every nvidia update a reboot, and a recommendation that fires every time
  # stops being read.
  #
  # `mesa-demos` is the one that pins that. nvidia-settings alone does not:
  # it contains no watch entry as a substring, so the faithful wrong
  # implementation -- `select($n | contains($w))` over the same full names --
  # still answers false for it and this test survives. `mesa-demos` is a real
  # package on this machine and a supercharged spelling of `mesa`, so it is
  # exactly what a substring rule would swallow. It is a graphics demo suite;
  # it does not touch the running GL stack.
  run bash -c "echo '{\"changed\":[{\"name\":\"nvidia-settings\",\"from\":\"595.84\",\"to\":\"595.91.07\"},{\"name\":\"mesa-demos\",\"from\":\"9.0.0\",\"to\":\"9.0.1\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == false and (.reboot_reason == [])'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot looks at added and removed, not only changed" {
  # Two thirds of the input surface. Collecting only `.changed` left every
  # other test in this file green, so nothing said the other two lists were
  # read at all -- the same hole that let nvidia-x11 be deleted from the watch
  # list unnoticed.
  #
  # Both are real shapes: the 60->65 diff on this machine added mesa-libgbm out
  # of nothing, and turning the proprietary driver off removes nvidia-x11
  # outright. A driver that disappears from the closure is the strongest reboot
  # case there is -- the module is still loaded and its files are about to stop
  # existing.
  run bash -c "echo '{\"changed\":[],\"added\":[{\"name\":\"mesa\",\"to\":\"26.2.0\"}],\"removed\":[{\"name\":\"nvidia-x11\",\"from\":\"595.84\"}]}' | closure_reboot | jq -e '.reboot_recommended == true and (.reboot_reason | sort) == [\"mesa\",\"nvidia-x11\"]'"
  [ "$status" -eq 0 ]
}

@test "closure_reboot refuses empty input instead of staying silent" {
  # Empty stdin makes jq produce no output at all and exit 0. A caller reading
  # a closure_diff that was never written -- the file missing on a first run,
  # or truncated -- would get an empty string and a clean status, and whatever
  # read `.reboot_recommended` out of it would see nothing and carry on. That
  # silence reads as "no reboot needed", which is the direction that hurts:
  # the panel would offer the hot apply for a driver change.
  run bash -c ": | closure_reboot 2> '$BATS_TMPDIR/empty-err.txt'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'closure_reboot' "$BATS_TMPDIR/empty-err.txt"
}

@test "closure_reboot refuses input that is not a closure_diff object" {
  # `null` is the other quiet one: every field lookup on it yields null, the
  # `// []` defaults turn that into empty lists, and the answer comes back as
  # a confident `reboot_recommended: false`. Status is jq's own error code
  # rather than 1, which is why this asserts non-zero and not a number.
  run bash -c "echo null | closure_reboot 2>/dev/null"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "closure_reboot reads what closure_parse writes, on the real diff" {
  # The two functions meet here, over the fixture copied from the 2026-08-11
  # /var/lib/nixos-upd/diff.txt: this is the update actually waiting on this
  # machine, and it must come out as "reboot", since nvidia-open moves.
  #
  # It is also the only case that pins nvidia-x11 and initrd-linux-xanmod. The
  # five cases above cover one list entry each for the kernel, the module and
  # mesa; those two could be deleted from the watch list and nothing else here
  # would notice. Asserting the whole reason list, sorted, rather than just the
  # boolean: the boolean would still be true with either of them gone.
  run bash -c "closure_parse < '$FIX' | closure_reboot | jq -ce '.reboot_recommended == true and (.reboot_reason | sort) == [\"initrd-linux-xanmod\",\"nvidia-open\",\"nvidia-x11\"]'"
  [ "$status" -eq 0 ]
}
