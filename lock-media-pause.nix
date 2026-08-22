{ pkgs, ... }:

# Session-lock media pause.
#
# Noctalia had a `hooks.session_locked = [ "playerctl pause" ]` line: without
# it, music kept playing to an empty room whenever the idle timer locked the
# session. DMS has no equivalent hook — its lock path (Modules/Lock/Lock.qml)
# pauses nothing and offers no user templates for it (checked in 1.5.3) — so
# the behaviour is rebuilt here.
#
# --- How the lock is detected, and why not by asking DMS ---
#
# The obvious route is polling `dms ipc call lock isLocked` once a second. It
# works, it is also 86 400 IPC round-trips a day to learn something the system
# already broadcasts.
#
# DMS's Lock.qml calls notifyLockedHint() on every lock and unlock, which goes
# through DMSService -> `loginctl set-locked-hint`. So systemd-logind holds the
# state, and logind emits PropertiesChanged on the session object whenever it
# flips. This service sleeps on that signal: zero polling, and it reacts the
# instant the screen locks instead of up to a second later.
#
# Two conditions this depends on, both verified against DMS 1.5.3:
#
#   * SettingsSpec.js has `loginctlLockIntegration: { def: true }` and the key
#     is absent from ~/.config/DankMaterialShell/settings.json, so the default
#     applies. Turning that switch off in Settings > Lock Screen also turns
#     this service into a no-op — that is the one setting that breaks it.
#   * The hint fires on `sessionLock.secure`, i.e. on a real lock, not on
#     `dms ipc call lock demo`.
#
# Verify the signal path by hand without locking anything:
#
#   gdbus monitor --system --dest org.freedesktop.login1 &
#   busctl --system call org.freedesktop.login1 \
#     "$(busctl --system get-property org.freedesktop.login1 \
#          /org/freedesktop/login1/user/self \
#          org.freedesktop.login1.User Display | cut -d'"' -f4)" \
#     org.freedesktop.login1.Session SetLockedHint b true
#
# SetLockedHint only sets the hint; it does not lock the screen, so this is
# safe to run on a live desktop. Set it back to false afterwards.
let
  # Pause whoever is playing right now. No resume on unlock: the old Noctalia
  # hook did not resume either, and music restarting by itself when you sit
  # back down is the kind of surprise nobody asked for.
  pause-players = pkgs.writeShellApplication {
    name = "lock-media-pause";
    runtimeInputs = [
      pkgs.playerctl
      pkgs.gawk
    ];
    text = ''
      # `playerctl -a pause` would be shorter, but it also errors on players
      # that expose no Pause method, and errexit would take the whole script
      # down with it. Only players reporting Playing are touched.
      playerctl -a status --format '{{playerInstance}} {{status}}' 2>/dev/null \
        | awk '$2 == "Playing" { print $1 }' \
        | while read -r player; do
            playerctl --player "$player" pause || true
          done
    '';
  };

  # gdbus rather than dbus-monitor: dbus-monitor is denied the new-style
  # monitoring interface as a normal user and falls back to eavesdropping,
  # which is both deprecated and one policy change away from breaking. gdbus
  # subscribes with an ordinary AddMatch and prints one line per signal.
  lock-watcher = pkgs.writeShellApplication {
    name = "lock-media-watch";
    runtimeInputs = [
      pkgs.glib # gdbus
      pkgs.systemd # busctl
      pkgs.gnugrep
      pkgs.coreutils
      pause-players
    ];
    text = ''
      # The graphical session's own object path. Resolving it rather than
      # watching every login1 object keeps another user's lock — or the user
      # manager's own session — from pausing this desktop's music.
      #
      # Deliberately not guarded with `|| true`: if logind cannot name a
      # Display session there is nothing sane to watch, and failing loudly
      # gets a restart plus a journal line instead of a service that sits
      # there looking healthy and doing nothing.
      # busctl prints `(so) "2" "/org/freedesktop/login1/session/_32"`, so the
      # path is the FOURTH quote-delimited field — the second is the numeric
      # session id, which looks plausible and is not a D-Bus path.
      session="$(busctl --system get-property org.freedesktop.login1 \
        /org/freedesktop/login1/user/self \
        org.freedesktop.login1.User Display \
        | cut -d'"' -f4)"

      case "$session" in
        /org/freedesktop/login1/session/*) ;;
        *)
          echo "logind named no Display session (got: '$session')" >&2
          exit 1
          ;;
      esac

      echo "watching $session for LockedHint"

      # PropertiesChanged only fires on a change, so no edge tracking is
      # needed here: every <true> line IS a fresh lock.
      gdbus monitor --system \
            --dest org.freedesktop.login1 \
            --object-path "$session" \
        | while read -r line; do
            case "$line" in
              *"'LockedHint': <true>"*)
                echo "session locked, pausing players"
                lock-media-pause
                ;;
            esac
          done
    '';
  };
in
{
  # playerctl is back as a package for exactly this. The media KEYS go through
  # DMS's own mpris IPC now (see config/niri/config.kdl); this watcher runs
  # from outside the shell, where playerctl is what reaches MPRIS.
  home.packages = [
    pkgs.playerctl
    pause-players
  ];

  systemd.user.services.lock-media-pause = {
    Unit = {
      Description = "Pause MPRIS playback when the session locks";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${lock-watcher}/bin/lock-media-watch";

      # `always`, not `on-failure`. gdbus exiting cleanly ends the pipeline and
      # the script returns 0 — with on-failure that reads as "job done" and the
      # watcher would stay dead for the rest of the session.
      Restart = "always";
      RestartSec = 5;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
