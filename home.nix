{ config, pkgs, inputs, ... }:
let
  # The nixtalia starter had this as "${homeDirectory}/daf3r/config", which
  # resolved to /home/daf3r/daf3r/config — a path that never existed, so every
  # symlink below pointed at nothing.
  dotfiles = "${config.home.homeDirectory}/nixos-config/config";
  create_symlink = path: config.lib.file.mkOutOfStoreSymlink path;

  # Mutable, symlinked out of the store so you can edit them live.
  # Noctalia is deliberately absent: it is fully declarative in ./noctalia.nix.
  # "foot" was in the starter's list but config/foot never existed, so it only
  # ever produced a dangling symlink.
  configs = {
    nvim = "nvim";
    hypr = "hypr";
  };
in
{
  imports = [
    ./terminal.nix
    ./apps.nix
    ./noctalia.nix
    ./wallpaper.nix
    ./gtk.nix
  ];

  home.username = "daf3r";
  home.homeDirectory = "/home/daf3r";
  home.stateVersion = "25.05";
  home.sessionPath = [ "$HOME/.npm-global/bin" ];
  programs.home-manager.enable = true;

  home.packages = with pkgs; [
    nodejs
    gcc
    (pkgs.writeShellApplication {
      name = "ns";
      runtimeInputs = with pkgs; [
        fzf
        (nix-search-tv.overrideAttrs { env.GOEXPERIMENT = "jsonv2"; })
      ];
      text = ''exec "${pkgs.nix-search-tv.src}/nixpkgs.sh" "$@"'';
    })

    inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  xdg.configFile = builtins.mapAttrs
    (name: subpath: {
      source = create_symlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
