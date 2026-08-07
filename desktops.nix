{ config, pkgs, inputs, ... }:

let
  # embeddedTheme rewrites ConfigFile= in the theme's metadata.desktop, so the
  # chosen variant is baked into the derivation. Change the string and rebuild.
  sddmTheme = pkgs.sddm-astronaut.override {
    embeddedTheme = "hyprland_kath";
  };
in
{
  imports = [ inputs.noctalia.nixosModules.default ];

  # Hyprland stays the default, known-good session. Mango and Plasma 6 were
  # dropped along with the nixtalia starter config.
  programs.hyprland = {
    enable = true;
    xwayland.enable = true; # CS2 and Steam's overlay still need it
  };

  # niri, installed *alongside* Hyprland rather than replacing it — both appear
  # in SDDM's session list, so trying it costs nothing and Hyprland is always
  # one logout away. Its config is config/niri/config.kdl, symlinked out of the
  # store by home.nix and validated with `niri validate`.
  #
  # It is a different paradigm, not an upgrade: scrollable tiling, where windows
  # sit in one infinite horizontal strip instead of subdividing a fixed screen.
  # Noctalia supports both compositors natively and ships a `niri` theme
  # template, so the shell is identical either way.
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

  # The Hyprland module registers xdg-desktop-portal-hyprland, which implements
  # screencast/screenshot but not FileChooser. Without the GTK portal, "open
  # file" / "save as" dialogs in Brave, Steam and Electron apps fall back or
  # fail outright.
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

  # Keyboard layout for the login screen; Hyprland sets its own in hyprland.conf.
  services.xserver.xkb.layout = "us";

  environment.systemPackages = with pkgs; [
    # Noctalia is a native binary and screenshots/clipboard are built in, so no
    # grim/slurp/wl-clipboard needed. These two are the exceptions:
    playerctl # Noctalia has no media-control IPC verb; the media keys use this
    ddcutil # now actually used: noctalia.nix sets brightness.enable_ddcutil

    sddmTheme # must be here, not in sddm.extraPackages — see the note above

    # X11 support for the niri session. Unlike programs.hyprland, the niri
    # module sets enableXWayland = false: niri has no built-in XWayland and
    # instead integrates xwayland-satellite, spawning it on demand when the
    # first X11 client connects. It only has to be on PATH — config/niri/
    # config.kdl deliberately does not spawn it, and documents the fallback if
    # the on-demand handshake ever fails.
    #
    # Not optional here: Steam and CS2 are both X11.
    xwayland-satellite
  ];
}
