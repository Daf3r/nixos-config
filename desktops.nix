{ config, lib, pkgs, inputs, ... }:

let
  # embeddedTheme rewrites ConfigFile= in the theme's metadata.desktop, so the
  # chosen variant is baked into the derivation. Change the string and rebuild.
  sddmTheme = pkgs.sddm-astronaut.override {
    embeddedTheme = "hyprland_kath";
  };

  # SDDM's Wayland greeter is weston in kiosk mode, and NixOS generates its
  # weston.ini from a fixed set of options with no way to configure outputs. The
  # greeter was therefore landing on HDMI-A-1 — weston picks the first connected
  # output, and the MSI enumerates ahead of the panel.
  #
  # Overriding the config file is the whole fix: `mode=off` disables an output in
  # weston, so the greeter has only the laptop panel to draw on. This affects the
  # login screen alone; both monitors come up normally once a session starts.
  #
  # Keying on HDMI-A-1 is safe even though the *panel's* connector name drifts
  # between eDP-1 and eDP-2 across boots (see ./gpu.nix): there is only one HDMI
  # connector, so that name does not move. Disabling the monitor we can name
  # reliably is what makes this robust.
  #
  # The keyboard and libinput blocks are copied from what the module generates so
  # nothing is lost by replacing the file — keep them in step with
  # services.xserver.xkb below if that ever changes.
  sddmWestonIni = pkgs.writeText "weston.ini" ''
    [keyboard]
    keymap_layout=us
    keymap_model=pc104
    keymap_options=terminate:ctrl_alt_bksp
    keymap_variant=

    [libinput]
    enable-tap=true
    left-handed=false

    [output]
    name=HDMI-A-1
    mode=off
  '';
in
{
  imports = [ ];

  # niri is the only session. Hyprland was the default until 2026-08-07 and was
  # removed once niri had been running as the daily driver long enough to trust;
  # Mango and Plasma 6 went earlier, with the nixtalia starter config.
  #
  # Its config is config/niri/config.kdl, symlinked out of the store by home.nix
  # and validated with `niri validate`. Scrollable tiling: windows sit in one
  # infinite horizontal strip instead of subdividing a fixed screen.
  programs.niri = {
    enable = true;

    # Off: this defaults to true and would pull in Nautilus purely to act as the
    # GNOME portal's file chooser. Dolphin is the file manager here, and
    # xdg-desktop-portal-gtk (configured below) already provides FileChooser.
    useNautilus = false;
  };

  # Backs DMS's bluetooth/battery/power widgets. These used to arrive
  # implicitly through Noctalia's recommendedServices; they are declared here
  # now that that module is gone. NetworkManager is NOT in this list because it
  # never came from that module — see ./configuration.nix, where it has always
  # been declared on its own.
  hardware.bluetooth.enable = true;
  services.upower.enable = true;
  services.power-profiles-daemon.enable = true;

  # geoclue2 is deliberately NOT enabled, and this comment is the whole reason
  # the line is here rather than absent.
  #
  # DMS's own NixOS module turns it on with mkDefault, and it is what would let
  # the weather widget and the night-light schedule find this machine without
  # being told a location. But it was never running under Noctalia either —
  # `nix store diff-closures` against the pre-migration system shows geoclue
  # arriving as a NEW service, not a restored one — so switching it on is a new
  # decision about sending location data, not part of removing the old shell.
  #
  # Turn it on the day the weather widget is actually wanted:
  #   services.geoclue2.enable = true;

  # `dms doctor` reports accountsservice as missing without this, and the user
  # avatar and name in the Settings panel stay blank. DMS's own NixOS module
  # would enable it, but ./dms.nix imports only the home-manager half — see the
  # note there. This is the one thing that half does not cover.
  services.accounts-daemon.enable = true;

  # The niri module registers xdg-desktop-portal-gnome, which implements
  # screencast/screenshot but is not what should answer FileChooser here — it
  # would want Nautilus (see useNautilus above). The module already sets
  # FileChooser=gtk as preferred in its own niri-portals.conf; this supplies the
  # gtk portal that setting points at. Without it, "open file" / "save as"
  # dialogs in Brave, Steam and Electron apps fall back or fail outright.
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
  };

  # Creates the i2c group, loads i2c-dev and installs the udev rules that let
  # members of that group reach /dev/i2c-*. ddcutil (already in the package list
  # below) needs all three; users.users.daf3r joins the group in
  # ./configuration.nix. Verify with `ddcutil detect`, which should name the MSI
  # MP243X on an /dev/i2c-* bus. No reboot is needed: a switch restarts
  # systemd-udevd, which is enough for the new rules to take effect.
  hardware.i2c.enable = true;

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;

    # Same command the module builds by default, with our weston.ini in place of
    # the generated one so the greeter stays on the laptop panel. See the note
    # on sddmWestonIni above.
    wayland.compositorCommand =
      "${lib.getExe pkgs.weston} --shell=kiosk -c ${sddmWestonIni}";

    # The stock SDDM greeter is the Qt default. sddm-astronaut bundles ten
    # variants and `embeddedTheme` picks which one is compiled in — swap the
    # string and rebuild to change it, no other edit needed. The full set is
    # astronaut, black_hole, cyberpunk, hyprland_kath, jake_the_dog,
    # japanese_aesthetic, pixel_sakura, pixel_sakura_static,
    # post-apocalyptic_hacker and purple_leaves; previews are in the upstream
    # README at github.com/Keyitdev/sddm-astronaut-theme.
    #
    # hyprland_kath, jake_the_dog and pixel_sakura use a video/gif background,
    # which is why the package propagates qtmultimedia.
    theme = "sddm-astronaut-theme";
    package = pkgs.kdePackages.sddm; # Qt6 build; the theme is Qt6-only

    # The theme itself goes in environment.systemPackages below, because SDDM
    # discovers themes under /run/current-system/sw/share/sddm/themes.
    # extraPackages is for Qt plugins and QML libraries only — here, the
    # qtsvg / qtmultimedia / qtvirtualkeyboard the theme's QML imports at
    # runtime, which the greeter cannot resolve on its own.
    extraPackages = sddmTheme.propagatedBuildInputs;
  };

  # Keyboard layout for the login screen; niri sets its own in config.kdl.
  services.xserver.xkb.layout = "us";

  # Synthesising input on this session. wlrctl, above, can only send a complete
  # click, and holding a button down is a different thing: a press event, an
  # arbitrary wait, and a release. ydotool writes to /dev/uinput through a
  # hardened system service, which is why it can do that at all — and also why
  # its events land wherever the focus happens to be, this session included.
  #
  # Enabling it here creates the `ydotool` group and the ydotoold unit; the user
  # joins that group in ./configuration.nix. Without either half, ydotool runs
  # and silently connects to nothing.
  programs.ydotool.enable = true;

  environment.systemPackages = with pkgs; [
    # Brightness of the external monitor over DDC/CI: DMS's brightness IPC
    # drives the laptop panel through its own backlight driver, but the MSI
    # needs ddcutil, and hardware.i2c below is what lets it work without root.
    # Verify with `ddcutil detect`, which should name the monitor on an
    # /dev/i2c-* bus.
    ddcutil

    # Reading from and writing to a *nested* niri instance — one compositor
    # running as a window inside this session, with its own Wayland socket, so a
    # program can be watched and driven without touching the real pointer and
    # keyboard.
    #
    # niri advertises zwlr_screencopy_manager_v1, zwlr_virtual_pointer_manager_v1
    # and zwp_virtual_keyboard_manager_v1 (checked with wayland-info on 26.04),
    # which is what makes this work at all: every tool below talks to whichever
    # compositor WAYLAND_DISPLAY points at, so aiming them at the nested socket
    # keeps their effects inside that window.
    #
    # Without these, the only way left to synthesise input is ydotool through
    # /dev/uinput, which injects at the kernel level: the clicks land on whatever
    # currently has focus, so the machine is unusable while it runs, and it needs
    # the user in the `uinput` group. That is precisely what this avoids.
    grim # captures a frame; unlike niri's own screenshot action it raises no notification
    slurp # picks the region to capture, once, while calibrating
    wlrctl # moves and clicks the virtual pointer
    wtype # types into the virtual keyboard
    wayland-utils # wayland-info: lists the globals a compositor advertises, for when this breaks

    sddmTheme # must be here, not in sddm.extraPackages — see the note above

    # Backs the app keybinds in config/niri/config.kdl that jump to an
    # already-open window instead of launching a second copy, which niri has no
    # native action for. See ./pkgs/focus-or-spawn.nix.
    (callPackage ./pkgs/focus-or-spawn.nix { })

    # Backs Mod+X: an autoclicker that only fires while Sober has focus. It
    # goes through ydotool, so programs.ydotool above and the `ydotool` group
    # membership in ./configuration.nix are both load-bearing — without them
    # the key looks dead. See ./pkgs/autoclick.nix.
    (callPackage ./pkgs/autoclick.nix { })

    # Backs Mod+Shift+V: drops the laptop panel to scale 1 so VMware Workstation,
    # which is X11 and therefore sees physical pixels through xwayland-satellite,
    # stops resizing itself and the guest against a 1.6x-wrong target. See
    # ./pkgs/vm-mode.nix for the measurement this is built on.
    (callPackage ./pkgs/vm-mode.nix { })

    # Backs Mod+Shift+M: mirrors the laptop panel onto a projector or TV, which
    # niri cannot do on its own — it has no clone action, so without this the
    # only option when presenting is an extended desktop and turning around to
    # read the wall. Pulls in wl-mirror, which does the actual capture. See
    # ./pkgs/present-mode.nix.
    (callPackage ./pkgs/present-mode.nix { })

    # Grows ~/Pictures/Wallpapers from wallhaven, filtered to colours that sit
    # with the Ayu palette so what bleeds through kitty's blur stays cold. Run
    # by hand; see ./pkgs/wallget.nix for why it is not on a timer.
    (callPackage ./pkgs/wallget.nix { })

    # X11 support for the niri session. niri has no built-in XWayland — there is
    # no enable switch on the module to flip — and instead integrates
    # xwayland-satellite, spawning it on demand when the first X11 client
    # connects. It only has to be on PATH — config/niri/
    # config.kdl deliberately does not spawn it, and documents the fallback if
    # the on-demand handshake ever fails.
    #
    # Not optional here: Steam and CS2 are both X11.
    xwayland-satellite
  ];
}
