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

  # Hyprland is the only compositor now. Niri, Mango and Plasma 6 were dropped
  # along with the nixtalia starter config.
  programs.hyprland = {
    enable = true;
    xwayland.enable = true; # CS2 and Steam's overlay still need it
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
  # ./configuration.nix. Verify after a reboot with `ddcutil detect`.
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
  ];
}
