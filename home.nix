{ config, pkgs, inputs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/nixtalia/config"; #change this if you move your configs
  create_symlink = path: config.lib.file.mkOutOfStoreSymlink path;

  configs = {
    nvim = "nvim";
    foot = "foot";
    hypr = "hypr";
    niri = "niri";
    noctalia = "noctalia";
    mango = "mango";

  };
in
{

  imports = [
    ./terminal.nix
    ./apps.nix

  ];

  home.username = "nixtalia"; # Change this for your username
  home.homeDirectory = "/home/nixtalia"; #same name as above here, unless you move your home directory
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    gcc
    (pkgs.writeShellApplication {
      name = "ns";
      runtimeInputs = with pkgs; [
        fzf
        (nix-search-tv.overrideAttrs { env.GOEXPERIMENT = "jsonv2"; })
      ];
      text = ''exec "${pkgs.nix-search-tv.src}/nixpkgs.sh" "$@"'';
    })

    inputs.zen-browser.packages.${pkgs.system}.default
  ];

  xdg.configFile = builtins.mapAttrs
    (name: subpath: {
      source = create_symlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
