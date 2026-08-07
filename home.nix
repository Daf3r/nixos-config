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
    niri = "niri";
  };
in
{
  imports = [
    ./terminal.nix
    ./apps.nix
    ./noctalia.nix
    ./wallpaper.nix
    ./gtk.nix
    ./qt.nix
    ./nix-tools.nix
    ./gamemode.nix
  ];

  home.username = "daf3r";
  home.homeDirectory = "/home/daf3r";
  home.stateVersion = "25.05";
  programs.home-manager.enable = true;

  # home.sessionPath used to carry $HOME/.npm-global/bin, for packages installed
  # with `npm i -g`. The directory is empty and the approach is superseded:
  # per-project toolchains now come from ./devshells through direnv, so a global
  # npm prefix has nothing left to hold. One line to restore if that changes.

  home.packages = with pkgs; [
    # nodejs is deliberately absent here: ./terminal/nvim.nix already installs
    # it — LazyVim needs it for the language servers that ship as npm packages —
    # and declaring the same package in two files only makes it unclear which
    # one is the reason it is present.
    #
    # gcc stays. Neovim's treesitter compiles its parsers with a C compiler at
    # runtime, so this is not a development dependency that could move into a
    # devshell.
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
    inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  xdg.configFile = builtins.mapAttrs
    (name: subpath: {
      source = create_symlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
