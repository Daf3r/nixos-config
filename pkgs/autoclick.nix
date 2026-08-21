# Toggle an autoclicker that only fires while Sober (Roblox) has focus.
#
# Bound to Mod+X in config/niri/config.kdl. The first press starts it, the
# second stops it: the running instance leaves its pid in a file under
# XDG_RUNTIME_DIR, so a later invocation finds it and kills it instead of
# stacking a second clicker on top of the first. Two clickers on the same
# key would be invisible — the clicks just come twice as fast — which is
# why the toggle is a pid file and not a "start" and a "stop" command.
#
# The focus guard is the point of the whole script. ydotool writes to
# /dev/uinput, which is below the compositor: every click lands wherever
# the pointer is, in whatever window happens to be focused. Without the
# guard, alt-tabbing to a browser turns a Roblox autoclicker into
# something that clicks links. Checking `niri msg focused-window` before
# each click makes leaving the game pause it rather than stop it, so
# coming back resumes without touching the keybind.
#
# Note the interval is checked every cycle, not just at start: the sleep
# runs whether or not the click did, so an unfocused clicker costs one
# niri IPC call every two seconds and nothing else.
{ writeShellApplication, niri, jq, ydotool, libnotify }:

writeShellApplication {
  name = "autoclick";
  runtimeInputs = [ niri jq ydotool libnotify ];
  text = ''
    # The app-id niri reports for the flatpak Sober, not Sober2 — verified
    # against `niri msg windows` on 2026-08-21. Sober2 is a separate local
    # install with its own id and is deliberately not matched here.
    app_id="org.vinegarhq.Sober"

    # One click every two seconds.
    interval=2

    pidfile="''${XDG_RUNTIME_DIR:-/tmp}/autoclick.pid"

    # Second press: stop the clicker that is already running. A stale pid
    # file (killed by a crash, or left by a previous login) is cleaned up
    # and falls through to starting a new one rather than refusing to run.
    if [ -f "$pidfile" ]; then
      old=$(cat "$pidfile")
      if kill -0 "$old" 2>/dev/null; then
        kill "$old"
        rm -f "$pidfile"
        notify-send -u low -a autoclick "Autoclick apagado"
        exit 0
      fi
      rm -f "$pidfile"
    fi

    echo $$ > "$pidfile"
    trap 'rm -f "$pidfile"' EXIT

    notify-send -u low -a autoclick "Autoclick encendido" \
      "1 click cada ''${interval}s, solo con Sober en foco"

    while true; do
      # `focused-window` prints null when nothing is focused, so .app_id?
      # keeps that from being an error rather than an empty string. The
      # `|| true` covers niri itself going away, which would otherwise take
      # the loop down through set -e without saying why.
      focused=$(niri msg --json focused-window 2>/dev/null |
        jq -r '.app_id? // empty' 2>/dev/null) || focused=""

      if [ "$focused" = "$app_id" ]; then
        # 0xC0 is press+release of the left button. A failure here means
        # ydotoold is not reachable, which would otherwise spin silently
        # forever clicking nothing — so it is loud and fatal instead.
        if ! ydotool click 0xC0 2>/dev/null; then
          notify-send -u critical -a autoclick "Autoclick detenido" \
            "ydotoold no responde"
          exit 1
        fi
      fi

      sleep "$interval"
    done
  '';
}
