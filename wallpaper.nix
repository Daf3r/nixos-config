{ config, pkgs, ... }:

# Wallpaper rotation, now driven by DMS.
#
# History: this module exists because Noctalia v5.0.0 drew its wallpaper
# surface at the wrong size on fractionally-scaled outputs (2560x1440 @ 1.6 got
# an 80%-covered panel), so drawing was moved out to awww and Noctalia was only
# told about the change so it could re-derive the palette. Under DMS that
# bridge is gone in both directions:
#
#   - DMS paints its own wallpaper surface (correct at scale 1.6), so awww is
#     no longer involved at all.
#   - DMS's IPC owns the wallpaper state: `dms ipc call wallpaper set <path>`
#     records it, repaints it AND regenerates every matugen palette (GTK, Qt,
#     kitty, niri colours...), which under Noctalia needed the separate
#     wallpaper_changed hook.
#
# So all that remains of the old machinery is the rotator: pick a random image
# from ~/Pictures/Wallpapers and hand it to DMS. The same 900s interval, same
# random order, same single source of truth for what is on screen.
let
  wallpapers = "${config.home.homeDirectory}/Pictures/Wallpapers";

  wallpaper-rotate = pkgs.writeShellApplication {
    name = "wallpaper-rotate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.dms-shell # provides the `dms` binary (IPC + screenshot CLI)
    ];
    text = ''
      dir="${wallpapers}"
      interval=900

      pick() {
        find "$dir" -type f \
          \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
             -o -iname '*.webp' -o -iname '*.bmp' \) | shuf -n1
      }

      apply() {
        local img
        img="$(pick)"
        [ -n "$img" ] || return 0

        # Telling DMS is enough: it records the path, repaints and re-derives
        # every palette via matugen. Fails silently when the shell is not up
        # (e.g. running this from a bare TTY), which is fine — the next tick
        # tries again.
        dms ipc call wallpaper set "$img" >/dev/null 2>&1 || true
      }

      apply
      if [ "''${1-}" = "--watch" ]; then
        while true; do
          sleep "$interval"
          apply
        done
      fi
    '';
  };
in
{
  home.packages = [ wallpaper-rotate ];

  # Creates ~/Pictures/Wallpapers, which is NOT in this repo — the images there
  # are other people's work and this repo is public.
  #
  # This is load-bearing, not tidiness. wallpaper-rotate is a
  # writeShellApplication, so it runs under `set -euo pipefail`, and its `find`
  # has no `2>/dev/null`: against a directory that does not exist, find exits
  # non-zero, pipefail propagates it, and the script dies at login instead of
  # simply having nothing to show. An *empty* directory is handled fine — `pick`
  # returns nothing and `apply` bails on its own — so all this has to guarantee
  # is that the path exists.
  #
  # (fastfetch's image folder needs no equivalent: fastfetch-random discards
  # find's stderr and falls through to the config's own logo. See
  # ./terminal/fastfetch.nix.)
  home.file."Pictures/Wallpapers/.keep".text = "";
}
