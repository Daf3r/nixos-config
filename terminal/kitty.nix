{ pkgs, ... }:

# kitty used to be a bare entry in terminal.nix's home.packages, which meant it
# ran on stock defaults: no font selection, no padding, no opacity, no cursor
# styling. `programs.kitty` installs the same binary *and* manages kitty.conf,
# so the package entry moved here.
#
# Division of labour with Noctalia: its `kitty` template writes *colours only*
# (the 16 ANSI slots, cursor, background/foreground, selection, tab and border
# colours) into ~/.config/kitty/themes/noctalia.conf. Everything else — font,
# spacing, opacity, cursor shape, tab bar style — is set here. Noctalia cannot
# do it, so a themed-but-otherwise-default kitty still looks like nothing.
#
# The `include themes/noctalia.conf` at the bottom is load-bearing. Noctalia's
# templates/kitty/apply.sh wants to append that exact line to kitty.conf via
# `cat tmp > kitty.conf`, which would fail here because home-manager makes
# kitty.conf a read-only symlink into the store. Because the line is already
# present its awk pass finds `include_seen`, produces identical output, and the
# guarding `cmp -s` skips the write entirely. The two never collide as long as
# this string stays byte-for-byte identical to apply.sh's `include_line`.
{
  programs.kitty = {
    enable = true;

    font = {
      # Already provided system-wide by fontsAndNeeds.nix. The Nerd Font variant
      # matters: starship's prompt and eza's --icons both draw glyphs from the
      # Private Use Area that plain JetBrains Mono does not carry.
      package = pkgs.nerd-fonts.jetbrains-mono;
      name = "JetBrainsMono Nerd Font";
      size = 12;
    };

    settings = {
      # --- Window ---
      # The old zero-padding look had text touching the window edge. eDP-1 runs
      # at scale 1.6, so these are logical pixels and 12 reads as ~19 physical.
      window_padding_width = 12;
      confirm_os_window_close = 0; # no "close with N windows?" prompt
      hide_window_decorations = "yes"; # Hyprland draws the border

      # --- Transparency ---
      # Hyprland's decoration.blur is already enabled (size 3, passes 2), and it
      # blurs any window that is translucent, so this picks the blur up for free.
      #
      # 0.96 rather than 0.92: enough transparency to keep the depth, little
      # enough that a bright wallpaper cannot lift the background off #131313
      # and wash out the text. The whole point of the monochrome palette is a
      # terminal that stays dark whatever is behind it.
      background_opacity = "0.96";
      dynamic_background_opacity = true; # lets kitty adjust opacity at runtime

      # --- Cursor ---
      cursor_shape = "beam";
      cursor_beam_thickness = "1.8";
      cursor_blink_interval = "0.5";
      cursor_trail = 3; # smear the cursor toward its new position
      cursor_trail_decay = "0.1 0.4";

      # --- Scrollback ---
      scrollback_lines = 10000;
      scrollback_pager_history_size = 64; # MB kept for the scrollback pager

      # --- Tabs ---
      tab_bar_edge = "top";
      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      tab_bar_min_tabs = 2; # hide the bar entirely with a single tab

      # --- Bell ---
      enable_audio_bell = false;
      visual_bell_duration = "0.1";

      # --- Text ---
      # JetBrains Mono ships programming ligatures (-> => != <=). cursor means
      # they render normally but break apart under the cursor so you can still
      # see the individual characters while editing.
      disable_ligatures = "cursor";
      url_style = "curly";
      copy_on_select = "clipboard";

      # --- Performance ---
      # Default is 10ms. 5 halves input-to-pixel latency on the 240 Hz panel at
      # a small GPU cost, which this machine has to spare.
      repaint_delay = 5;
      sync_to_monitor = true;

      # shell_integration is deliberately NOT set here. The home-manager module
      # emits `shell_integration no-rc` of its own accord and wires the fish
      # side up itself; overriding it to "enabled" would win (kitty takes the
      # last occurrence) and let kitty inject its own rc hooks on top, giving
      # fish the integration twice.
    };

    # Must stay exactly this string — see the apply.sh note in the header above.
    # It sits last so Noctalia's palette wins over anything set in `settings`.
    extraConfig = ''
      include themes/noctalia.conf
    '';
  };
}
