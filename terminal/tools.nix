{ config, pkgs, ... }:

# Command-line tooling. fzf, ripgrep, fd, eza, zoxide and jq were already here —
# these are the gaps, and four of the five have a Noctalia theme template so they
# pick up the same palette as kitty and starship (see ../noctalia.nix).
{
  home.packages = with pkgs; [
    # Terminal file manager. Fast, vim-style keys, image previews in kitty via
    # its graphics protocol. Complements Dolphin rather than replacing it: this
    # is the one that gets used without leaving the terminal.
    yazi

    # Persistent terminal sessions, panes and layouts that survive the terminal
    # closing or crashing. This is the one thing wezterm had over kitty when the
    # terminal question came up; kitty plus zellij covers it without switching.
    zellij
  ];

  # cat with syntax highlighting and git gutters. Also worth having for what it
  # does to *other* tools: it becomes the pager for `--help` output and for
  # `gh` (already installed), so the improvement is not limited to typing `bat`.
  programs.bat = {
    enable = true;
    config.theme = "noctalia"; # written by Noctalia's bat template
  };

  # Full-screen git. The reason it earns a place over the `gs`/`ga`/`gc`
  # abbreviations in ./fish.nix is the things those cannot do comfortably:
  # staging individual lines rather than whole files, interactive rebase,
  # and resolving conflicts with both sides on screen.
  programs.lazygit = {
    enable = true;
    settings = {
      gui.theme = { }; # left to Noctalia's lazygit template
      git.paging = {
        colorArg = "always";
        pager = "delta --dark --paging=never";
      };
    };
  };

  # git itself. It was never configured declaratively — ~/.gitconfig held only a
  # name and an email, hand-written on 2026-08-05.
  # Option names here are the current ones. home-manager renamed the lot:
  # userName/userEmail/extraConfig folded into `settings`, and the delta
  # integration moved out to its own `programs.delta`. The old spellings still
  # work but warn on every rebuild.
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Daf3r";
        email = "87869353+Daf3r@users.noreply.github.com";
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true; # `git push` on a new branch just works
      merge.conflictstyle = "zdiff3"; # shows the common ancestor in conflicts
      diff.algorithm = "histogram";
      rerere.enabled = true; # remember how a conflict was resolved
    };
  };

  # delta replaces git's diff output with syntax-highlighted, side-by-side
  # hunks. It applies to every diff git shows — `git diff`, `git show`,
  # `git log -p` — so it is a single setting that changes all of them.
  programs.delta = {
    enable = true;

    # Used to be implied by programs.git.delta.enable; home-manager now wants it
    # stated, and warns that the automatic version is deprecated.
    enableGitIntegration = true;

    options = {
      navigate = true; # n / N jump between files in the diff
      line-numbers = true;
      side-by-side = true;
      syntax-theme = "Nord"; # bat theme name; Noctalia's is applied separately
    };
  };
}
