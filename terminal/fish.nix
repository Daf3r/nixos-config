{ pkgs, ... }:

{
  programs.fish = {
    enable = true;

    shellInit = ''
      set -gx STARSHIP_CONFIG ~/nixos-config/config/starship.toml
    '';

    interactiveShellInit = ''
      set -g fish_greeting ""

      # fastfetch-random picks a different image from Pictures/Fastfetch on
      # every launch and hands it to fastfetch — see ./fastfetch.nix. It falls
      # back to plain fastfetch when that folder is empty, so an interactive
      # shell can never fail to start because of this.
      if type -q fastfetch-random
        fastfetch-random
      else if type -q fastfetch
        fastfetch
      end
    '';

    shellAbbrs = {
      # --- Rebuilds ---
      #
      # These go through nh rather than nixos-rebuild. The reason is the output:
      # nh prints a diff of the packages a switch will change, where
      # nixos-rebuild prints a wall of store paths. NH_FLAKE is set in
      # ../configuration.nix, so none of them needs the flake path spelled out.
      ns = "nh os switch"; # apply now
      nb = "nh os boot"; # apply at next boot
      nt = "nh os test"; # apply now, no boot entry
      nd = "nh os build"; # build only, no sudo, no changes

      # nixos-rebuild directly, for when nh itself is what broke.
      nrs = "sudo nixos-rebuild switch --flake ~/nixos-config";

      # --- Flake maintenance ---
      flakeup = "nix flake update --flake ~/nixos-config";
      # Bump only Noctalia, leaving nixpkgs pinned:
      noctup = "nix flake update noctalia --flake ~/nixos-config";
      ngen = "nh os info"; # list generations

      # --- git ---
      #
      # Deliberately no `git add .`: staging everything unseen is how unrelated
      # changes end up in one commit. `ga` takes paths, and `lg` covers the case
      # where you want to stage interactively.
      lg = "lazygit"; # the one that gets used most
      gs = "git status --short --branch";
      ga = "git add";
      gc = "git commit";
      gp = "git push";
      gl = "git log --oneline --graph --decorate -20";
      gd = "git diff"; # rendered by delta, see ./tools.nix
      gds = "git diff --staged";
      gco = "git checkout";
      gb = "git branch";

      # --- direnv ---
      # Needed once per project, and impossible to remember the first time.
      da = "direnv allow";
      dr = "direnv reload";
    };

    shellAliases = {
      vim = "nvim";

      # No ls/ll/la here on purpose: programs.eza below generates exactly those,
      # from `icons = "auto"`, and duplicating them by hand only makes it
      # ambiguous which definition is in effect.

      # yazi and zellij are new enough that the short names have not stuck yet.
      y = "yazi";
      zj = "zellij";
    };
  };

  # --- Integrations ---

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  # Smart cd: `z down` jumps to ~/Downloads by frecency.
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # ls replacement. The fish integration is what defines ls, ll, la, lla and lt
  # — see the note in shellAliases above.
  programs.eza = {
    enable = true;
    enableFishIntegration = true;
    icons = "auto";
  };
}
