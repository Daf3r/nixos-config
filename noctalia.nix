{ config, pkgs, inputs, ... }:

let
  wallpapers = "${config.home.homeDirectory}/nixos-config/Pictures/Wallpapers";
in
{
  imports = [ inputs.noctalia.homeModules.default ];

  # Custom palettes are read from ~/.config/noctalia/palettes/<name>.json, which
  # theme.custom_palette below selects by bare name. The Noctalia home-manager
  # module only owns config.toml in that directory, so dropping another file
  # alongside it is safe.
  xdg.configFile."noctalia/palettes/AyuBlueFixed.json".source =
    ./config/noctalia/palettes/AyuBlueFixed.json;

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

        # Was source = "wallpaper", which was dead config for two independent
        # reasons. First, the Settings GUI had written source = "builtin" into
        # ~/.local/state/noctalia/settings.toml, and the state file wins per
        # setting. Second, and more fundamental: deriving the palette from the
        # wallpaper requires Noctalia to know when the wallpaper changed, and
        # its wallpaper module is disabled here because swww owns the
        # background (see ./wallpaper.nix) — so nothing would ever re-trigger
        # the regeneration even if this key had taken effect.
        #
        # A fixed palette is the honest answer while swww does the rotation:
        # the templates below then render one stable set of colours instead of
        # drifting every 900s. Change it with
        #   noctalia msg color-scheme-set community "<name>"
        # which writes the state file, then mirror it back here so the two
        # agree. `noctalia msg color-scheme-get` prints what is actually live.
        # Not source = "community" / "Ayu Blue": that palette ships its ANSI
        # yellow and blue slots swapped in all four groups, which inverts every
        # program that colours by ANSI name (ls directories, warnings, and
        # config/starship.toml's bg:yellow + fg:blue). ./config/noctalia/
        # palettes/AyuBlueFixed.json is the same palette with those two keys
        # put back; its header documents the evidence. Drop the custom copy and
        # go back to "community" once upstream fixes it.
        source = "custom";
        custom_palette = "AyuBlueFixed";

        # App theming. These render the palette into each app's own config;
        # `noctalia msg templates-apply` re-runs them on demand.
        #
        # Two of them write inside this repo rather than into ~/.config, since
        # config/hypr is symlinked out of the store and starship.toml is read
        # via $STARSHIP_CONFIG:
        #   hyprland -> config/hypr/noctalia.conf  (gitignored, generated)
        #   starship -> config/starship.toml       (block between markers)
        # Both are idempotent and, with a fixed palette, only change when the
        # palette does.
        #
        # Full list: `noctalia theme --list-templates`.
        templates = {
          enable_builtin_templates = true;
          builtin_ids = [
            "kitty" # colours only; the rest of kitty is ./terminal/kitty.nix
            "starship" # defines [palettes.noctalia]; config/starship.toml already
            # styles with blue/cyan/green/yellow, so it adopts the
            # palette without rewriting a single module
            "btop"
            "gtk3"
            "gtk4"
            "qt" # writes qt5ct + qt6ct colour schemes
            "hyprland" # window border colours; replaces the hardcoded
            # cyan->green gradient in config/hypr/hyprland.conf
          ];
        };
      };

      # Off on purpose — v5.0.0 mis-sizes the wallpaper surface under fractional
      # monitor scales, and eDP-1 runs at 1.6. swww draws the background
      # instead; see ./wallpaper.nix for the full write-up and the replacement
      # for [wallpaper.automation]. `directory` stays so that theme.source =
      # "wallpaper" and the wallpaper-set IPC keep resolving the same folder.
      wallpaper = {
        enabled = false;
        directory = wallpapers;
      };

      bar.main = {
        position = "top";
        thickness = 34;
        radius = 12;
        reserve_space = true;
        shadow = true;

        # No "wallpaper" widget: it drives the disabled wallpaper module, so its
        # panel would open onto nothing. `wallpaper-rotate` handles rotation.
        start = [ "launcher" "workspaces" "cpu" "ram" "temp" ];
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

      # The internal panel has a sysfs backlight, the external MSI does not —
      # so without DDC/CI the brightness keys silently only ever moved eDP-1.
      # ddcutil talks to the monitor over the HDMI i2c bus; desktops.nix sets
      # hardware.i2c.enable and configuration.nix puts daf3r in the i2c group,
      # which are both required for this to do anything.
      #
      # sync_all_monitors stays false on purpose: the panel and the MSI have
      # very different peak brightness, so one shared level suits neither.
      # `noctalia msg brightness-set <connector> <value>` targets one output.
      brightness = {
        enable_ddcutil = true;
        sync_all_monitors = false;
      };

      widget.clock.format = "{:%H:%M · %a %d %b}";

      # Resolve coordinates from IP instead of hardcoding a city — the starter
      # config had the original author's "Seffner, FL" baked in here.
      location.auto_locate = true;

      weather = {
        enabled = true;
        unit = "celsius";
      };

      # Off: the warm shift at night threw the colours off. Re-enable by
      # flipping this back to true — turning it off in the Settings GUI alone
      # does not survive a rebuild.
      nightlight = {
        enabled = false;
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
