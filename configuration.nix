{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./desktops.nix
    ./gaming.nix
    ./fontsAndNeeds.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_xanmod_latest;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
  };

  networking.hostName = "daf3r-starter"; #Change this to the host name of your choice, this is also how you will reference the flake to update.
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

  users.users.daf3r = { #Change username here
    isNormalUser = true;
    description = "Noctalia is Great!!"; # Change this to the long form user name of your choice. (This only shows on login in)
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.fish;
  };

  system.stateVersion = "25.05";
}
