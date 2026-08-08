{ config, lib, pkgs, inputs, ... }:

let
  # Outside the repo on purpose: these are other people's images, and this repo
  # is public. ./wallpaper.nix creates the directory so a fresh checkout does
  # not land on a path that does not exist.
  wallpapers = "${config.home.homeDirectory}/Pictures/Wallpapers";

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

  # Community templates write straight to $XDG_CONFIG_HOME/<app>/... and do not
  # create the directory first, so on a machine where the app has never been
  # launched templates-apply reports ok and silently writes nothing. Every app
  # below is installed, so seeding the directories makes the themes land on the
  # first run instead of the first launch.
  #
  # Plain mkdir rather than home.file entries: the .keep marker needed to
  # materialise an empty directory would show up in each app's own theme list.
  #
  # Check `ls` on these after adding a template — silent failure is this
  # subsystem's normal failure mode, not an exception.
  home.activation.seedAppThemeDirs =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "${config.xdg.configHome}/vesktop/themes" \
                   "${config.xdg.configHome}/heroic/themes" \
                   "${config.xdg.configHome}/bat/themes" \
                   "${config.xdg.configHome}/lazygit/themes" \
                   "${config.xdg.configHome}/yazi/flavors" \
                   "${config.xdg.configHome}/zellij/themes" \
                   "${config.xdg.configHome}/zathura" \
                   "${config.xdg.configHome}/telegram-desktop/themes"
    '';

  programs.noctalia = {
    enable = true;

    # niri starts the shell via `spawn-at-startup "noctalia"` in config.kdl, so
    # no systemd user unit here. Enabling both would race and launch Noctalia
    # twice.
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
          # "glass" lets the wallpaper through the panels. With a bright or busy
          # image behind them that washes the surfaces out, which is the exact
          # thing to avoid on a desktop meant to stay dark. Panels are now
          # opaque; the bar keeps its own slight transparency below.
          transparency_mode = "opaque";
          borders = true;
          shadow = true;
          list_item_background = true; # separates rows instead of floating text
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
        # Derived from the wallpaper again, which is now possible because the
        # wallpaper_changed hook below closes the loop: a change made in
        # Noctalia is a change Noctalia observes, so it can regenerate the
        # palette from the new image. The original objection — that swww drew
        # the wallpaper behind Noctalia's back and it could never notice — no
        # longer holds now that wallpaper-rotate goes *through* Noctalia rather
        # than around it.
        #
        # If the colours shifting every 900s becomes tiring, the alternative is
        # still in the repo and is one line:
        #   source = "custom"; custom_palette = "AyuBlueFixed";
        # That is ./config/noctalia/palettes/AyuBlueFixed.json — a corrected
        # copy of the community "Ayu Blue", which ships its ANSI yellow and blue
        # slots swapped in all four groups and inverts anything colouring by
        # ANSI name. Its header records the evidence. Worth keeping around.
        #
        # To change palette: `noctalia msg color-scheme-set <source> <name>`
        # writes the state file, then mirror the choice back here so the two
        # agree. `noctalia msg color-scheme-get` prints what is actually live.
        source = "wallpaper";

        # m3-monochrome rather than the m3-tonal-spot default. The difference is
        # not subtle, measured against the Spiderman wallpaper:
        #
        #   m3-tonal-spot   surface #1a1110  accent #ffb4ac   (red cast)
        #   m3-monochrome   surface #131313  accent #ffffff   (neutral)
        #
        # tonal-spot carries the wallpaper's hue into every surface, so the
        # whole desktop took on a red tint from that image and would shift again
        # at the next rotation. monochrome keeps deriving *luminance* from the
        # wallpaper while dropping the hue, which is what makes it restful for
        # long sessions.
        #
        # pure_black_dark stays off deliberately. It re-anchors the surface ramp
        # to #000000, which is right on OLED and wrong here: this is an IPS
        # panel, and pure black under white text produces halation — the glow
        # that makes text look like it is vibrating. #131313 is dark without
        # that.
        wallpaper_scheme = "m3-monochrome";
        pure_black_dark = false;

        # App theming. These render the palette into each app's own config;
        # `noctalia msg templates-apply` re-runs them on demand.
        #
        # Two of them write inside this repo rather than into ~/.config, since
        # config/niri is symlinked out of the store and starship.toml is read
        # via $STARSHIP_CONFIG:
        #   niri     -> config/niri/noctalia.kdl   (gitignored, generated)
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
        #                  config.kdl actually launches.
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
            "niri" # focus-ring colours; writes config/niri/noctalia.kdl,
            # which is gitignored and sourced from the bottom of
            # config.kdl
          ];

          enable_community_templates = true;
          community_ids = [
            "fastfetch" # runs on every fish start, so the most visible one
            "discord" # -> ~/.config/vesktop/themes/, pick it in Vesktop settings
            "heroiclauncher" # -> ~/.config/heroic/themes/, pick it in Heroic
            "bat" # -> bat/themes/; terminal/tools.nix selects it
            "lazygit" # -> lazygit/themes/
            "yazi" # -> yazi/flavors/noctalia.yazi/
            "zellij" # -> zellij/themes/
            "zathura" # -> zathura/noctaliarc
            "telegram" # -> telegram-desktop/themes/, pick it in Chat Settings
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
        # on the bar background.
        #
        # On its own this draws one pill per widget, which is what made the bar
        # feel busy: fifteen widgets meant fifteen containers in a row, and the
        # borders were doing as much of the visual noise as the contents. The
        # capsule_group blocks below collapse related widgets into shared
        # pills — six containers instead of fifteen — without changing what any
        # of them shows.
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

        # Trimmed on 2026-08-07 from fifteen widgets to twelve. Each of the five
        # removed was carrying no information, checked against the machine
        # rather than guessed at:
        #
        #   launcher    the fourth way to open it. A bare SUPER tap (keyd, see
        #               ../keyboard.nix), SUPER+Space and the bottom-left hot
        #               corner were already three.
        #   cpu         reads 1% at rest and is the least actionable number
        #               here. `temp` stays: it turns red past
        #               system.monitor.cpu_temp_activity_threshold and is the
        #               one readout that has ever prompted an action on this
        #               laptop.
        #   ram         showed "7.1 GiB" absolute against 30 GiB installed, so
        #               reading it meant doing the division. Noctalia has no
        #               percentage mode for it.
        #   bluetooth   powered on with zero paired devices — a permanently
        #               dead icon. Add it back if headphones ever arrive.
        #   clipboard   SUPER+F3, and it is also a Control Center tab.
        #
        # `battery` stays despite reading 100% on AC all day: this is a laptop,
        # and the widget's job is the 20% warning, which cannot fire from a
        # panel that is not on screen.
        #
        # The old warning still holds. At scale 1.6 eDP-1 gives the bar 1600
        # logical pixels, HDMI-A-1 gives 1920, and Noctalia drops overflowing
        # widgets *silently* rather than eliding them. Anything added here comes
        # out of that 1600 — check it against a screenshot of eDP-1, never the
        # wide monitor, or the overflow is invisible from where you are looking.
        #
        # No "wallpaper" widget: it drives the disabled wallpaper module, so its
        # panel would open onto nothing. `wallpaper-rotate` handles rotation.
        # `clock` is alone in the centre, and that is the whole point of this
        # arrangement. It was briefly grouped with `media`, which centred the
        # pair — so the group's width tracked the track title and the clock slid
        # sideways every time the song changed. Measured at ~17px between
        # "Nothing playing" and a long video title, in the same crop of two
        # screenshots. A clock is glanced at rather than looked for, so it has
        # to be in the same place every time; alone and centred, its own width
        # barely varies and it never moves.
        #
        # `media` sits at the head of `end`, and it got there the hard way. Put
        # next to `active_window` on the left it printed the same string twice —
        # "donk 36 Kills In A..." as the track and "(1377) donk 36 Kills In..."
        # as the window — because the focused window usually *is* whatever is
        # playing. Both were true, both were useless together.
        #
        # First position in `end` is the one spot where a variable-width widget
        # costs nothing. That lane is right-anchored, so the rightmost pill is
        # pinned and everything grows leftwards from it: `media` can swell to a
        # long title without shifting alerts, status or system, which are the
        # pills actually being clicked. There is room — the gap between the two
        # lanes measured 776 of the 1600 logical pixels.
        #
        # `active_window` stays last on the left because it is the one thing
        # here that can move for free: text you read, not a target you aim at.
        start = [ "workspaces" "active_window" ];
        center = [ "clock" ];
        end = [ "media" "group:alerts" "group:status" "group:system" ];

        # Seven pills instead of fifteen. The grouping is by what the widgets
        # are *for*, so each pill reads as one thing:
        #
        #   alerts   what wants you      — unread notifications and the tray
        #   status   how the machine is  — heat, link, sound, charge
        #   system   what you can do     — Control Center and the session menu
        #
        # The three on the left stay ungrouped. workspaces and active_window are
        # what get scanned most and a shared pill would slow that down, and
        # `media` is left out of a pill with the window title because two
        # truncated names sharing one container read as one confusing string.
        capsule_group = [
          {
            id = "alerts";
            members = [ "notifications" "tray" ];
          }
          {
            id = "status";
            members = [
              "temp"
              "network"
              "volume"
              "battery"
              # My claude-usage plugin: the 5h/weekly subscription window as a
              # glyph plus a percentage. In `status` rather than its own pill
              # for two reasons. It is a resource gauge like the four above, so
              # it reads as the same kind of thing; and joining an existing
              # capsule costs only widget_spacing, where a separate pill would
              # also cost capsule_padding on both sides — which matters against
              # the 1600 logical pixels eDP-1 has to give.
              #
              # Deliberately NOT appended to `end`. That lane is right-anchored,
              # so the last entry is the pinned one, and putting it there pushes
              # `group:system` off the edge it is aimed at.
              "daf3r/claude-usage:meter"
            ];
          }
          {
            id = "system";
            members = [ "control-center" "session" ];
          }
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
        # com.brave.Origin.desktop, but config.kdl launches brave-origin, so
        # matching that keeps a running window from docking as a second icon.
        #
        # This is also the surface to use for "click the icon, go to the window".
        # The bar's tray widget cannot do that: a tray icon's click is handled by
        # the application over StatusNotifierItem, not by Noctalia — there is not
        # a single tray setting in the whole config schema — and most apps,
        # Discord included, only toggle their own visibility rather than raising
        # a window that lives on another workspace. The dock tracks windows, so
        # clicking there focuses the real one.
        pinned = [
          "brave-origin"
          "kitty"
          "org.kde.dolphin"
          "apple-music"
          "vesktop"
          "discord"
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

      # Off, and it cannot be turned on here. It is meant to dim and blur behind
      # an *open panel* — which it does under Hyprland — but under niri it
      # registers a permanent layer-shell surface on the background layer of
      # every output, visible in `niri msg layers` as "noctalia-backdrop"
      # sitting alongside "swww-daemon", and washes the wallpaper in the
      # palette's primary colour whether a panel is open or not. With Ayu blue
      # that is a blue screen.
      #
      # It is a per-compositor bug, not a setting that needs tuning, so this
      # stays off for as long as niri is the session.
      backdrop.enabled = false;

      # Rounds the physical screen corners to match geometry-corner-radius 12 in
      # config/niri/config.kdl, so maximised windows stop looking square against
      # the rounded ones.
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
      # IPC verb the keybinds in config/niri/config.kdl already use.
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

      # The bridge back to swww. Noctalia's own wallpaper *drawing* is disabled
      # (see ./wallpaper.nix for the fractional-scale bug that forced it), but
      # everything else about its wallpaper handling still works: the Settings
      # picker, the recorded path, and re-deriving the palette from the image.
      #
      # Without this hook the picker looked broken in a very specific way —
      # choosing a new wallpaper changed the colours and left the image on
      # screen untouched, because nothing told swww. wallpaper-apply reads
      # NOCTALIA_WALLPAPER_PATH and NOCTALIA_WALLPAPER_CONNECTOR and paints it.
      hooks.wallpaper_changed = [ "wallpaper-apply" ];

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
      #
      # claude-usage is mine, and it does not come from a git remote: it is the
      # working tree at ~/Projects/noctalia-plugins, wired in through a `path`
      # source below. A plugin dropped into plugins/materialized/ by hand is
      # NOT picked up — the registry is built from the sources, so without that
      # entry `noctalia msg plugins list` never shows it.
      plugins.enabled = [
        "noctalia/wallhaven"
        "daf3r/claude-usage"
      ];

      # All three sources have to be listed, including the two that ship with
      # Noctalia. This key replaces the built-in list rather than adding to it,
      # so naming only "daf3r" would take the official and community catalogs
      # away with it — and wallhaven above along with them.
      #
      # A `path` source watches the directory live: editing service.luau or
      # logic.luau hot-reloads the service with no rebuild and no shell
      # restart, which is the whole point of pointing it at the working tree
      # instead of installing a copy.
      plugins.source = [
        {
          name = "official";
          kind = "git";
          location = "https://github.com/noctalia-dev/official-plugins";
        }
        {
          name = "community";
          kind = "git";
          location = "https://github.com/noctalia-dev/community-plugins";
        }
        {
          name = "daf3r";
          kind = "path";
          location = "${config.home.homeDirectory}/Projects/noctalia-plugins";
        }
      ];

      # The starter had the original author's "Seffner, FL" baked in, which was
      # replaced by auto_locate. That turned out to be worse, not better: IP
      # geolocation was placing this machine somewhere cold enough for the
      # weather widget to report 6 °C in August, which is not San Salvador
      # under any reading. An explicit address is both correct and stable.
      #
      # This also feeds the sunrise/sunset schedule that [nightlight] would use
      # if it were re-enabled, so it is worth having right even with the
      # nightlight off.
      location = {
        auto_locate = false;
        address = "San Salvador, El Salvador";
      };

      weather = {
        enabled = true;
        unit = "celsius";
      };

      # Back on, but gentler. It was turned off because 4000 K threw the colours
      # too far warm; 4500 K is a noticeably lighter touch and still cuts the
      # blue that costs you at night.
      #
      # The schedule follows real sunrise and sunset for San Salvador, since
      # location is now set explicitly rather than guessed from IP — see the
      # [location] block above.
      nightlight = {
        enabled = true;
        temperature_day = 6500;
        temperature_night = 4500;
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
