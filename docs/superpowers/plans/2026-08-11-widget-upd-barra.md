# Apply from the bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the nightly prepared update visible and appliable from the DankMaterialShell bar, with the password prompt DMS already draws, without weakening any guard `upd` enforces today.

**Architecture:** Three layers that fail separately. The engine grows a machine-readable `status.json` (schema 2) and a `upd status --json` subcommand that adds live blockers. A root `nixos-upd-apply@.service` template does the `nh os switch|boot` half, gated by polkit. A DMS plugin in this repository reads the first and starts the second.

**Tech Stack:** bash, bats, jq, awk, nix, systemd, polkit, QML (Quickshell), JavaScript, node --test.

Spec: `docs/superpowers/specs/2026-08-11-widget-upd-barra-design.md`

## Global Constraints

- Target repo: `/home/daf3r/nixos-config`. Flake attribute: `daf3r-starter`.
- **The engine still never writes to `~/nixos-config` and never switches.** `upd apply --ff-only` is the only thing that writes to the repo, it runs as daf3r, and it stops before `nh`.
- All scripts: `set -euo pipefail`. Library files under `updates/lib/` are sourced, carry `# shellcheck shell=bash`, and define functions only.
- The user's shell is **fish**. Every command here is for `bash -c` or `nix run`; never write a bash heredoc into a fish prompt.
- Commits: **no `Co-Authored-By` trailer**, author `Daf3r <87869353+Daf3r@users.noreply.github.com>` (already the repo's git config). Commit messages in Spanish, matching this repo's history; comments in `.nix`, `.sh`, `.qml` and `.js` in English.
- bats: `nix run nixpkgs#bats -- updates/tests/`. The derivation runs the same suite at build time, so a red suite cannot be activated.
- node tests: `nix develop ~/nixos-config#dms-plugins -c node --test updates/dms-plugin/tests/*.test.js`
- Runtime state: `/var/lib/nixos-upd`, owned by daf3r via `StateDirectory=`.
- DMS is pinned to 1.5.3. Plugin manifest ids are camelCase; the directory name is what appears under `~/.config/DankMaterialShell/plugins/`.
- **`nix store diff-closures` has no `--json`** (verified 2026-08-11: `error: unrecognised flag '--json'`). Its human output must be parsed, and its ANSI colour codes stripped first.

---

## File Structure

| File | Responsibility |
|---|---|
| `updates/lib/closure.sh` | **new** — parse `nix store diff-closures` text into `closure_diff` JSON; decide `reboot_recommended` |
| `updates/lib/inputs.sh` | **new** — diff two `flake.lock` files into `changes[]` entries of kind `input` |
| `updates/lib/status.sh` | schema bumped to 2 |
| `updates/bump-brave-origin.sh` | emits a JSON object instead of a prose line |
| `updates/bump-t3code-app.sh` | same |
| `updates/nixos-upd.sh` | composes `changes[]`, `closure_diff`, `reboot_recommended` into the ready body |
| `updates/upd.sh` | `SCHEMA=2`; renders `changes[]`; new `status --json`; `apply` split into `--ff-only` and the unit start |
| `updates.nix` | packages the new lib files; adds `nixos-upd-apply@.service` and the polkit rules |
| `updates/dms-plugin/plugin.json` | manifest, id `nixosUpd` |
| `updates/dms-plugin/logic.js` | pure: parse, classify, choose the button. All unit tests point here |
| `updates/dms-plugin/Daemon.qml` | polls, holds state, watches the apply unit |
| `updates/dms-plugin/Widget.qml` | the bar item |
| `updates/dms-plugin/Popout.qml` | the panel, instantiated from `Widget.qml`'s `popoutContent` — not a surface in `plugin.json` |
| `dms.nix` | declares the plugin with a relative `src` |

---

### Task 1: Parse the closure diff

**Files:**
- Create: `updates/lib/closure.sh`
- Create: `updates/tests/closure.bats`
- Create: `updates/tests/fixtures/diff-closures.txt`

**Interfaces:**
- Produces: `closure_parse` — reads `nix store diff-closures` text on stdin, writes to stdout a JSON object `{added: [{name, to}], removed: [{name, from}], changed: [{name, from, to}], size_delta_mb: <number>}`. Returns 1 and writes nothing if stdin had non-blank lines but none parsed.

- [ ] **Step 1: Capture the fixture from a real run**

The engine has a real diff on disk right now. Copy it verbatim, ANSI codes included — the point of the fixture is that it is not idealised:

```bash
cp /var/lib/nixos-upd/diff.txt updates/tests/fixtures/diff-closures.txt
```

Then append three lines by hand for shapes the current diff does not contain, so the parser is tested against them too:

```
somethingnew: ∅ → 1.2.3
multiver: 1.0, 1.0-fish → 2.0, 2.0-fish, 1.5 MiB
biggrowth: 4.5 → 4.6, 1.2 GiB
```

- [ ] **Step 2: Write the failing test**

`updates/tests/closure.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/closure.sh"
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

@test "closure_parse on empty input is an empty diff, not an error" {
  run bash -c ": | closure_parse | jq -e '.added == [] and .removed == [] and .changed == [] and .size_delta_mb == 0'"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run the tests and watch them fail**

Run: `nix run nixpkgs#bats -- updates/tests/closure.bats`
Expected: every test fails with `closure_parse: command not found`.

- [ ] **Step 4: Implement it**

`updates/lib/closure.sh`:

```bash
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
          # A trailing ", <number> <unit>" is the size field. Anchored at the
          # end so a version containing a space could never be eaten by it.
          if (match(rest, /, -?[0-9]+(\.[0-9]+)? (B|KiB|MiB|GiB)$/)) {
            size = bytes(substr(rest, RSTART + 2))
            rest = substr(rest, 1, RSTART - 1)
          }

          from = ""; to = ""
          if (index(rest, " → ") > 0) {
            split(rest, halves, " → ")
            from = halves[1]
            to = halves[2]
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
```

Note the first line of the function body: stdin is read once into `raw` (`local raw; raw="$(cat)"`) and the pipeline starts from `printf '%s\n' "$raw"`, not from stdin directly. Streaming would make "no input" and "no matches" indistinguishable, which is precisely the distinction the last test demands.

- [ ] **Step 5: Run the whole suite**

Run: `nix run nixpkgs#bats -- updates/tests/`
Expected: all 61 existing tests plus the 7 new ones pass.

- [ ] **Step 6: Commit**

```bash
git add updates/lib/closure.sh updates/tests/closure.bats updates/tests/fixtures/diff-closures.txt
git commit -m "updates: parsear el diff de closures a JSON"
```

---

### Task 2: Decide whether a reboot is needed

**Files:**
- Modify: `updates/lib/closure.sh`
- Modify: `updates/tests/closure.bats`

**Interfaces:**
- Consumes: `closure_parse` output from Task 1.
- Produces: `closure_reboot` — reads a `closure_diff` JSON object on stdin, writes `{reboot_recommended: <bool>, reboot_reason: [<name>, ...]}`.

- [ ] **Step 1: Write the failing tests**

Append to `updates/tests/closure.bats`:

```bash
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
  run bash -c "echo '{\"changed\":[{\"name\":\"nvidia-settings\",\"from\":\"595.84\",\"to\":\"595.91.07\"}],\"added\":[],\"removed\":[]}' | closure_reboot | jq -e '.reboot_recommended == false'"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `nix run nixpkgs#bats -- updates/tests/closure.bats`
Expected: five failures, `closure_reboot: command not found`.

- [ ] **Step 3: Implement**

Append to `updates/lib/closure.sh`:

```bash
# Which packages, when they move, make `nh os switch` the wrong verb.
#
# Exact names, not substrings. `nvidia-open` is the kernel module and matters;
# `nvidia-settings` is a GUI that ships alongside it and does not. A substring
# rule would fire on every nvidia update, and an advisory that always fires is
# an advisory nobody reads. `linux-xanmod` is this machine's kernel — a kernel
# switch elsewhere would need its own entry, which is the honest trade for not
# pattern-matching.
_CLOSURE_REBOOT_PKGS="linux-xanmod initrd-linux-xanmod nvidia-open nvidia-x11 mesa"

# stdin: a closure_diff object. stdout: {reboot_recommended, reboot_reason}.
closure_reboot() {
  jq --arg pkgs "$_CLOSURE_REBOOT_PKGS" '
    ($pkgs | split(" ")) as $watch
    | [ (.changed // [])[], (.added // [])[], (.removed // [])[] ]
    | map(.name) | map(select(. as $n | $watch | index($n)))
    | { reboot_recommended: (length > 0), reboot_reason: . }'
}
```

- [ ] **Step 4: Run the tests**

Run: `nix run nixpkgs#bats -- updates/tests/closure.bats`
Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add updates/lib/closure.sh updates/tests/closure.bats
git commit -m "updates: decidir si la actualizacion pide reinicio"
```

---

### Task 3: Diff two flake.lock files into changes[]

**Files:**
- Create: `updates/lib/inputs.sh`
- Create: `updates/tests/inputs.bats`
- Create: `updates/tests/fixtures/lock-before.json`, `updates/tests/fixtures/lock-after.json`

**Interfaces:**
- Produces: `inputs_diff OLD NEW` — two paths to `flake.lock` files. Writes a JSON array of `{name, kind: "input", from, to}`, one per input whose locked revision moved. `from`/`to` are the 7-character short revs. Inputs present in only one file are skipped.

- [ ] **Step 1: Build the fixtures from this repo's real lock**

```bash
git -C /home/daf3r/nixos-config show c7dec43:flake.lock > updates/tests/fixtures/lock-before.json
cp /home/daf3r/nixos-config/flake.lock updates/tests/fixtures/lock-after.json
```

These two differ by the `dms-plugins` input added on 2026-08-11, which makes the "present in only one file" case real rather than invented.

- [ ] **Step 2: Write the failing test**

`updates/tests/inputs.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../lib/inputs.sh"
  BEFORE="${BATS_TEST_DIRNAME}/fixtures/lock-before.json"
  AFTER="${BATS_TEST_DIRNAME}/fixtures/lock-after.json"
}

@test "inputs_diff reports nothing when both sides are the same file" {
  run bash -c "inputs_diff '$AFTER' '$AFTER' | jq -e '. == []'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff skips an input that exists on only one side" {
  # dms-plugins was added on 2026-08-11. An input that appeared is not an input
  # that moved: reporting it as a change with an empty `from` would put a
  # meaningless row in the panel every time an input is added.
  run bash -c "inputs_diff '$BEFORE' '$AFTER' | jq -e 'map(.name) | index(\"dms-plugins\") | not'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff reports a moved input with short revs" {
  jq '.nodes.nixpkgs_3.locked.rev = "0000000000000000000000000000000000000000"' "$AFTER" > "$BATS_TMPDIR/moved.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/moved.json' | jq -e '.[0].to == \"0000000\" and (.[0].from | length) == 7 and .[0].kind == \"input\"'"
  [ "$status" -eq 0 ]
}

@test "inputs_diff names the input, not the internal node key" {
  # nixpkgs appears in the lock as node `nixpkgs_3` because of follows
  # resolution. A panel that says "nixpkgs_3 moved" is leaking lock internals.
  jq '.nodes.nixpkgs_3.locked.rev = "1111111111111111111111111111111111111111"' "$AFTER" > "$BATS_TMPDIR/moved.json"
  run bash -c "inputs_diff '$AFTER' '$BATS_TMPDIR/moved.json' | jq -e '.[0].name == \"nixpkgs\"'"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 3: Run and watch it fail**

Run: `nix run nixpkgs#bats -- updates/tests/inputs.bats`
Expected: four failures, `inputs_diff: command not found`.

- [ ] **Step 4: Implement**

`updates/lib/inputs.sh`:

```bash
# shellcheck shell=bash
#
# What moved between two flake.lock files.
#
# The engine used to report this as nothing at all: the first real run moved six
# inputs and status.json named none of them. Reading the lock is the reliable
# source — `nix flake update`'s own stdout is prose meant for a human and it
# changes between nix versions.
#
# Node keys are not input names. The root node's `inputs` map holds the real
# names and points at node keys, and follows-resolution routinely produces keys
# like `nixpkgs_3`. This resolves through that map so the reader sees `nixpkgs`.

# $1 old lock, $2 new lock. stdout: JSON array of {name, kind, from, to}.
inputs_diff() {
  jq -n --slurpfile old "$1" --slurpfile new "$2" '
    def revs($lock):
      ($lock.nodes[$lock.root].inputs // {})
      | with_entries(.value = ($lock.nodes[(.value | if type == "array" then .[0] else . end)].locked.rev // ""));

    revs($old[0]) as $o | revs($new[0]) as $n
    | [ $o | keys[]
        | select($n[.] != null and $o[.] != null)
        | select($o[.] != $n[.])
        | select($o[.] != "" and $n[.] != "")
        | {name: ., kind: "input", from: ($o[.][0:7]), to: ($n[.][0:7])} ]'
}
```

- [ ] **Step 5: Run the tests**

Run: `nix run nixpkgs#bats -- updates/tests/inputs.bats`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add updates/lib/inputs.sh updates/tests/inputs.bats updates/tests/fixtures/lock-before.json updates/tests/fixtures/lock-after.json
git commit -m "updates: sacar del lock que inputs se movieron"
```

---

### Task 4: Emit schema 2

**Files:**
- Modify: `updates/bump-brave-origin.sh` (the two `echo` lines at the end)
- Modify: `updates/bump-t3code-app.sh` (same)
- Modify: `updates/lib/status.sh:81`
- Modify: `updates/nixos-upd.sh` (around `:356`, `:500` and the `ready_body` block at `:540`)
- Modify: `updates/upd.sh:43` and the `ready)` arm at `:135`
- Modify: `updates/tests/status.bats`
- Modify: `updates/tests/upd.bats`
- Modify: `updates.nix` (add the two new lib files to the derivation)

**Interfaces:**
- Consumes: `closure_parse`, `closure_reboot` (Task 1, 2), `inputs_diff` (Task 3).
- Produces: `status.json` with `schema: 2`, carrying `changes[]`, `closure_diff`, `reboot_recommended`, `reboot_reason`. `local_pkgs` is gone.

- [ ] **Step 1: Write the failing tests**

In `updates/tests/status.bats`, change every `jq -e '.schema == 1'` to `== 2`. Then append:

```bash
@test "status_write still refuses a body that would forge the envelope" {
  # The envelope must win over the body — unchanged from schema 1, retested
  # because the schema bump touches that exact jq expression.
  status_write "$WORK/s.json" "ready" '{"schema":99,"state":"current"}'
  jq -e '.schema == 2 and .state == "ready"' "$WORK/s.json"
}
```

In `updates/tests/upd.bats`, add:

```bash
@test "upd show refuses a schema 1 status file" {
  # The reader and the engine ship in the same derivation, so the only way
  # these disagree is a stale upd earlier on $PATH. It must say so rather than
  # render a file whose fields it is about to misread.
  echo '{"schema":1,"state":"ready","checked_at":"x","warnings":[]}' > "$STATE_DIR/status.json"
  run upd_main show
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema 1"* ]]
}

@test "upd show lists changes[] instead of local_pkgs" {
  cat > "$STATE_DIR/status.json" <<'JSON'
{"schema":2,"state":"ready","checked_at":"x","warnings":[],"unmanaged":[],
 "branch":"auto/update","build":{"ok":true,"log":"/dev/null"},
 "changes":[{"name":"nixpkgs","kind":"input","from":"abc1234","to":"def5678"}],
 "closure_diff":{"added":[],"removed":[],"changed":[],"size_delta_mb":0},
 "reboot_recommended":false,"reboot_reason":[]}
JSON
  run upd_main show
  [ "$status" -eq 0 ]
  [[ "$output" == *"nixpkgs"* ]]
  [[ "$output" == *"abc1234"* ]]
}

@test "upd show announces a recommended reboot" {
  cat > "$STATE_DIR/status.json" <<'JSON'
{"schema":2,"state":"ready","checked_at":"x","warnings":[],"unmanaged":[],
 "branch":"auto/update","build":{"ok":true,"log":"/dev/null"},"changes":[],
 "closure_diff":{"added":[],"removed":[],"changed":[],"size_delta_mb":0},
 "reboot_recommended":true,"reboot_reason":["nvidia-open"]}
JSON
  run upd_main show
  [[ "$output" == *"nvidia-open"* ]]
  [[ "$output" == *"reinicio"* ]]
}
```

If `upd.bats` does not already expose the script as `upd_main` with a settable `STATE_DIR`, match whatever harness the existing tests in that file use — read it first and follow it rather than introducing a second style.

- [ ] **Step 2: Run and watch them fail**

Run: `nix run nixpkgs#bats -- updates/tests/`
Expected: the schema assertions and the three new `upd` tests fail; everything else passes.

- [ ] **Step 3: Bump the schema**

`updates/lib/status.sh:81`, in the `jq -n` envelope: `{schema: 1, ...}` becomes `{schema: 2, ...}`. Update the comment block at the top of the file, which currently says the reader is "a future reader (the phase-2 Noctalia bar plugin)" — it is now the DMS plugin in `updates/dms-plugin/`.

`updates/upd.sh:43`: `SCHEMA=2`.

- [ ] **Step 4: Make the bump scripts emit JSON**

In `updates/bump-t3code-app.sh`, replace the two `echo` lines:

```bash
# was: echo "t3code-app $current (current)"
jq -nc --arg f "$current" --arg t "$current" \
  '{name: "t3code-app", kind: "local_pkg", from: $f, to: $t}'
exit 0
```

```bash
# was: echo "t3code-app $current -> $latest"
jq -nc --arg f "$current" --arg t "$latest" \
  '{name: "t3code-app", kind: "local_pkg", from: $f, to: $t}'
```

Do the same in `updates/bump-brave-origin.sh` with `"brave-origin"`. A package that is already current reports `from == to`; the reader treats that as "no change" rather than needing a separate flag.

- [ ] **Step 5: Compose the new body**

In `updates/nixos-upd.sh`:

At `:356` and `:360`, the failure fallbacks currently assign prose. They become JSON objects so the body is uniform even when a bump fails:

```bash
if ! brave_json="$(LIB_DIR="$LIB_DIR" bash "$SELF_DIR/bump-brave-origin.sh" --repo "$WT" 2>>"$LOG")"; then
  brave_json='{"name":"brave-origin","kind":"local_pkg","from":"","to":"","error":"bump failed"}'
  warn brave_bump_failed "bump-brave-origin.sh failed; see $LOG"
fi
```

Same shape for t3code. Note this adds a `warn` call that the prose version did not have — a failed bump was previously visible only as the words "(bump failed)" inside a string.

Before the flake update runs, save the old lock so Task 3's function has something to compare against. Add right after the clone is in place:

```bash
cp "$WT/flake.lock" "$STATE_DIR/lock.before" 2>>"$LOG" \
  || warn lock_snapshot_failed "could not snapshot flake.lock; the input change list will be empty"
```

After the diff at `:500`, add the parse:

```bash
closure_json='{"added":[],"removed":[],"changed":[],"size_delta_mb":0}'
if ! closure_json="$(printf '%s\n' "$diff_txt" | closure_parse)"; then
  warn closure_parse_failed "could not parse the closure diff; the change list will be empty. nix store diff-closures may have changed format"
  closure_json='{"added":[],"removed":[],"changed":[],"size_delta_mb":0}'
fi
reboot_json="$(printf '%s' "$closure_json" | closure_reboot)"

inputs_json='[]'
if [ -f "$STATE_DIR/lock.before" ]; then
  inputs_json="$(inputs_diff "$STATE_DIR/lock.before" "$WT/flake.lock")" || inputs_json='[]'
fi
```

Then replace the `ready_body` block at `:540`:

```bash
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
```

Source the new libraries wherever the existing `lib/*.sh` are sourced near the top of the file.

- [ ] **Step 6: Render it in `upd show`**

In `updates/upd.sh`, the `ready)` arm replaces the `local_pkgs` line:

```bash
      ready)
        echo "hay una actualizacion preparada en la rama $(jq -r '.branch // "auto/update"' "$STATUS")"
        jq -r '.changes[]? | select(.from != .to)
               | "  " + .name + " " + (if .from == "" then "(nuevo)" else .from end)
                 + " -> " + (if .to == "" then "(fuera)" else .to end)' "$STATUS"
        jq -r '.closure_diff? | select(. != null)
               | "  " + ((.changed | length) | tostring) + " paquetes cambian, "
                 + ((.added | length) | tostring) + " entran, "
                 + ((.removed | length) | tostring) + " salen ("
                 + (.size_delta_mb | tostring) + " MB)"' "$STATUS"
        if [ "$(jq -r '.reboot_recommended // false' "$STATUS")" = "true" ]; then
          echo
          echo "  ESTO PIDE REINICIO: $(jq -r '.reboot_reason | join(", ")' "$STATUS")"
          echo "  aplicar con \`upd apply --boot\` y reiniciar, no con switch en caliente."
        fi
        print_unmanaged
        ;;
```

- [ ] **Step 7: Package the new files**

In `updates.nix`, the derivation copies `updates/lib/*.sh` into the store. Read the `installPhase` and confirm whether it globs or lists files individually. If it lists them, add `closure.sh` and `inputs.sh`. If it globs, verify with:

```bash
nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel --no-link 2>&1 | tail -5
bash -c 'ls $(dirname $(readlink -f $(which nixos-upd)))/../lib/' 2>/dev/null || true
```

The suite runs inside the build, so a missing library file fails the build rather than failing at 07:32 tomorrow.

- [ ] **Step 8: Run everything**

Run: `nix run nixpkgs#bats -- updates/tests/`
Expected: PASS, all tests.

- [ ] **Step 9: Run the engine for real and read its output**

```bash
upd check && upd show && jq '.schema, .changes, .reboot_recommended' /var/lib/nixos-upd/status.json
```

Expected: `schema` is 2, `changes` is a non-empty array of objects, `reboot_recommended` is `true` (the prepared update moves `nvidia-open`, verified 2026-08-11). A test cannot catch a real-format surprise; this step is what does.

- [ ] **Step 10: Commit**

```bash
git add updates/ updates.nix
git commit -m "updates: status.json pasa a schema 2, con los cambios en estructura"
```

---

### Task 5: `upd status --json` — done in `c53dc4d`, revised in `ee4ebd3`

> **This section was rewritten after the fact**, in the second review round, and
> now describes what is in the tree rather than what was designed. Six things
> came out different, each of them measured against the machine before it was
> changed rather than argued; the evidence is in
> `.superpowers/sdd/2026-08-11-widget-upd-barra/task-5-report.md`.
>
> It is written this way because the previous version of this section was about
> to do damage: Task 6 is written by reading this file, and until this edit the
> code block below still said `_UPD_BOOTED_SYSTEM`, a name that was deliberately
> retired. The source of truth is `updates/upd.sh:267-394`; what follows is what
> Task 6 and the plugin tasks need in order not to reintroduce any of it.

**Files:**
- Modified: `updates/upd.sh` (new `status` arm in the `case "$cmd"` block, between `show)` and `diff)`)
- Modified: `updates/tests/upd.bats`

**Interfaces:**
- Produces: `upd status --json` on stdout — the `status.json` object **exactly as the engine wrote it**, plus `blockers: [{code, detail}]`. No filtering of any kind: `show` drops the `from == to` rows out of `changes[]` because a human does not need them, this arm does not, because the consumer counts and groups on its own and two differently-filtered readings of one file is how the two come to disagree.
- Exit 0 whenever there is an object to emit, blockers and all. Exit 1 when there is none — a status file that is missing, unparseable, or of a schema this reader does not understand — and in that case **stdout is empty and the refusal goes to stderr**. That pairing is the contract: it is what lets a consumer tell "nothing to apply" from "no answer", and a half-built object would be read as the first.
- `upd status` takes `--json` and nothing else. Both a missing and an extra argument are refused, for the reason `apply --boot` was refused in Task 3: an option accepted and ignored is indistinguishable from an option that worked.

**The blocker vocabulary** — six codes, not the four the design named:

| `code` | When |
|---|---|
| `dirty_tree` | `$REPO` has uncommitted or untracked changes |
| `wrong_branch` | `$REPO` is on a branch other than `$BRANCH`, or on a detached HEAD |
| `engine_running` | the engine holds `$STATE_DIR/lock` right now |
| `pending_reboot` | the system profile and `/run/current-system` are different generations, **in either direction** |
| `lock_uncheckable` | the lock could not be opened at all, or `flock` is missing — *not* the same as the engine holding it |
| `repo_uncheckable` | `$REPO` could not be opened as a git repository, **or git could not read all of its work tree**, **or its warnings could not be captured**, or `git` is missing |

Consumers must treat an **unknown** `code` as a blocker and render its `detail`, never as noise to skip: this vocabulary grew by two during implementation and can grow again. The logic sketched for Task 8 already does the right thing (any blocker disables the button, the reason is the `detail`s joined); what must not appear is a `switch` on `code` whose `default` shows nothing.

**What differs from the original design, and why**

1. **The `flock` block has three outcomes, not two.** The single `if ! (exec 9>"$STATE_DIR/lock" && flock -n 9)` cannot tell "the engine holds it" from "I could not open it at all", and answers the first for both. Measured with a non-existent `$STATE_DIR` and again with a read-only one: `engine_running`, both times. That state is permanent — a lock file left owned by root after a change of `User=` in the unit is the live way to reach it — so the panel would keep a dead button for ever, blaming a check that is not running. `apply` already separates the two cases (`updates/upd.sh:451-456`); so does this.
2. **A guard in front of the two git calls.** Both fail silently in the same way: `git status` in a directory that is not a repository prints nothing on stdout, which reads as a clean tree, and `symbolic-ref` failing there is indistinguishable from a real detached HEAD. Two confident statements about a repository that was never opened, the second of which sends the reader off to `git switch` something that does not exist.
3. **`$#` is validated, not just `$2`.** See the interface note above.
4. **`_UPD_SYSTEM_PROFILE`, not `_UPD_BOOTED_SYSTEM`.** `/nix/var/nix/profiles/system` is the *profile*; NixOS spells the booted system `/run/booted-system`. The old name is a trap with a concrete cost: whoever aligns the default with the name ends up comparing `/run/booted-system` against `/run/current-system`, which differ after any plain switch onto a new kernel, and turns the blocker into a permanent one for a condition `reboot_recommended` already reports from the closure diff. **`_UPD_CURRENT_SYSTEM` keeps its name** — that one is exact. Neither variable is set by anything but the tests.
5. **`pending_reboot`'s `detail` names the disagreement, not a direction.** `nixos-rebuild test` and `nh os test` activate without writing the profile, leaving it on the *older* generation while `/run/current-system` is on the newer one — the same inequality with the opposite sign. Blocking is right for both; "there is a generation staged for the next boot" is false for one of them. The code keeps its name (it is the dominant case and it is interface for Tasks 8-10); only the wording is neutral.
6. **There is no `--help` in `upd.sh`.** The original Step 3 said to add `status` "to the usage text in the `*)` arm and to the `--help` output". The second does not exist: `upd --help` falls into `*)`, prints the usage and exits 1. There is one text, and it is the one that was edited. Adding a real `--help` with exit 0 would be an interface change nobody asked for.

- [ ] **Step 1: Write the failing tests**

Fifteen of them, in a `--- status --json ---` section of `updates/tests/upd.bats` (`:394-630`). Rather than reproduce them here — a copy in this file is a copy that goes stale, which is what this whole section is a correction of — what matters for the tasks that come after:

- The harness is **`upd_status`** (`updates/tests/upd.bats:123-128`), a sibling of the file's existing `upd` helper. Not `upd_main`, which this plan invented and which `upd.bats` has never had; the note under Task 4 already says to follow the file's own style, and that is what was done.
- It pins the two system paths through **`env`**, not through an assignment prefix in front of `run`. The prefix does reach the child — measured, it works through bash's rule that temporary assignments to a *function* call are exported for its duration — but `env` says so without depending on it, and it is the form the file already uses for `BRANCH`.
- It sets **`GIT_CEILING_DIRECTORIES="$WORK"`**. `rev-parse --is-inside-work-tree` walks up the parents, so a `$TMPDIR` inside a git repository would make the `repo_uncheckable` test assert the opposite of what it names. Verified by building that scenario on purpose: with the ceiling green, without it red.
- The refusal test uses **`run --separate-stderr`** and asserts `[ -z "$output" ]`. A bare `run` merges the two streams, so an assertion about "nothing on stdout" made on `$output` really only says the *concatenation* does not parse — measured: with `jq -n '{blockers:[]}'` inserted before `require_readable_status`, stdout carried the half-object and the test stayed green. **Do not "fix" this to `[ -z "$stdout" ]`**: `run --separate-stderr` defines `$output` and `$stderr` and no `$stdout` at all, so that assertion passes on an undefined variable, always. The file declares `bats_require_minimum_version 1.5.0` for the flag.
- Both directions of `pending_reboot` have a test. One of them would pass on a `detail` that branches by direction; the pair does not.

- [ ] **Step 2: Run and watch them fail**

Run: `nix run nixpkgs#bats -- tests/` from `updates/`
Observed: fourteen failures (the fifteenth test arrived with the review round), the rest of the suite untouched — `upd` prints its usage and exits 1 on the unknown `status` command.

- [ ] **Step 3: Implement**

`updates/upd.sh:267-394`, added before the `*)` arm. Read it there rather than from a copy. Its shape, in order: argument validation → `[ -f "$STATUS" ]` → `require_readable_status` → `blockers='[]'` and a jq-based `add_blocker` → the git guard and the two live git facts → the three-way lock check → the profile comparison → `jq --argjson b "$blockers" '. + {blockers: $b}' "$STATUS"`.

Also add `status` to the usage text in the `*)` arm (`updates/upd.sh:605-613`), and extend the exit-code taxonomy in the file header (`:27-38`) — a dirty tree is exit 1 when it stops an `apply` and exit 0 with a `blockers[]` entry when `status --json` reports it, and the header said only the first.

One invariant this arm depends on and now states in place (`updates/upd.sh:340-349`): **`$STATE_DIR/lock` carries no content.** Both probes open it for writing, which truncates it, and this is the one subcommand a panel will poll on a timer. If the lock ever has to carry a PID or a timestamp, it needs a second file.

- [ ] **Step 4: Run the tests**

`nix run nixpkgs#bats -- tests/` → 135 ok, 0 not ok. `shellcheck -x -- *.sh lib/*.sh` → empty.
Beyond the suite: every test was checked counterfactually, by breaking the production line it claims to cover on a copy outside the repository and confirming it goes red — 18 mutations, 18 killed. Two of those mutations restore this plan's original `flock` block and its missing repository guard, so a later "simplification" back to the design turns the suite red at the exact spot.

- [ ] **Step 5: Verify against the live machine**

**Not** `upd status --json` from `$PATH`: that binary is the installed one, built before this change, and it does not know the subcommand. Until a `nh os switch` it has to be the script from the checkout, with the variables the store wrapper supplies:

```bash
env REPO=/home/daf3r/nixos-config BRANCH=main STATE_DIR=/var/lib/nixos-upd \
    LIB_DIR=/home/daf3r/nixos-config/updates/lib \
    bash updates/upd.sh status --json | jq '{state, reboot_recommended, blockers}'
```

And `blockers` is **not** `[]` on a working branch: the engine prepares from `main`, so `wrong_branch` is the correct answer and the sign that it works. Both were run — with `BRANCH=main` the two real blockers appear (`dirty_tree`, `wrong_branch`) and with `BRANCH=upd-barra` on a clean tree the list is empty, exit 0 in both cases, against the real schema-2 `status.json`.

- [ ] **Step 6: Commit**

```bash
git add updates/upd.sh updates/tests/upd.bats
git commit -m "upd: subcomando status --json con los bloqueos en vivo"
```

Explicit paths, never `git add -A`: there is an untracked file from another session in this tree.

---

### Task 5b: extract the blocker calculation to `updates/lib/` — done

> **Added to this plan in the same commit that did the work** — the one that
> adds `updates/lib/blockers.sh` — and deliberately not folded into Task 6. daf3r decided the order: extract first, rewrite `apply` second. A task
> that extracts and rewrites at once leaves nobody able to say which of the two
> broke something when something breaks — and the two touch the same file.
>
> The other half of the reason is that extracting *after* Task 6 would mean
> touching `apply` twice: once to split it, once again when the neighbouring arm
> moves out from under it. This way Task 6 opens a file where `status` is nine
> lines and a function call, and nothing it does to `apply` can disturb the
> blocker logic by accident.

**Files:**
- Added: `updates/lib/blockers.sh`
- Modified: `updates/upd.sh` (the `status)` arm shrinks; `LIB_DIR` and one `source` at the top)
- Added: `updates/tests/blockers.bats` (review rounds: the clauses of the contract the end-to-end tests cannot reach)
- Modified: `updates/tests/upd.bats` — **one test added**, none changed; see Step 2
- Not modified: `updates.nix` — verified against the store, not by reading it

**Interfaces:**
- Produces: `blockers_live REPO BRANCH LOCK SYSTEM_PROFILE RUNNING_SYSTEM` — a JSON array of `{code, detail}` on stdout, `[]` when nothing is in the way. An error it can *foresee* is itself a blocker rather than a failure, because "I could not check" and "there is nothing to report" are different answers and the panel must not confuse them. Not an unconditional zero, but for a narrower reason than this said for one round: **errexit does not act inside a command substitution that is part of an assignment**, which is how it is called, so a failure in the middle of it never aborted anything — only the status of the last command, the `jq`, reaches the caller, and `upd.sh` turns that into its documented "exit 1, empty stdout, no answer" with a `|| die`. Every other foreseeable failure, `$TMPDIR` included, has a branch of its own and comes back as a blocker. Nothing is written to stderr on any path — checked by a test, not intended.
- Consumes: nothing. It reads no globals and no environment; the five things it needs are its five arguments. That is the point of the boundary — the caller owns *this machine's* layout (where the repository is, where the lock lives, which two system paths mean "profile" and "running system"), and the function owns the question "what would stop an apply?".
- The defaults for the two system paths stay in `upd.sh` (`:305-307`) along with the `_UPD_SYSTEM_PROFILE` / `_UPD_CURRENT_SYSTEM` overrides the tests use. They are facts about NixOS's layout, not about the question.

**Why this piece and not another:** it is the only part of the `status` arm that can be named in a sentence and asked a question. What is left in the arm is the shape of a subcommand — which arguments it accepts, which file it reads, what it prints — and that is inseparable from `upd.sh` by definition.

**It is a refactor: no behaviour changes.** The net is the 135 tests that already existed.

- [x] **Step 1: Move it**

`updates/upd.sh:292-386` (as it stood at `ee4ebd3`) becomes `blockers_live` in `updates/lib/blockers.sh`, with `$REPO`/`$BRANCH`/`$STATE_DIR/lock` and the two resolved system paths as parameters instead of globals. The `add_blocker` helper does not survive the move: instead of growing a JSON string one `jq` call per blocker, the function accumulates flat `code, detail` pairs in a bash array and makes **one** `jq -n --args … -- "${found[@]}"` call at the end. One process instead of N, and the same escaping guarantee for quotes, backslashes, newlines, `$`, backticks, unicode and embedded JSON — **but only with the `--`**, which the first version of this section claimed was unnecessary and the review disproved. jq keeps parsing options after `--args`, so a value beginning with a dash was read as one: measured, `--json` and `-x` exit 2, and `--args` is accepted and yields `detail: null`. Reachable through a `$repo` whose name starts with a dash, which `git -C` accepts.

`updates/upd.sh` gains the `LIB_DIR` resolution and the `source` that the other three entry points already have (`:51-57`), sourced unconditionally like they do: the file only defines functions.

- [x] **Step 2: Run the suite without touching it**

`nix run nixpkgs#bats -- tests/` from `updates/` → 135 ok, 0 not ok at the move itself; 144 after two review rounds added nine. `shellcheck -x -- *.sh lib/*.sh` → empty.

**No existing test was modified, at any point.** That is the acceptance criterion for the move and not merely an outcome: the 15 `status --json` tests drive the subcommand, never the internals, so a move that needed a test edited would have been a move that changed behaviour. Nothing in `upd.bats` names `add_blocker` or `blockers_live`. The tests *added* afterwards are a different matter and are listed in Step 5.

- [x] **Step 3: Re-run the mutations on the extracted code**

A refactor that leaves a mutant alive that used to die has lost coverage without the suite noticing, so all 18 mutations from Task 5 were re-pointed at the file each line now lives in and re-run, plus two new ones on the boundary the refactor creates (the five-argument call): swapping `$REPO` and `$BRANCH`, and passing `$STATE_DIR` where the lock file goes. 20 mutations, 20 killed — and 28 after Steps 5 and 6. Intentionally *not* included: swapping the profile and the running system, which is a **equivalent mutant** (the comparison is `!=`, so it is unobservable).

- [x] **Step 4: Prove the new file reaches the store**

`updates.nix` copies `./lib` wholesale, so in principle nothing there needs editing — but "in principle" is what this repository has been caught by before, so it was checked against the store and not by reading the `.nix`:

```
$ ls $out/libexec/nixos-upd/lib/
blockers.sh  brave.sh  closure.sh  inputs.sh  nixpin.sh  status.sh  t3code.sh
$ $out/bin/upd status --json | jq -c '{state, blockers: [.blockers[].code]}'
{"state":"ready","blockers":["dirty_tree","wrong_branch"]}
```

And `git add` before believing any of it: flake evaluation only sees tracked files, so a new file left untracked is a green build over a file that was never there.

- [x] **Step 5: The review round**

Three findings, all of them the same shape as the ones Task 5 kept closing — a check that cannot conclude being reported as a clean result — plus the documentation that had drifted:

1. **`jq` and the leading dash**, above. Fixed with `--`, verified over the five failing cases, the normal case and everything that already worked.
2. **The header promised two things the code did not do.** "Nothing to stderr" was false (`git status`'s warnings went straight through) and "never fails" was false (finding 1). Both are now stated in the form they can be kept, and both are tested.
3. **`git status` failing read as "clean tree"** — the third copy of the defect the `flock` arm and the repository guard had already closed. In a work tree git cannot fully read (a directory the user cannot open) it warns on stderr, **exits 0, and prints nothing on stdout**, so `[ -n "$(…)" ]` was false and no `dirty_tree` was reported. It now answers `repo_uncheckable`, which is why that row grew in Task 5's table above.

`updates/tests/blockers.bats` exists for the clauses the end-to-end suite cannot reach: an argument beginning with a dash, and stderr staying empty. Everything else stays in `upd.bats` — duplicating it would mean two places to update and one of them drifting. One test was added to `upd.bats` for the `|| die` seam, injected through `$LIB_DIR` the way `nixos-upd.bats` already stubs `closure_reboot`; without it the guard would be code nobody ever ran, which this repository has a commit about.

- [x] **Step 6: The second review round**

One finding, and it is the same header again: with an unwritable `$TMPDIR` the function broke all three of its own clauses at once — `mktemp` leaked its complaint to stderr plus two more from bash behind it, and the function returned 0 while the header claimed that case propagated. The *verdict* was right (`repo_uncheckable`, because the redirection failed and git never ran) but right by accident. `mktemp` is now silenced and has its own branch, with a test asserting all three promises: empty stderr, exit 0, and a blocker rather than silence.

The cause is worth carrying into Task 6: **errexit does not act inside a command substitution that is part of an assignment**. Measured on bash 5.3.15. Nothing in `blockers_live` was ever being aborted by `set -e`, which is why every failure it can foresee has an explicit branch — and why `apply`, which is written in the same style, should not assume otherwise either.

Two smaller things from the same round: `tr … | head -c 200` was a race under `pipefail`, not a pipeline (`head` exits at its 200th byte and `tr` takes a SIGPIPE — reproduced at 1 failure in 10 identical runs over 64 KB), replaced by expansions that also spawn nothing in the path the panel polls; and `blockers.bats` now sets `set -euo pipefail` in its `setup`, so the library is measured in the shell it actually runs in.

**What Task 6 inherits:** an `apply` arm nothing else in this file reaches into, and a `status` arm that is nine lines and a call. The two can now be worked on at the same time without colliding. If Task 6 needs a blocker of its own — say, `apply --boot` wanting to refuse when a generation is already staged — the place to add it is `blockers_live`, and its `detail` should be written for a human reading it off a panel, because that is where it will end up.

---

### Task 6: Split `apply` into its two halves — done

> Rewritten after the fact, like Task 5's section above it, and for the same
> reason: the source of truth is the tree, and a copy of the code in this file
> is a copy that goes stale. What follows is the shape of what landed and the
> decisions that are not visible in a diff. `updates/upd.sh`, the `apply)` arm.

**Files:**
- Modified: `updates/upd.sh` — the `apply)` arm, **and the `ready)` advisory and its footer in `show`**, which the brief did not list. See below.
- Modified: `updates/tests/upd.bats`

**Interfaces:**
- `upd apply` — unchanged: guards, fast-forward, `nh os switch`.
- `upd apply --boot` — the same with `nh os boot`, which writes the profile and leaves `/run/current-system` alone. This is what the reboot advisory now tells people to type, and what `status --json` reports as `pending_reboot` afterwards.
- `upd apply --ff-only` — every guard, plus the fast-forward, and then stops without calling `nh`. Exit 0 and a line saying what it did and did not do.
- One mode at a time, from a closed list. `--ff`, `--frobnicate` and `--boot --ff-only` are all refused, naming what arrived.

**Why `--ff-only` exists at all:** the bar plugin's work is split by *who runs it*. The repository half must run as daf3r — a merge done as root leaves root-owned objects in `.git` and breaks the next commit made by hand — and the activation half is a root systemd unit started separately. `--ff-only` is the first of those two, and it is the reason the `nh` preflight is skipped in that mode: demanding a tool the run will never invoke would refuse exactly where the mode is meant to be used.

**Three things the brief did not have**

1. **The `ready)` advisory had to move back to `--boot`, in this same commit.** Task 4 removed the flag from that advice *because* it did not exist: `apply` accepted `--boot`, ignored it, and activated hot, so the warning against hot activation was sending people into it. Leaving the advice as it was now that the flag works would be the same defect inverted. The rule both rounds are instances of: **advice may name a flag exactly as long as the flag behaves, and the two move in the same commit.**
2. **The footer under it had to move too**, which only showed up by running the thing: the advisory said `upd apply --boot` and four lines below `aplicar: upd apply` printed on the same screen — two instructions, the contradictory one last. It is now conditional on the same `reboot_recommended` the advisory reads.
3. **`state="$(jq -r '.state …')"` had no `|| …` guard** while the six assignments below it do. At the top level errexit *does* act, so a failing jq killed `apply` with jq's status and jq's message — measured at exit 5, with no line of upd.sh's own. It now `die`s. Not `|| state=""` like its neighbours: that falls into the branch below and says "no hay ninguna actualizacion lista (estado: )", which names the wrong problem.

**Testing notes**

- The suite already stubs `nh` through `$NH_MARKER`; the brief's `$BATS_TMPDIR/nh-was-called` would have been a second mechanism, and the brief itself says not to add one.
- **Two existing tests were inverted**, both of which had predicted their own inversion in a comment: the `--boot` half of "apply refuses an argument it does not know" (its `--frobnicate` half stays, and is what keeps the guard covered across the change), and the `!= "--boot"` assertion in the reboot advisory test.
- A test that asserts a tool is missing **cannot get there by deleting the stub**: removing `$WORK/bin/nh` only uncovers the machine's real `nh` further down `$PATH`. Measured — the first version of that test fast-forwarded the throwaway repository and then ran the real `nh os switch` on it. It now builds a `$PATH` containing everything `apply` uses except `nh`, and asserts that premise before relying on it.
- 17 mutations, 17 killed. **One survived first**: with the footer also naming `--boot`, deleting the flag from the advisory left the advisory's test green, because the assertion looked for `--boot` anywhere in the output. Two places that can satisfy one assertion means it covers neither; it is now anchored to the advisory's own sentence.

**What Task 7 inherits:** `upd apply --ff-only`, which is the repository half of what the root unit will complete, and an `apply` whose mode is parsed once at the top and used in exactly one place at the bottom.

---

### Task 7: The root unit and the polkit rules

**Files:**
- Modify: `updates.nix`

**Interfaces:**
- Produces: `nixos-upd-apply@switch.service` and `nixos-upd-apply@boot.service`, startable by daf3r with a password prompt. `nixos-upd.service` startable by daf3r with no prompt.

- [ ] **Step 1: Add the unit**

In `updates.nix`, alongside the existing `systemd.services.nixos-upd`:

```nix
  # The root half of an apply. It does one thing: activate. The git
  # fast-forward has already happened, as daf3r, via `upd apply --ff-only` --
  # if root did the merge, .git would end up with root-owned objects and the
  # user's next commit would fail.
  #
  # A unit rather than a child of the shell, so a `dms restart` in the middle of
  # a twenty-minute switch does not orphan it and its result stays queryable
  # afterwards. Instance name is the nh verb, and nothing else is accepted.
  systemd.services."nixos-upd-apply@" = {
    description = "Apply the prepared system update (%i)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "nixos-upd-apply" ''
        set -euo pipefail
        case "$1" in
          switch|boot) ;;
          *) echo "nixos-upd-apply: unknown mode '$1'" >&2; exit 1 ;;
        esac
        exec ${pkgs.nh}/bin/nh os "$1" /home/daf3r/nixos-config
      ''} %i";
      # nh shells out to nix, which needs these on a system unit's minimal PATH.
      Environment = "PATH=/run/current-system/sw/bin:/run/wrappers/bin";
    };
  };
```

Verify the `nh` attribute name against the pinned nixpkgs before building — if `pkgs.nh` does not exist under that name the build fails loudly, which is the desired failure.

- [ ] **Step 2: Add the polkit rules**

```nix
  # Two levels on purpose.
  #
  # The check only builds -- it can never change the running system -- so
  # demanding a password for it is friction with nothing bought. The apply gets
  # auth_admin every time, and deliberately NOT auth_admin_keep: a five-minute
  # grace period on the one action that changes the system is exactly what we do
  # not want.
  #
  # A polkit rule can be syntactically fine and silently authorise nothing --
  # that already happened on this machine with gamemode. The acceptance test is
  # starting the unit and seeing the prompt, not reading this block.
  security.polkit.extraConfig = '''
    polkit.addRule(function(action, subject) {
      if (action.id != "org.freedesktop.systemd1.manage-units") return undefined;
      if (subject.user != "daf3r") return undefined;
      var unit = action.lookup("unit");
      if (unit == "nixos-upd.service") return polkit.Result.YES;
      if (unit == "nixos-upd-apply@switch.service" ||
          unit == "nixos-upd-apply@boot.service") return polkit.Result.AUTH_ADMIN;
      return undefined;
    });
  ''';
```

(The `'''` above is this document's quoting; in the `.nix` file use Nix's `''` string delimiters.)

- [ ] **Step 3: Build**

Run: `nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel --no-link`
Expected: builds. A red bats suite or a missing `pkgs.nh` stops it here.

- [ ] **Step 4: Apply and verify by hand — this is the acceptance test**

The switch must be run by daf3r (needs root):

```bash
nh os switch ~/nixos-config
```

Then, with the graphical session running:

```bash
systemctl start nixos-upd.service
```

Expected: **no prompt**, the unit runs, `systemctl status nixos-upd.service` shows it executed.

```bash
systemctl start nixos-upd-apply@boot.service
```

Expected: the **DMS polkit modal appears** asking for a password. Cancel it. Confirm with `systemctl is-active nixos-upd-apply@boot.service` that it did not run, and that `readlink /nix/var/nix/profiles/system` is unchanged.

If no modal appears, the rule did not take effect — check `journalctl -u polkit -b` and do not proceed to Task 8 until it does. A silently-ineffective polkit rule is the known failure mode here.

- [ ] **Step 5: Commit**

```bash
git add updates.nix
git commit -m "updates: unidad de apply con root y reglas polkit acotadas"
```

---

### Task 8: The plugin's pure logic

**Files:**
- Create: `updates/dms-plugin/logic.js`
- Create: `updates/dms-plugin/tests/logic.test.js`

**Interfaces:**
- Produces:
  - `classify(status)` → `{state, icon, tone, summary}` where `tone` is one of `"ok" | "ready" | "warn" | "error" | "unknown"`.
  - `buttonFor(status)` → `{label, action, enabled, reason}` where `action` is `"apply" | "apply-boot" | "check" | "none"`.
  - `changeLines(status)` → array of `{name, text}` for the panel.

- [ ] **Step 1: Write the failing tests**

`updates/dms-plugin/tests/logic.test.js`:

```javascript
const { test } = require('node:test')
const assert = require('node:assert')
const { classify, buttonFor, changeLines } = require('../logic.js')

const ready = {
  schema: 2, state: 'ready', checked_at: '2026-08-11T06:41:49-06:00',
  warnings: [], blockers: [], reboot_recommended: false, reboot_reason: [],
  changes: [{ name: 'nixpkgs', kind: 'input', from: 'abc1234', to: 'def5678' }],
  closure_diff: { added: [], removed: [], changed: [], size_delta_mb: 1.5 },
}

test('a ready update offers to apply', () => {
  const b = buttonFor(ready)
  assert.equal(b.action, 'apply')
  assert.equal(b.enabled, true)
})

test('a reboot-recommended update offers boot, never switch', () => {
  const b = buttonFor({ ...ready, reboot_recommended: true, reboot_reason: ['nvidia-open'] })
  assert.equal(b.action, 'apply-boot')
})

test('ready with warnings is visually distinct from ready without', () => {
  const clean = classify(ready)
  const warned = classify({ ...ready, warnings: [{ code: 'x', detail: 'y' }] })
  assert.notEqual(clean.tone, warned.tone)
})

test('a blocker disables the button and says why', () => {
  const b = buttonFor({ ...ready, blockers: [{ code: 'dirty_tree', detail: 'el arbol de trabajo tiene cambios sin commitear' }] })
  assert.equal(b.enabled, false)
  assert.match(b.reason, /sin commitear/)
})

test('an unknown schema is unknown, never healthy', () => {
  const c = classify({ schema: 99, state: 'ready' })
  assert.equal(c.tone, 'unknown')
  assert.notEqual(c.tone, 'ok')
})

test('a null status is unknown, never up to date', () => {
  // The failure that matters: upd not on PATH, the state dir unreadable, the
  // process killed. Rendering that as "todo al dia" would recreate, in the most
  // visible place on the screen, the exact failure the engine exists to remove.
  const c = classify(null)
  assert.equal(c.tone, 'unknown')
})

test('build_failed is an error, not a ready', () => {
  assert.equal(classify({ ...ready, state: 'build_failed' }).tone, 'error')
})

test('changeLines skips entries whose version did not move', () => {
  const lines = changeLines({ ...ready, changes: [
    ...ready.changes,
    { name: 'brave-origin', kind: 'local_pkg', from: '1.93.134', to: '1.93.134' },
  ]})
  assert.equal(lines.length, 1)
  assert.equal(lines[0].name, 'nixpkgs')
})

test('changeLines renders an added and a removed package readably', () => {
  const lines = changeLines({ ...ready, changes: [
    { name: 'nuevo', kind: 'input', from: '', to: 'abc1234' },
  ]})
  assert.match(lines[0].text, /abc1234/)
})
```

- [ ] **Step 2: Run and watch it fail**

Run: `nix develop ~/nixos-config#dms-plugins -c node --test updates/dms-plugin/tests/logic.test.js`
Expected: `Cannot find module '../logic.js'`.

- [ ] **Step 3: Implement**

`updates/dms-plugin/logic.js`:

```javascript
// Pure decisions for the bar plugin. No QML, no I/O — everything here is
// testable with `node --test`, which is the only part of a QML plugin that can
// be tested at all. Daemon.qml calls these and does nothing else with the data.

const SCHEMA = 2

// The rule the whole engine is built around: an incomplete or unreadable state
// must never render like a healthy one. Every early return here lands on
// 'unknown', never on 'ok'.
function classify(status) {
  if (!status || typeof status !== 'object') {
    return { state: 'unknown', icon: 'help', tone: 'unknown', summary: 'no se pudo leer el estado' }
  }
  if (status.schema !== SCHEMA) {
    return { state: 'unknown', icon: 'help', tone: 'unknown',
             summary: `status.json declara schema ${status.schema}, y este plugin entiende ${SCHEMA}` }
  }
  const warned = Array.isArray(status.warnings) && status.warnings.length > 0
  switch (status.state) {
    case 'current':
      return { state: 'current', icon: 'check_circle', tone: warned ? 'warn' : 'ok',
               summary: 'todo al dia' }
    case 'ready':
      return { state: 'ready', icon: 'system_update_alt', tone: warned ? 'warn' : 'ready',
               summary: `${changeLines(status).length} cambios preparados` }
    case 'build_failed':
      return { state: 'build_failed', icon: 'error', tone: 'error',
               summary: 'la actualizacion preparada NO compila' }
    case 'check_failed':
      return { state: 'check_failed', icon: 'error', tone: 'error',
               summary: status.error || 'la comprobacion fallo' }
    default:
      return { state: 'unknown', icon: 'help', tone: 'unknown',
               summary: `estado desconocido: ${status.state}` }
  }
}

function buttonFor(status) {
  const c = classify(status)
  if (c.tone === 'unknown') {
    return { label: 'Sin estado', action: 'none', enabled: false, reason: c.summary }
  }
  if (status.state !== 'ready') {
    return { label: 'Comprobar ahora', action: 'check', enabled: true, reason: '' }
  }
  const blockers = Array.isArray(status.blockers) ? status.blockers : []
  if (blockers.length > 0) {
    // The engine's own wording, passed through untouched. Rewording it here
    // would mean maintaining two descriptions of the same refusal.
    return { label: 'Aplicar', action: 'none', enabled: false,
             reason: blockers.map(b => b.detail).join('; ') }
  }
  return status.reboot_recommended
    ? { label: 'Aplicar al arrancar', action: 'apply-boot', enabled: true,
        reason: `pide reinicio: ${(status.reboot_reason || []).join(', ')}` }
    : { label: 'Aplicar', action: 'apply', enabled: true, reason: '' }
}

function changeLines(status) {
  if (!status || !Array.isArray(status.changes)) return []
  return status.changes
    .filter(c => c.from !== c.to)
    .map(c => ({
      name: c.name,
      text: `${c.from || '(nuevo)'} → ${c.to || '(fuera)'}`,
    }))
}

module.exports = { classify, buttonFor, changeLines, SCHEMA }
```

- [ ] **Step 4: Run the tests**

Run: `nix develop ~/nixos-config#dms-plugins -c node --test updates/dms-plugin/tests/logic.test.js`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add updates/dms-plugin/
git commit -m "plugin: la logica pura del widget, con sus pruebas"
```

---

### Task 9: The bar item

**Files:**
- Create: `updates/dms-plugin/plugin.json`, `updates/dms-plugin/Daemon.qml`, `updates/dms-plugin/Widget.qml`
- Modify: `dms.nix`

**Interfaces:**
- Consumes: `logic.js` from Task 8, `upd status --json` from Task 5.
- Produces: a bar item that shows state. No buttons yet — Task 10 adds the panel.

- [ ] **Step 1: Write the manifest**

`updates/dms-plugin/plugin.json`:

```json
{
    "id": "nixosUpd",
    "name": "NixOS updates",
    "description": "The nightly prepared system update, and the button that applies it",
    "version": "0.1.0",
    "author": "daf3r",
    "type": "composite",
    "icon": "system_update_alt",
    "capabilities": ["dankbar-widget"],
    "components": {
        "daemon": "./Daemon.qml",
        "widget": "./Widget.qml"
    },
    "permissions": ["process"],
    "requires_dms": ">=1.5.0"
}
```

`permissions` is decorative in DMS 1.5.3 — `PluginService.qml:295-302` stores it and three settings screens display it, nothing enforces it. Declared honestly anyway, because the panel that shows it to the user is the only audit surface there is.

- [ ] **Step 2: Write the daemon**

`updates/dms-plugin/Daemon.qml`:

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Modules.Plugins
import "./logic.js" as Logic

// The daemon surface runs ONCE for the whole shell. The widget surface is
// instantiated once PER SCREEN, and this machine has two — claude-usage learned
// that the expensive way, giving itself a 429 by doing I/O in the pill. So
// every process, timer and file read lives here, and the widget only paints
// what this publishes through the global var.
PluginComponent {
    id: root

    property int pollIntervalMs: 60000

    // The channel to the widget. Same varName on both sides. It carries the
    // already-classified view rather than the raw status: classify() is the
    // decision, and running it once here beats running it per screen.
    PluginGlobalVar {
        id: updState
        varName: "updState"
        defaultValue: ({ view: Logic.classify(null), status: null, applying: false, lastError: "" })
    }

    function publish(status, applying, lastError) {
        updState.set({
            view: Logic.classify(status),
            status: status,
            applying: applying,
            lastError: lastError,
        })
    }

    function poll() {
        statusProc.running = true
    }

    Process {
        id: statusProc
        command: ["upd", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                var parsed = null
                try {
                    parsed = JSON.parse(text)
                } catch (e) {
                    parsed = null   // stays null: classify() renders it unknown
                }
                root.publish(parsed, false, "")
            }
        }
        onExited: (code, st) => {
            // A non-zero exit means upd refused to answer — unreadable status,
            // unknown schema, or not on PATH. Publishing null is the honest
            // outcome; the one thing forbidden is leaving the last good state
            // on screen as though it were current.
            if (code !== 0)
                root.publish(null, false, "")
        }
    }

    Timer {
        interval: root.pollIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }
}
```

Check the `import qs.Modules.Plugins` line against `claude-usage/Daemon.qml:75` and use whatever import that file uses for `PluginComponent` — it is the working reference on this machine.

- [ ] **Step 3: Write the widget**

`updates/dms-plugin/Widget.qml`. It paints and nothing else — no `Process`, no
`Timer`, no file access, for the per-screen reason in the daemon's header
comment:

```qml
import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    PluginGlobalVar {
        id: updState
        varName: "updState"     // same name the daemon publishes under
    }

    readonly property var view: updState.value && updState.value.view
        ? updState.value.view
        : { state: "unknown", icon: "help", tone: "unknown", summary: "" }

    // The tone→colour map is the whole point of the bar item. `ready` and
    // `warn` MUST be different here and not only inside the panel: upd.sh makes
    // the same distinction in its heading, because a ready carrying warnings
    // that looks identical to a clean one leaves reading them to chance.
    readonly property color toneColor: {
        switch (view.tone) {
        case "ok":      return Theme.surfaceVariantText
        case "ready":   return Theme.primary
        case "warn":    return Theme.warning
        case "error":   return Theme.error
        default:        return Theme.surfaceVariantText
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            DankIcon {
                name: root.view.icon
                color: root.toneColor
                anchors.verticalCenter: parent.verticalCenter
            }
            StyledText {
                text: root.view.state === "ready" ? root.view.summary : ""
                color: root.toneColor
                font.pixelSize: Theme.fontSizeSmall
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    popoutContent: Component {
        Popout {}
    }
}
```

Read `claude-usage/Widget.qml:95-250` before writing this and match its actual
property names for the pill components and the imports — that file is the
working reference on this machine, and DMS's plugin API is not documented
anywhere else. If it declares both a horizontal and a vertical pill, declare
both here too rather than leaving the vertical bar broken.

- [ ] **Step 4: Declare it**

In `dms.nix`, next to the `plugins.claude-usage` block:

```nix
    # The bar half of the update engine in ./updates. Unlike claude-usage this
    # is NOT a flake input: a path relative to this flake's own tree is fine
    # under pure evaluation -- what fails is an absolute path -- so the engine
    # and its reader move in the same commit and iterating costs one switch,
    # with no push and no `nix flake update`.
    plugins.nixos-upd = {
      enable = true;
      src = ./updates/dms-plugin;
    };
```

- [ ] **Step 5: Build, switch, and look at the bar**

```bash
nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel --no-link
nh os switch ~/nixos-config   # daf3r runs this
journalctl --user -u dms.service -f | grep -i nixosUpd
```

Expected: `DankBar: Plugin loaded: nixosUpd` and `Daemon plugin loaded: nixosUpd`, and the icon appears in the bar showing the real current state. This is the step that catches a QML error, which no unit test can.

- [ ] **Step 6: Verify the unknown path by breaking it on purpose**

```bash
chmod 000 /var/lib/nixos-upd/status.json
```

Expected: within a minute the bar shows the unknown state, **not** "todo al dia". Then `chmod 600 /var/lib/nixos-upd/status.json` and confirm it recovers.

- [ ] **Step 7: Commit**

```bash
git add updates/dms-plugin/ dms.nix
git commit -m "plugin: el icono de estado en la barra"
```

---

### Task 10: The panel and the apply

**Files:**
- Create: `updates/dms-plugin/Popout.qml`
- Modify: `updates/dms-plugin/plugin.json` (register the popout), `updates/dms-plugin/Daemon.qml` (the actions)

**Interfaces:**
- Consumes: `buttonFor`, `changeLines` (Task 8); `upd apply --ff-only` (Task 6); `nixos-upd-apply@*.service` (Task 7).

- [ ] **Step 1: Add the actions to the daemon**

First, replace Task 9's `publish(status, applying, lastError)` with the
`lastStatus` property and `republish()` below — one function reading three
properties, rather than a signature that grows an argument every time the daemon
gains a piece of state. Update `statusProc`'s two call sites accordingly:
`root.lastStatus = parsed; root.republish()` on success, and
`root.lastStatus = null; root.republish()` on a non-zero exit.

Then add to `Daemon.qml`:

```qml
    // Two processes, because they are two different failure domains. The
    // fast-forward runs as daf3r and either succeeds or prints exactly why not;
    // only if it succeeded does the root half start. Chaining them into one
    // shell line would lose which of the two failed.
    // Mirrors of what publish() sends to the widget. Kept as properties so the
    // process handlers below have somewhere to write before republishing.
    property string lastError: ""
    property bool applying: false
    property var lastStatus: null

    function republish() {
        updState.set({
            view: Logic.classify(root.lastStatus),
            status: root.lastStatus,
            applying: root.applying,
            lastError: root.lastError,
        })
    }

    function apply(mode) {   // mode: "switch" | "boot"
        root.lastError = ""
        root.applying = true
        root.republish()
        ffProc.pendingMode = mode
        ffProc.running = true
    }

    Process {
        id: ffProc
        property string pendingMode: "switch"
        command: ["upd", "apply", "--ff-only"]
        stderr: StdioCollector { id: ffErr }
        onExited: (code, st) => {
            if (code !== 0) {
                root.applying = false
                root.lastError = ffErr.text        // the engine's words, verbatim
                root.republish()
                return
            }
            unitProc.command = ["systemctl", "start", "--no-block",
                                "nixos-upd-apply@" + ffProc.pendingMode + ".service"]
            unitProc.running = true
        }
    }

    Process {
        id: unitProc
        stderr: StdioCollector { id: unitErr }
        onExited: (code, st) => {
            if (code !== 0) {
                root.applying = false
                root.lastError = unitErr.text      // includes a cancelled polkit prompt
                root.republish()
                return
            }
            unitWatch.running = true
        }
    }

    // --no-block returns as soon as the job is queued, so completion has to be
    // watched for. A switch can take twenty minutes; the shell must not pretend
    // it is done when it is only started.
    Timer {
        id: unitWatch
        interval: 3000
        repeat: true
        onTriggered: watchProc.running = true
    }

    Process {
        id: watchProc
        command: ["systemctl", "show", "-p", "ActiveState", "-p", "Result", "--value",
                  "nixos-upd-apply@" + ffProc.pendingMode + ".service"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                if (lines[0] === "failed" || (lines[0] === "inactive" && lines[1] !== "success")) {
                    root.applying = false
                    unitWatch.running = false
                    root.lastError = "la unidad termino en " + lines[1]
                    root.republish()
                } else if (lines[0] === "inactive" && lines[1] === "success") {
                    root.applying = false
                    unitWatch.running = false
                    root.poll()   // poll() republishes with the fresh status
                }
            }
        }
    }

    function check() {
        checkProc.running = true
    }

    Process {
        id: checkProc
        command: ["systemctl", "start", "--no-block", "nixos-upd.service"]
        onExited: root.poll()
    }
```

- [ ] **Step 2: Write the panel**

`updates/dms-plugin/Popout.qml`. It is instantiated from `popoutContent` in
Widget.qml, so it is not registered in `plugin.json` — DMS's popout is a
`Component` on the widget, not a fourth surface. Skeleton:

```qml
import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./logic.js" as Logic

Column {
    id: root
    spacing: Theme.spacingM

    PluginGlobalVar {
        id: updState
        varName: "updState"
    }

    readonly property var st: updState.value ? updState.value.status : null
    readonly property var view: updState.value ? updState.value.view : Logic.classify(null)
    readonly property bool applying: updState.value ? updState.value.applying : false
    readonly property string lastError: updState.value ? updState.value.lastError : ""
    readonly property var button: Logic.buttonFor(root.st)

    StyledText {
        text: root.view.summary
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeMedium
    }

    Repeater {
        model: Logic.changeLines(root.st)
        delegate: Row {
            spacing: Theme.spacingS
            StyledText { text: modelData.name; color: Theme.surfaceText }
            StyledText { text: modelData.text; color: Theme.surfaceVariantText }
        }
    }

    // Warnings and blockers, verbatim. Rewording them here would mean two
    // descriptions of the same refusal drifting apart.
    Repeater {
        model: root.st && root.st.warnings ? root.st.warnings : []
        delegate: StyledText {
            text: "AVISO [" + modelData.code + "] " + modelData.detail
            color: Theme.warning
            wrapMode: Text.Wrap
            width: parent.width
        }
    }

    StyledText {
        visible: !root.button.enabled && root.button.reason !== ""
        text: root.button.reason
        color: Theme.error
        wrapMode: Text.Wrap
        width: parent.width
    }

    Row {
        spacing: Theme.spacingS

        // Disabled, never hidden. A missing button teaches nothing; a disabled
        // one reading "la rama es dms, no main" says what to do about it.
        DankButton {
            text: root.applying ? "Aplicando..." : root.button.label
            enabled: root.button.enabled && !root.applying
            onClicked: {
                if (root.button.action === "apply") daemon.apply("switch")
                else if (root.button.action === "apply-boot") daemon.apply("boot")
                else if (root.button.action === "check") daemon.check()
            }
        }

        DankButton {
            text: "Comprobar ahora"
            iconName: "refresh"
            enabled: !root.applying
            onClicked: daemon.check()
        }
    }

    StyledText {
        visible: root.lastError !== ""
        text: root.lastError
        color: Theme.error
        font.family: Theme.monoFontFamily
        wrapMode: Text.Wrap
        width: parent.width
    }
}
```

`daemon` here is however `claude-usage`'s popout reaches its daemon surface —
read `Widget.qml:780-800` to see how it wires `popoutContent` to daemon
functions, and use that mechanism. If the daemon is not directly reachable, move
`apply()`/`check()` behind the global var (a command field the daemon watches),
and say so in a comment rather than duplicating the processes into the popout,
which would run them once per screen.

- [ ] **Step 3: Confirm the manifest needs no popout entry**

`plugin.json` keeps only `daemon` and `widget` under `components`. Verify by
checking `claude-usage/plugin.json`, which declares the same two and still shows
a popout on click.

- [ ] **Step 4: Build, switch, and drive it**

```bash
nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel --no-link
nh os switch ~/nixos-config
```

Then, in the running session:

1. Click the icon. The panel lists the real prepared changes.
2. `touch ~/nixos-config/borrame.txt`, wait a minute, reopen: the button is disabled and says the tree is dirty. `rm ~/nixos-config/borrame.txt`.
3. Press Apply. **The DMS polkit modal appears.** Cancel it. The panel reports the cancellation and does not claim success.
4. Press Apply again and enter the password. The panel shows the apply running; `journalctl -u nixos-upd-apply@boot.service -f` shows `nh` working.
5. When it finishes, confirm `readlink /nix/var/nix/profiles/system` moved, and that the panel now shows the `pending_reboot` blocker rather than offering to apply again.

- [ ] **Step 5: Commit**

```bash
git add updates/dms-plugin/
git commit -m "plugin: el panel, con el boton que aplica"
```

---

### Task 11: Close the loop

**Files:**
- Modify: `docs/superpowers/specs/2026-08-09-actualizacion-automatica-design.md` (its Phase 2 section)
- Modify: `README.md` and `README.es.md` if they describe `upd`'s subcommands

- [ ] **Step 1: Retire the Phase 2 section**

The 2026-08-09 spec lists three deferred items: the bar plugin, `switch` being the wrong verb, and the missing machine-readable change list. All three are now implemented. Replace that section with a pointer to `2026-08-11-widget-upd-barra-design.md` and a one-line statement of what shipped. Leaving a "deferred" section describing work that is done is the same stale-state problem the engine exists to prevent, one level up.

- [ ] **Step 2: Update the READMEs**

Check whether they document `upd`'s subcommands:

```bash
grep -n "upd " README.md README.es.md
```

If they do, add `status --json`, `apply --boot` and `apply --ff-only`, and mention the bar plugin.

- [ ] **Step 3: Full verification pass**

```bash
nix run nixpkgs#bats -- updates/tests/
nix develop ~/nixos-config#dms-plugins -c node --test updates/dms-plugin/tests/*.test.js
nix build .#nixosConfigurations.daf3r-starter.config.system.build.toplevel --no-link
upd status --json | jq '.schema, .blockers, .reboot_recommended'
```

Expected: all green, `schema` 2.

- [ ] **Step 4: Commit and publish**

```bash
git add docs/ README.md README.es.md
git commit -m "docs: la fase 2 del motor esta hecha"
git push origin main
```

---

## Notes for the implementer

- **`nix store diff-closures` output is a parsing bet.** Task 1 makes an unparseable diff a hard error precisely so the bet is visible. If it ever fires, the fix is in `closure_parse` and its fixture, not in silencing the warning.
- **A polkit rule can be written, evaluate cleanly, and authorise nothing.** That happened on this machine with gamemode. Task 7 Step 4 is not optional and is not replaceable by reading the `.nix`.
- **The engine and the plugin ship in the same derivation.** They cannot disagree within a generation, which is why the schema check is a refusal rather than a compatibility shim.
- **Do not weaken any existing guard in `upd apply`.** Every one of them was reproduced from a real failure before it was written; `upd.sh`'s comments record which. Task 6 moves where the last two lines run, and nothing else.
