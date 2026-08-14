# Jump to an app's window if it is already open, launch it if it is not.
#
# niri has no native action for this: `focus-window` takes a numeric window id
# that only exists at runtime, and there is nothing that matches on app-id. So
# a bare `spawn "discord"` on a keybind does nothing visible once the app is
# running — the second instance talks to the first over its singleton lock and
# exits without asking for focus. Verified on 2026-08-14 that this is true of
# `spawn` and `spawn-sh` alike, so it is the app's behaviour and not the bind's.
#
# Usage:  focus-or-spawn <app-id> <command> [args...]
#
# The app-id is what `niri msg windows` reports, which is not always the binary
# name — check there before adding a binding rather than guessing.
{ writeShellApplication, niri, jq }:

writeShellApplication {
  name = "focus-or-spawn";
  runtimeInputs = [ niri jq ];
  text = ''
    app_id=$1
    shift

    # Most recently focused wins when several windows share an app-id, which is
    # the one you meant if you have two of them open.
    id=$(niri msg --json windows |
      jq -r --arg a "$app_id" '
        map(select(.app_id == $a))
        | sort_by(.focus_timestamp.secs, .focus_timestamp.nanos)
        | last
        | .id // empty
      ')

    if [ -n "$id" ]; then
      # Follows the window across workspaces and monitors, not just the current one.
      niri msg action focus-window --id "$id"
    else
      # Deliberately NOT exec. An FHS-packaged app (discord) execs
      # `bwrap --die-with-parent`, which arms PR_SET_PDEATHSIG: replace this
      # shell and the sandbox has no live parent, the signal fires, and the app
      # kills itself before it ever maps a window — silently, with nothing in
      # the journal. Keeping the shell alive as the parent is what prevents it.
      # See the Mod+D comment in config/niri/config.kdl for the full story.
      "$@"
    fi
  '';
}
