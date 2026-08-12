// The bar item. It paints and nothing else -- no Process, no Timer, no file
// access -- for the per-screen reason in Daemon.qml's header comment. The one
// thing it does import is logic.js, and only to ask it what an unknown state
// looks like; the classification of a real status still happens once, in the
// daemon, and arrives here already decided.
//
// `popoutContent` at the bottom is what turns a click on the pill into the
// panel: PluginComponent only builds a PluginPopout when that property is set.
// The panel itself is Popout.qml, and this file is the only place that can wire
// it to the daemon -- both plugin global vars are declared here because
// PluginGlobalVar reads the plugin id off its own `parent`, and only a direct
// child of the PluginComponent has one. Popout.qml's header has the measurement.

import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets
import "logic.js" as Logic

PluginComponent {
    id: root

    // What this paints before anyone has published, and if what arrives is not
    // the shape agreed with the daemon. The gap before the first publish is
    // emphatically NOT "everything is fine": it is "nobody has answered yet",
    // which is the same thing an unreadable status means and gets the same face.
    //
    // Asked of logic.js rather than written out here, and the earlier version of
    // this file did write it out. The argument for the copy was that importing
    // logic.js costs a parse per screen -- true, and not worth what it buys: two
    // evaluations of a 150-line pure module at shell start against a literal
    // that nothing ties to `classify`. Change the unknown icon or tone over
    // there and the face this paints before the first poll would have drifted in
    // silence, with no test able to see it. Deriving it makes the divergence
    // impossible instead of merely tested for.
    readonly property var unknownView: Logic.classify(null)

    // Same varName the daemon publishes under: this is the channel. It has to
    // be a direct child of the PluginComponent, because `value` reads the
    // pluginId off its own parent.
    PluginGlobalVar {
        id: updState
        varName: "updState"
        defaultValue: ({
                view: root.unknownView,
                status: null,
                applying: false,
                lastError: ""
            })
    }

    // The other half of the channel: what the panel asks the daemon to DO. Same
    // rule about the parent as updState above -- a direct child of the
    // PluginComponent, never inside the popout, where `parent` is a Loader with
    // no pluginId and `set()` would log a warning and silently do nothing.
    //
    // A timestamp rides along so the value genuinely changes on every press.
    // PluginService fires globalVarChanged unconditionally today, so nothing
    // depends on it -- but two identical presses producing an identical object
    // is the kind of thing a future dedupe would swallow without a sound.
    PluginGlobalVar {
        id: updCommand
        varName: "updCommand"
        defaultValue: null
    }

    function requestApply(mode) {
        updCommand.set({
            action: "apply",
            mode: mode,
            at: Date.now()
        });
    }

    function requestCheck() {
        updCommand.set({
            action: "check",
            at: Date.now()
        });
    }

    readonly property var view: (updState.value && updState.value.view) ? updState.value.view : root.unknownView

    // The tone->colour map is the whole point of the bar item. `ready` and
    // `warn` MUST be different here and not only inside the panel: upd.sh makes
    // the same distinction in its own heading, because a ready carrying
    // warnings that looks identical to a clean one leaves reading them to
    // chance. `unknown` deliberately shares the muted colour of `ok` and is
    // told apart by its icon instead -- a grey question mark is not a claim
    // that anything is fine, and painting it red would cry failure over a
    // shell that has merely not finished its first poll.
    readonly property color toneColor: {
        switch (root.view.tone) {
        case "ok":
            return Theme.surfaceVariantText;
        case "ready":
            return Theme.primary;
        case "warn":
            return Theme.warning;
        case "error":
            return Theme.error;
        default:
            return Theme.surfaceVariantText;
        }
    }

    // The bar decides these, not the plugin: both scale with the configured bar
    // thickness and with the user's icon and font scaling. PluginComponent
    // already exposes iconSizeLarge under exactly the expression claude-usage
    // spells out by hand for its own pill; the text size has no such shortcut.
    readonly property int pillTextSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale, root.barConfig?.maximizeWidgetText)

    // Only a `ready` says anything in words. The other four states are an icon
    // and a colour: `current` is the state this bar spends its whole day in and
    // a permanent "todo al dia" would be a sentence nobody reads after the
    // first week, while the two failures have a message that belongs in the
    // panel, where there is room for it and something to do about it.
    readonly property string pillText: root.view.state === "ready" ? root.view.summary : ""

    horizontalBarPill: Component {
        Item {
            // BasePill measures the implicit size of whatever it loads and adds
            // its own padding around it, so these two are the whole contract.
            implicitWidth: hRow.implicitWidth
            implicitHeight: hRow.implicitHeight

            Row {
                id: hRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    name: root.view.icon
                    size: root.iconSizeLarge
                    color: root.toneColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    visible: root.pillText !== ""
                    text: root.pillText
                    color: root.toneColor
                    font.pixelSize: root.pillTextSize
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    // The vertical bar gets the icon and nothing else, and that is a limit of
    // the space rather than a decision: in vertical orientation BasePill pins
    // the pill's width to widgetThickness, so "6 cambios preparados" would be
    // cut off mid-word rather than shortened. What survives the trim is what
    // the horizontal pill leads with anyway -- the icon says which of the five
    // states this is, and the colour still separates a clean ready from one
    // carrying warnings. The count itself is nowhere on a vertical bar until
    // Task 10 puts the panel behind the click.
    //
    // Declaring this at all is the point: leaving verticalBarPill null makes
    // PluginComponent measure the widget at zero and the item simply is not
    // there, which on a side bar reads as a plugin that failed to load.
    verticalBarPill: Component {
        Item {
            implicitWidth: vIcon.implicitWidth
            implicitHeight: vIcon.implicitHeight

            DankIcon {
                id: vIcon
                anchors.centerIn: parent
                name: root.view.icon
                size: root.iconSizeLarge
                color: root.toneColor
            }
        }
    }

    // 460 rather than the 400 default because the widest thing the panel draws
    // is a blocker detail -- "`/home/daf3r/nixos-config` esta en la rama
    // 'upd-barra' y el motor prepara desde 'main'; haz `git -C ... switch main`"
    // -- and those wrap rather than elide, so a narrow panel buys nothing and
    // costs lines.
    //
    // `popoutHeight` is only the first frame. PluginPopout replaces it with a
    // binding on the loaded item's implicitHeight the moment the Loader
    // finishes (PluginPopout.qml, Loader.onLoaded), so it is a starting
    // estimate, not a ceiling: 260 is roughly the headline, six change rows and
    // the button row, which is what this machine shows today.
    popoutWidth: 460
    popoutHeight: 260

    popoutContent: Component {
        Popout {
            // Handed the whole published object rather than reading the global
            // var itself. See Popout.qml's header for why it cannot read it.
            published: updState.value

            // One tone->colour map for both surfaces. A second copy inside the
            // panel would let the pill and the panel disagree about the same
            // state after one edit.
            toneColor: root.toneColor

            onApplyRequested: mode => root.requestApply(mode)
            onCheckRequested: root.requestCheck()
        }
    }
}
