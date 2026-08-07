{ ... }:

# Makes a bare SUPER tap open the app launcher.
#
# Neither compositor can do this properly on its own. niri rejects a
# modifier-only bind outright — `Mod { ... }` is an invalid value and there is no
# on-release property — so there is nothing to configure there at all. Hyprland
# has `bindr`, which fires on release, but it fires whether or not another key
# was pressed in between, so SUPER+E would open Dolphin *and* the launcher.
#
# keyd solves it a layer lower, at evdev, before either compositor sees the key.
# `overload(meta, f13)` means: hold it and it is the Meta modifier exactly as
# before, so every SUPER+<key> binding keeps working; tap and release it alone
# and it emits F13 instead. Both configs then bind F13 to the launcher, and the
# behaviour is identical in either session — which the compositor-specific
# approaches could not manage.
#
# F13 because it is a real key in the Linux keycode table that no physical
# keyboard here has, so nothing else will ever send it.
#
# Safety: keyd grabs the keyboard, so a broken config could in principle lock you
# out. It has a built-in escape hatch — pressing backspace + escape + enter
# together terminates the daemon and restores the raw keyboard. Worth knowing
# before editing this file. The config is also validated at build time by the
# NixOS module.
{
  services.keyd = {
    enable = true;

    keyboards.default = {
      ids = [ "*" ];

      settings.main = {
        # Left Super only. The right one is left alone as a plain modifier, so
        # there is always an unmodified Meta key available.
        leftmeta = "overload(meta, f13)";
      };
    };
  };
}
