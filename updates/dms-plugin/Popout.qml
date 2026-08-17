// The panel behind the click on the pill. It paints what the daemon published
// and turns two buttons into two commands -- it owns no Process and no Timer,
// for the same reason Daemon.qml's header gives about the pill: DMS instantiates
// the widget surface, and with it this popout, ONCE PER SCREEN. This machine has
// two. A Process declared here would run `nh os switch` twice.
//
// Two things about this file are measured rather than chosen, and both would be
// invisible failures if they were got wrong:
//
// 1. It is HANDED its state through `published` instead of declaring a
//    PluginGlobalVar of its own. PluginGlobalVar resolves the plugin it belongs
//    to as `parent?.pluginId ?? ""` (DMS Widgets/PluginGlobalVar.qml), and the
//    parent of a popout's content item is the Loader inside PluginPopout.qml,
//    which has no `pluginId`. A PluginGlobalVar declared here would therefore
//    read its defaultValue forever -- so the panel would announce "no se pudo
//    leer el estado" over a perfectly healthy system -- and its `set()` would
//    log "Cannot set ... no pluginId from parent" and do nothing, leaving both
//    buttons silently inert. Widget.qml is a direct child of the
//    PluginComponent and owns both vars; this file only receives and signals.
//
// 2. `toneColor` arrives from Widget.qml rather than being recomputed here. The
//    tone->colour map is a decision with a comment on it over there, and a
//    second copy would drift: change the colour of `warn` in one place and the
//    pill and the panel would start telling different stories about one state.
//
// Everything the two buttons decide comes from logic.js -- `buttonFor` and
// `checkFor` -- and nothing is re-derived here. That is not tidiness: QML in a
// popout is the one part of this plugin no test can reach, so a rule written
// here is a rule nothing checks.

import QtQuick
import qs.Common
import qs.Widgets
import "logic.js" as Logic

Item {
    id: root

    // DMS fills these two on the popout content item if it declares them (see
    // PluginPopout.qml's Loader.onLoaded). Neither is used yet -- there is no
    // close button, the popout is dismissed with Escape or a click outside --
    // but declaring them keeps `"closePopout" in item` true for a later task
    // that wants the open/close edges, and costs nothing now.
    property var closePopout: null
    property var parentPopout: null

    // The whole published object, exactly as the daemon set it: `{ view,
    // status, applying, lastError }`. Bound from Widget.qml.
    property var published: null

    // The pill's colour for the current tone. See the header.
    property color toneColor: Theme.surfaceVariantText

    // The two commands. They travel out as signals rather than as direct calls
    // because the daemon is another object entirely -- see Widget.qml's
    // `requestApply` / `requestCheck`, which put them on the plugin's global-var
    // channel.
    signal applyRequested(string mode)
    signal checkRequested

    // The Loader that owns this item is sized by the popout; taking its width is
    // what gives the wrapped paragraphs below something to wrap against. Without
    // it they measure zero and every blocker reason renders as one unbounded
    // line running off the panel.
    width: parent ? parent.width : 0

    // The popout must not grow past the screen just because a blocker detail or
    // an error became long. Keep the whole surface usable and let DankFlickable
    // handle the exceptional case instead of clipping the action row off-screen.
    readonly property real maxContentHeight: {
        const screen = root.parentPopout ? root.parentPopout.screen : null;
        const screenHeight = screen && screen.height > 0 ? screen.height : 900;
        return Math.max(300, Math.min(520, screenHeight * 0.68));
    }

    // The unknown face comes from logic.js and is not written out here, for the
    // reason Widget.qml gives about the same literal: a hand-copied
    // `{ state: 'unknown', ... }` would drift from `classify` in silence, and no
    // test can see a divergence between a QML literal and a JS module.
    readonly property var st: root.published ? root.published.status : null
    readonly property var view: (root.published && root.published.view) ? root.published.view : Logic.classify(null)
    readonly property bool applying: root.published ? root.published.applying === true : false
    readonly property string lastError: (root.published && root.published.lastError) ? root.published.lastError : ""

    // Recomputed here from the raw status rather than shipped by the daemon, and
    // deliberately so: both are pure and cheap, and reading them from the same
    // document the view was computed from is what guarantees the sentence next
    // to a button describes the state the panel is painting.
    readonly property var button: Logic.buttonFor(root.st)
    readonly property var check: Logic.checkFor(root.st)

    implicitHeight: viewport.height

    DankFlickable {
        id: viewport
        width: root.width
        height: Math.min(contentColumn.implicitHeight, root.maxContentHeight)
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true

        // When a fresh poll shortens the report, keep the scroll position inside
        // the new bounds. Without this, the panel can reopen at an empty tail.
        onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))

        Column {
            id: contentColumn
            width: viewport.width
            spacing: Theme.spacingM

            // ── The headline: the same icon and the same colour the pill is showing ──
            // Not decoration. A panel that opened with a different face from the pill
            // that opened it would leave the user deciding which of the two to believe.
            Row {
        width: parent.width
        spacing: Theme.spacingS

        DankIcon {
            id: headIcon
            name: root.view.icon
            size: Theme.iconSize
            color: root.toneColor
            anchors.verticalCenter: parent.verticalCenter
        }

        StyledText {
            width: parent.width - headIcon.width - Theme.spacingS
            text: root.view.summary
            color: Theme.surfaceText
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            wrapMode: Text.WordWrap
            elide: Text.ElideNone
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ── What actually changed ────────────────────────────────────────────────
    // Its own Column so the list stays tight while the sections around it
    // breathe: the separation here is whitespace and nothing else, no rule and
    // no card. `changeLines` has already dropped the entries whose version did
    // not move, which on this machine is one of the seven.
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: changes.count > 0

        Repeater {
            id: changes
            model: Logic.changeLines(root.st)

            delegate: Item {
                id: changeRow
                required property var modelData

                width: parent.width
                height: Math.max(changeName.implicitHeight, changeText.implicitHeight)

                StyledText {
                    id: changeName
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    // The version column owns the right-hand side; a long input
                    // name elides rather than pushing the versions off-panel.
                    width: Math.min(implicitWidth, Math.max(0, parent.width - changeText.width - Theme.spacingM))
                    text: changeRow.modelData.name
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                }

                StyledText {
                    id: changeText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: changeRow.modelData.text
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeSmall
                    // Monospaced because these are revisions read side by side:
                    // `05bbbc6 → 517c6ab` only says anything if the two halves
                    // line up character for character.
                    isMonospace: true
                }
            }
        }
    }

    // ── Warnings, verbatim ───────────────────────────────────────────────────
    // Rewording them here would mean two descriptions of the same finding
    // drifting apart, and the engine's is the one with the context. The code
    // rides along even when there is a detail: it is what a user can grep for in
    // upd.sh and quote in a report.
    Column {
        width: parent.width
        spacing: Theme.spacingXS
        visible: warnings.count > 0

        Repeater {
            id: warnings
            model: (root.st && Array.isArray(root.st.warnings)) ? root.st.warnings : []

            delegate: StyledText {
                id: warningLine
                required property var modelData

                width: parent.width
                text: "AVISO [" + (warningLine.modelData.code || "sin codigo") + "] " + (warningLine.modelData.detail || "sin explicacion; mira `upd status`")
                color: Theme.warning
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
            }
        }
    }

    // Why the button below is dead, or -- on an `apply-boot` -- why it sends the
    // user to a reboot instead of a switch. `buttonFor` fills `reason` in both
    // cases, so the colour has to tell them apart: a live button with an
    // explanation is information, a dead one is a refusal.
    //
    // Put the reason in its own surface rather than leaving a long red paragraph
    // floating between the change list and the buttons. It gives the warning a
    // readable hierarchy and, because it is part of the flickable content, it
    // can never push the action row outside the visible panel.
    Rectangle {
        id: blockerCard
        width: parent.width
        visible: root.button.reason !== "" && root.button.reason !== root.view.summary
        color: Theme.withAlpha(Theme.error, 0.10)
        border.color: Theme.withAlpha(Theme.error, 0.32)
        border.width: 1
        radius: Theme.cornerRadius
        implicitHeight: blockerContent.implicitHeight + Theme.spacingS * 2

        Column {
            id: blockerContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingS
            spacing: Theme.spacingXS

            Row {
                width: parent.width
                spacing: Theme.spacingXS

                DankIcon {
                    name: "warning"
                    size: Theme.iconSizeSmall
                    color: Theme.error
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    width: parent.width - Theme.iconSizeSmall - Theme.spacingXS
                    text: root.button.enabled ? "Requiere reinicio" : "No se puede aplicar todavía"
                    color: Theme.error
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.Medium
                    wrapMode: Text.WordWrap
                }
            }

            StyledText {
                width: parent.width
                text: root.button.reason
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                wrapMode: Text.WordWrap
                elide: Text.ElideNone
            }
        }
    }

    Row {
        id: actionRow
        width: parent.width
        spacing: Theme.spacingS

        // Disabled, never hidden. A missing button teaches nothing; a disabled
        // one with "el motor prepara desde 'main'" above it says what to do
        // about it.
        DankButton {
            width: root.button.label !== root.check.label ? (actionRow.width - actionRow.spacing) / 2 : actionRow.width
            text: root.applying ? "Aplicando..." : root.button.label
            iconName: {
                if (root.applying)
                    return "hourglass_top";
                if (root.button.action === "apply" || root.button.action === "apply-boot")
                    return "system_update_alt";
                if (root.button.label === root.check.label)
                    return "refresh";
                // An offer that is not on offer. The barred glyph says the same
                // thing the greyed-out button does, one more time, because the
                // 0.4 opacity DankButton uses for `enabled: false` is easy to
                // miss on a dark panel.
                return "block";
            }
            enabled: root.button.enabled && !root.applying
            onClicked: {
                if (root.button.action === "apply")
                    root.applyRequested("switch");
                else if (root.button.action === "apply-boot")
                    root.applyRequested("boot");
                else if (root.button.action === "check")
                    root.checkRequested();
            }
        }

        // The check, when the primary button is offering something else. Hidden
        // rather than repeated when the two are the same button: every state
        // that is not `ready` already leads with "Comprobar ahora", and drawing
        // it twice side by side would read as two different actions.
        //
        // Its own `enabled` comes from `checkFor`, NOT from `!applying` alone,
        // and that is the whole point of the decision recorded in logic.js: with
        // the engine holding its lock a live "Comprobar ahora" hands the user a
        // run that waits on a lock it cannot see. A second, unconditionally live
        // copy of the button here would have undone that fix in the one place a
        // user actually presses it.
        DankButton {
            width: (actionRow.width - actionRow.spacing) / 2
            visible: root.button.label !== root.check.label
            text: root.check.label
            iconName: "refresh"
            enabled: root.check.enabled && !root.applying
            // Quieter than the button beside it, on purpose. DankButton's
            // default is the filled primary, and two filled primaries side by
            // side say the two actions weigh the same -- when one of them
            // switches the running system and the other asks a question. The
            // hierarchy is the fill, not a border: measured in the probe, the
            // default pair came out as two identical `#c0c1ff` slabs.
            backgroundColor: Theme.surfaceContainer
            textColor: Theme.surfaceText
            onClicked: root.checkRequested()
        }
    }

    // Whatever the engine or systemd said when something failed, in its own
    // words and in a monospaced face because it is program output -- including a
    // cancelled polkit prompt, which is the one failure a user causes on purpose
    // and the one that must never be reported as a success.
    StyledText {
        width: parent.width
        visible: root.lastError !== ""
        text: root.lastError
        color: Theme.error
        font.pixelSize: Theme.fontSizeSmall
        isMonospace: true
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
        }
    }
}
}
