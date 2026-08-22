{ config, lib, pkgs, inputs, ... }:

# DankMaterialShell, the session shell since 2026-08-10 (replacing Noctalia
# v5, fully removed on 2026-08-21).
#
# Do not run `dms update`. It self-updates the installation, which on NixOS is
# both wrong and impossible: the store is read-only. Updates come from bumping
# the flake input.
#
# Why DMS won, so it is not re-argued: it tags real semver releases every 7-10
# days while Noctalia v5 stayed beta; it ships a test suite for its own Nix
# modules (distro/nix/tests/); and its plugins are a first-class Nix option
# whose `src` accepts a local path, which is where claude-usage lives.

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
  # `inputs.dms.nixosModules.default` is also left out, on purpose. It adds a
  # PAM service for FIDO2 unlock and turns on power-profiles-daemon,
  # accounts-daemon and geoclue2 with mkDefault — services this repo declares
  # explicitly in ./desktops.nix instead, where they are visible and auditable.
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
    # it becomes declarative.
    #
    # Whoever writes the file owns it — there is no precedence puzzle.
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

    # Claude subscription usage — github:Daf3r/dms-plugins. The attribute name
    # is the DIRECTORY that gets created
    # under ~/.config/DankMaterialShell/plugins/, so it is hyphenated; the
    # plugin's own `id` is `claudeUsage` in camelCase because DMS's plugin
    # schema demands it. Declaring this REPLACES the development symlink at
    # that same path with a read-only link into the store, so from here on a
    # code change needs a push, a `nix flake update dms-plugins` and a switch —
    # see the input's comment in ./flake.nix for why it is not a local path.
    #
    # `settings` is left out ON PURPOSE, and it is the same one-or-the-other as
    # the shell's own `settings = { }` above. The submodule's `settings` flips
    # `managePluginSettings`, which writes plugin_settings.json as a read-only
    # store symlink — and the plugin ships a settings panel of its own, which
    # would then have nothing it could save to.
    plugins.claude-usage = {
      enable = true;
      src = "${inputs.dms-plugins}/claude-usage";
    };

    # The bar half of the update engine in ./updates. Unlike claude-usage this
    # is NOT a flake input: a path relative to this flake's own tree is fine
    # under pure evaluation — what fails is an absolute path — so the engine and
    # its reader move in the same commit and iterating costs one switch, with no
    # push and no `nix flake update`.
    #
    # The directory is the whole plugin source, tests included. They ride along
    # into the store because `src` is copied wholesale, and they are harmless
    # there: DMS discovers plugins by looking for a plugin.json, and there is
    # only one, at the top. `node --test` over them is not part of any
    # derivation — it is the loop a human runs while editing logic.js.
    plugins.nixos-upd = {
      enable = true;
      src = ./updates/dms-plugin;
    };
  };
}
