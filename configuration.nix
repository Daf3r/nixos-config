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

  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";

  programs.fish.enable = true;
  programs.nix-ld.enable = true;
  users.users.daf3r = {
    isNormalUser = true;
    description = "daf3r";
    extraGroups = [ "networkmanager" "wheel" "video" ];
    shell = pkgs.fish;
  };

  system.stateVersion = "25.05";
}
