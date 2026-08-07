{ config, lib, pkgs, ... }:

# Hybrid laptop: NVIDIA RTX 4060 Mobile (0000:01:00.0) + AMD Radeon "Raphael"
# iGPU (0000:09:00.0).
#
# PRIME offload does NOT apply to this machine. Checked /sys/class/drm: the
# internal panel and HDMI-A-1 both hang off the NVIDIA card (card1), and every
# connector on the AMD iGPU reads "disconnected".
#
# The panel's connector name is NOT stable and must never be relied on. It has
# been observed as both card1-eDP-1 and card1-eDP-2 across reboots of this same
# machine with nothing changed — the NVIDIA driver simply numbers its eDP
# connector differently, and the presence of a second eDP on the iGPU makes the
# index ambiguous. niri's config.kdl therefore matches monitors by EDID
# make/model — the quoted name in each `output` block — rather than by
# connector. Getting this wrong is not subtle: the rules are
# ignored wholesale and the displays come up at the wrong rate, in the wrong
# order.
#
# To find the panel in /sys/class/drm on any given boot, look for the eDP
# connector under the card whose device/vendor reads 0x10de (NVIDIA). The display MUX is in
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
    # setting the compositor actually depends on.
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
