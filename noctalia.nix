{ config, lib, pkgs, inputs, ... }:

let
  wallpapers = "${config.home.homeDirectory}/nixos-config/Pictures/Wallpapers";

  # Noctalia ships exactly two sounds in its own package; there is no separate
  # sound theme to install. Referencing them through the flake input keeps the
  # store path correct across upgrades instead of pinning a hash by hand.
  noctaliaPkg = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
  sounds = "${noctaliaPkg}/share/noctalia/assets/sounds";
in
{
  imports = [ inputs.noctalia.homeModules.default ];

  # Custom palettes are read from ~/.config/noctalia/palettes/<name>.json, which
  # theme.custom_palette below selects by bare name. The Noctalia home-manager
  # module only owns config.toml in that directory, so dropping another file
  # alongside it is safe.
  xdg.configFile."noctalia/palettes/AyuBlueFixed.json".source =
    ./config/noctalia/palettes/AyuBlueFixed.json;

  # The discord and heroiclauncher community templates write straight to
  # $XDG_CONFIG_HOME/<app>/themes/ and do not create the directory first, so on
  # a machine where neither app has been launched yet templates-apply reports
  # ok and silently writes nothing. Both apps are installed (vesktop in
  # ./apps.nix, heroic in ./gaming.nix), so seed the two directories and the
  # templates land on the first run instead of the first launch.
  #
  # A plain mkdir rather than a home.file entry: the .keep marker that would
  # otherwise be needed to materialise an empty directory would sit in the
  # themes list of both apps.
  home.activation.seedAppThemeDirs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "${config.xdg.configHome}/vesktop/themes" \
                   "${config.xdg.configHome}/heroic/themes"
    '';

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
        # Community templates are cached under
        # ~/.local/state/noctalia/community-templates/. Each folder arrives
        # holding only template.toml; catalog.json lists the rest of the files
        # (the CSS/JSONC inputs and apply.sh) with md5s, and they are fetched
        # lazily. Listing an id here is what triggers that fetch.
        #
        # Only templates whose app is actually installed are enabled — the rest
        # would render colours into a config nothing reads. Deliberately left
        # out, with the reason, so this does not get re-litigated:
        #
        #   neovim         writes $XDG_CONFIG_HOME/nvim/lua/matugen.lua, and
        #                  ~/.config/nvim resolves out of the store into
        #                  config/nvim in this repo — so it would commit noise
        #                  on every palette change, and LazyVim would still
        #                  need a require() before it did anything.
        #   papirus-icons  recolours the icon theme in place; Papirus is served
        #                  read-only from the Nix store, so it cannot work here.
        #   steam          targets steamui/skins/Material-Theme/, which is only
        #                  present if that skin was installed inside Steam.
        #   spicetify      would need spicetify-cli back in ./apps.nix.
        #   zen-browser    Zen is installed but brave-origin is the browser
        #                  hyprland.conf actually launches.
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

          enable_community_templates = true;
          community_ids = [
            "fastfetch" # runs on every fish start, so the most visible of the three
            "discord" # -> ~/.config/vesktop/themes/, pick it in Vesktop settings
            "heroiclauncher" # -> ~/.config/heroic/themes/, pick it in Heroic
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

        # Groups adjacent widgets into rounded pills instead of floating them
        # on the bar background. capsule_group is left at its default: it takes
        # explicit groupings, and the automatic behaviour is what reads well
        # with the three sections below.
        capsule = true;
        capsule_fill = "surface_variant";
        capsule_opacity = 1.0;
        capsule_padding = 4;
        hover_highlight = true;

        # The binding constraint is eDP-1, not the 2560px panel it sounds like:
        # at scale 1.6 the bar is 1600 logical pixels wide, and HDMI-A-1 gives
        # 1920. The default margin_ends of 100 spends 200 of those 1600 on empty
        # edges, which is what tipped the widget row over and made the sysmon
        # readouts silently drop off. Widget spacing is trimmed for the same
        # reason.
        margin_ends = 16;
        widget_spacing = 4;
        padding = 10;

        # `active_window` earns its space — what has focus matters more than
        # load average when the screen is split between an editor and Brave —
        # but an earlier revision added it while leaving thirteen widgets in
        # `end`, and the row overflowed 1600 logical pixels. Noctalia drops the
        # overflow silently instead of eliding it, and what disappeared was
        # cpu/ram/temp: the first three of `end`, and the only three that had
        # been visible before the change.
        #
        # So the readouts go back to `start`, which was never the crowded side,
        # and `audio_visualizer` is dropped — it is the one widget here that
        # conveys nothing, and it was costing the width they needed.
        #
        # Anything added below comes out of the same 1600px. Check it against a
        # screenshot of eDP-1, not the 1920px MSI, or an overflow will be
        # invisible from the wide monitor.
        #
        # No "wallpaper" widget: it drives the disabled wallpaper module, so its
        # panel would open onto nothing. `wallpaper-rotate` handles rotation.
        start = [ "launcher" "workspaces" "cpu" "ram" "temp" "active_window" ];
        center = [ "clock" "media" ];
        end = [
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

      # The dock is off by default. auto_hide plus reserve_space = false is the
      # combination that matters here: eDP-1 is only 900 logical pixels tall at
      # scale 1.6, and a reserved dock would eat that on top of the 34px bar.
      # This way it stays out of the way until the pointer reaches the edge.
      dock = {
        enabled = true;
        auto_hide = true;
        reserve_space = false;
        position = "bottom";

        icon_size = 40;
        magnification = true;
        magnification_scale = 1.35;
        show_running = true;
        show_instance_count = true;

        # Desktop-entry ids without the .desktop suffix. brave-origin is the
        # locally packaged build (see ./pkgs/brave-origin.nix); it also ships a
        # com.brave.Origin.desktop, but hyprland.conf launches brave-origin, so
        # matching that keeps a running window from docking as a second icon.
        pinned = [
          "brave-origin"
          "kitty"
          "org.kde.dolphin"
          "spotify"
          "vesktop"
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

      # Long titles are the norm in a browser and an editor, so cap the width
      # and scroll on hover rather than letting the widget push the workspaces
      # around every time the focus changes.
      widget.active_window = {
        max_length = 190;
        min_length = 60;
        title_scroll = "hover";
        icon_size = 16;
      };

      # Trimmed from the 220 default for the same 1600px budget as the bar
      # layout above. Both of these are variable-width, so they are where the
      # slack has to come from.
      widget.media = {
        max_length = 150;
        min_length = 60;
        title_scroll = "hover";
      };

      # OSD sits opposite the bar. At top_center it shares an edge with a top
      # bar, so volume and brightness popups land right against it; bottom is
      # also where the eye is not while reading.
      osd = {
        position = "bottom_center";
        offset_y = 24;
        background_opacity = 0.97;
        border = true;
      };

      # Dims and blurs whatever is behind an open panel, which separates the
      # panel from a busy window underneath. Off by default.
      backdrop = {
        enabled = true;
        blur_intensity = 0.5;
        tint_intensity = 0.3;
      };

      # Rounds the physical screen corners to match decoration:rounding = 12 in
      # config/hypr/hyprland.conf, so maximised windows stop looking square
      # against the rounded ones.
      shell.screen_corners = {
        enabled = true;
        size = 16;
      };

      # Keeps screenshots out of ~/Pictures, which is also where the wallpaper
      # folder search would otherwise trip over them. filename_pattern is left
      # empty on purpose — the built-in default already produces
      # screenshot_<date>_<time>[-region].png.
      shell.screenshot = {
        directory = "${config.home.homeDirectory}/Pictures/Screenshots";
        save_to_file = true;
        copy_to_clipboard = true;
        freeze_screen = true;
      };

      # Noctalia ships notification.wav and volume-change.wav and uses neither
      # unless enable_sounds is on. The volume sound is deliberately left unset:
      # it would fire on every keypress of the volume rocker.
      audio = {
        enable_sounds = true;
        notification_sound = "${sounds}/notification.wav";
        sound_volume = 0.4;
      };

      # 10% is very late on a laptop that idles around 15W; 20% leaves time to
      # find a charger.
      battery.warning_threshold = 20;

      calendar.enabled = true;
      control_center.calendar.show_week_numbers = true;

      # The state file already holds two login boxes, one per output, positioned
      # by hand — but the subsystem itself was left off, so none of it rendered.
      # NOTE: [lockscreen_widgets] enabled is also present in the state file,
      # and per-setting the state wins (see the README notes on precedence), so
      # this may need flipping in the GUI instead. Verified after switching.
      lockscreen_widgets.enabled = true;

      # Corners are a compositor-wide pointer trap, which is a real hazard with
      # CS2 in the mix, so only one corner is armed and it needs a deliberate
      # half-second dwell. Bottom-left is the safest: it is diagonally opposite
      # the bar's session/power controls, and away from the eDP-1 -> HDMI-A-1
      # edge the pointer crosses all day.
      #
      # `command` is used rather than a named action so the binding is the same
      # IPC verb the keybinds in hyprland.conf already use.
      hot_corners = {
        enabled = true;
        delay_ms = 500;
        bottom_left = {
          action = "command";
          command = "noctalia msg panel-toggle launcher";
        };
      };

      # 19 hook points exist and all of them were empty. This is the one that
      # earns its keep: music kept playing to an empty room when the idle timer
      # locked the session. playerctl is already installed for the media keys.
      hooks.session_locked = [ "playerctl pause" ];

      # Plugins are fetched into ~/.local/state/noctalia/plugins/sources/ from
      # the two git remotes already listed in [[plugins.source]]; only the ids
      # named here are loaded. 11 official and ~80 community plugins are
      # available — `catalog.toml` in each repo is the index.
      #
      # Both checkouts were found empty on 2026-08-07: normal blobless clones
      # (partialclonefilter=blob:none, no sparse-checkout) whose working trees
      # had been wiped with the deletions left staged in the index. Repaired
      # with `git reset --hard HEAD` in each. If plugins ever go missing again,
      # check `git -C <repo> status` there before assuming a config problem.
      #
      # wallhaven earns the first slot because only one image lives in
      # Pictures/Wallpapers, which makes wallpaper-rotate's 900s shuffle a
      # no-op. Point its download_dir at that folder in the plugin's own
      # settings panel and swww starts having something to rotate through.
      plugins.enabled = [ "noctalia/wallhaven" ];

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
