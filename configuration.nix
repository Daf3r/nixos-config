{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./desktops.nix
    ./gpu.nix
    ./asus.nix
    ./gaming.nix
    ./fontsAndNeeds.nix
    ./keyboard.nix
    ./wireguard.nix
    ./tailscale.nix
    ./storage.nix
    ./memory.nix
    ./monitor.nix
    ./diagnostics.nix
    ./updates.nix
  ];

  # No swap device exists on this machine and btrfs makes swapfiles awkward.
  # Compressed swap in RAM covers memory spikes (rebuilds, CS2 + browser)
  # without touching the disk.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];

    # Prebuilt Noctalia v5 binaries, so a rebuild downloads instead of
    # compiling a C++ shell from source.
    substituters = [ "https://noctalia.cachix.org" ];
    trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
  };

  networking.hostName = "daf3r-starter"; # must match the nixosConfigurations attribute in flake.nix
  networking.networkmanager.enable = true;
  services.printing.enable = true;

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # America/New_York came from the nixtalia starter and was two hours fast:
  # El Salvador is CST -0600 and, unlike the US, does not observe DST, so the
  # offset is the same year round.
  time.timeZone = "America/El_Salvador";
  i18n.defaultLocale = "en_US.UTF-8";

  # Qt application theming has to be wired at the system level, not in
  # home-manager. The module's own description is the reason: "Enabling this
  # option is necessary for Qt plugins to work in the installed profiles."
  #
  # nixpkgs wraps every Qt application with a QT_PLUGIN_PATH pointing at its own
  # closure, so a platform-theme plugin living in the *user* profile is simply
  # invisible to it — checking Dolphin's /proc/<pid>/environ showed exactly that,
  # with no qt6ct anywhere in its plugin path. This option puts the plugins in
  # environment.systemPackages and QT_QPA_PLATFORMTHEME in environment.variables,
  # which is what the wrappers actually see.
  #
  # "qt5ct" installs qt5ct *and* qt6ct, and the qt6ct plugin registers itself
  # under both the qt5ct and qt6ct keys — so this one value covers Qt5 and Qt6.
  # The per-application settings (icon theme, the palette Noctalia generates)
  # live in ./qt.nix.
  qt = {
    enable = true;
    platformTheme = "qt5ct";
  };

  # Docker. RemesaFam ships docker-compose.dev.yml and a Dockerfile, and unlike
  # the rest of the development toolchain this cannot live in a per-project
  # devShell: it needs a daemon and a socket, which are system state.
  #
  # Everything else — node, pnpm, Rust, the Tauri libraries — is declared in
  # each project's own flake.nix and enters the shell through direnv, so the
  # two projects do not have to agree on versions. See ./nix-tools.nix.
  virtualisation.docker = {
    enable = true;
    # Reclaims dangling images and stopped containers weekly. Docker otherwise
    # accumulates them indefinitely, and this is a laptop.
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  programs.fish.enable = true;
  programs.nix-ld.enable = true;

  # Prebuilt applications ask /usr/bin/ldd whether this system runs glibc or
  # musl. The library that does it, detect-libc, ships inside sharp and so
  # inside most Electron apps; when it cannot read that file it falls back to
  # process.report.getReport(), and that call traps inside Electron's Node.
  # The ChatGPT desktop app died with SIGILL about three seconds after start
  # until this symlink existed — dropping it brings the crash back, and for
  # every other packaged app carrying sharp too. NixOS already exposes
  # /usr/bin/env for the same class of reason.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/ldd - - - - ${pkgs.glibc.bin}/bin/ldd"
  ];

  # A friendlier front end for nixos-rebuild. The reason it is worth having:
  # `nh os switch` prints a *diff of the packages that changed* between the
  # running generation and the new one, instead of the wall of store paths
  # nixos-rebuild emits. Rebuilding stops being a blind operation.
  #
  #   nh os switch      apply now          (= nixos-rebuild switch)
  #   nh os boot        apply at next boot
  #   nh os test        apply without a boot entry
  #   nh search <pkg>   fast package search
  #
  # NH_FLAKE means none of those need --flake ~/nixos-config spelled out.
  programs.nh = {
    enable = true;
    flake = "/home/daf3r/nixos-config";

    # Replaces running `ncg` by hand. Keeps the last 10 generations and anything
    # newer than a week, weekly.
    clean = {
      enable = true;
      extraArgs = "--keep 10 --keep-since 7d";
    };
  };
  users.users.daf3r = {
    isNormalUser = true;
    description = "daf3r";
    # i2c: required for ddcutil to talk DDC/CI to the external MSI over HDMI.
    # Without it the brightness keys only ever move the laptop panel, because
    # the internal panel has a sysfs backlight and an external monitor does not.
    # docker: without it every docker command needs sudo, because the daemon
    # socket is root-owned. Note this is effectively root access to the host —
    # standard for a single-user development machine, worth knowing anyway.
    # gamemode: the polkit rule in ./gaming.nix grants the privileged helpers —
    # CPU governor, GPU clocks — to this group rather than to every local user.
    # programs.gamemode creates the group but deliberately leaves it empty, so
    # without this line gamemode activates and is denied everything it tries.
    extraGroups = [ "networkmanager" "wheel" "video" "i2c" "docker" "gamemode" ];
    shell = pkgs.fish;
  };

  system.stateVersion = "25.05";
}
