{ config, pkgs, inputs, ... }:

# Wallpaper rendering, deliberately taken away from Noctalia.
#
# Noctalia v5.0.0 sizes its wallpaper surface as `physical_resolution /
# ceil(scale)` — it divides by the integer Wayland buffer scale instead of the
# real fractional scale. On eDP-1 (2560x1440 @ scale 1.6) that draws the image
# at 1280x720 logical px inside a 1600x900 logical surface, anchored to the
# bottom-left: the image covers 80% of the panel and the rest stays black.
# The maths only works out at integer scales:
#
#   scale 1.0  -> 2560x1440 logical, draws 2560x1440  (correct)
#   scale 1.25 -> 2048x1152 logical, draws 1280x720   (62%)
#   scale 1.6  -> 1600x900  logical, draws 1280x720   (80%)
#   scale 2.0  -> 1280x720  logical, draws 1280x720   (correct)
#
# Ruled out: restarting the shell, QT_SCALE_FACTOR_ROUNDING_POLICY=PassThrough,
# accessibility.ui_scale, and patching the QML (v5 ships a compiled binary).
# Scale 1 makes everything too small on a 17" 1440p panel and scale 2 makes it
# too large, so the fractional 1.6 stays and only the wallpaper module goes.
#
# Everything else Noctalia draws (bar, panels, lockscreen) is correct at 1.6 —
# this is specific to the wallpaper surface.
let
  wallpapers = "${config.home.homeDirectory}/Pictures/Wallpapers";
  noctaliaPkg = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # The other half of the bridge: what actually paints the image.
  #
  # Bound to Noctalia's `wallpaper_changed` hook in ./noctalia.nix, so it runs
  # whenever the recorded wallpaper changes — from the Settings picker, from
  # `noctalia msg wallpaper-set`, from anywhere. Noctalia hands it two
  # variables:
  #
  #   NOCTALIA_WALLPAPER_PATH       the image
  #   NOCTALIA_WALLPAPER_CONNECTOR  the output, empty when not output-specific;
  #                                 the hook fires once per changed connector
  #
  # This is what was missing. Picking a wallpaper in Noctalia updated its record
  # and re-derived the palette — so the colours changed — while the image on
  # screen stayed put, because Noctalia's own drawing module is disabled and
  # nothing told swww.
  wallpaper-apply = pkgs.writeShellApplication {
    name = "wallpaper-apply";
    runtimeInputs = [ pkgs.swww pkgs.coreutils ];
    text = ''
      img="''${NOCTALIA_WALLPAPER_PATH:-''${1:-}}"
      [ -n "$img" ] || exit 0
      [ -e "$img" ] || exit 0

      # swww img fails until the daemon is accepting connections. Matters at
      # login, where the hook can fire before swww-daemon is up.
      for _ in $(seq 1 50); do
        swww query >/dev/null 2>&1 && break
        sleep 0.2
      done

      connector="''${NOCTALIA_WALLPAPER_CONNECTOR:-}"
      if [ -n "$connector" ]; then
        swww img --outputs "$connector" "$img" \
          --transition-type fade --transition-duration 1.5
      else
        swww img "$img" --transition-type fade --transition-duration 1.5
      fi
    '';
  };

  # Replaces Noctalia's [wallpaper.automation]: same 900s interval, same random
  # order, same 1.5s fade.
  wallpaper-rotate = pkgs.writeShellApplication {
    name = "wallpaper-rotate";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils noctaliaPkg ];
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

        # Deliberately does NOT call swww here. Telling Noctalia is enough: it
        # records the path, re-derives the palette, and fires wallpaper_changed,
        # which runs wallpaper-apply above. Calling swww directly as well would
        # paint the same image twice and show two fades.
        noctalia msg wallpaper-set "$img" >/dev/null 2>&1 || true
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
  home.packages = [ pkgs.swww wallpaper-rotate wallpaper-apply ];

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
