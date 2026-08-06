{ config, pkgs, inputs, ... }:

let
  wallpapers = "${config.home.homeDirectory}/nixos-config/Pictures/Wallpapers";
in
{
  imports = [ inputs.noctalia.homeModules.default ];

  programs.noctalia = {
    enable = true;

    # Hyprland starts the shell via exec-once, so no systemd user unit here.
    # Enabling both would race and launch Noctalia twice.
    systemd.enable = false;

    # Every rebuild runs `noctalia config validate` over the generated TOML, so
    # a bad key fails the build instead of silently breaking the shell.
    #
    # This file is the source of truth: ~/.config/noctalia/config.toml is a
    # read-only symlink into the Nix store, so changes made in Noctalia's own
    # Settings GUI do NOT survive a rebuild. Tweak in the GUI to find what you
    # like, then write it back here.
    settings = {
      accessibility.ui_scale = 1.0;

      shell = {
        # v5 has a single font_family for the whole shell UI (v4's split
        # fontDefault/fontFixed is gone), so this wants a proportional face —
        # a monospace here makes the bar and panels look like a terminal.
        font_family = "Noto Sans";
        settings_show_advanced = true;
        polkit_agent = true; # Plasma is gone; Noctalia is the polkit agent now
        clipboard_enabled = true;
        clipboard_history_max_entries = 200;

        animation = {
          enabled = true;
          speed = 1.0;
        };

        panel = {
          transparency_mode = "glass";
          borders = true;
          shadow = true;
        };

        launcher = {
          categories = true;
          show_icons = true;
          sort_by_usage = true;
        };
      };

      theme = {
        mode = "dark";
        source = "wallpaper"; # regenerate the palette from the current wallpaper
        wallpaper_scheme = "m3-content";

        # Opt in to app theming with the ids from
        # `noctalia theme --list-templates`, e.g. [ "kitty" "foot" "gtk" ].
        templates.enable_builtin_templates = true;
      };

      wallpaper = {
        enabled = true;
        directory = wallpapers;
        fill_mode = "crop";
        transition_duration = 1500;
        automation = {
          enabled = true;
          interval_seconds = 900;
          order = "random";
        };
      };

      bar.main = {
        position = "top";
        thickness = 34;
        radius = 12;
        reserve_space = true;
        shadow = true;

        start = [ "launcher" "wallpaper" "workspaces" "cpu" "ram" "temp" ];
        center = [ "clock" "media" ];
        end = [
          "audio_visualizer"
          "notifications"
          "tray"
          "network"
          "bluetooth"
          "volume"
          "battery"
          "clipboard"
          "control-center"
          "session"
        ];
      };

      widget.clock.format = "{:%H:%M · %a %d %b}";

      # Resolve coordinates from IP instead of hardcoding a city — the starter
      # config had the original author's "Seffner, FL" baked in here.
      location.auto_locate = true;

      weather = {
        enabled = true;
        unit = "celsius";
      };

      nightlight = {
        enabled = true;
        temperature_day = 6500;
        temperature_night = 4000;
      };

      lockscreen = {
        enabled = true;
        blur_intensity = 0.5;
      };

      notification.enable_daemon = true;

      system.monitor.enabled = true;

      idle.behavior = {
        lock = {
          enabled = true;
          timeout = 600;
          action = "lock";
        };
        "screen-off" = {
          enabled = true;
          timeout = 900;
          action = "screen_off";
        };
      };
    };
  };
}
