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

      # Remember volume across runs, and never blow an ear out on start.
      volume-max = 150;
      volume = 70;

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

    # Pick a colour from anywhere on screen. Works under both compositors
    # despite the name.
    hyprpicker

    # Prints the Wayland events a key produces. The tool to reach for when a
    # keybind does not fire and it is unclear whether the compositor is even
    # seeing the key — which came up more than once configuring niri.
    wev
  ];

  # imv ships its desktop entry with NoDisplay=true, which hides it from every
  # application chooser. Setting it as the default for image/* is then not
  # enough on its own: `xdg-mime query default` answers imv.desktop, but
  # Dolphin refuses to offer a hidden application and puts up an empty "select
  # the program you want to use" dialog instead.
  #
  # Upstream marks it hidden because imv is meant to be launched from an
  # association rather than a menu, which is precisely the case that breaks.
  # This copy lands in ~/.local/share/applications and takes precedence.
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
