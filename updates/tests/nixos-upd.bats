#!/usr/bin/env bats
#
# The engine end to end. Until schema 2 it had no test at all: every library it
# calls was covered and the file that composes their output into status.json was
# not, so deliberate mutation of the composition survived the whole suite --
# `changes` renamed back to `local_pkgs`, the closure-parse warning deleted, the
# lock snapshot taken from the wrong revision. All three are caught here.
#
# Hermetic. Everything nixos-upd.sh reaches the network or the store for is a
# stub on PATH -- `nix`, `nixos-rebuild`, `nix-store`, `curl`, `npm` -- and the
# repository, the clone and the state directory are built from scratch under
# $TMPDIR. The libraries and the bump scripts are the real ones: stubbing those
# would leave nothing under test but the stubs.
#
# The shebangs are written as $BASH rather than `/usr/bin/env bash` for the same
# reason upd.bats does it: the suite runs inside the nix build sandbox, which has
# no /usr/bin/env, and a stub that never runs turns an assertion about the engine
# into an assertion about the sandbox.

ENGINE="${BATS_TEST_DIRNAME}/../nixos-upd.sh"
FIX="${BATS_TEST_DIRNAME}/fixtures"

setup() {
  WORK="$(mktemp -d)"
  STATE="$WORK/state"
  REPO="$WORK/repo"
  CLOSURE="$WORK/closure"
  mkdir -p "$STATE" "$WORK/bin" "$CLOSURE"

  # A $HOME holding a claude-code the npm stub agrees with, so the unmanaged
  # check runs and reports nothing. Left out, it warns that it could not run,
  # and every assertion about `warnings` below would be reading that instead.
  export HOME="$WORK/home"
  mkdir -p "$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code"
  printf '{"version":"1.0.0"}\n' \
    > "$HOME/.npm-global/lib/node_modules/@anthropic-ai/claude-code/package.json"

  # What the `nix flake update` stub will write: this repository's real lock
  # with nixpkgs moved and nothing else touched, so `changes[]` has exactly one
  # input in it and the assertions can name it.
  jq '.nodes.nixpkgs_3.locked.rev = "2222222222222222222222222222222222222222"' \
    "$FIX/lock-before.json" > "$WORK/lock-after.json"

  # The closure diff the stub serves. A file rather than a fixed fixture path so
  # a test can replace it to exercise a diff the parser refuses.
  cp "$FIX/diff-closures.txt" "$WORK/diff.txt"

  make_repo
  make_stubs
  PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

# $REPO as the engine expects to find it: a lock to move and the two
# hand-packaged derivations the bump scripts rewrite.
make_repo() {
  mkdir -p "$REPO/pkgs"
  git init -q -b main "$REPO"
  cp "$FIX/lock-before.json" "$REPO/flake.lock"
  cp "$FIX/sample-pkg.nix" "$REPO/pkgs/brave-origin.nix"
  cp "$FIX/sample-pkg.nix" "$REPO/pkgs/t3code-app.nix"
  printf 'result\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm base
}

make_stubs() {
  { printf '#!%s\n' "$BASH"
    cat <<EOF
case "\$1 \$2" in
  "flake update")
    cp "$WORK/lock-after.json" "\$4/flake.lock" ;;
  "store diff-closures")
    [ -e "$WORK/diff-closures-fails" ] && exit 1
    cat "$WORK/diff.txt" ;;
  "store prefetch-file")
    printf '{"hash":"sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="}\n' ;;
  "hash convert")
    printf 'sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=\n' ;;
  *)
    echo "stub nix: no sé qué hacer con: \$*" >&2; exit 1 ;;
esac
EOF
  } > "$WORK/bin/nix"

  # Drops the `result` symlink in the current directory, which is what the
  # engine cd's into $WT for. It must resolve somewhere other than
  # /run/current-system or the engine reports `current` and stops.
  { printf '#!%s\n' "$BASH"
    printf 'ln -sfn "%s" "$PWD/result"\n' "$CLOSURE"
  } > "$WORK/bin/nixos-rebuild"

  # An empty closure: no brave binary to check, which the engine turns into a
  # brave_vaapi_check_skipped warning. That warning is expected in every run
  # here and is itself worth having -- it is the path that proves a warning
  # raised late in the run still reaches status.json.
  { printf '#!%s\n' "$BASH"; printf 'exit 0\n'; } > "$WORK/bin/nix-store"

  { printf '#!%s\n' "$BASH"
    cat <<EOF
for a in "\$@"; do url="\$a"; done
case "\$url" in
  *brave*)  [ -e "$WORK/brave-feed-fails" ] && exit 7
            cat "$FIX/brave-packages.txt" ;;
  *github*) cat "$FIX/t3code-release.json" ;;
  *)        echo "stub curl: URL inesperada: \$url" >&2; exit 1 ;;
esac
EOF
  } > "$WORK/bin/curl"

  { printf '#!%s\n' "$BASH"; printf '%s\n' 'printf "1.0.0\n"'; } > "$WORK/bin/npm"

  chmod +x "$WORK/bin/nix" "$WORK/bin/nixos-rebuild" "$WORK/bin/nix-store" \
    "$WORK/bin/curl" "$WORK/bin/npm"
}

engine() {
  REPO="$REPO" BRANCH=main STATE_DIR="$STATE" FLAKE_ATTR=prueba bash "$ENGINE"
}

# --- the composed body ------------------------------------------------------

@test "a ready run writes schema 2 with changes[], and local_pkgs is gone" {
  run engine
  [ "$status" -eq 0 ]
  jq -e '.schema == 2 and .state == "ready"' "$STATE/status.json"

  # The whole point of the schema bump. `has("local_pkgs") | not` is the half
  # that matters most: renaming `changes` back to `local_pkgs` in the engine
  # leaves every library test green, and before this line it left the whole
  # suite green too.
  jq -e '.changes | type == "array"' "$STATE/status.json"
  jq -e 'has("local_pkgs") | not' "$STATE/status.json"

  # One input moved, and it is named with both short revs -- the failure that
  # started this: the first real run moved six inputs and named none.
  jq -e '[.changes[] | select(.kind == "input")]
         == [{name: "nixpkgs", kind: "input", from: "f13ff45", to: "2222222"}]' \
    "$STATE/status.json"

  # Both hand-packaged apps are there, as objects rather than as prose.
  jq -e '[.changes[] | select(.kind == "local_pkg") | .name] | sort
         == ["brave-origin", "t3code-app"]' "$STATE/status.json"
  jq -e '.changes[] | select(.name == "t3code-app")
         | .from == "1.0.0" and .to == "0.0.34"' "$STATE/status.json"
  jq -e '.changes[] | select(.name == "brave-origin")
         | .from == "1.0.0" and .to == "1.93.134"' "$STATE/status.json"
}

@test "a ready run carries the parsed closure diff and the reboot verdict" {
  run engine
  [ "$status" -eq 0 ]

  # The exact totals the fixture parses to, measured, not assumed -- the first
  # version of this test asserted production's numbers instead and failed.
  # Asserting totals rather than "not empty" is what keeps a half-parsed diff
  # -- the shape a format change takes -- from passing as a full one.
  jq -e '.closure_diff.changed | length == 21' "$STATE/status.json"
  jq -e '.closure_diff.added | length == 1' "$STATE/status.json"
  jq -e '.closure_diff.removed == []' "$STATE/status.json"
  jq -e '.closure_diff.size_delta_mb == 1239.18' "$STATE/status.json"

  # And the verdict that changes what the user has to type.
  jq -e '.reboot_recommended == true' "$STATE/status.json"
  jq -e '.reboot_reason | sort
         == ["initrd-linux-xanmod", "nvidia-open", "nvidia-x11"]' "$STATE/status.json"
}

# --- what the snapshot is measured against ----------------------------------

@test "the second run in a row still measures against the running system, not against yesterday's prepared update" {
  # The bug this test exists for, and it is silent: on the second night without
  # an apply, $WT still holds the lock the *previous* run prepared. A snapshot
  # taken before the reset to FETCH_HEAD therefore measures today's update
  # against yesterday's update instead of against $BRANCH -- so nixpkgs, which
  # really did move from f13ff45 for anyone actually running the system, is
  # reported as not having moved at all, with a clean `ready` and no warning.
  #
  # Measured on the real repository before the fix: five inputs became one, and
  # that one carried a `from` the running system had never had.
  run engine
  [ "$status" -eq 0 ]

  run engine
  [ "$status" -eq 0 ]

  # The clone must have been reused, or this proves nothing: a re-clone brings
  # back $BRANCH's lock and hides the bug.
  ! grep -q "cloning" "$STATE/last.log"

  jq -e '[.changes[] | select(.kind == "input")]
         == [{name: "nixpkgs", kind: "input", from: "f13ff45", to: "2222222"}]' \
    "$STATE/status.json"
  # And the snapshot really is $BRANCH's lock, byte for byte.
  run diff -q "$REPO/flake.lock" "$STATE/lock.before"
  [ "$status" -eq 0 ]
}

# --- every failure below stays visible --------------------------------------

@test "a closure diff it cannot parse is a warning, never a quiet empty diff" {
  # closure_parse fails all-or-nothing on a shape it does not know, a size unit
  # some future nix invents being the likeliest. Treating that 1 as "no
  # updates" would put an empty change list under a `ready` that just built a
  # different closure -- the exact silence the engine exists to remove.
  printf 'gcc: 16.1.0 → 16.2.0, 1.5 TiB\n' > "$WORK/diff.txt"

  run engine
  [ "$status" -eq 0 ]
  jq -e '.state == "ready"' "$STATE/status.json"
  jq -e '.warnings | map(.code) | index("closure_parse_failed") != null' "$STATE/status.json"
  jq -e '.closure_diff.changed == [] and .closure_diff.size_delta_mb == 0' "$STATE/status.json"
  # The reboot verdict that follows an unparsed diff must not read as a
  # confident "safe to apply hot" with nothing next to it.
  jq -e '.reboot_recommended == false' "$STATE/status.json"
  jq -e '.warnings | length > 0' "$STATE/status.json"
}

@test "diff-closures failing outright is told apart from a diff that would not parse" {
  # Both end in an empty closure_diff, and pointing the user at "the format may
  # have changed" when the command simply did not run sends them to read a
  # parser that is fine.
  : > "$WORK/diff-closures-fails"

  run engine
  [ "$status" -eq 0 ]
  jq -e '.warnings | map(.code) | index("closure_diff_failed") != null' "$STATE/status.json"
  jq -e '.warnings | map(.code) | index("closure_parse_failed") == null' "$STATE/status.json"
}

@test "a failed bump keeps changes[] uniform and says so" {
  # A bump that dies leaves that package where it is and must not stop the run.
  # Two separate signals are needed: the warning a reader gates on, and an entry
  # in changes[] so no consumer has to cope with a list that is sometimes one
  # element shorter.
  : > "$WORK/brave-feed-fails"

  run engine
  [ "$status" -eq 0 ]
  jq -e '.state == "ready"' "$STATE/status.json"
  jq -e '.warnings | map(.code) | index("local_bump_failed") != null' "$STATE/status.json"
  jq -e '.changes[] | select(.name == "brave-origin")
         | .kind == "local_pkg" and .from == "" and .to == "" and .error == "bump failed"' \
    "$STATE/status.json"
  # The other one still moved: one failing bump must not take the other with it.
  jq -e '.changes[] | select(.name == "t3code-app") | .to == "0.0.34"' "$STATE/status.json"
}
