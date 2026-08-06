{ config, pkgs, inputs, ... }:

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

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  # Keyboard layout for the login screen; Hyprland sets its own in hyprland.conf.
  services.xserver.xkb.layout = "us";

  environment.systemPackages = with pkgs; [
    # Noctalia is a native binary and screenshots/clipboard are built in, so no
    # grim/slurp/wl-clipboard needed. These two are the exceptions:
    playerctl # Noctalia has no media-control IPC verb; the media keys use this
    ddcutil # only consumed if you set brightness.enable_ddcutil = true
  ];
}
