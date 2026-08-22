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

  # The FunSociety lab needs the host to sit at .2 on both host-only networks,
  # not at .1. VMware always hands the first address of the subnet to its own
  # host adapter, and .1 is already taken by the FortiGate: port2 is
  # 192.168.2.1 on the LAN and port3 is 172.16.1.1 on the DMZ. That duplicate
  # address has broken this lab once before — the domain controller and the
  # Wazuh agent both lost connectivity until the host was moved off .1 — and
  # the network editor gives no way to choose the host address, so it has to be
  # reassigned after the fact. vmware-networks reapplies .1 every time it
  # starts, hence PartOf: this unit is torn down and re-run with it rather than
  # being a one-shot that silently goes stale on the next restart.
  systemd.services.vmware-funsociety-net = {
    description = "Move the VMware host adapters off the FortiGate gateway addresses";
    after = [ "vmware-networks.service" ];
    requires = [ "vmware-networks.service" ];
    partOf = [ "vmware-networks.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Written to be idempotent: the delete is allowed to fail so a re-run on an
    # already-corrected interface is a no-op rather than an error.
    script = ''
      ${pkgs.iproute2}/bin/ip addr del 192.168.2.1/24 dev vmnet1 || true
      ${pkgs.iproute2}/bin/ip addr replace 192.168.2.2/24 dev vmnet1
      ${pkgs.iproute2}/bin/ip addr del 172.16.1.1/24 dev vmnet2 || true
      ${pkgs.iproute2}/bin/ip addr replace 172.16.1.2/24 dev vmnet2
    '';
  };

  # The lab guests have no working time source of their own. The FunSociety
  # project measures MTTD as the distance between a Windows event and the Wazuh
  # alert it produced, so a skewed guest clock does not degrade the metric, it
  # inverts it: measured on 2026-08-22 the domain controller and the client were
  # both an hour ahead in UTC and every MTTD came out at roughly minus one hour.
  # They cannot reach an internet NTP server either — w32time times out with
  # 0x800705B4 because UDP 123 does not make it out through the FortiGate — so
  # the host serves the time itself, directly over the host-only networks and
  # without the firewall in the path. timesyncd cannot do this: it is a client
  # only, which is why chrony replaces it here.
  services.chrony = {
    enable = true;
    extraConfig = ''
      allow 192.168.2.0/24
      allow 172.16.1.0/24

      # Keep serving time when the laptop is offline. Without this chrony
      # declares itself unsynchronised the moment it loses its upstream peers,
      # the guests reject its answers, and the clocks drift apart again — which
      # would happen precisely in a lecture hall with no usable wifi, in the
      # middle of the demo. The high stratum keeps a real upstream winning
      # whenever one is reachable.
      local stratum 10
    '';
  };

  # chrony only listens where it is allowed to. These are the two host-only
  # networks the lab lives on: vmnet1 is the LAN with the domain controller and
  # the Windows client, vmnet2 the DMZ with the Wazuh manager. Without these the
  # daemon runs, answers nothing, and the guests fail to sync with no error on
  # the host side to explain it.
  networking.firewall.interfaces."vmnet1".allowedUDPPorts = [ 123 ];
  networking.firewall.interfaces."vmnet2".allowedUDPPorts = [ 123 ];
}
