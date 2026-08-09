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

  # Restored 2026-08-08. Per-project toolchains still come from ./devshells
  # through direnv, so this is not for project dependencies — it is for the one
  # global npm install that is genuinely global: the `codex` CLI, which ChatGPT
  # Desktop shells out to at runtime.
  #
  # It was reachable before this line existed, but only through fish_user_paths,
  # a universal variable sitting in ~/.config/fish/fish_variables — imperative
  # state outside this repo, which a fresh install would not reproduce. Declaring
  # it here does not remove that variable; it just stops being the only source.
  home.sessionPath = [ "$HOME/.npm-global/bin" ];

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

    # python3 is here for the same reason as gcc, not as a language toolchain:
    # Claude Code's security-guidance plugin runs its hooks through
    # `sg-python.sh`, which probes python3, python and `py -3` and gives up if
    # none answer. On a system without any of them the plugin fails on every
    # prompt, commit and push — quietly, with a non-blocking error that says
    # nothing about what it stopped doing.
    #
    # A devshell cannot cover this: the hooks run in Claude Code's environment,
    # outside direnv. Project Python belongs in ./devshells as usual.
    python3
    (pkgs.writeShellApplication {
      name = "ns";
      runtimeInputs = with pkgs; [
        fzf
        (nix-search-tv.overrideAttrs { env.GOEXPERIMENT = "jsonv2"; })
      ];
      text = ''exec "${pkgs.nix-search-tv.src}/nixpkgs.sh" "$@"'';
    })

    inputs.zen-browser.packages.${pkgs.stdenv.hostPlatform.system}.default

    # Not the flake's package directly: it needs a flag before it can reach the
    # keyring under niri, or every sign-in is lost on exit. See the file.
    (pkgs.callPackage ./pkgs/claude-desktop-keyring.nix {
      claude-desktop = inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default;
    })

    # ChatGPT Desktop, wrapped for the same keyring reason as Claude above.
    # It shells out to the `codex` CLI at runtime and finds it on PATH — see the
    # home.sessionPath note near the top of this file, which exists for this.
    (pkgs.callPackage ./pkgs/codex-desktop-keyring.nix {
      codex-desktop = inputs.codex-desktop-linux.packages.${pkgs.stdenv.hostPlatform.system}.codex-desktop;
    })
  ];

  xdg.configFile = builtins.mapAttrs
    (name: subpath: {
      source = create_symlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
