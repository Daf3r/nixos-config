{ config, pkgs, ... }:

{
  imports = [
    ./terminal/fish.nix
    ./terminal/nvim.nix
  ];

  home.packages = with pkgs; [
    kitty # the terminal hyprland.conf binds to SUPER+Return
    btop
    fastfetch
    gh
  ];

  # Removed from the starter's list:
  #   foot, kdePackages.konsole -> two extra terminals nothing launches
  #   starship, eza             -> already installed by programs.starship /
  #                                programs.eza in terminal/fish.nix
  #   bootdev-cli               -> Boot.dev course CLI; re-add if you use it
}
