# Toggle a presentation mode that mirrors the laptop panel onto whatever screen
# is attached — a projector in a lecture room, a TV, the desk monitor.
#
# niri has no mirroring of its own. Verified on 2026-08-22 against niri 26.04:
# `niri msg output` offers off, on, mode, custom-mode, modeline, scale,
# transform, position and vrr, and nothing that clones one output onto another.
# Overlapping two outputs at the same logical position is not a substitute
# either — niri lays them out side by side and moves them apart. Mirroring has
# to come from a client that captures one output and paints it on the other,
# which is what wl-mirror does, and it works here because niri exposes
# zwlr_screencopy_manager_v1 (version 3, confirmed with wayland-info).
#
# The panel also drops to its preferred mode for as long as the mirror is up.
# The panel's other mode is 240Hz, and wl-mirror captures the source output at
# whatever rate that output runs: at 240Hz it would capture and repaint four
# frames for every one a 60Hz projector can show, and it would do it while
# VMware is running the lab guests on the same GPU. Nothing on a projector
# benefits from those frames. The mode is read back from the state file on the
# way out rather than written down here, so this keeps working if the panel's
# modes ever change.
#
# Scaling is left at wl-mirror's default of "fit", which letterboxes rather than
# crops. On a 4:3 projector that means black bars above and below a 16:9 panel;
# the alternative, "cover", would fill the screen by cutting off the sides of
# the slide, which is worse in a room where people are reading it.
{ writeShellApplication, niri, wl-mirror, jq, libnotify, util-linux }:

writeShellApplication {
  name = "present-mode";
  runtimeInputs = [ niri wl-mirror jq libnotify util-linux ];
  text = ''
    statefile="''${XDG_RUNTIME_DIR:-/tmp}/present-mode.state"

    # Same lookup as ./vm-mode.nix: the panel by model, because this laptop has
    # renamed its internal connector between boots, and the external output as
    # "whatever is not the panel", because the whole point is a projector this
    # machine has never seen before.
    outputs=$(niri msg --json outputs)
    panel=$(echo "$outputs" | jq -r '
      to_entries[] | select(.value.model == "MNH301CA3-1") | .key' | head -1)
    external=$(echo "$outputs" | jq -r --arg p "$panel" '
      to_entries[] | select(.key != $p) | .key' | head -1)

    if [ -z "$panel" ]; then
      notify-send -u critical -a present-mode "Modo presentación" \
        "No encuentro el panel del portátil (modelo MNH301CA3-1)"
      exit 1
    fi

    if [ -f "$statefile" ]; then
      PANEL_MODE=""
      MIRROR_PID=""
      # shellcheck disable=SC1090
      . "$statefile"

      # The mirror is killed before the mode is restored, and the failure is
      # tolerated: wl-mirror may already be gone (the projector was unplugged,
      # or it crashed), and this script's job on the way out is to leave the
      # panel correct either way. Without the `|| true` the set -e that
      # writeShellApplication injects would abort right here and leave the panel
      # stuck at 60Hz with the state file still on disk.
      if [ -n "$MIRROR_PID" ]; then
        kill "$MIRROR_PID" 2>/dev/null || true
      fi

      if [ -n "$PANEL_MODE" ]; then
        niri msg output "$panel" mode "$PANEL_MODE"
      fi

      rm -f "$statefile"
      notify-send -u low -a present-mode "Modo presentación apagado" \
        "Panel de vuelta a $PANEL_MODE"
      exit 0
    fi

    if [ -z "$external" ]; then
      notify-send -u critical -a present-mode "Modo presentación" \
        "No hay ninguna pantalla externa conectada; no hay nada que duplicar"
      exit 1
    fi

    # Refresh rates arrive from niri in millihertz and go back to it as decimal
    # hertz with three places — 240002 is the mode spelled "240.002". Rounding
    # it to 240 addresses no mode at all and niri rejects it.
    current_mode=$(echo "$outputs" | jq -r --arg p "$panel" '
      .[$p] | .modes[.current_mode] |
      "\(.width)x\(.height)@\(.refresh_rate / 1000 | tostring)"')
    preferred_mode=$(echo "$outputs" | jq -r --arg p "$panel" '
      .[$p].modes | map(select(.is_preferred)) | first |
      "\(.width)x\(.height)@\(.refresh_rate / 1000 | tostring)"')

    # The "espejo" workspace is declared in config/niri/config.kdl pinned to
    # HDMI-A-1, because that is the port a projector goes into. This laptop also
    # has two DisplayPort outputs over USB-C, and on those the pinned workspace
    # would sit on the wrong screen — the mirror would open on a display nobody
    # is watching. Moving it is a no-op in the normal HDMI case.
    espejo_output=$(niri msg --json workspaces | jq -r '
      .[] | select(.name == "espejo") | .output' | head -1)
    if [ -n "$espejo_output" ] && [ "$espejo_output" != "$external" ]; then
      niri msg action move-workspace-to-monitor --reference espejo "$external"
    fi

    # Whatever has the keyboard right now, so the focus can be handed straight
    # back after the mirror has been made its workspace's active window.
    previous_window=$(niri msg --json windows | jq -r '
      .[] | select(.is_focused) | .id' | head -1)

    # setsid, so the mirror outlives this script. Backgrounding alone would do
    # it here, but setsid also detaches it from the terminal or keybind that
    # started it, which is what keeps the mirror up when that goes away.
    #
    # The log goes to a file rather than /dev/null. wl-mirror is the part of
    # this that can fail in ways niri will not report — a capture protocol that
    # is not there, a backend that refuses the format — and with the output
    # discarded the failure looks exactly like success: the process runs, the
    # window exists, and the projector shows nothing.
    logfile="''${XDG_RUNTIME_DIR:-/tmp}/present-mode.log"
    setsid wl-mirror --fullscreen-output "$external" "$panel" \
      >"$logfile" 2>&1 &
    mirror_pid=$!

    # Written the moment the PID exists and before anything else can go wrong.
    # Everything below — waiting for the window, moving the focus, changing the
    # mode — takes time and can be interrupted, and without this file already on
    # disk an interrupted run would leave a mirror nobody can turn off and a
    # panel nobody knows the old mode of.
    {
      echo "PANEL_MODE=$current_mode"
      echo "MIRROR_PID=$mirror_pid"
    } > "$statefile"

    # niri makes a new window fullscreen through the window-rule in
    # config/niri/config.kdl, but it does not focus it, and a workspace showing
    # two fullscreen windows displays the *active* one. Measured on 2026-08-22:
    # the mirror sat fullscreen behind a fullscreen terminal and the external
    # screen kept showing the terminal. Focusing it makes it that workspace's
    # active window, and that survives handing the focus straight back — so the
    # keyboard stays on the laptop while the projector shows the mirror.
    mirror_window=""
    for _ in $(seq 30); do
      mirror_window=$(niri msg --json windows | jq -r --arg pid "$mirror_pid" '
        .[] | select(.pid == ($pid | tonumber)) | .id' | head -1)
      [ -n "$mirror_window" ] && break
      sleep 0.1
    done

    if [ -n "$mirror_window" ]; then
      niri msg action focus-window --id "$mirror_window"

      # Where the focus goes next decides what the projector shows, which is not
      # obvious and cost a round to find. Handing it back to the previous window
      # is right only when that window is on the laptop panel: if the key was
      # pressed while focus sat on the external screen, giving it back switches
      # that screen away from the "espejo" workspace and the mirror is covered
      # again. Measured on 2026-08-22 — the same script worked or failed purely
      # on which window happened to be focused at the time. Focusing the panel
      # is also what you want while presenting: the keyboard stays on the
      # laptop and the external screen does nothing but mirror.
      previous_output=""
      if [ -n "$previous_window" ]; then
        previous_ws=$(niri msg --json windows | jq -r --arg w "$previous_window" '
          .[] | select(.id == ($w | tonumber)) | .workspace_id' | head -1)
        if [ -n "$previous_ws" ]; then
          previous_output=$(niri msg --json workspaces | jq -r --arg ws "$previous_ws" '
            .[] | select(.id == ($ws | tonumber)) | .output' | head -1)
        fi
      fi

      if [ -n "$previous_window" ] && [ "$previous_output" = "$panel" ]; then
        niri msg action focus-window --id "$previous_window"
      else
        niri msg action focus-monitor "$panel"
      fi
    else
      # Not fatal on its own — the window may still turn up a moment later — but
      # it is the one case where the external screen silently shows the wrong
      # thing, so it says where to look instead of failing quietly.
      notify-send -u normal -a present-mode "Modo presentación" \
        "El espejo tardó en aparecer. Si la pantalla externa no lo muestra, mira $logfile"
    fi

    if [ -n "$preferred_mode" ] && [ "$preferred_mode" != "$current_mode" ]; then
      niri msg output "$panel" mode "$preferred_mode"
    fi

    notify-send -u low -a present-mode "Modo presentación encendido" \
      "Duplicando el panel en $external. Panel a $preferred_mode."
  '';
}
