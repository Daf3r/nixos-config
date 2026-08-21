{ config, lib, pkgs, inputs, ... }:
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

  # Bound here rather than inline because both the package list and the desktop
  # entry below have to name the exact same store path.
  hermes-desktop = pkgs.callPackage ./pkgs/hermes-desktop-sandbox.nix { };
in
{
  imports = [
    ./terminal.nix
    ./apps.nix
    ./noctalia.nix
    ./dms.nix # coexists with Noctalia and autostarts nothing — see its header
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
  #
  # ~/.grok/bin holds xAI's Grok CLI, installed on 2026-08-12 by its own
  # curl | bash installer rather than by Nix: the binary is statically linked,
  # so it runs here unpatched, and it keeps itself up to date from the stable
  # channel. That installer also tries to append a fish_add_path line to
  # ~/.config/fish/config.fish, which home-manager owns and points at the store,
  # so it dies on a read-only filesystem before writing anything. Without this
  # entry the install silently ends with `grok` off PATH.
  # ~/.local/bin is where Hermes Agent's installer drops its `hermes` launcher.
  # That installer has the same failure mode as Grok's, but worse: when it finds
  # ~/.local/bin missing from PATH it tries to append a fish_add_path line to
  # ~/.config/fish/config.fish, dies on the read-only store symlink, and — since
  # it runs under `set -e` — aborts before it ever writes ~/.hermes/.env or runs
  # its setup wizard, leaving a half-configured install behind. Declaring the
  # directory here makes the installer take its "already on PATH" branch and
  # never touch the fish config at all.
  # ~/.kimi-code/bin holds Moonshot's Kimi Code CLI, installed on 2026-08-13 by
  # the third curl | bash installer to hit this same wall: it copies the binary,
  # then dies with "Permission denied" trying to write the fish config, so the
  # tool is fully installed and simply unreachable. The binary is dynamically
  # linked and needs libstdc++, which glibc here does not carry — it runs only
  # because nix-ld is enabled in ../configuration.nix, and would die with a
  # loader error without it.
  home.sessionPath = [
    "$HOME/.npm-global/bin"
    "$HOME/.grok/bin"
    "$HOME/.local/bin"
    "$HOME/.kimi-code/bin"
  ];

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

    # gnumake is here for the same reason, and gcc alone was not enough. Hermes
    # Agent's desktop workspace depends on node-pty, which ships no prebuilt
    # binary for linux-x64 and falls back to `node-gyp rebuild` — that needs a
    # compiler AND make. Without this, `hermes desktop` and every `hermes
    # update` die with "gyp ERR! stack Error: not found: make" after minutes of
    # npm work. Hermes runs npm from its own checkout, outside direnv, so its
    # bundled dev shell never gets a chance to provide it.
    gnumake

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
      # This used to carry `nix-search-tv.overrideAttrs { env.GOEXPERIMENT =
      # "jsonv2"; }`, inherited from the nixtalia starter. nixpkgs now sets that
      # exact value itself, and adds `ldflags = [ "-s" ]` — which is what strips
      # the symbol table where a Go binary records the toolchain path.
      #
      # Keeping the override forced a local rebuild that lost that protection,
      # and `buildGoModule` refuses the result: "output nix-search-tv-2.2.8 is
      # not allowed to refer to /nix/store/…-go-1.26.5". Without it the package
      # comes straight from the binary cache. Found by ../updates.nix.
      runtimeInputs = with pkgs; [
        fzf
        nix-search-tv
      ];
      text = ''exec "${pkgs.nix-search-tv.src}/nixpkgs.sh" "$@"'';
    })

    # Not the flake's package directly: it needs a flag before it can reach the
    # keyring under niri, or every sign-in is lost on exit. See the file.
    (pkgs.callPackage ./pkgs/claude-desktop-keyring.nix {
      claude-desktop = inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.default;
    })

    # ChatGPT Desktop, from OpenAI's official Linux .deb and wrapped for the
    # same keyring reason as Claude above.
    # It shells out to the `codex` CLI at runtime and finds it on PATH — see the
    # home.sessionPath note near the top of this file, which exists for this.
    (pkgs.callPackage ./pkgs/chatgpt-desktop-keyring.nix {
      chatgpt-desktop = pkgs.callPackage ./pkgs/chatgpt-desktop.nix { };
    })

    # `bwrap` on PATH, requested for ChatGPT Desktop. Nothing in the .deb
    # references it — the package was grepped and comes up empty — so the caller
    # is something the app shells out to at runtime rather than the app itself,
    # the way it already shells out to `codex`. A sandbox helper that is missing
    # fails the way sandboxes do: the caller either refuses to run the sandboxed
    # step or silently runs it unsandboxed, and neither says "bwrap".
    bubblewrap

    # Hermes Desktop's launcher asks for sudo from a menu icon that has no way
    # to answer it, so without this the app stops opening after any update that
    # rebuilds it. See the package for the whole story.
    hermes-desktop
  ];

  # Hermes Agent writes this entry itself on every desktop launch, and it gets
  # the Exec line wrong: `resolve_hermes_bin` prefers argv[0] over PATH, and
  # under the ~/.local/bin shim argv[0] is the checkout entrypoint, whose
  # `#!/usr/bin/env python3` shebang picks the system interpreter — which has
  # none of Hermes' dependencies. The entry then dies with ModuleNotFoundError
  # before any window appears, and because it carries Terminal=false nothing is
  # ever shown: clicking the icon does nothing at all.
  #
  # Writing it here makes the path a read-only store symlink. Hermes' rewrite
  # then fails with OSError, which its own code already treats as non-fatal
  # ("a convenience, never a reason to fail a launch"), so the launch still
  # works and the correct entry survives. That matters because Hermes
  # auto-updates: the local patch that fixes the generator lives in a checkout
  # whose updater autostashes local changes, and one conflict against upstream
  # would silently restore the broken entry.
  #
  # It has to be `xdg.dataFile`, not `xdg.desktopEntries`. That option builds a
  # package and installs it through home.packages, so the entry lands in
  # ~/.nix-profile/share/applications while Hermes keeps rewriting the copy in
  # ~/.local/share/applications — which XDG_DATA_DIRS ranks *higher*, so the
  # broken one still wins and the menu grows a duplicate icon. Only a file at
  # the exact path Hermes writes to can stop it.
  #
  # Exec points at ./pkgs/hermes-desktop-sandbox.nix rather than at the
  # ~/.local/bin shim: `hermes desktop` alone demands sudo for its chrome-sandbox
  # preflight and, finding no terminal behind the icon, exits before any window
  # appears — the same do-nothing symptom as above, from a different cause. That
  # wrapper still runs Hermes' own desktop command underneath.
  xdg.dataFile."applications/hermes.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Hermes
    GenericName=Hermes Desktop
    Comment=Launch Hermes Desktop
    Exec=${lib.getExe hermes-desktop}
    Icon=${config.home.homeDirectory}/.hermes/hermes-agent/apps/desktop/assets/icon.png
    Terminal=false
    Categories=Utility;
    StartupNotify=true
    StartupWMClass=Hermes
  '';

  xdg.configFile = builtins.mapAttrs
    (name: subpath: {
      source = create_symlink "${dotfiles}/${subpath}";
      recursive = true;
    })
    configs;
}
