{ config, lib, pkgs, ... }:

# ASUS ROG Strix G17 (G713PV) — Ryzen 9 7845HX + RTX 4060 Mobile.
{
  # asusd backs the hardware that generic Linux does not reach on ROG laptops:
  # the keyboard RGB (this machine exposes asus::kbd_backlight), the
  # Quiet/Balanced/Performance platform profiles behind Fn+F5, custom fan
  # curves, the ROG key, and the battery charge limit.
  # `enableUserService = false` used to sit here, with a note that asusd-user
  # drives per-user Aura/AniMe effects and that this model has no AniMe Matrix.
  # Upstream removed the option — "the asusd user service is no longer required"
  # — and turned it into a hard assertion, so keeping the line stops the whole
  # configuration evaluating on any newer nixpkgs.
  #
  # Dropping it is a no-op on the pinned nixpkgs too: the option's default there
  # is already `false`, which is what the line set. The prepared-update engine
  # (../updates.nix) is what surfaced this, before it could break a rebuild.
  services.asusd.enable = true;

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

  # asus-shutdown is a guard that asusctl's own package ships as a unit; nothing
  # here declares it, services.asusd above is what links it in. It sits idle for
  # the whole session and applies deferred GPU settings on the way down, so it
  # only exits when a real shutdown is under way — on SIGTERM it logs "Deferring
  # exit until deferred shutdown apply reaches a safe completion point" and stays
  # put. Its unit also carries SendSIGKILL=no, so systemd is forbidden from
  # forcing it. The combination means the unit cannot be restarted on a live
  # system at all: any switch that changes it (a new asusctl store path is
  # enough) burns two 45s stop timeouts, marks the unit failed, and then cannot
  # start the new one because the old process still holds the cgroup — which is
  # exactly what broke `nh os switch` on 2026-08-13.
  #
  # Leaving it alone across a switch is not a workaround but the behaviour the
  # binary was written for: it is replaced at the next boot, when it exits
  # cleanly by itself. asDropin is required — without it NixOS would generate a
  # unit of its own and shadow the package's, which is the one that carries the
  # actual ExecStart and its sandbox.
  systemd.services.asus-shutdown = {
    overrideStrategy = "asDropin";
    restartIfChanged = false;
    stopIfChanged = false;
  };

  # asusd persists the Aura *mode and colour* in /etc/asusd/aura_19b6.ron, but
  # not the backlight level — asus::kbd_backlight comes up at 0 on every boot,
  # which reads as "the RGB is dead" even though the mode is set correctly.
  # Restore it here. 3 is max on this board (see max_brightness); Fn+F3/F4 still
  # overrides it at runtime.
  #
  # Colour is white, set once with: asusctl aura static -c FFFFFF
  systemd.services.asus-kbd-backlight = {
    description = "Restore keyboard backlight brightness at boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "asusd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'echo 3 > /sys/class/leds/asus::kbd_backlight/brightness'";
    };
  };

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
