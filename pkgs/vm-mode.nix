# Toggle a "VM mode" that drops the laptop panel to scale 1 for as long as a
# virtual machine has the screen.
#
# VMware Workstation is an X11 program, so it reaches the compositor through
# xwayland-satellite, which has no notion of per-output fractional scale: it
# hands X11 clients the panel's *physical* 2560x1440 while niri lays the window
# out in the 1600x900 logical space that scale 1.6 produces. Measured on
# 2026-08-22 with the AD guest open — niri reported that window as 1600x900 and
# xwininfo reported the same window as 2560x1440, a factor of exactly 1.6.
# VMware sizes its own window and drives the guest's resolution from the X11
# number, so autofit chases a target 1.6x away from the pixels actually on
# screen and the window keeps growing and shrinking while you work.
#
# Nothing fixes that with the panel at 1.6. xwayland-satellite takes no scale
# option at all — any argument other than the display number makes it panic —
# and niri exposes no XWayland scale either. Making the logical size equal the
# physical one is the only way the X11 arithmetic comes out right, and that is
# all this script does.
#
# The external monitor has to move as well. config/niri/config.kdl parks it at
# x=1600 because that is where the panel's *logical* width ends — at scale 1 the
# panel becomes 2560 wide and the two outputs would overlap by 960px. The new
# position is derived from the panel's own mode and the external output's own
# logical size, so it comes out right for a display this script has never seen:
# see the comment on the move itself for why that stopped being a detail.
#
# Restoring reads back a state file written on the way in, rather than either
# hardcoding 1.6 or asking niri to reload its config. The reload was the first
# design and it does not work: verified on 2026-08-22 that `niri msg action
# load-config-file` leaves a temporarily-set scale exactly where it was, and so
# does touching the config file to force a reload — a `niri msg output` override
# outlives both. Reading the previous values back is also what keeps this script
# correct if config.kdl ever changes its scale or positions, which a hardcoded
# 1.6 here would not.
{ writeShellApplication, niri, jq, libnotify }:

writeShellApplication {
  name = "vm-mode";
  runtimeInputs = [ niri jq libnotify ];
  text = ''
    statefile="''${XDG_RUNTIME_DIR:-/tmp}/vm-mode.state"

    # The panel is looked up by model and not by connector name: this laptop has
    # already renamed its internal panel between boots (eDP-1 became eDP-2), and
    # a script keyed on the connector would quietly do nothing after that.
    #
    # The external output, in contrast, is whatever is attached that is not the
    # panel. It used to be matched on the MSI's model string, which meant that
    # plugging anything else into the same HDMI port — a projector in a lecture
    # room, a TV — left `external` empty: the panel still went to scale 1 and
    # doubled its logical width to 2560, but the other screen was never moved
    # out of the way and the two overlapped. Matching by "not the panel" is what
    # makes this work with a display that was never seen before.
    outputs=$(niri msg --json outputs)
    panel=$(echo "$outputs" | jq -r '
      to_entries[] | select(.value.model == "MNH301CA3-1") | .key' | head -1)
    external=$(echo "$outputs" | jq -r --arg p "$panel" '
      to_entries[] | select(.key != $p) | .key' | head -1)

    if [ -z "$panel" ]; then
      notify-send -u critical -a vm-mode "vm-mode" \
        "No encuentro el panel del portátil (modelo MNH301CA3-1)"
      exit 1
    fi

    if [ -f "$statefile" ]; then
      # Every field is restored explicitly, including the ones this script did
      # not change: the state file is the only record of what the screen looked
      # like before, and a partial restore would leave the desktop in a third
      # state that is neither VM mode nor normal.
      #
      # Declared empty first because they are the state file's whole contract:
      # it makes shellcheck see them as assigned, and it means a truncated file
      # fails the guard below instead of expanding to nothing under `set -u`.
      PANEL_SCALE=""
      PANEL_X=""
      PANEL_Y=""
      EXTERNAL_X=""
      EXTERNAL_Y=""
      # shellcheck disable=SC1090
      . "$statefile"

      if [ -z "$PANEL_SCALE" ] || [ -z "$PANEL_X" ] || [ -z "$PANEL_Y" ]; then
        rm -f "$statefile"
        notify-send -u critical -a vm-mode "vm-mode" \
          "Estado guardado ilegible; restaura la escala con niri msg output"
        exit 1
      fi

      niri msg output "$panel" scale "$PANEL_SCALE"
      niri msg output "$panel" position set "$PANEL_X" "$PANEL_Y"

      if [ -n "$external" ] && [ -n "$EXTERNAL_X" ] && [ -n "$EXTERNAL_Y" ]; then
        niri msg output "$external" position set "$EXTERNAL_X" "$EXTERNAL_Y"
      fi

      rm -f "$statefile"
      notify-send -u low -a vm-mode "Modo VM apagado" \
        "Panel de vuelta a escala $PANEL_SCALE"
      exit 0
    fi

    # Written before anything is changed, so an interrupted run still leaves a
    # way back rather than a screen nobody can restore.
    {
      echo "$outputs" | jq -r --arg p "$panel" '
        .[$p].logical |
        "PANEL_SCALE=\(.scale)", "PANEL_X=\(.x)", "PANEL_Y=\(.y)"'
      if [ -n "$external" ]; then
        echo "$outputs" | jq -r --arg e "$external" '
          .[$e].logical | "EXTERNAL_X=\(.x)", "EXTERNAL_Y=\(.y)"'
      fi
    } > "$statefile"

    niri msg output "$panel" scale 1
    niri msg output "$panel" position set 0 0

    # The external monitor is optional: undocked, there is nothing to move and
    # the panel alone is already consistent.
    #
    # Both coordinates are computed rather than written down. x is the panel's
    # *physical* width, which is the logical width it takes once scale is 1, so
    # the external output starts exactly where the panel stops and the two never
    # overlap. y bottom-aligns them, the way config.kdl's y=180 does at scale
    # 1.6. The old values were the literals 2560 and 360, which are the right
    # answer only for this panel and a 1080-tall monitor — a projector running
    # 1280x800 would have been left floating 280px above the panel's bottom
    # edge, with the pointer jumping as it crossed between screens.
    if [ -n "$external" ]; then
      ext_x=$(echo "$outputs" | jq -r --arg p "$panel" '
        .[$p] | .modes[.current_mode].width')
      ext_y=$(echo "$outputs" | jq -r --arg p "$panel" --arg e "$external" '
        (.[$p] | .modes[.current_mode].height) - .[$e].logical.height')
      niri msg output "$external" position set "$ext_x" "$ext_y"
    fi

    notify-send -u low -a vm-mode "Modo VM encendido" \
      "Panel a 2560x1440 nativo. El escalado va dentro del invitado."
  '';
}
