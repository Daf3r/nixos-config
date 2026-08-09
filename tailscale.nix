{ config, lib, pkgs, ... }:

# Tailscale, for the machines that are not reachable through the netcup tunnel.
#
# The two are not alternatives and do not overlap. WireGuard (./wireguard.nix)
# carries 10.8.0.0/24 and is what `ssh netcup` needs; Tailscale carries
# 100.64.0.0/10 on its own `tailscale0` interface, and is what the `pbs` host in
# ~/.ssh/config needs — the Proxmox Backup Server that holds the Vaultwarden
# backups. Neither touches the default route.
#
# This machine was reinstalled without Tailscale, so `ssh pbs` had been silently
# dead: the address resolves to nothing and the connection just hangs until it
# times out, with no hint that a VPN is missing.
#
# **One manual step after the first switch:** `sudo tailscale up`, then approve
# the machine in the browser. Enrolment mints a node key that has to be stored,
# so it cannot be declared here — a `authKeyFile` would work for unattended
# enrolment, but that means putting a secret on disk for something done once.
{
  services.tailscale = {
    enable = true;

    # `client` opens the UDP port for direct peer-to-peer connections. Without
    # it traffic still works, but falls back to relaying through Tailscale's
    # DERP servers — slower, and pointlessly so for a laptop that can usually
    # reach its peers directly.
    openFirewall = true;
    useRoutingFeatures = "client";
  };

  # `tailscale` itself comes with the service; this is `tailscale status` and
  # friends being on the interactive PATH, which is where they get used from.
  environment.systemPackages = [ pkgs.tailscale ];
}
