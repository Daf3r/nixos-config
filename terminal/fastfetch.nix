{ config, lib, pkgs, ... }:

# fastfetch runs on every interactive fish start (see ./fish.nix), so it is the
# most-seen output on this machine after the prompt itself.
#
# Two things are wired here: the layout, and a different image on every launch.
#
# --- The layout ---
#
# ../config/fastfetch/config.jsonc, adapted from
# github.com/israrkhan-cys/Arch-_hyprland_rice. Changes from the original:
#
#   * The original is JSONC — `//` comments and trailing commas — which parses
#     fine for fastfetch but NOT for Noctalia's template, whose apply.sh merges
#     colours with jq and rejects anything that is not strict JSON. Rewritten
#     without either.
#   * The decorative dot rows were raw ANSI escapes in a custom module. They are
#     fastfetch's own `colors` module with symbol "circle" here, which produces
#     the same row from the terminal palette without embedding control
#     characters in a JSON file.
#   * Per-module `keyColor` is dropped so Noctalia's fastfetch template drives
#     the colours from the active palette instead of a hardcoded ANSI number.
#   * `packages` loses the "(pacman)" suffix, for obvious reasons.
#
# config.jsonc is left MUTABLE rather than managed as a store symlink, because
# Noctalia's apply.sh rewrites it in place on every palette change. It is seeded
# from the repo copy only when absent, so a fresh machine gets the layout and an
# existing one keeps its merged colours. To pick up an edit to the repo copy,
# delete ~/.config/fastfetch/config.jsonc and rebuild.
#
# --- The image ---
#
# fastfetch has no notion of a random logo: `logo.source` is a single path. So
# the shell calls `fastfetch-random` instead, which picks one image and passes
# it in. Images live in ~/Pictures/Fastfetch — drop more in and they join the
# rotation with no rebuild.
#
# That directory is outside this repo on purpose: the images are other people's
# work and this repo is public. Nothing creates it — fastfetch-random already
# falls through to the config's own logo when the folder is missing, which is
# the whole reason for the `2>/dev/null ... || true` below.
#
# --- Why jq is a dependency ---
#
# Noctalia's fastfetch template needs it and never declares it. Its first call
# is `if ! jq empty "$config_file"` with stderr discarded, so a missing jq
# surfaces as "could not be parsed as strict JSON" about a file that parses
# fine. It also refuses to create config.jsonc itself, which is the other half
# of why the seeding below exists.
let
  fastfetchImages = "${config.home.homeDirectory}/Pictures/Fastfetch";

  fastfetch-random = pkgs.writeShellApplication {
    name = "fastfetch-random";
    runtimeInputs = [
      pkgs.fastfetch
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      dir="${fastfetchImages}"

      img="$(find "$dir" -maxdepth 1 -type f \
        \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
        2>/dev/null | shuf -n1 || true)"

      # No images, or the folder is gone: fall through to whatever logo the
      # config specifies rather than failing at shell startup.
      if [ -z "$img" ]; then
        exec fastfetch "$@"
      fi

      # --logo-type is repeated even though config.jsonc sets it, because
      # --logo resets the type to auto-detect. Outside kitty this degrades to
      # the ASCII distro logo on its own, which is the right fallback.
      exec fastfetch --logo "$img" --logo-type kitty "$@"
    '';
  };
in
{
  home.packages = [
    pkgs.jq
    fastfetch-random
  ];

  home.activation.fastfetchSeedConfig =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      fastfetchConfig="${config.xdg.configHome}/fastfetch/config.jsonc"
      if [ ! -e "$fastfetchConfig" ]; then
        run mkdir -p "$(dirname "$fastfetchConfig")"
        run cp ${./../config/fastfetch/config.jsonc} "$fastfetchConfig"
        run chmod u+w "$fastfetchConfig"
      fi
    '';
}
