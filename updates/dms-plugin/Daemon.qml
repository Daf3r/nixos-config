// The headless half of the plugin: it asks the engine and publishes the answer.
//
// The daemon surface runs ONCE for the whole shell. The widget surface is
// instantiated once PER SCREEN, and this machine has two -- claude-usage
// learned that the expensive way, giving itself a 429 by doing I/O in the pill.
// So every process and every timer lives here, and the widget only paints what
// this publishes through the global var.
//
// It asks `upd status --json` and never reads /var/lib/nixos-upd/status.json,
// and that is not an optimisation waiting to happen. The two documents are
// byte-identical apart from one key: the file does not carry `blockers` and
// never will, because two of the six conditions -- a dirty tree, a checked-out
// branch -- are facts about the moment somebody looks, and the nightly pass
// would be writing them down hours in advance (see lib/blockers.sh). Read the
// file instead and Task 10's panel would never offer to apply anything.

import QtQuick
import Quickshell.Io
import qs.Modules.Plugins
import qs.Widgets
import "logic.js" as Logic

PluginComponent {
    id: root

    property int pollIntervalMs: 60000

    // How long a single poll gets before it is declared lost. Well under
    // pollIntervalMs on purpose: the guard has to have fired and given up
    // before the next tick arrives, or a hung `upd` would just accumulate.
    property int stallTimeoutMs: 15000

    // The channel to the widget. Same varName on both sides. It carries the
    // already-classified view rather than the raw status: classify() is the
    // decision, and running it once here beats running it per screen. `status`
    // travels alongside it because Task 10's panel needs the raw document --
    // the blockers, the changes, the closure diff -- and it must be the same
    // document the view was computed from, not a second poll of its own.
    //
    // `applying` and `lastError` are the panel's two fields and nothing in this
    // task ever writes anything but these constants into them. They are shipped
    // now anyway because the shape of this object is the contract between two
    // sessions that do not share a context: the panel is written against it
    // elsewhere, and a key that appears later is a key that reads as
    // `undefined` in the meantime.
    PluginGlobalVar {
        id: updState
        varName: "updState"
        defaultValue: ({
                view: Logic.classify(null),
                status: null,
                applying: false,
                lastError: ""
            })
    }

    function publish(status, applying, lastError) {
        stallGuard.stop();
        updState.set({
            view: Logic.classify(status),
            status: status,
            applying: applying === true,
            lastError: lastError || ""
        });
    }

    function poll() {
        // A poll still in flight owns the cycle; starting a second process on
        // top of it would leave two collectors racing to publish.
        if (statusProc.running) {
            // ...and this is what keeps that branch from being permanent.
            // Measured on Quickshell 0.3.0, because the obvious assumption is
            // wrong: `running = false` does NOT clear the flag, it asks for a
            // SIGTERM and leaves `running` true until the child actually dies.
            // A child that ignores TERM keeps it true forever -- confirmed with
            // `sh -c "trap '' TERM; sleep 300"`, still running four seconds
            // after the request, while an obedient sibling reported exit 15.
            //
            // That is reachable here rather than academic: `upd status --json`
            // is bash, and a non-interactive bash does not act on a signal until
            // the foreground child it is waiting on returns -- so a `git status`
            // stalled on a filesystem outlives the SIGTERM and holds this true
            // with it. With stallGuard already spent (repeat: false) and this
            // returning early every minute, nothing would be armed and the
            // daemon would sit on its last `null` and never try again.
            if (!stallGuard.running)
                stallGuard.restart();
            return;
        }
        statusProc.running = true;
        stallGuard.restart();
    }

    Process {
        id: statusProc
        command: ["upd", "status", "--json"]

        stdout: StdioCollector {
            onStreamFinished: {
                var parsed = null;
                try {
                    parsed = JSON.parse(text);
                } catch (e) {
                    parsed = null; // stays null: classify() renders it unknown
                }
                root.publish(parsed, false, "");
            }
        }

        onExited: (code, st) => {
            // A non-zero exit means upd refused to answer -- unreadable status,
            // unknown schema, no status file yet. Publishing null is the honest
            // outcome; the one thing forbidden is leaving the last good state
            // on screen as though it were current.
            if (code !== 0)
                root.publish(null, false, "");
        }
    }

    Timer {
        id: stallGuard
        interval: root.stallTimeoutMs
        repeat: false

        // Measured on Quickshell 0.3.0 rather than assumed, because the answer
        // is not the obvious one: when the command is not on PATH, Process
        // fires NEITHER `exited` NOR `streamFinished`. It logs "Process failed
        // to start" and that is all. Without this timer an `upd` that vanished
        // -- mid-switch, or after a rename -- would freeze the last good
        // reading in the bar forever, which is exactly the outcome the comment
        // on onExited above forbids. The same guard covers the other silent
        // shape: `upd status --json` shells out to git, and a git that hangs
        // hangs this.
        onTriggered: {
            statusProc.running = false; // terminate a hung poll so the next tick is free
            root.publish(null, false, "");
        }
    }

    Timer {
        interval: root.pollIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }
}
