{ config, pkgs, ... }:

{
  programs.mangohud = {
    enable = true;
    settings = {
      full = true;
      limit_fps = 144;
    };
  };

  home.packages = with pkgs; [
    # Brave Origin is not in nixpkgs, so it is packaged locally from Brave's
    # own .deb — see ./pkgs/brave-origin.nix for how to bump it.
    (pkgs.callPackage ./pkgs/brave-origin.nix { })

    kdePackages.dolphin # SUPER+E in hyprland.conf
    kdePackages.kate # SUPER+K
    filezilla
    spotify
    vesktop
  ];

  # Removed from the starter: pcmanfm (second file manager nothing launches),
  # spicetify-cli (only useful with the Spotify theming template enabled, and
  # that one is a *community* template, so it would go in
  # theme.templates.community_ids — not builtin_ids), vivaldi and
  # firefox (you asked for brave-origin), pywalfox-native (drove v4's pywalfox
  # template, which no longer exists in v5).
}
