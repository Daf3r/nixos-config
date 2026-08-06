{ config, pkgs, ... }:

{
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    tree
  ];

  fonts.fontconfig.enable = true;
  fonts.packages = with pkgs; [
    # UI text. Noctalia's shell.font_family points at Noto Sans; it draws its
    # own icons (Tabler glyphs are built into the binary), so it does not need
    # a Nerd Font.
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    liberation_ttf

    # Monospace for kitty/neovim. Nerd variant for editor/prompt glyphs.
    nerd-fonts.jetbrains-mono
  ];

  # Dropped from the starter: nerd-fonts.fira-code, nerd-fonts.droid-sans-mono,
  # cascadia-code, monaspace, hack-font, fantasque-sans-mono — six more
  # monospace families that nothing in this config selects.
}
