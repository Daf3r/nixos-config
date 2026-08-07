{ config, pkgs, ... }:

{
  imports = [
    ./terminal/fish.nix
    ./terminal/kitty.nix
    ./terminal/nvim.nix
  ];

  home.packages = with pkgs; [
    btop
    fastfetch
    gh
  ];

  # kitty moved out of this list: it is installed by programs.kitty in
  # ./terminal/kitty.nix, which also manages kitty.conf. Listing the package
  # here as well would be redundant.

  # Removed from the starter's list:
  #   foot, kdePackages.konsole -> two extra terminals nothing launches
  #   starship, eza             -> already installed by programs.starship /
  #                                programs.eza in terminal/fish.nix
  #   bootdev-cli               -> Boot.dev course CLI; re-add if you use it
}
