{ config, pkgs, ... }:

# Command-line tooling. fzf, ripgrep, fd, eza and zoxide were already here —
# these are the gaps. jq is declared here too: it used to ride in through
# fastfetch.nix as a Noctalia-template dependency, and nothing else puts it on
# the interactive PATH.
#
# Theming: DMS's matugen has no templates for any of the tools below, so their
# palettes are frozen files in ../config/themes/ (captured from Noctalia v5 on
# the day of the migration and now owned by this repo). They no longer follow
# the wallpaper; if that is ever wanted again it means hand-writing matugen
# templates for each tool.
let
  themes = ./../config/themes;
in
{
  home.packages = with pkgs; [
    # Terminal file manager. Fast, vim-style keys, image previews in kitty via
    # its graphics protocol. Complements Dolphin rather than replacing it: this
    # is the one that gets used without leaving the terminal.
    yazi

    # JSON Swiss-army knife on the interactive PATH. See the header: it used to
    # arrive transitively via fastfetch.nix and vanished with Noctalia.
    jq

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
  # The theme is the frozen Noctalia palette in ../config/themes/.
  #
  # WATCH OUT on themes.<name>: `src` is the *directory* holding the file and
  # `file` is appended to it — pointing src at the file itself produces a
  # symlink to a non-directory, bat's cache build silently skips it, and
  # config.theme names a theme that does not exist. Verified against
  # ~/.config/bat/themes after a real activation.
  programs.bat = {
    enable = true;
    themes.noctalia = {
      src = "${themes}";
      file = "noctalia.tmTheme";
    };
    config.theme = "noctalia";
  };

  # Persistent terminal sessions, panes and layouts that survive the terminal
  # closing or crashing — the one thing wezterm had over kitty when the terminal
  # question came up. kitty plus zellij covers it without switching.
  #
  # Declared through programs.zellij rather than as a bare package because the
  # theme has to be *selected*: the frozen palette lands in
  # zellij/themes/noctalia.kdl via xdg.configFile below and, unlike most of the
  # other tools, zellij ships no other way to wire it up. Without `theme` here
  # the file is generated and ignored.
  programs.zellij = {
    enable = true;
    settings = {
      theme = "noctalia";
      pane_frames = false; # niri already draws window borders
      copy_on_select = true;
    };
  };

  # btop was a bare package and had never been run, so ~/.config/btop/btop.conf
  # did not exist and nothing themed it. Setting color_theme both creates the
  # config and selects the frozen palette deployed via xdg.configFile below.
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
  #
  # The theme lives INLINE here, not in a themes/ file: lazygit has no theme
  # directory it reads on its own — the only loaders are config.yml itself and
  # --use-config-file / LG_CONFIG_FILE (verified against `lazygit --help` and
  # the binary's strings). The old noctalia.nix deployed
  # lazygit/themes/noctalia.yml and nothing ever read it; the colours came from
  # the template writing into config.yml directly, which home-manager forbids.
  # gui.theme below is the palette from ../config/themes/noctalia.yml, kept in
  # step by hand if the wallpaper palette ever changes materially.
  programs.lazygit = {
    enable = true;
    settings = {
      gui.theme = {
        activeBorderColor = [ "#e6b450" "bold" ];
        inactiveBorderColor = [ "#aad94c" ];
        searchingActiveBorderColor = [ "#39bae6" "bold" ];
        optionsTextColor = [ "#8e959e" ];
        selectedLineBgColor = [ "#8e959e" ];
        inactiveViewSelectedLineBgColor = [ "bold" ];
        cherryPickedCommitFgColor = [ "#8e959e" ];
        cherryPickedCommitBgColor = [ "#39bae6" ];
        markedBaseCommitFgColor = [ "#39bae6" ];
        markedBaseCommitBgColor = [ "#d95757" ];
        unstagedChangesColor = [ "#d95757" ];
        defaultFgColor = [ "#d1d1c7" ];
      };

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
      # WATCH OUT: home-manager writes this to ~/.config/git/config, and git
      # ignores that file entirely when ~/.gitconfig exists — it is not a merge,
      # the older path simply wins. A stray ~/.gitconfig left by the NixOS
      # install silently overrode this block for two days, so `git config
      # --global user.email` kept answering the old address after a rebuild that
      # had clearly succeeded.
      #
      # `git config --global --show-origin user.email` names the file that is
      # actually winning. If it is not the store symlink, delete ~/.gitconfig.
      user = {
        name = "Daf3r";
        # GitHub's noreply address rather than the real one. Every commit
        # records the author email in plain text and this repo is public, so
        # the personal address would be readable in the history of anything
        # ever pushed. The noreply form still links commits to the GitHub
        # account, so contribution graphs and mentions keep working.
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
  # `origin` used to point at the upstream starter, so `git push` was never
  # possible from here. Since 2026-08-07 it points at Daf3r/nixos-config and
  # pushing works — that repo was made with `gh repo create --source=.`, which
  # is the shortest path from a local repo to a published one.
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
      syntax-theme = "Nord"; # bat theme name; bat's own theme is set above
    };
  };

  # Frozen Noctalia-era palettes for the tools matugen does not cover (see the
  # header). Source files live in ../config/themes/ and are deployed read-only
  # from the store — they are now owned by this repo, not by any shell.
  #
  # lazygit is NOT here: it reads no themes/ directory (see the note on
  # programs.lazygit above), so its palette is inlined in gui.theme instead.
  # The noctalia.yml kept in ../config/themes/ is only the reference copy the
  # inline values were transcribed from.
  xdg.configFile = {
    "zellij/themes/noctalia.kdl".source = "${themes}/noctalia.kdl";
    "btop/themes/noctalia.theme".source = "${themes}/noctalia.theme";
    "zathura/noctaliarc".source = "${themes}/noctaliarc";
    # yazi's theme system DOES read flavors/<name>.yazi/ — theme.toml selects
    # flavor "noctalia". The flavor is a directory with two files, which
    # home-manager expresses as separate entries under one path.
    #
    # tmtheme.xml is the SAME file bat gets: yazi's flavor spec and bat both
    # want a TextMate theme, and Noctalia generated one palette for both. It
    # was checked in twice (2112 identical lines) until the duplicate was
    # dropped — one source, two deploy paths.
    "yazi/flavors/noctalia.yazi/flavor.toml".source =
      "${themes}/yazi-noctalia.toml";
    "yazi/flavors/noctalia.yazi/tmtheme.xml".source = "${themes}/noctalia.tmTheme";
    "yazi/theme.toml".text = ''
      [flavor]
      dark = "noctalia"
      light = "noctalia"
    '';
  };
}
