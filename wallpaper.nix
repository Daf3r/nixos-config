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
  wallpapers = "${config.home.homeDirectory}/nixos-config/Pictures/Wallpapers";
  noctaliaPkg = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Replaces Noctalia's [wallpaper.automation]: same 900s interval, same random
  # order, same 1.5s fade.
  wallpaper-rotate = pkgs.writeShellApplication {
    name = "wallpaper-rotate";
    runtimeInputs = [ pkgs.swww pkgs.coreutils pkgs.findutils noctaliaPkg ];
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
        swww img "$img" --transition-type fade --transition-duration 1.5

        # Noctalia's theme.source = "wallpaper" derives the palette from the
        # path it has on record. The drawing module is off, but wallpaper-set
        # still updates that path, so m3-content theming keeps following the
        # wallpaper.
        noctalia msg wallpaper-set "$img" >/dev/null 2>&1 || true
      }

      # swww img fails until the daemon is accepting connections.
      for _ in $(seq 1 50); do
        swww query >/dev/null 2>&1 && break
        sleep 0.2
      done

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
  home.packages = [ pkgs.swww wallpaper-rotate ];
}
