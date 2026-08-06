{ config, lib, pkgs, ... }:

# ASUS ROG Strix G17 (G713PV) — Ryzen 9 7845HX + RTX 4060 Mobile.
{
  # asusd backs the hardware that generic Linux does not reach on ROG laptops:
  # the keyboard RGB (this machine exposes asus::kbd_backlight), the
  # Quiet/Balanced/Performance platform profiles behind Fn+F5, custom fan
  # curves, the ROG key, and the battery charge limit.
  services.asusd = {
    enable = true;
    # asusd-user drives per-user Aura/AniMe effects. This model has no AniMe
    # Matrix and static RGB is handled by the system daemon, so it stays off.
    enableUserService = false;
  };

  # asusd turns this on by default (lib.mkDefault true). Disabled on purpose.
  #
  # supergfxd switches the GPU MUX between Integrated / Hybrid / AsusMuxDgpu by
  # loading and unloading the NVIDIA kernel modules at runtime. On a system
  # that pins services.xserver.videoDrivers = [ "nvidia" ] (see ./gpu.nix,
  # required because the panel is wired to the dGPU) that fight is the single
  # most common way to end up at a black screen after an update.
  #
  # Switch modes in the BIOS instead. If you later want runtime switching, flip
  # this to true and re-read ./gpu.nix at the same time — the two must agree.
  services.supergfxd.enable = false;

  # Cap charging to preserve the battery when the laptop lives on AC. asusctl
  # persists this across reboots.  Change with: asusctl -c 100
  systemd.services.asus-battery-charge-limit = {
    description = "Limit battery charge to 80%";
    wantedBy = [ "multi-user.target" ];
    after = [ "asusd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo 80 > /sys/class/power_supply/BAT0/charge_control_end_threshold'";
    };
  };

  # No extra packages needed: services.asusd installs the asusctl package, which
  # already ships asusctl (CLI), asusd, asusd-user and rog-control-center (GUI).
}
