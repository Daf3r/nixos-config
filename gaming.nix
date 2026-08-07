{ config, pkgs, ... }:

{
  programs.steam = {
    enable = true;

    # Steam's module already turns on hardware.graphics.enable32Bit and
    # hardware.steam-hardware, so the 32-bit runtime CS2 needs is covered.
    gamescopeSession.enable = true;

    remotePlay.openFirewall = true;
    localNetworkGameTransfers.openFirewall = true;

    # Proton-GE, selectable per game in Steam > Properties > Compatibility.
    # CS2 has a native Linux build, so it does not need this — it is here for
    # the rest of your library.
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };

  programs.gamescope = {
    enable = true;
    capSysNice = true;
  };

  # Drops the CPU governor to performance and raises the game's priority for
  # the duration of a session. In Steam, set CS2's launch options to:
  #   gamemoderun %command%
  programs.gamemode.enable = true;

  environment.systemPackages = with pkgs; [
    heroic
    protonup-qt
    lutris
    mangohud # also configured per-user in apps.nix

    # `sensors`. Missing when it was first needed: nvidia-smi reports the GPU,
    # but nothing on the system could read CPU package temperature, which is
    # exactly the number wanted while diagnosing whether a game is thermally
    # limited. Run `sudo sensors-detect --auto` once if a sensor is missing.
    lm_sensors
  ];
}
