{ pkgs, ... }:

# Neovim and the tools LazyVim expects to find on PATH. The configuration
# itself is ../config/nvim, symlinked out of the store by ../home.nix so it
# stays editable without a rebuild — LazyVim writes its own lockfile and plugin
# state there.
#
# These are here rather than in a devshell because they follow the editor, not
# a project: opening any file anywhere should give you working search and
# completion.
{
  home.packages = with pkgs; [
    neovim

    # Telescope shells out to both of these. Without them its file and grep
    # pickers fall back to something much slower, or fail outright.
    ripgrep
    fd
    fzf

    # Language servers. LazyVim can install these itself through Mason, but
    # Mason downloads prebuilt binaries into ~/.local/share, and those are
    # dynamically linked against paths that do not exist on NixOS. Declaring
    # them here is what makes them work at all.
    lua-language-server # the LazyVim config itself is Lua
    nil # Nix
    nixpkgs-fmt # formatter for the same

    # Needed by the language servers that ship as npm packages, which is most
    # of them. This is also the only copy of node on the system: ../home.nix
    # deliberately does not duplicate it, and project toolchains come from
    # ../devshells instead.
    nodejs
  ];
}
