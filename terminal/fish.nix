{ pkgs, ... }:

{
  programs.fish = {
    enable = true;

    shellInit = ''
      set -gx STARSHIP_CONFIG ~/nixos-config/config/starship.toml
    '';

    interactiveShellInit = ''
      # QoL: Disable the "Welcome to fish" message
      set -g fish_greeting ""

      # The starter passed --logo ~/nixos-config/Pictures/tbearlogo.png, which
      # is the original author's logo and does not exist here.
      if type -q fastfetch
        fastfetch
      end
    '';

    shellAbbrs = {
      # --- Rebuilds ---
      # The flake output is named after networking.hostName, so no #attribute
      # is needed and these work from any directory.
      nrs = "sudo nixos-rebuild switch --flake ~/nixos-config"; # apply now
      nrb = "sudo nixos-rebuild boot --flake ~/nixos-config"; # apply at next boot
      nrt = "sudo nixos-rebuild test --flake ~/nixos-config"; # apply now, no boot entry
      nrd = "nixos-rebuild build --flake ~/nixos-config"; # just build, no sudo, no changes

      # --- Flake maintenance ---
      flakeup = "nix flake update --flake ~/nixos-config";
      # Bump only Noctalia, leaving nixpkgs pinned:
      noctup = "nix flake update noctalia --flake ~/nixos-config";

      # Delete generations older than a week, then prune the store.
      ncg = "sudo nix-collect-garbage --delete-older-than 7d";
      ngen = "sudo nix-env --list-generations --profile /nix/var/nix/profiles/system";

      # Git shortcuts are huge quality of life
      gs = "git status";
      ga = "git add .";
      gc = "git commit -m";
      gp = "git push";
    };

    shellAliases = {
      vim = "nvim";
      ls = "eza --icons --group-directories-first";
      ll = "eza -l --icons --group-directories-first";
    };
  };

  # --- Integrations ---

  # Enable Starship Prompt
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
  };

  # Enable Zoxide (Smart 'cd')
  # Usage: type 'z down' to jump to 'Downloads' automatically
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  # Enable Eza (Modern 'ls' replacement)
  programs.eza = {
    enable = true;
    enableFishIntegration = true;
    icons = "auto";
  };
}
