{ config, pkgs, ... }:

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

      # Remember volume across runs, and never blow an ear out on start.
      volume-max = 150;
      volume = 70;

      # Subtitles: prefer Spanish, fall back to English.
      slang = "es,spa,en,eng";
      alang = "es,spa,en,eng";

      screenshot-directory = "${config.home.homeDirectory}/Pictures/Screenshots";
    };
  };

  programs.mangohud = {
    enable = true;
    settings = {
      full = true;

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

    kdePackages.dolphin # SUPER+E in hyprland.conf
    kdePackages.kate # SUPER+K
    filezilla
    spotify

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

    # --- The gaps ---
    #
    # `xdg-mime query default` found no handler at all for video, audio or
    # archives, and images and PDFs were both opening in Brave. Double-clicking
    # a folder launched kitty. All of that came from the nixtalia starter, which
    # shipped a shell without the applications a desktop needs to open files.

    imv # image viewer: Wayland-native, keyboard-driven, opens instantly
    zathura # PDF: keyboard-driven and has a Noctalia theme template
    kdePackages.ark # archives; adds itself to Dolphin's context menu
  ];

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

        "text/html" = browser;
        "x-scheme-handler/http" = browser;
        "x-scheme-handler/https" = browser;
      };
  };

  # Removed from the starter: pcmanfm (second file manager nothing launches),
  # spicetify-cli (only useful with the Spotify theming template enabled, and
  # that one is a *community* template, so it would go in
  # theme.templates.community_ids — not builtin_ids), vivaldi and
  # firefox (you asked for brave-origin), pywalfox-native (drove v4's pywalfox
  # template, which no longer exists in v5).
}
