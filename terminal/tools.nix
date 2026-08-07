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

    # Media and image work from the command line. imagemagick was already
    # present as a dependency of something else; ffmpeg was not, and mpv's
    # bundled copy is not on PATH.
    ffmpeg
    imagemagick

    # `tldr tar` prints the five invocations anyone actually uses instead of a
    # man page. tealdeer is the fast Rust client.
    tealdeer

    # Disk usage that is readable: dust ranks directories by size as a tree,
    # duf shows mounted filesystems as a table. `du -sh *` sorted by hand is the
    # thing these replace.
    dust
    duf
  ];

  # cat with syntax highlighting and git gutters. Also worth having for what it
  # does to *other* tools: it becomes the pager for `--help` output and for
  # `gh` (already installed), so the improvement is not limited to typing `bat`.
  programs.bat = {
    enable = true;
    config.theme = "noctalia"; # written by Noctalia's bat template
  };

  # Persistent terminal sessions, panes and layouts that survive the terminal
  # closing or crashing — the one thing wezterm had over kitty when the terminal
  # question came up. kitty plus zellij covers it without switching.
  #
  # Declared through programs.zellij rather than as a bare package because the
  # theme has to be *selected*: Noctalia's template writes a `themes { noctalia
  # { ... } }` block to zellij/themes/noctalia.kdl and, unlike most of the other
  # templates, ships no apply.sh to wire it up. Without the line below the file
  # is generated and ignored.
  programs.zellij = {
    enable = true;
    settings = {
      theme = "noctalia";
      pane_frames = false; # niri and Hyprland already draw window borders
      copy_on_select = true;
    };
  };

  # btop was a bare package and had never been run, so ~/.config/btop/btop.conf
  # did not exist — and Noctalia's btop template refuses to do anything without
  # it ("Warning: btop config file not found"). Same failure as fastfetch had.
  #
  # Setting color_theme here fixes both halves at once: the file now exists, and
  # apply.sh's guard is `grep -qE '^color_theme\s*=\s*"noctalia"'`, which this
  # satisfies — so it returns without writing, and the read-only store symlink
  # home-manager creates is never a problem. Same pre-empted-value trick as
  # ./kitty.nix and ../gtk.nix.
  programs.btop = {
    enable = true;
    settings = {
      color_theme = "noctalia";
      theme_background = false; # let kitty's transparency through
      vim_keys = true;
      update_ms = 1000;
    };
  };

  # Full-screen git. The reason it earns a place over the `gs`/`ga`/`gc`
  # abbreviations in ./fish.nix is the things those cannot do comfortably:
  # staging individual lines rather than whole files, interactive rebase,
  # and resolving conflicts with both sides on screen.
  programs.lazygit = {
    enable = true;
    settings = {
      gui.theme = { }; # left to Noctalia's lazygit template

      # `pagers`, as a list — not the `paging` object it used to be. lazygit
      # 0.57 renamed it and migrates old configs automatically, except that
      # home-manager writes this file as a read-only store symlink, so the
      # migration fails with "read-only file system" every single launch and
      # the pager silently never applies. The schema here is what lazygit's own
      # migration produces.
      git.pagers = [
        {
          colorArg = "always";
          pager = "delta --dark --paging=never";
        }
      ];
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

  # GitHub CLI. The binary was already installed as a bare package; declaring it
  # here adds the parts that make it actually useful.
  #
  # The important one is gitCredentialHelper, on by default: after a single
  # `gh auth login`, plain `git push` and `git clone` over HTTPS authenticate
  # through gh's stored token. No personal access token to paste, no SSH key to
  # generate, and nothing secret lands in this repo.
  #
  # Authentication itself has to be done by hand once — it is a browser flow:
  #   gh auth login
  #
  # Worth knowing for this machine specifically: ~/nixos-config's `origin` still
  # points at TimothyBear11/nixtalia, the upstream starter, so `git push` has
  # never been possible. Once logged in, `gh repo create` can make your own and
  # point origin at it.
  programs.gh = {
    enable = true;

    settings = {
      git_protocol = "https"; # pairs with the credential helper above
      editor = "nvim";
      prompt = "enabled";

      aliases = {
        pv = "pr view";
        pc = "pr create";
        prs = "pr list";
        iss = "issue list";
        # Clone into ~/GitHub rather than wherever the shell happens to be.
        cl = "repo clone";
      };
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
