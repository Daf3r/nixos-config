{ ... }:

# Makes a bare SUPER tap open the app launcher.
#
# niri cannot do this on its own: it rejects a modifier-only bind outright —
# `Mod { ... }` is an invalid value and there is no on-release property — so
# there is nothing to configure there at all.
#
# keyd solves it a layer lower, at evdev, before the compositor sees the key.
# `overload(meta, ...)` means: hold it and it is the Meta modifier exactly as
# before, so every SUPER+<key> binding keeps working; tap and release it alone
# and it emits the chord instead. config.kdl binds that chord to the launcher.
#
# The chord is Ctrl+Alt+Shift+P, and the reason it is not simply F13 matters.
# F13 was the obvious choice — a real Linux keycode (183) no physical keyboard
# here can send — and it silently did nothing. The keycode exists in XKB's
# evdev map (`<FK13> = 191`), but no symbols file loaded by the `us` layout
# assigns it a keysym: FK13 only appears in `symbols/fkeys` and some vendor
# files, neither of which `pc`+`us` pulls in. So the key arrived as NoSymbol and
# no compositor binding could ever match it.
#
# Ctrl+Alt+Shift+P is made of keys that certainly have keysyms, and nothing
# else uses that combination. Avoid Ctrl+Alt+F<n> for this: those are VT
# switches.
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
        leftmeta = "overload(meta, C-A-S-p)";
      };
    };
  };
}
