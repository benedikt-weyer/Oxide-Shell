pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common
import qs.modules.nexus.pages.compositor

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config
    property var detected: null // name -> {make, model, width, height, ...}, or null before detection finishes
    property string detectStatus: qsTr("Detecting connected monitors…")
    readonly property var arrangementMonitors: {
        const out = [];
        for (const n in (root.detected ?? {})) {
            const d = root.detected[n];
            out.push({
                name: n,
                x: d.x,
                y: d.y,
                width: d.width,
                height: d.height
            });
        }
        return out;
    }
    readonly property string primaryOutputName: {
        const outs = root.cfg?.outputs ?? {};
        for (const n in outs)
            if (outs[n].primary)
                return n;
        return "";
    }

    function describe(name: string): string {
        const detail = root.cfg?.outputs[name];
        if (!detail)
            return qsTr("Auto-placed, extended");
        const parts = [];
        if (detail.primary)
            parts.push(qsTr("Primary"));
        parts.push(detail.refresh_rate ? qsTr("%1 Hz").arg((detail.refresh_rate / 1000).toFixed(3).replace(/\.?0+$/, "")) : qsTr("Auto refresh"));
        if (detail.mirror_of)
            parts.push(qsTr("Mirrors %1").arg(detail.mirror_of));
        else if (detail.position?.right_of)
            parts.push(qsTr("Right of %1").arg(detail.position.right_of));
        else if (detail.position?.left_of)
            parts.push(qsTr("Left of %1").arg(detail.position.left_of));
        else if (detail.position?.above)
            parts.push(qsTr("Above %1").arg(detail.position.above));
        else if (detail.position?.below)
            parts.push(qsTr("Below %1").arg(detail.position.below));
        else if (detail.position)
            parts.push(qsTr("At (%1, %2)").arg(detail.position.x).arg(detail.position.y));
        return parts.join(" · ");
    }

    function displayName(name: string): string {
        const detail = root.detected?.[name];
        if (!detail)
            return name;
        if (!detail.make && !detail.model)
            return `${name} — ${detail.width}×${detail.height}`;
        return `${name} — ${detail.make} ${detail.model} (${detail.width}×${detail.height})`;
    }

    function runDetect(): void {
        root.detectStatus = qsTr("Detecting connected monitors…");
        IronlandCtl.detectOutputs(outputs => {
            if (!outputs) {
                root.detected = {};
                root.detectStatus = qsTr("Automatic detection unavailable. You can still add a connector manually below.");
                return;
            }
            const byName = {};
            for (const o of outputs)
                byName[o.name] = o;
            root.detected = byName;
            root.detectStatus = qsTr("%1 connected monitor(s) detected.").arg(outputs.length);
        });
    }

    title: qsTr("Displays")

    Component.onCompleted: root.runDetect()

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        SectionHeader {
            first: true
            text: qsTr("Arrangement")
            visible: arrangement.visible
        }

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            visible: arrangement.visible
            text: qsTr("Drag a monitor to reposition it — edges snap to its neighbours.")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.small
            wrapMode: Text.WordWrap
        }

        MonitorArrangement {
            id: arrangement

            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.medium
            visible: root.arrangementMonitors.length > 0
            monitors: root.arrangementMonitors
            primaryName: root.primaryOutputName
            onPlaced: (name, x, y) => IronlandCtl.outputsSet(name, ["--x", String(x), "--y", String(y)], () => root.runDetect())
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            spacing: Tokens.spacing.medium

            StyledText {
                Layout.fillWidth: true
                text: root.detectStatus
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
                wrapMode: Text.WordWrap
            }

            IconButton {
                icon: "refresh"
                type: IconButton.Tonal
                onClicked: root.runDetect()
            }
        }

        Repeater {
            id: rows

            model: {
                const names = new Set(Object.keys(root.cfg?.outputs ?? {}));
                for (const n in (root.detected ?? {}))
                    names.add(n);
                return [...names].sort();
            }

            NavRow {
                required property string modelData
                required property int index

                first: index === 0
                last: index === rows.count - 1
                icon: "monitor"
                text: root.displayName(modelData)
                subtext: root.describe(modelData)
                onClicked: {
                    root.nState.selectedOutputName = modelData;
                    root.nState.openSubPage(1);
                }
            }
        }

        ConnectedRect {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.medium
            first: true
            last: true
            visible: rows.count === 0
            implicitHeight: emptyLabel.implicitHeight + Tokens.padding.large * 2

            StyledText {
                id: emptyLabel

                anchors.centerIn: parent
                text: qsTr("No monitors detected or configured yet")
                color: Colours.palette.m3outlineVariant
                font: Tokens.font.body.small
            }
        }

        SectionHeader {
            text: qsTr("Colour")
        }

        NavRow {
            first: true
            last: true
            icon: "nightlight"
            text: qsTr("Night mode")
            subtext: NightMode.active ? qsTr("On") : (GlobalConfig.nightMode.scheduled ? qsTr("Scheduled, %1 to %2").arg(GlobalConfig.nightMode.startTime).arg(GlobalConfig.nightMode.endTime) : qsTr("Off"))
            onClicked: root.nState.openSubPage(2)
        }

        SectionHeader {
            text: qsTr("Add manually")
        }

        TextFieldRow {
            id: addField

            first: true
            last: true
            label: qsTr("Connector name")
            placeholderText: qsTr("e.g. eDP-1 or HDMI-A-1")
            onEditingFinished: v => {
                if (!v)
                    return;
                IronlandCtl.outputsSet(v, [], () => addField.clear());
            }
        }
    }
}
