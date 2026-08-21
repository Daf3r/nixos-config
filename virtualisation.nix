{ config, pkgs, ... }:

{
  # VMware Workstation, for running the FunSociety lab VMs that were built on
  # VMware and exist as .vmx/.vmdk pairs. Importing this module is what pulls
  # in the out-of-tree vmmon and vmnet kernel modules
  # (config.boot.kernelPackages.vmware), the setuid wrapper vmware-vmx needs to
  # open /dev/vmmon, and the vmware-networks services that create the NAT and
  # host-only interfaces. Without the module the package alone installs fine
  # and then every VM fails to power on with "Could not open /dev/vmmon".
  #
  # The kernel modules are built against boot.kernelPackages, which here is
  # linuxPackages_xanmod_latest. Checked on 2026-08-21: cache.nixos.org serves
  # vmware-modules-workstation-25h2-20251015-7.1.8 prebuilt, so this costs a
  # download rather than a kernel-module compile. If a future xanmod bump lands
  # before upstream patches the modules for it, this is the first thing that
  # breaks — pin boot.kernelPackages to the last working kernel rather than
  # patching vmmon by hand.
  virtualisation.vmware.host = {
    enable = true;

    # Guest disks and shared folders on this laptop live on NTFS volumes that
    # came from the Windows install. Without ntfs3g the VMware file dialogs
    # cannot see a mounted NTFS image at all.
    extraPackages = [ pkgs.ntfs3g ];
  };

  # vmware-vmx allocates the guest's memory as one large mapping, and with
  # transparent hugepages left on the kernel wakes kcompactd to defragment
  # memory for it on every allocation. The NixOS vmware-host module documents
  # this as a known cause of the host stuttering while a VM runs, and it is the
  # same synchronous-compaction path that memory.nix already tunes against on
  # this machine, so the two changes pull in the same direction. Omitting it
  # does not stop VMware from working — it makes the host freeze in bursts
  # while a guest is under memory pressure.
  boot.kernelParams = [ "transparent_hugepage=never" ];
}
