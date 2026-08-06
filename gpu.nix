{ config, lib, pkgs, ... }:

# Hybrid laptop: NVIDIA RTX 4060 Mobile (0000:01:00.0) + AMD Radeon "Raphael"
# iGPU (0000:09:00.0).
#
# PRIME offload does NOT apply to this machine. Checked /sys/class/drm: the
# internal panel (eDP-2) and HDMI-A-1 are both wired to the NVIDIA card, and
# every connector on the AMD iGPU reads "disconnected". The display MUX is in
# discrete mode, so NVIDIA has to be the primary GPU — offload would leave the
# desktop rendering on a GPU that drives no outputs.
#
# If you ever flip the BIOS MUX to hybrid/Optimus, revisit this: at that point
# hardware.nvidia.prime.offload becomes the right choice, with
# nvidiaBusId = "PCI:1:0:0" and amdgpuBusId = "PCI:9:0:0".
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    # Required for Wayland. Sets nvidia_drm.modeset=1, which is the single
    # setting Hyprland actually depends on.
    modesetting.enable = true;

    # Ada (RTX 4060) runs the open kernel modules well, and they are the
    # supported path on driver 560+.
    open = true;

    powerManagement.enable = true; # save/restore VRAM across suspend
    powerManagement.finegrained = false; # offload-only; would break this setup

    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Keep the iGPU's userspace drivers around: it drives no display, but it is
  # still present for compute and for video decode fallbacks.
  hardware.graphics = {
    enable = true;
    enable32Bit = true; # also set by programs.steam; explicit here for clarity
  };
}
