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

  # Raises CPU clocks and the game's priority for the duration of a session,
  # then puts everything back. It only does any of this when the game is
  # actually launched through it, so Steam's launch options must say:
  #
  #   gamemoderun mangohud %command%
  #
  # Measured on 2026-08-07 while CS2 felt choppy, and the numbers said the
  # machine was not working hard: GPU between 54% and 92% with its clock pinned
  # at exactly 2490 MHz of a possible 3105, drawing 68 W of an available 140,
  # never thermally throttling, and niri's logs completely clean. Utilisation
  # swinging that far with a fixed clock is the signature of a system with
  # capacity to spare that is not being allowed to use it — the platform profile
  # was `balanced` and the CPU governor `powersave`.
  #
  # The governor is the half worth changing automatically. `powersave` on
  # amd_pstate keeps per-core clocks low and ramps them lazily, which costs
  # exactly the single-thread responsiveness a shooter depends on — and it does
  # so even at 30% total utilisation, which is why "the CPU is not busy" was
  # misleading.
  #
  # The ASUS platform profile is deliberately NOT touched here. Switching it to
  # `performance` is what unlocks the GPU's remaining clock headroom, but it
  # also drives the fan curve hard, and this laptop is used quietly most of the
  # time. Uncomment the custom hooks below to trade that noise for the frames;
  # they revert on exit, so it only applies while a game is running.
  programs.gamemode = {
    enable = true;

    settings = {
      general = {
        renice = 10;
        desiredgov = "performance";
        defaultgov = "powersave"; # what to restore on exit
      };

      # custom = {
      #   start = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance";
      #   end = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced";
      # };
    };
  };

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
