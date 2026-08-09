{ config, lib, pkgs, ... }:

# Split tunnel to the netcup VPS. The `netcup` host in ~/.ssh/config resolves to
# an address that only exists inside this tunnel, so without it there is no VPS.
#
# **Every parameter lives in /etc/wireguard/netcup.conf, which is not in this
# repo and never will be.** This file names it and stops there. That is the
# whole point: the profile carries a private key *and* a preshared key, and this
# repo is public.
#
# `configFile` is typed `str`, not `path` — which is exactly why it is used here.
# A `path` would be copied into /nix/store at build time, and the store is
# world-readable, so the keys would be exposed to every user on the machine even
# though git never saw them. As a string it is copied by wg-quick at *service
# start*, straight from /etc, and nothing secret enters the store.
#
# It also overrides every other option in the module, so address, peers and mtu
# are deliberately absent below rather than duplicated here.
#
# Recreating /etc/wireguard/netcup.conf on a fresh install:
#
#   1. Download the `Daf3r-Laptop-Access-Base` profile from wg-easy — the only
#      one of the six that is a split tunnel; the rest route 0.0.0.0/0.
#   2. Delete its `DNS =` line. That resolver sits outside AllowedIPs, so it is
#      unreachable through the tunnel, and as a *system* resolver it takes every
#      lookup on the laptop down with it while the link is up.
#   3. Append the tunnel's IPv6 prefix to AllowedIPs — the /64 that the profile's
#      own interface address comes out of. The download assigns the address but
#      does not route the prefix, so v6 inside the tunnel is dead without this.
#   4. Install it as root, mode 600.
#
# Note the tunnel does not carry everything: the `pbs` host in ~/.ssh/config sits
# on a Tailscale address, and Tailscale is not installed on this machine.
{
  # wg, wg-quick and wg-show by hand. The module pulls in what the service
  # needs on its own; this is for reading the link state from a shell.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  networking.wg-quick.interfaces.netcup = {
    configFile = "/etc/wireguard/netcup.conf";
    # autostart defaults to true, which is what is wanted: the tunnel is
    # permanent and comes up on every boot. The endpoint in the profile is a
    # literal IP, so this does not race DNS at startup.
  };

  # The link does not always survive a suspend: the socket keeps its pre-sleep
  # source port, the NAT mapping on the far side has expired, and PersistentKeepalive
  # alone does not always re-punch it — leaving an interface that is up and
  # carries nothing. Bouncing it on resume fixes that.
  #
  # `try-restart`, not `restart`, on purpose: it is a no-op when the unit is
  # stopped, so a tunnel taken down deliberately stays down across a suspend
  # instead of reviving itself.
  systemd.services.wireguard-resume = {
    description = "Restart the netcup WireGuard tunnel after resume";
    after = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
      "suspend-then-hibernate.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl try-restart wg-quick-netcup.service";
    };
  };
}
