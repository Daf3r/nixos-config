#!/usr/bin/env bats

# bump-discord.sh against a stubbed manifest. `curl` serves the fixture (or
# fails), and `nix hash convert` is replaced by a stand-in that turns each hex
# digest into a distinct SRI-shaped string, so a test can tell the host's hash
# from a module's and a module's from another's.

SCRIPT="${BATS_TEST_DIRNAME}/../bump-discord.sh"
FIX="${BATS_TEST_DIRNAME}/fixtures"

setup() {
  WORK="$(mktemp -d)"
  mkdir -p "$WORK/bin" "$WORK/repo/pkgs"
  cp "$FIX/discord-sources.json" "$WORK/repo/pkgs/discord-sources.json"
  cp "$FIX/discord-manifest.json" "$WORK/manifest.json"

  { printf '#!%s\n' "$BASH"
    cat <<EOF2
[ -e "$WORK/curl-fails" ] && exit 22
# The real endpoint rejects a User-Agent that is not a Discord-Updater one.
case " \$* " in *" -A Discord-Updater/1 "*) ;; *) echo "stub curl: sin el User-Agent de Discord" >&2; exit 1 ;; esac
cat "$WORK/manifest.json"
EOF2
  } > "$WORK/bin/curl"

  { printf '#!%s\n' "$BASH"
    cat <<'EOF2'
# nix hash convert --hash-algo sha256 --to sri <hex>
hex="${*: -1}"
printf 'sha256-%s=\n' "${hex:0:12}"
EOF2
  } > "$WORK/bin/nix"
  chmod +x "$WORK/bin/curl" "$WORK/bin/nix"
  PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$WORK"
}

bump() { bash "$SCRIPT" --repo "$WORK/repo"; }
pin() { jq -r "$1" "$WORK/repo/pkgs/discord-sources.json"; }

@test "a newer release is reported and written with the host and every module" {
  run bump
  [ "$status" -eq 0 ]
  jq -e '.name == "discord" and .kind == "local_pkg" and .from == "1.0.159" and .to == "1.0.160"' <<<"$output"

  [ "$(pin '."linux-stable".version')" = "1.0.160" ]
  [ "$(pin '."linux-stable".distro.url')" = "https://dl.discordapp.net/distro/app/stable/linux/x64/1.0.160/full.distro" ]
  [ "$(pin '."linux-stable".distro.hash')" = "sha256-61fd92d48527=" ]
  [ "$(pin '."linux-stable".modules.discord_voice.version')" = "3" ]
  [ "$(pin '."linux-stable".modules.discord_voice.hash')" = "sha256-aaaaaaaaaaaa=" ]
  [ "$(pin '."linux-stable".modules.discord_utils.hash')" = "sha256-bbbbbbbbbbbb=" ]
}

@test "the written file keeps the shape nixpkgs' metadata.nix reads" {
  run bump
  [ "$status" -eq 0 ]
  jq -e '."linux-stable" | (keys | sort) == ["distro","kind","modules","version"]
         and .kind == "distro"
         and (.distro | keys | sort) == ["hash","url"]
         and all(.modules[]; (keys | sort) == ["hash","url","version"])' \
    "$WORK/repo/pkgs/discord-sources.json"
}

@test "an unchanged release writes nothing and says from == to" {
  jq '."linux-stable".version = "1.0.160"' "$FIX/discord-sources.json" \
    > "$WORK/repo/pkgs/discord-sources.json"
  before="$(cksum < "$WORK/repo/pkgs/discord-sources.json")"
  run bump
  [ "$status" -eq 0 ]
  jq -e '.from == "1.0.160" and .to == "1.0.160"' <<<"$output"
  [ "$(cksum < "$WORK/repo/pkgs/discord-sources.json")" = "$before" ]
}

@test "a module without a well-formed hash refuses the whole bump" {
  jq '.modules.discord_voice.full.package_sha256 = "nothex"' "$FIX/discord-manifest.json" \
    > "$WORK/manifest.json"
  before="$(cksum < "$WORK/repo/pkgs/discord-sources.json")"
  run bump
  [ "$status" -eq 1 ]
  [[ "$output" == *"left as it is"* ]]
  [ "$(cksum < "$WORK/repo/pkgs/discord-sources.json")" = "$before" ]
}

@test "a truncated or empty digest is refused, not turned into a valid-looking hash" {
  # The dangerous malformed digest is not the obviously wrong one: a short or
  # empty hex string still converts to something shaped like an SRI hash.
  for bad in "" "61fd92d48527c46aa5dafa2a8a625e1b96a8bb50282206c0437a9489b014556" \
             "61fd92d48527c46aa5dafa2a8a625e1b96a8bb50282206c0437a9489b01455620"; do
    jq --arg h "$bad" '.full.package_sha256 = $h' "$FIX/discord-manifest.json" > "$WORK/manifest.json"
    run bump
    [ "$status" -eq 1 ]
    [ "$(pin '."linux-stable".version')" = "1.0.159" ]
  done
}

@test "a manifest with no modules is refused rather than written empty" {
  jq '.modules = {}' "$FIX/discord-manifest.json" > "$WORK/manifest.json"
  run bump
  [ "$status" -eq 1 ]
  [ "$(pin '."linux-stable".version')" = "1.0.159" ]
}

@test "a manifest without a host version is refused" {
  jq 'del(.full.host_version)' "$FIX/discord-manifest.json" > "$WORK/manifest.json"
  run bump
  [ "$status" -eq 1 ]
  [ "$(pin '."linux-stable".version')" = "1.0.159" ]
}

@test "a failed request leaves the pin alone and exits non-zero" {
  : > "$WORK/curl-fails"
  run bump
  [ "$status" -ne 0 ]
  [ "$(pin '."linux-stable".version')" = "1.0.159" ]
}

@test "no temporary file is left next to the pin, on success or on refusal" {
  run bump
  [ "$status" -eq 0 ]
  jq '.modules = {}' "$FIX/discord-manifest.json" > "$WORK/manifest.json"
  jq '."linux-stable".version = "1.0.0"' "$WORK/repo/pkgs/discord-sources.json" \
    > "$WORK/x" && cp "$WORK/x" "$WORK/repo/pkgs/discord-sources.json"
  run bump
  [ "$status" -eq 1 ]
  [ "$(ls "$WORK/repo/pkgs" | wc -l)" -eq 1 ]
}

@test "the file mode is preserved" {
  chmod 0644 "$WORK/repo/pkgs/discord-sources.json"
  run bump
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$WORK/repo/pkgs/discord-sources.json")" = "644" ]
}

@test "--repo is required and an unknown argument is refused" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" --repo "$WORK/repo" --nope
  [ "$status" -eq 1 ]
}
