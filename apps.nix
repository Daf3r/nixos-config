{ config, pkgs, ... }:

{
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
  ];

  # Removed from the starter: pcmanfm (second file manager nothing launches),
  # spicetify-cli (only useful with the Spotify theming template enabled, and
  # that one is a *community* template, so it would go in
  # theme.templates.community_ids — not builtin_ids), vivaldi and
  # firefox (you asked for brave-origin), pywalfox-native (drove v4's pywalfox
  # template, which no longer exists in v5).
}
