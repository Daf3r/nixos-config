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
    // `applying` and `lastError` are the panel's two fields. Task 9 shipped them
    // as constants so the shape of this object would already be the contract
    // between two sessions that do not share a context; Task 10 filled them in,
    // and they are now written by apply(), check() and the three process
    // handlers at the bottom of this file.
    //
    // The defaultValue is what the panel paints in the gap before the first
    // publish, and `applying: false` there is not a claim that nothing is being
    // applied -- it is what a shell that has just started knows, which is
    // nothing. An apply started before a `dms restart` is invisible to this
    // plugin either way; see the note about the reattach path further down.
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

    // The channel the panel writes its two commands into: `{ action, mode }`,
    // where action is "apply" or "check". It exists because the panel lives in
    // the widget surface -- another object, and one instance per screen -- and
    // cannot call the functions below directly. Duplicating the processes into
    // the popout instead would run them once per screen, which on this two-
    // screen machine means two `nh os switch` for one click.
    //
    // Same mechanism claude-usage uses for its refresh button. The value is not
    // read for its identity: PluginService fires globalVarChanged on every
    // set(), whether or not the value differs.
    PluginGlobalVar {
        id: updCommand
        varName: "updCommand"
        defaultValue: null
    }

    Connections {
        target: root.pluginService

        function onGlobalVarChanged(pluginId, varName) {
            if (pluginId !== root.pluginId || varName !== "updCommand")
                return;
            const cmd = updCommand.value;
            if (!cmd)
                return;
            if (cmd.action === "apply")
                // The mode is narrowed to the two known words rather than
                // forwarded. It ends up as the instance name of
                // `nixos-upd-apply@%i.service`, and the polkit rule in
                // updates.nix authorises exactly `@switch` and `@boot` -- so
                // anything else would be a unit that does not exist, failing
                // late and obscurely instead of never being asked for.
                root.apply(cmd.mode === "boot" ? "boot" : "switch");
            else if (cmd.action === "check")
                root.check();
        }
    }

    // Mirrors of what republish() sends to the widget. Kept as properties so the
    // process handlers below have somewhere to write before republishing.
    //
    // Together they are the message, and that is why there is no
    // `publish(status, applying, lastError)` any more: a signature grows an
    // argument every time the daemon gains a piece of state, and every caller
    // then has to restate the parts it does not care about. That is precisely
    // how the old shape went wrong -- the poll called `publish(parsed, false,
    // "")` every minute, so a poll landing in the middle of an apply erased
    // `applying` and the panel offered to apply again over an `nh` still
    // running.
    property string lastError: ""
    property bool applying: false
    property var lastStatus: null

    function republish() {
        updState.set({
            view: Logic.classify(root.lastStatus),
            status: root.lastStatus,
            applying: root.applying,
            lastError: root.lastError
        });
    }

    function poll() {
        // A poll still in flight owns the cycle; starting a second process on
        // top of it would leave two collectors racing to publish.
        if (statusProc.running) {
            // This branch can last a while, and the reason is measured rather
            // than assumed: `running = false` does NOT clear the flag. It asks
            // for a SIGTERM and leaves `running` true until the child actually
            // dies. A child that ignores TERM keeps it true for as long as it
            // lives -- confirmed with `sh -c "trap '' TERM; sleep 300"`, still
            // true four seconds after the request, while an obedient sibling
            // reported exit 15. And it is reachable here: `upd status --json`
            // is bash, and a non-interactive bash does not act on a signal
            // until the foreground child it is waiting on returns, so a `git
            // status` stalled on a filesystem outlives the SIGTERM.
            //
            // What re-arming buys, stated no wider than the measurement: while
            // the flag is stuck, every cycle asks for the child's termination
            // again and republishes the unknown state. Without it the guard is
            // spent after its first firing and the blocked ticks do nothing at
            // all -- measured with that same stubborn child, publishes at 8s /
            // 28s / 48s with this line against a single one at 8s without it.
            //
            // What it does NOT buy, and an earlier version of this comment
            // claimed it did: recovery. The poll Timer at the bottom is
            // `repeat: true` and nothing stops it, so the moment the flag
            // clears the next tick starts a fresh process on its own, with or
            // without this line -- measured, two process starts in 60 s with
            // this line removed. Nor can any re-arming retry the process while
            // the flag is stuck, because the `return` below comes first.
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
                // Disarmed HERE, at the two points where the poll actually ends,
                // and NOT inside republish(). Both halves of that matter.
                //
                // Inside republish() it would be wrong because an apply
                // republishes too, and an apply landing mid-poll would disarm
                // the guard covering a poll still in flight.
                //
                // Leaving it out altogether is worse in the other direction, and
                // is what the task brief's snippet did: the timer is still armed
                // from poll(), so 15 s after every SUCCESSFUL read it would fire
                // and republish null -- the bar spending three quarters of every
                // minute claiming it cannot read a state it had just read.
                stallGuard.stop();
                root.lastStatus = parsed;
                root.republish();
            }
        }

        onExited: (code, st) => {
            // A non-zero exit means upd refused to answer -- unreadable status,
            // unknown schema, no status file yet. Publishing null is the honest
            // outcome; the one thing forbidden is leaving the last good state
            // on screen as though it were current.
            if (code !== 0) {
                stallGuard.stop();
                root.lastStatus = null;
                root.republish();
            }
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
            // Only the status is lost. `applying` and `lastError` survive,
            // because a poll that could not answer says nothing at all about an
            // apply that is running -- and clearing the flag here would put a
            // live Aplicar back on the panel over an `nh` still working.
            root.lastStatus = null;
            root.republish();
        }
    }

    Timer {
        interval: root.pollIntervalMs
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.poll()
    }

    // ── Applying ─────────────────────────────────────────────────────────────
    //
    // Two processes, because they are two different failure domains. The
    // fast-forward runs as daf3r and either succeeds or prints exactly why not;
    // only if it succeeded does the root half start. Chaining them into one
    // shell line would lose which of the two failed.

    function apply(mode) {   // mode: "switch" | "boot"
        // A second press while one is in flight would start a second `nh`. The
        // panel already greys the button out while `applying`, but the panel is
        // one instance per screen and the command channel is shared, so the
        // refusal belongs here too.
        if (root.applying)
            return;
        root.lastError = "";
        root.applying = true;
        root.republish();
        ffProc.pendingMode = mode;
        ffProc.running = true;
    }

    Process {
        id: ffProc
        property string pendingMode: "switch"
        command: ["upd", "apply", "--ff-only"]
        stderr: StdioCollector { id: ffErr }
        onExited: (code, st) => {
            if (code !== 0) {
                root.applying = false;
                // The engine's words, verbatim. The fallback is for the shape
                // that says nothing at all: a dead panel reporting a failure
                // with no text is one a user can neither act on nor report.
                root.lastError = ffErr.text || ("`upd apply --ff-only` fallo con codigo " + code + " y no dijo nada; mira `upd status`");
                root.republish();
                return;
            }
            // No --no-block. Amended in Task 7 against measurement, and the
            // measurement is in that task's report and in the spec: --no-block
            // returns 0 before the unit has run, and the ActiveState/Result
            // poll it forced cannot make up the difference, because a unit that
            // has *never run* and one that *finished successfully* both say
            // `inactive` / `success`. The watcher used to treat that pair as a
            // completed apply -- so the panel could announce success over an
            // `nh` that had not started. Blocking, the exit status is the
            // answer: 0 the apply finished and succeeded, non-zero it failed or
            // the polkit prompt was cancelled. A Process does not block the UI
            // thread, so this costs nothing.
            unitProc.command = ["systemctl", "start",
                                "nixos-upd-apply@" + ffProc.pendingMode + ".service"];
            unitProc.running = true;
        }
    }

    Process {
        id: unitProc
        stderr: StdioCollector { id: unitErr }
        onExited: (code, st) => {
            root.applying = false;
            if (code !== 0) {
                root.lastError = unitErr.text || ("la unidad nixos-upd-apply@" + ffProc.pendingMode + " fallo con codigo " + code + "; mira `systemctl status nixos-upd-apply@" + ffProc.pendingMode + ".service`");
                root.republish();
                return;
            }
            // Republish BEFORE polling, and not only through it. poll() returns
            // without publishing anything when a status process is already in
            // flight -- so an apply that finished in the same second as a tick
            // would leave "Aplicando..." on the panel over a system already
            // switched, until that poll happened to finish. One extra set() is
            // cheaper than reasoning about the window.
            root.republish();
            root.poll();   // and again, with the fresh status
        }
    }

    // What is deliberately NOT here: the 3-second ActiveState/Result watcher.
    // It is still the only way to recover an outcome after a `dms restart`
    // mid-apply, and if that reattach path is wanted it belongs in Task 11 with
    // `inactive`/`success` read as "not running" -- never as "succeeded", which
    // is the reading that made it wrong here.

    // The apply has no stallGuard, and it needs a different answer to the same
    // measured hazard: a Process whose command is not on PATH fires NEITHER
    // `exited` NOR `streamFinished` (measured on Quickshell 0.3.0 -- see the
    // comment on stallGuard above). For a poll that costs a stale reading. For
    // an apply it costs the whole plugin: `applying` never returns to false, so
    // the panel reads "Aplicando..." with both buttons dead until the shell is
    // restarted, and nothing on screen ever says why.
    //
    // It cannot be a timeout -- `nh os switch` legitimately runs for an hour --
    // so it does not measure duration. It checks an invariant: while `applying`
    // is true, one of the two processes must be running. The handoff between
    // them happens inside ffProc's onExited, synchronously, so there is no
    // moment when both are idle and the apply is still alive.
    Timer {
        id: applyGuard
        interval: 5000
        repeat: true
        running: root.applying
        onTriggered: {
            if (ffProc.running || unitProc.running)
                return;
            root.applying = false;
            root.lastError = "la aplicacion se perdio: ni el fast-forward ni la unidad estan corriendo, y ninguno de los dos dijo como acabo; mira `journalctl --user -u dms.service` y `systemctl status nixos-upd-apply@" + ffProc.pendingMode + ".service`";
            root.republish();
        }
    }

    // ── Checking ─────────────────────────────────────────────────────────────

    function check() {
        root.lastError = "";
        root.republish();
        checkProc.running = true;
    }

    Process {
        id: checkProc
        command: ["systemctl", "start", "--no-block", "nixos-upd.service"]
        stderr: StdioCollector { id: checkErr }
        onExited: (code, st) => {
            // --no-block here and blocking for the apply, and the difference is
            // not an inconsistency. The check builds and changes nothing, it
            // takes minutes, and its outcome arrives on its own: the status the
            // poll reads a minute later IS the answer. What --no-block still
            // cannot hide is the unit failing to *start at all* -- a renamed
            // unit, a polkit rule that authorises nothing -- and systemctl says
            // that on stderr before returning non-zero. Without these lines,
            // pressing "Comprobar ahora" over a unit that no longer exists would
            // look exactly like pressing it over one that works.
            if (code !== 0) {
                root.lastError = checkErr.text || ("no se pudo arrancar nixos-upd.service (systemctl salio con " + code + ")");
                root.republish();
                return;
            }
            // Not to see the result -- there is none yet -- but to pick up the
            // `engine_running` blocker, which is what turns the button dark and
            // says the run just asked for is under way. It may miss it by a
            // hair: --no-block returns before the unit has taken the lock. The
            // next tick catches it, and a minute of a live button is a far
            // smaller cost than a panel that shows nothing at all in answer to
            // a press.
            root.poll();
        }
    }
}
