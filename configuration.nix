{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./desktops.nix
    ./gpu.nix
    ./asus.nix
    ./gaming.nix
    ./fontsAndNeeds.nix
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

  programs.fish.enable = true;
  programs.nix-ld.enable = true;

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
    extraGroups = [ "networkmanager" "wheel" "video" "i2c" ];
    shell = pkgs.fish;
  };

  system.stateVersion = "25.05";
}
