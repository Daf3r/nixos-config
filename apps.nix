{ config, pkgs, inputs, ... }:

let
  noctaliaPkg = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
  screenshots = "${config.home.homeDirectory}/Pictures/Screenshots";

  # Capture a region, annotate it, and put the result back on the clipboard.
  #
  # Noctalia's capture and satty each do half of this and neither can do the
  # other's half: Noctalia has the region selector and the clipboard handling,
  # satty has the arrows, boxes and blur. Noctalia's own pipe_to_command would
  # route *every* screenshot through satty, which is the wrong default when most
  # captures need no annotation — so this is a separate command on its own key.
  screenshot-annotate = pkgs.writeShellApplication {
    name = "screenshot-annotate";
    runtimeInputs = [
      pkgs.satty
      pkgs.wl-clipboard
      pkgs.coreutils
      pkgs.findutils
      noctaliaPkg
    ];
    text = ''
      dir="${screenshots}"
      mkdir -p "$dir"

      # find rather than `ls -t`: writeShellApplication runs shellcheck, and
      # SC2012 fails the build over parsing ls output.
      newest() {
        find "$dir" -maxdepth 1 -type f -name '*.png' -printf '%T@ %p\n' 2>/dev/null \
          | sort -rn | head -1 | cut -d' ' -f2-
      }

      # Watch for a *new* file rather than for the clipboard to hold an image:
      # the clipboard usually already holds the previous screenshot, so waiting
      # on its type would return instantly with the wrong picture.
      before="$(newest)"

      noctalia msg screenshot-region >/dev/null 2>&1 || true

      # 30s of headroom — the region selector is interactive, so this is however
      # long it takes to drag a box. Gives up quietly if the capture is aborted.
      shot=""
      for _ in $(seq 1 300); do
        latest="$(newest)"
        if [ -n "$latest" ] && [ "$latest" != "$before" ]; then
          shot="$latest"
          break
        fi
        sleep 0.1
      done
      [ -n "$shot" ] || exit 0

      # Enter copies the annotated image and quits, which is the whole point —
      # the next thing that happens is a paste into Discord or Brave.
      satty --filename "$shot" \
        --output-filename "$dir/annotated-%Y%m%d_%H%M%S.png" \
        --copy-command wl-copy \
        --actions-on-enter save-to-clipboard,exit \
        --early-exit
    '';
  };
in
{
  # Video and audio. Everything below is mpv doing the work; nothing else on
  # this machine could open a video file at all before it.
  programs.mpv = {
    enable = true;

    config = {
      # The reason mpv is here rather than any other player: it writes the
      # playback position to ~/.local/state/mpv/watch_later on quit and picks it
      # back up when the same file is opened again. Half-watched films and
      # long videos resume by themselves.
      save-position-on-quit = true;

      # Do not close the window at end of file — otherwise the last frame and
      # the chance to rewind vanish instantly.
      keep-open = true;

      # Hardware decoding. auto-safe rather than nvdec: it only enables decoders
      # known to be sound for the codec in play, which avoids the green-frame
      # and black-video failures the forced settings are famous for on NVIDIA.
      hwdec = "auto-safe";
      vo = "gpu-next";
      profile = "high-quality";

      # eDP-1 is a 240 Hz panel and most video is 24 or 30 fps. Interpolation
      # smooths the cadence mismatch instead of letting frames land unevenly.
      video-sync = "display-resample";
      interpolation = true;
      tscale = "oversample";

      # This was 70, which is where "the sound is a bit quiet" came from
      # (2026-08-08). Nothing else in the chain was down: both CS35L41 amps
      # bind with firmware loaded and calibration applied at gain 17, and the
      # PipeWire sink sits at 1.00 — mpv was the only stage below maximum, and
      # it was throwing away 30% before the speakers ever saw the signal.
      #
      # 100 is not "loud", it is *unattenuated*: mpv now plays at whatever the
      # system volume is, which is what every other application on the desktop
      # already does. The original intent of 70 — not starting at a shout — is
      # the system volume's job, not a per-player handicap.
      volume = 100;

      # Software gain above 100 for the quiet ones: films mastered with a wide
      # dynamic range, and phone video with dialogue recorded far from the mic.
      # Reachable live with the volume keys; the laptop speakers distort well
      # before 150, so it is headroom to use deliberately, not to sit at.
      volume-max = 150;

      # Subtitles: prefer Spanish, fall back to English.
      slang = "es,spa,en,eng";
      alang = "es,spa,en,eng";

      screenshot-directory = "${config.home.homeDirectory}/Pictures/Screenshots";
    };
  };

  # PDF reader. Keyboard-driven, which suits a tiling session, and it starts
  # instantly where a browser tab does not.
  #
  # Declared here rather than as a bare package for the same reason as btop in
  # ./terminal/tools.nix: Noctalia's zathura template writes the palette to
  # zathura/noctaliarc, but its apply.sh only reloads running instances over
  # D-Bus — it never adds the include. Without the line below the colours are
  # generated and never read.
  programs.zathura = {
    enable = true;
    extraConfig = ''
      include noctaliarc
    '';
    options = {
      selection-clipboard = "clipboard"; # yank goes to the real clipboard
      adjust-open = "width";
      guioptions = ""; # no toolbar or statusbar chrome
      font = "JetBrainsMono Nerd Font 10";
    };
  };

  programs.mangohud = {
    enable = true;

    # Not `full`. That switch turns on every readout MangoHud has — VRAM, RAM,
    # swap, engine version, resolution, battery, per-core CPU — which is a lot
    # of text to sit on top of a shooter, and none of it answers the question
    # you actually have while playing.
    #
    # What is left is the set that does: the frametime graph is the one to
    # watch. A flat line at a low framerate means the machine is simply
    # working; a jagged one at a high average means stutter, and those two feel
    # very different while pointing at completely different causes.
    settings = {
      fps = true;
      frametime = true;
      frame_timing = true; # the graph itself

      gpu_stats = true;
      gpu_temp = true;
      cpu_stats = true;
      cpu_temp = true;

      # Top left, out of the way of the crosshair and the radar.
      position = "top-left";
      font_size = 20;
      background_alpha = "0.35";
      round_corners = 8;

      # Toggle it off mid-game without restarting.
      toggle_hud = "Shift_R+F12";

      # The starter capped this at 144, which predates knowing what panel this
      # is: eDP-1 runs at 240 Hz, so that threw away 96 Hz of headroom in a game
      # where latency is the whole point. Uncapped now.
      #
      # Worth revisiting if the laptop runs hot — it already idles around 75 °C,
      # and an uncapped competitive shooter is the workload most likely to push
      # it. `limit_fps = 240` (match the panel, render nothing it cannot show)
      # is the middle setting if that happens.
    };
  };

  home.packages = with pkgs; [
    # Brave Origin is not in nixpkgs, so it is packaged locally from Brave's
    # own .deb — see ./pkgs/brave-origin.nix for how to bump it.
    (pkgs.callPackage ./pkgs/brave-origin.nix { })

    # T3 Code. Upstream ships Linux only as an AppImage, so it is wrapped
    # locally — see ./pkgs/t3code-app.nix, which also explains the
    # --password-store flag it has to be launched with.
    (pkgs.callPackage ./pkgs/t3code-app.nix { })

    kdePackages.dolphin # SUPER+E in config/niri/config.kdl
    kdePackages.kate # SUPER+K
    filezilla

    # Nextcloud desktop sync client. Qt, so it picks up the platform theme and
    # palette wired in ../qt.nix rather than falling back to Breeze.
    nextcloud-client

    # Two Discord clients on purpose, because they are not interchangeable here.
    #
    # vesktop is the one Noctalia can theme: its `discord` community template
    # writes CSS into ~/.config/vesktop/themes/ (and webcord/legcord), and the
    # official client has no equivalent — it would need BetterDiscord or Vencord
    # injected before it could load a stylesheet at all. vesktop also tends to
    # behave better under Wayland, screenshare included, since Vencord is built in.
    #
    # discord is the official build, added on request. It works, it just stays
    # the one window on the desktop that ignores the palette.
    vesktop
    discord

    # Telegram. Has a Noctalia community template, so it picks up the palette
    # like vesktop does — pick "noctalia" under Settings > Chat Settings >
    # Theme once it is installed.
    telegram-desktop

    # Office suite. Chosen over LibreOffice because OOXML is what it edits
    # natively — a .docx someone sends comes back out of it still laid out the
    # way they wrote it, which is the whole reason it is here. LibreOffice
    # converts to ODF on open and back on save, and complex documents do not
    # survive the round trip intact.
    #
    # The trade is macros and the rarer Excel functions, which LibreOffice
    # handles better. If that ever comes up, libreoffice-qt6-fresh installs
    # alongside this without conflict — the mimeApps block below decides which
    # one actually opens a file, not which ones are installed.
    #
    # Its .desktop also claims application/pdf. zathura keeps it: the default
    # set below wins over anything a MimeType= line declares.
    onlyoffice-desktopeditors

    # --- The gaps ---
    #
    # `xdg-mime query default` found no handler at all for video, audio or
    # archives, and images and PDFs were both opening in Brave. Double-clicking
    # a folder launched kitty. All of that came from the nixtalia starter, which
    # shipped a shell without the applications a desktop needs to open files.

    imv # image viewer: Wayland-native, keyboard-driven, opens instantly
    kdePackages.ark # archive GUI

    # Ark is a front end — it shells out to these, and none of them were
    # installed, so it could open a .zip and almost nothing else. Setting ark as
    # the handler for application/zip above without these was half a fix.
    unzip
    p7zip
    unrar

    # --- Wayland desktop utilities ---

    # wl-copy / wl-paste. Noctalia has its own clipboard for the GUI, but
    # nothing could reach the clipboard from a script or a pipe without this.
    wl-clipboard

    # Annotate a screenshot before sending it — arrows, boxes, blur over
    # anything private. Noctalia's capture already lands on the clipboard, and
    # this is the step between that and pasting it into Discord.
    satty
    screenshot-annotate # the two wired together; bound to SUPER+Print

    # Pick a colour from anywhere on screen. Kept after the Hyprland removal on
    # purpose: it is a standalone wlroots-protocol tool, not part of that
    # session, and it works fine under niri despite the name.
    hyprpicker

    # Prints the Wayland events a key produces. The tool to reach for when a
    # keybind does not fire and it is unclear whether the compositor is even
    # seeing the key — which came up more than once configuring niri.
    wev
  ];

  # imv ships its desktop entry with NoDisplay=true, which hides it from every
  # application chooser. Setting it as the default for image/* is then not
  # enough on its own: `xdg-mime query default` answers imv.desktop, but a
  # NoDisplay entry is not offered in an "Open With" list, so there is no way
  # to pick it by hand when the default does not take.
  #
  # Upstream marks it hidden because imv is meant to be launched from an
  # association rather than a menu, which is precisely the case that breaks.
  # This copy lands in ~/.local/share/applications and takes precedence.
  #
  # (The *empty* chooser dialog Dolphin used to put up was a different fault
  # entirely — see the applications.menu block below. NoDisplay hides one
  # entry; that one hid all of them.)
  xdg.desktopEntries.imv = {
    name = "imv";
    genericName = "Image viewer";
    comment = "Fast Image Viewer";
    exec = "imv %F";
    icon = "multimedia-photo-viewer";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "2DGraphics" "Viewer" ];
    mimeType = [
      "image/png"
      "image/jpeg"
      "image/gif"
      "image/webp"
      "image/bmp"
      "image/tiff"
      "image/svg+xml"
      "image/avif"
      "image/heif"
      "image/jxl"
      "image/qoi"
      "image/x-farbfeld"
    ];
    settings.Keywords = "photo;picture;";
  };

  # Apple Music, which has no Linux client at all — this is Brave in app mode,
  # so it opens as its own frameless window instead of a tab.
  #
  # **`--class` does not work here and was removed.** In `--app=` mode Chromium
  # derives the Wayland app_id from the app URL and the profile directory name
  # and ignores the flag entirely — no warning, the window just comes up as
  # `brave-music.apple.com__-Default`. Verified with `niri msg windows`.
  #
  # So StartupWMClass below spells out what Chromium actually produces, which is
  # what lets the dock tie the running window to this entry instead of stacking
  # it under the Brave icon. It is deterministic (URL + profile), but if either
  # the URL or `--user-data-dir` changes, re-check it with `niri msg windows`.
  #
  # `--user-data-dir` keeps the Apple session in its own profile directory. The
  # alternative — sharing the main Brave profile — means the app window and the
  # browser fight over the same cookie jar, and signing out of one signs out of
  # the other.
  #
  # The icon name resolves against Papirus-Dark (see ../gtk.nix), which ships
  # apple-music.svg; there is no file path to keep in sync.
  xdg.desktopEntries.apple-music = {
    name = "Apple Music";
    genericName = "Music streaming";
    comment = "Apple Music in a dedicated Brave window";
    exec = "brave-origin --app=https://music.apple.com --user-data-dir=${config.xdg.dataHome}/apple-music";
    icon = "apple-music";
    terminal = false;
    type = "Application";
    categories = [ "AudioVideo" "Audio" "Player" ];
    settings = {
      StartupWMClass = "brave-music.apple.com__-Default";
      Keywords = "music;apple;streaming;itunes;";
    };
  };

  # Fixes the associations above. Without this, the defaults stay wherever the
  # starter left them — `xdg-mime query default inode/directory` really did
  # answer kitty-open.desktop.
  xdg.mimeApps = {
    enable = true;
    defaultApplications =
      let
        image = [ "imv.desktop" ];
        video = [ "mpv.desktop" ];
        pdf = [ "org.pwmt.zathura.desktop" ];
        archive = [ "org.kde.ark.desktop" ];
        browser = [ "brave-origin.desktop" ];
        office = [ "onlyoffice-desktopeditors.desktop" ];
      in
      {
        "inode/directory" = [ "org.kde.dolphin.desktop" ];

        "image/png" = image;
        "image/jpeg" = image;
        "image/gif" = image;
        "image/webp" = image;
        "image/bmp" = image;
        "image/tiff" = image;
        "image/svg+xml" = image;

        "video/mp4" = video;
        "video/x-matroska" = video;
        "video/webm" = video;
        "video/quicktime" = video;
        "video/x-msvideo" = video;
        "audio/mpeg" = video;
        "audio/flac" = video;
        "audio/ogg" = video;
        "audio/wav" = video;
        "audio/x-vorbis+ogg" = video;

        "application/pdf" = pdf;

        "application/zip" = archive;
        "application/x-tar" = archive;
        "application/gzip" = archive;
        "application/x-7z-compressed" = archive;
        "application/vnd.rar" = archive;
        "application/x-xz" = archive;

        # Office documents. Spelled out rather than left to the MimeType= line
        # in OnlyOffice's own .desktop, for the reason the t3code note below
        # gives: declaring a type is not the same as being its default. The
        # legacy .doc/.xls/.ppt types are separate from the OOXML ones and both
        # sets are needed — a 2003-era attachment does not match the openxml
        # media type.
        "application/msword" = office;
        "application/vnd.ms-excel" = office;
        "application/vnd.ms-powerpoint" = office;
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = office;
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template" = office;
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = office;
        "application/vnd.openxmlformats-officedocument.spreadsheetml.template" = office;
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" = office;
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow" = office;
        "application/vnd.openxmlformats-officedocument.presentationml.template" = office;
        "application/vnd.oasis.opendocument.text" = office;
        "application/vnd.oasis.opendocument.spreadsheet" = office;
        "application/vnd.oasis.opendocument.presentation" = office;
        "application/rtf" = office;
        "text/csv" = office;

        "text/html" = browser;
        "x-scheme-handler/http" = browser;
        "x-scheme-handler/https" = browser;

        # T3 Code drives its own UI through deep links — opening its settings
        # asks the portal to handle a t3code:// URL, and with nothing claiming
        # the scheme the portal answers with "No Apps available" instead. The
        # app's own .desktop declares the MimeType, but declaring is not the
        # same as being the registered default.
        "x-scheme-handler/t3code" = [ "t3code.desktop" ];
        "x-scheme-handler/t3code-dev" = [ "t3code.desktop" ];
      };
  };

  # **Everything above is invisible to Dolphin without this file.**
  #
  # The symptom: double-clicking a video in Dolphin put up "Select the program
  # you want to use to open the file" with an *empty* list — no mpv, no
  # applications at all, and nothing to pick. Meanwhile `xdg-mime query default
  # video/mp4` answered `mpv.desktop`, mimeapps.list was correct, and
  # `mpv.desktop` really was in XDG_DATA_DIRS. Every layer checked out.
  #
  # The cause is one directory below all of that. KDE applications do not read
  # the .desktop files off disk at open time; they read KService's cache
  # (~/.cache/ksycoca6_*), and kbuildsycoca6 does not scan share/applications
  # directly either — it walks the freedesktop *menu* at
  # $XDG_CONFIG_DIRS/menus/applications.menu and indexes what that menu
  # includes. With no such file it indexes nothing, and KService's answer to
  # "what can open video/mp4" is a truthful, empty list.
  #
  # Nothing here ships one. On a normal KDE install it comes from
  # plasma-workspace; this is Dolphin and Ark on niri, without Plasma. Counting
  # `.desktop` strings in the cache before and after: 0, then 213. (Those
  # strings are UTF-16BE — `strings -eb`, or a plain grep finds nothing and the
  # measurement looks like a dead end.)
  #
  # <All/> is deliberate — the menu exists only to hand kbuildsycoca6 the full
  # set of applications, not to build a categorised launcher (Noctalia's
  # launcher reads the .desktop files itself and never needed this). The name
  # must match $XDG_MENU_PREFIX + "applications.menu"; the prefix is unset
  # under niri, so plain `applications.menu` is what gets looked up.
  #
  # Costs nothing to carry: `nix store diff-closures` across this change is
  # empty. No package, no daemon, no autostart — one inert XML file.
  #
  # After a rebuild, KDE apps that are already running keep the stale cache —
  # close them and reopen, or run `kbuildsycoca6 --noincremental`.
  xdg.configFile."menus/applications.menu".text = ''
    <!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN" "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">
    <Menu>
      <Name>Applications</Name>
      <DefaultAppDirs/>
      <DefaultDirectoryDirs/>
      <DefaultMergeDirs/>
      <Include><All/></Include>
    </Menu>
  '';

  # Removed from the starter: pcmanfm (second file manager nothing launches),
  # spicetify-cli (only useful with the Spotify theming template enabled, and
  # that one is a *community* template, so it would go in
  # theme.templates.community_ids — not builtin_ids), vivaldi and
  # firefox (you asked for brave-origin), pywalfox-native (drove v4's pywalfox
  # template, which no longer exists in v5).
}
