{ config, lib, pkgs, inputs, ... }:

let
  # embeddedTheme rewrites ConfigFile= in the theme's metadata.desktop, so the
  # chosen variant is baked into the derivation. Change the string and rebuild.
  sddmTheme = pkgs.sddm-astronaut.override {
    embeddedTheme = "hyprland_kath";
  };

  # SDDM's Wayland greeter is weston in kiosk mode, and NixOS generates its
  # weston.ini from a fixed set of options with no way to configure outputs. The
  # greeter was therefore landing on HDMI-A-1 — weston picks the first connected
  # output, and the MSI enumerates ahead of the panel.
  #
  # Overriding the config file is the whole fix: `mode=off` disables an output in
  # weston, so the greeter has only the laptop panel to draw on. This affects the
  # login screen alone; both monitors come up normally once a session starts.
  #
  # Keying on HDMI-A-1 is safe even though the *panel's* connector name drifts
  # between eDP-1 and eDP-2 across boots (see ./gpu.nix): there is only one HDMI
  # connector, so that name does not move. Disabling the monitor we can name
  # reliably is what makes this robust.
  #
  # The keyboard and libinput blocks are copied from what the module generates so
  # nothing is lost by replacing the file — keep them in step with
  # services.xserver.xkb below if that ever changes.
  sddmWestonIni = pkgs.writeText "weston.ini" ''
    [keyboard]
    keymap_layout=us
    keymap_model=pc104
    keymap_options=terminate:ctrl_alt_bksp
    keymap_variant=

    [libinput]
    enable-tap=true
    left-handed=false

    [output]
    name=HDMI-A-1
    mode=off
  '';
in
{
  imports = [ inputs.noctalia.nixosModules.default ];

  # niri is the only session. Hyprland was the default until 2026-08-07 and was
  # removed once niri had been running as the daily driver long enough to trust;
  # Mango and Plasma 6 went earlier, with the nixtalia starter config.
  #
  # Its config is config/niri/config.kdl, symlinked out of the store by home.nix
  # and validated with `niri validate`. Scrollable tiling: windows sit in one
  # infinite horizontal strip instead of subdividing a fixed screen.
  programs.niri = {
    enable = true;

    # Off: this defaults to true and would pull in Nautilus purely to act as the
    # GNOME portal's file chooser. Dolphin is the file manager here, and
    # xdg-desktop-portal-gtk (configured below) already provides FileChooser.
    useNautilus = false;
  };

  # System side of Noctalia v5. The shell itself, its settings and its autostart
  # live in the home-manager module (see ./noctalia.nix).
  programs.noctalia = {
    enable = true;
    # Pulls in NetworkManager, Bluetooth, UPower and power-profiles-daemon,
    # which back the Control Center's network/bluetooth/battery/power widgets.
    recommendedServices.enable = true;
  };

  # The niri module registers xdg-desktop-portal-gnome, which implements
  # screencast/screenshot but is not what should answer FileChooser here — it
  # would want Nautilus (see useNautilus above). The module already sets
  # FileChooser=gtk as preferred in its own niri-portals.conf; this supplies the
  # gtk portal that setting points at. Without it, "open file" / "save as"
  # dialogs in Brave, Steam and Electron apps fall back or fail outright.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Creates the i2c group, loads i2c-dev and installs the udev rules that let
  # members of that group reach /dev/i2c-*. ddcutil (already in the package list
  # below) needs all three; users.users.daf3r joins the group in
  # ./configuration.nix. Verify with `ddcutil detect`, which should name the MSI
  # MP243X on an /dev/i2c-* bus. No reboot is needed: a switch restarts
  # systemd-udevd, which is enough for the new rules to take effect.
  hardware.i2c.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;

    # Same command the module builds by default, with our weston.ini in place of
    # the generated one so the greeter stays on the laptop panel. See the note
    # on sddmWestonIni above.
    wayland.compositorCommand =
      "${lib.getExe pkgs.weston} --shell=kiosk -c ${sddmWestonIni}";

    # The stock SDDM greeter is the Qt default. sddm-astronaut bundles ten
    # variants and `embeddedTheme` picks which one is compiled in — swap the
    # string and rebuild to change it, no other edit needed. The full set is
    # astronaut, black_hole, cyberpunk, hyprland_kath, jake_the_dog,
    # japanese_aesthetic, pixel_sakura, pixel_sakura_static,
    # post-apocalyptic_hacker and purple_leaves; previews are in the upstream
    # README at github.com/Keyitdev/sddm-astronaut-theme.
    #
    # hyprland_kath, jake_the_dog and pixel_sakura use a video/gif background,
    # which is why the package propagates qtmultimedia.
    theme = "sddm-astronaut-theme";
    package = pkgs.kdePackages.sddm; # Qt6 build; the theme is Qt6-only

    # The theme itself goes in environment.systemPackages below, because SDDM
    # discovers themes under /run/current-system/sw/share/sddm/themes.
    # extraPackages is for Qt plugins and QML libraries only — here, the
    # qtsvg / qtmultimedia / qtvirtualkeyboard the theme's QML imports at
    # runtime, which the greeter cannot resolve on its own.
    extraPackages = sddmTheme.propagatedBuildInputs;
  };

  # Keyboard layout for the login screen; niri sets its own in config.kdl.
  services.xserver.xkb.layout = "us";

  environment.systemPackages = with pkgs; [
    # Noctalia is a native binary and screenshots/clipboard are built in, so no
    # grim/slurp/wl-clipboard needed. These two are the exceptions:
    playerctl # Noctalia has no media-control IPC verb; the media keys use this
    ddcutil # now actually used: noctalia.nix sets brightness.enable_ddcutil

    sddmTheme # must be here, not in sddm.extraPackages — see the note above

    # X11 support for the niri session. niri has no built-in XWayland — there is
    # no enable switch on the module to flip — and instead integrates
    # xwayland-satellite, spawning it on demand when the first X11 client
    # connects. It only has to be on PATH — config/niri/
    # config.kdl deliberately does not spawn it, and documents the fallback if
    # the on-demand handshake ever fails.
    #
    # Not optional here: Steam and CS2 are both X11.
    xwayland-satellite
  ];
}
