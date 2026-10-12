import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.Wayland
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config
    readonly property list<MenuItem> positionItems: [
        MenuItem {
            text: qsTr("Top left")
        },
        MenuItem {
            text: qsTr("Top right")
        },
        MenuItem {
            text: qsTr("Bottom left")
        },
        MenuItem {
            text: qsTr("Bottom right")
        }
    ]
    readonly property var positionValues: ["top_left", "top_right", "bottom_left", "bottom_right"]
    // Cycled through by a stable hash of each stage name, so the same stage
    // (e.g. "submit") always gets the same colour across repaints without
    // hardcoding a name-to-colour table that would silently go stale the
    // moment the compositor reports a stage name this page doesn't know
    // about (see `ironland-frame-capture-v1.xml`'s own doc on that).
    readonly property list<color> stageColors: [Colours.palette.m3primary, Colours.palette.m3secondary, Colours.palette.m3tertiary, Colours.palette.m3error, Colours.palette.m3outline]

    function stageColor(name: string): color {
        let hash = 0;
        for (let i = 0; i < name.length; i++) {
            hash = (hash * 31 + name.charCodeAt(i)) >>> 0;
        }
        return root.stageColors[hash % root.stageColors.length];
    }

    title: qsTr("Performance")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        SectionHeader {
            first: true
            text: qsTr("FPS overlay")
        }

        ToggleRow {
            first: true
            text: qsTr("Show FPS overlay")
            subtext: qsTr("Frame rate, last frame time, and a stutter counter drawn on every output")
            checked: root.cfg?.performance.fps_overlay ?? false
            onToggled: IronlandCtl.setValue("performance.fps_overlay", checked ? "true" : "false")
        }

        SelectRow {
            label: qsTr("Position")
            menuItems: root.positionItems
            active: root.positionItems[Math.max(0, root.positionValues.indexOf(root.cfg?.performance.fps_overlay_position ?? "top_right"))]
            onSelected: item => IronlandCtl.setValue("performance.fps_overlay_position", root.positionValues[root.positionItems.indexOf(item)])
        }

        TextFieldRow {
            last: true
            label: qsTr("Redraw interval")
            subtext: qsTr("How often the overlay's text is redrawn (ms) - frame timing is still sampled every frame either way; 0 redraws every frame too")
            value: String(root.cfg?.performance.fps_overlay_interval_ms ?? 500)
            validator: IntValidator {
                bottom: 0
            }
            onEditingFinished: v => IronlandCtl.setValue("performance.fps_overlay_interval_ms", v || "500")
        }

        SectionHeader {
            text: qsTr("Stutter analytics")
        }

        TextFieldRow {
            first: true
            label: qsTr("Stutter threshold")
            subtext: qsTr("Frame time (ms) above which a frame counts as a stutter; empty/0 picks 1.5× the output's refresh interval automatically")
            value: (root.cfg?.performance.stutter_threshold_ms ?? 0) > 0 ? String(root.cfg.performance.stutter_threshold_ms) : ""
            validator: DoubleValidator {
                bottom: 0
            }
            onEditingFinished: v => IronlandCtl.setValue("performance.stutter_threshold_ms", v || "0")
        }

        ToggleRow {
            last: true
            text: qsTr("Log stutters")
            subtext: qsTr("Also report each detected stutter via the compositor's log (journalctl --user, or the terminal under `run`)")
            checked: root.cfg?.performance.stutter_log ?? true
            onToggled: IronlandCtl.setValue("performance.stutter_log", checked ? "true" : "false")
        }

        SectionHeader {
            text: qsTr("Key tracker")
        }

        ToggleRow {
            first: true
            text: qsTr("Show key tracker overlay")
            subtext: qsTr("Shows whether each listed key is currently pressed, as seen by the compositor - handy for finding a stuck key")
            checked: root.cfg?.key_tracker.enabled ?? false
            onToggled: IronlandCtl.setValue("key_tracker.enabled", checked ? "true" : "false")
        }

        SelectRow {
            label: qsTr("Position")
            menuItems: root.positionItems
            active: root.positionItems[Math.max(0, root.positionValues.indexOf(root.cfg?.key_tracker.position ?? "top_left"))]
            onSelected: item => IronlandCtl.setValue("key_tracker.position", root.positionValues[root.positionItems.indexOf(item)])
        }

        TextFieldRow {
            last: true
            label: qsTr("Tracked keys")
            subtext: qsTr("Comma-separated xkb key names, e.g. Control_L, Control_R, Shift_L, Super_L")
            value: (root.cfg?.key_tracker.keys ?? ["Control_L", "Control_R"]).join(", ")
            onEditingFinished: v => IronlandCtl.setValue("key_tracker.keys", v || "Control_L,Control_R")
        }

        SectionHeader {
            text: qsTr("Frame timing capture")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            text: qsTr("A debugging aid, not something you'd normally leave running: captures a detailed per-stage timing breakdown of the next few frames on every connected monitor, so a stutter or a refresh-rate shortfall can be compared against real numbers instead of guessed at.")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.small
            wrapMode: Text.WordWrap
        }

        // qmllint disable unresolved-type
        IronlandFrameCapture {
            // qmllint enable unresolved-type
            id: capture
        }

        RowButton {
            first: true
            icon: "speed"
            text: capture.capturing ? qsTr("Capturing…") : qsTr("Capture next 3 frames")
            subtext: qsTr("Every currently connected output, independently")
            disabled: capture.capturing
            onClicked: capture.capture(3)
        }

        RowButton {
            last: true
            icon: copyTimer.running ? "inventory" : "content_copy"
            text: qsTr("Copy as JSON")
            subtext: qsTr("For pasting into an issue, a chat, or another tool")
            disabled: capture.frames.length === 0
            onClicked: {
                Quickshell.clipboardText = JSON.stringify(capture.frames, null, 2);
                copyTimer.restart();
            }

            Timer {
                id: copyTimer

                interval: 1500
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.small
            visible: capture.frames.length === 0
            text: qsTr("No capture yet.")
            color: Colours.palette.m3outline
            font: Tokens.font.body.small
        }

        Canvas {
            id: flameGraph

            readonly property int laneHeight: 28
            readonly property int labelWidth: 140
            // Longest total duration across every captured frame, so every
            // lane shares one time scale - a frame that's twice as slow as
            // another should visibly look it.
            readonly property real maxTotalUs: {
                let max = 1;
                for (const frame of capture.frames) {
                    let total = 0;
                    for (const stage of frame.stages) {
                        total = Math.max(total, stage.startUs + stage.durationUs);
                    }
                    max = Math.max(max, total);
                }
                return max;
            }

            Layout.topMargin: Tokens.spacing.small
            Layout.fillWidth: true
            visible: capture.frames.length > 0
            implicitHeight: capture.frames.length * laneHeight

            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);
                ctx.font = "11px sans-serif";
                ctx.textBaseline = "middle";

                const barLeft = labelWidth;
                const barWidth = Math.max(1, width - labelWidth);
                const pxPerUs = barWidth / maxTotalUs;

                capture.frames.forEach((frame, row) => {
                    const y = row * laneHeight;
                    ctx.fillStyle = Colours.palette.m3onSurface;
                    ctx.fillText(`${frame.output} #${frame.frameIndex}${frame.stutter ? " ⚠" : ""}`, 0, y + laneHeight / 2);

                    for (const stage of frame.stages) {
                        ctx.fillStyle = root.stageColor(stage.name);
                        ctx.fillRect(barLeft + stage.startUs * pxPerUs, y + 3, Math.max(1, stage.durationUs * pxPerUs), laneHeight - 6);
                    }
                });
            }

            Connections {
                function onFramesChanged() {
                    flameGraph.requestPaint();
                }

                target: capture
            }
        }
    }
}
