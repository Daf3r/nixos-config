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
    # UI text everywhere: the shell's bar and panels, GTK and Qt windows.
    #
    # IBM Plex Sans rather than the Noto Sans this used to be, and the reason is
    # not taste for its own sake. Noto Sans is the fallback nobody chooses — the
    # typeface a desktop lands on when no one decided — and swapping it is the
    # cheapest change that stops the whole session looking generated. Plex was
    # drawn for interface work by Bold Monday, so it holds up at bar sizes where
    # a display face would fall apart, and it has enough character to be
    # recognisable without asking for attention.
    #
    # DMS's own fontFamily is set separately in its GUI settings — see ./dms.nix
    # for why that file is not declared here. Keep the three in step:
    # DMS fontFamily, gtk.font in ./gtk.nix, and Fonts.general in ./qt.nix.
    ibm-plex

    # Kept as the fallback and for the scripts Plex does not cover — CJK arrives
    # through noto-fonts-cjk-sans below, and emoji through the colour build.
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
