{ config, lib, pkgs, inputs, ... }:

# DankMaterialShell, evaluated as a replacement for Noctalia v5.
#
# This module deliberately coexists with ./noctalia.nix rather than replacing
# it. Nothing here autostarts, so a rebuild on this branch changes what is
# installed and nothing about what runs: the session still comes up on Noctalia,
# spawned by config/niri/config.kdl exactly as before. Start DMS by hand to
# compare them:
#
#   dms run &      # start it;  `dms kill` puts Noctalia's bar back
#   dms doctor     # checks the install and its dependencies
#
# Not `systemctl --user start dms`: systemd.enable below is false, so no unit
# is generated — the binary is the only entry point on this branch.
#
# Do not run `dms update`. It self-updates the installation, which on NixOS is
# both wrong and impossible: the store is read-only. Updates come from bumping
# the flake input.
#
# Running both at once is not fatal but is not useful either — two bars, two
# lock screens, two notification daemons fighting over the same signals.
#
# Why the migration is being considered at all, so it is not re-argued: DMS
# tags real semver releases every 7-10 days while Noctalia v5 is still beta; it
# ships a test suite for its own Nix modules (distro/nix/tests/); and its
# plugins are a first-class Nix option whose `src` accepts a local path, which
# is where claude-usage would live.

{
  # Only the shell module. `inputs.dms.homeModules.niri` is deliberately NOT
  # imported: it generates niri config fragments — outputs, layout, binds,
  # colors, windowrules — and includes them into niri's config with
  # `override = true`, meaning DMS wins over what is already there.
  #
  # That is aimed at niri-flake, which generates its config. This machine does
  # not: config/niri/config.kdl is 504 hand-written lines and is the source of
  # truth, including the output blocks that took real work to get right (the
  # panel's connector name drifts between eDP-1 and eDP-2 across boots, and the
  # modes are exact to three decimals — see ./gpu.nix and ./desktops.nix).
  #
  # Leaving the module out is cleaner than importing it and disabling its
  # options one by one, because `includes.enable` defaults to true: an import
  # alone would already start writing files.
  # `inputs.dms.nixosModules.default` is also left out, and only for the trial.
  # It adds a PAM service for FIDO2 unlock and turns on power-profiles-daemon,
  # accounts-daemon and geoclue2 with mkDefault — the first of which Noctalia's
  # own NixOS module already enables in ./desktops.nix. Two shell modules both
  # asserting system services is avoidable noise while the question is still
  # "do I like this shell". Add it if DMS wins.
  imports = [ inputs.dms.homeModules.dank-material-shell ];

  programs.dank-material-shell = {
    enable = true;

    # DMS is the session shell as of this commit. The unit binds to
    # graphical-session.target and gets restarted if it dies, which a
    # spawn-at-startup line cannot do — that is why the Noctalia spawn in
    # config/niri/config.kdl was removed rather than repointed.
    systemd.enable = true;

    # Left empty ON PURPOSE, and this is the whole config story on NixOS.
    #
    # The home-manager module writes ~/.config/DankMaterialShell/settings.json
    # only when this attrset is non-empty, and it writes it as a read-only
    # symlink into the store. So it is strictly one or the other:
    #
    #   settings = { }      -> the file stays mutable, the Settings GUI owns it
    #   settings = { ... }  -> declarative and in this repo, GUI can no longer save
    #
    # Starting on the GUI side is deliberate: it is how you find out what the
    # options actually do before writing Nix against names you have not seen.
    # Once the desktop is how you want it, `cat` that JSON into this attrset and
    # it becomes declarative — the same round trip ./noctalia.nix documents for
    # its own TOML.
    #
    # Note this is still an improvement on Noctalia, where a store-owned
    # config.toml and a GUI-written settings.toml both existed and which one won
    # was a genuine question. Here there is no precedence puzzle: whoever writes
    # the file owns it.
    settings = { };

    # Optional dependency groups. Each one only adds packages to the profile —
    # the widgets are inert without them, so enabling a group is what makes the
    # corresponding part of the shell work at all.
    enableSystemMonitoring = true; # dgop, for the CPU/RAM/temp widgets
    enableDynamicTheming = true; # matugen, palette generated from the wallpaper
    enableVPN = true; # there is a WireGuard tunnel to netcup — see ./wireguard.nix
    enableAudioWavelength = true; # cava

    # Off: this pulls in khal, a CLI calendar that would need its own config and
    # a CalDAV account to show anything. Nothing on this machine feeds it.
    enableCalendarEvents = false;
  };
}
