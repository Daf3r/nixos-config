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

  # ntsync — the kernel implementation of Windows synchronisation primitives
  # (mutexes, semaphores, events). It replaces the eventfd juggling of esync and
  # fsync, and it is where a heavily threaded Proton game gains the most, which
  # is precisely the profile of an Unreal Engine 5 title. Proton-GE has used it
  # since 10-9 and mainline Proton since 11.
  #
  # The xanmod kernel builds it as a module and nothing loads it, so /dev/ntsync
  # simply did not exist before this line: Proton finds no device, falls back to
  # fsync and says nothing about it.
  boot.kernelModules = [ "ntsync" ];

  # Loading the module is only half of it. ntsync registers as a misc device, so
  # the node comes up root-owned and unreadable by the user, and the kernel patch
  # that would have made it 0666 by default was dropped in favour of a udev rule
  # that systemd 261 still does not ship — checked in its own
  # 50-udev-default.rules, which has no ntsync entry. Without the rule below the
  # device exists and Proton still cannot open it, which is the same silent
  # failure mode as gamemode's polkit policy: everything looks configured and
  # nothing happens.
  #
  # `uaccess` rather than a blanket 0666 hands access to whoever is logged in at
  # the seat, the way systemd would have done it upstream.
  services.udev.extraRules = ''
    KERNEL=="ntsync", SUBSYSTEM=="misc", MODE="0660", TAG+="uaccess"
  '';

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
  # The ASUS platform profile is deliberately NOT touched here, and the reason
  # is no longer "noise" — it is that it does not work. Tested live on
  # 2026-08-07 with CS2 running, switching to `performance` and back:
  #
  #   balanced     2490 MHz   78-86 W   GPU 85 C   Tctl 93.9 C   fans 4000/4400
  #   performance  2490 MHz   76-87 W   GPU 87 C   Tctl 95.8 C   fans 6000/6300
  #
  # The clock did not move by a single MHz. The fans went up 50% and the CPU
  # got 2 C hotter. The earlier claim that `performance` "unlocks the GPU's
  # remaining clock headroom" was never measured — it was inferred from the
  # clock sitting still, and it is wrong. Leave the hooks below commented.
  #
  # What the clock is actually doing: the 3105 MHz that nvidia-smi reports as
  # "Max Clocks" is a silicon spec number this part will not sustain, and the
  # 140 W in "Max Power Limit" is likewise not the configured limit — the real
  # one is `Current Power Limit: 100.00 W`. Against that, 78-86 W at 85-87 C
  # is not a machine being held back. 2490 MHz is simply the boost bin for
  # this thermal state, and NVIDIA's soft thermal binning does not raise any
  # flag in clocks_throttle_reasons, which is why that field reads 0x0 while
  # the clock is visibly capped. A fixed clock is NOT by itself evidence of an
  # artificial cap — check the power limit and temperature before concluding.
  #
  # The real ceiling is thermal and it is shared: Tctl runs 93-96 C against a
  # ~95 C Tjmax while the GPU sits at 85-87 C, on a chassis whose fans are
  # already loud in `balanced`. CPU and GPU are drawing from one budget, so
  # anything that heats the CPU costs the GPU clocks. That makes gamemode's
  # `desiredgov = "performance"` below a genuine open question rather than a
  # settled win: it boosts all 24 cores for a game that loads about five, and
  # the heat comes out of the same budget. Untested as of 2026-08-07.
  #
  # Without the polkit rule below, gamemode activates and then silently
  # changes nothing.
  #
  # Its own polkit policy ships every action denied — allow_any, allow_inactive
  # and allow_active are all "no" — because upstream expects the administrator
  # to decide who may use it. Nothing in nixpkgs fills that in, so the result
  # was `gamemode is active` in one breath and this in the journal in the next:
  #
  #   pkexec: daf3r: Error executing command as another user: Not authorized
  #   gamemoded: Failed to update split_lock_mitigate
  #
  # The four helpers are the whole privileged surface: the CPU governor, GPU
  # clock states, CPU pinning, and a couple of kernel sysctls. Granting them to
  # the `gamemode` group rather than to everyone means the authorisation is
  # something you opt into by adding a user to that group — see
  # ./configuration.nix.
  security.polkit.extraConfig = ''
    polkit.addRule(function(action, subject) {
      if (action.id.indexOf("com.feralinteractive.GameMode.") == 0
          && subject.isInGroup("gamemode")) {
        return polkit.Result.YES;
      }
    });
  '';

  programs.gamemode = {
    enable = true;

    settings = {
      general = {
        renice = 10;
        desiredgov = "performance";
        defaultgov = "powersave"; # what to restore on exit
      };

      # The platform profile now sits at Balanced on AC (see ../asus.nix for the
      # fan and temperature numbers that decided it), so Performance has to be
      # asked for rather than assumed. gamemode is the right place to ask: the
      # profile is raised for exactly as long as a game holds the lock and drops
      # back on its own when the game exits, including when it crashes.
      #
      # powerprofilesctl rather than asusctl because both daemons drive the same
      # platform_profile and this is the one that does not need root: gamemoded
      # runs these as the user. asusd notices the change rather than fighting it
      # — it logs "watch_platform_profile changed" and follows.
      custom = {
        start = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set performance";
        end = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced";
      };
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
