{ pkgs, ... }:

{
  programs.fish = {
    enable = true;

    shellInit = ''
      set -gx STARSHIP_CONFIG ~/daf3r/config/starship.toml
    '';

    interactiveShellInit = ''
      # QoL: Disable the "Welcome to fish" message
      set -g fish_greeting ""

      # Fastfetch with custom logo
      # The check ensures the shell still opens even if fastfetch isn't installed
      if type -q fastfetch
        fastfetch --logo ~/nixos-config/Pictures/tbearlogo.png --logo-type auto --logo-width 35 --logo-height 30
      end
    '';

    shellAbbrs = {
      nrs = "sudo nixos-rebuild switch --flake ~/nixos-config#my-nix-den";
      flakeup = "nix flake update";

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
