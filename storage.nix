{ config, lib, pkgs, ... }:

# The second NVMe, formerly the CachyOS disk. Wiped and reformatted on
# 2026-08-09, once a reboot had proven the machine boots from the KINGSTON's own
# systemd-boot rather than through Limine, which lived here.
#
# **Mounted by UUID, never by device node.** The kernel's numbering on this
# machine is not stable: this disk was `nvme0n1` in the morning and `nvme1n1`
# by the afternoon, with no hardware change — and the system disk took the name
# it vacated. A `/dev/nvme0n1p1` in this file would therefore have named the
# root disk half the time. The by-id path (`nvme-WD_PC_SN560_…_240964805912`)
# is equally stable and is the one to use when partitioning by hand.
#
# `nofail` is deliberate: this is data, not system. If the disk is missing or
# fails, the machine must still reach a login prompt rather than dropping into
# an emergency shell over a drive that holds nothing it needs to boot.
{
  fileSystems."/mnt/datos" = {
    device = "/dev/disk/by-uuid/f919b4b9-c258-407f-aa73-d5ac2e4faeda";
    fsType = "btrfs";
    options = [
      # Matches the root filesystem's setup.
      "compress=zstd"
      # No read timestamps: pointless writes on an SSD holding bulk data.
      "noatime"
      # See the header. Missing disk must not block boot.
      "nofail"
    ];
  };

  # Ownership is deliberately NOT declared here, and a tmpfiles rule would be
  # wrong: it asserts on the *mount point*, which the filesystem is then mounted
  # over. What decides who can write is the btrfs root directory, which mkfs
  # created as root:root — so the rule ran, reported success, and the disk was
  # still read-only for daf3r.
  #
  # That ownership lives inside the filesystem, so a single
  #   sudo chown daf3r:users /mnt/datos
  # after the first mount is permanent and survives every rebuild. Run once on
  # 2026-08-09; it needs redoing only if the disk is ever reformatted.
}
