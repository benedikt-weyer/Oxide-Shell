import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components.controls
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config
    readonly property list<MenuItem> modeItems: [
        MenuItem {
            text: qsTr("Split per monitor")
        },
        MenuItem {
            text: qsTr("Combined across monitors")
        }
    ]

    title: qsTr("Workspaces")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        SelectRow {
            first: true
            label: qsTr("Layout")
            subtext: qsTr("Split: each screen has its own workspaces. Combined: every screen shows the same workspace")
            menuItems: root.modeItems
            active: root.modeItems[root.cfg?.workspaces.mode === "combined" ? 1 : 0]
            onSelected: item => IronlandCtl.setValue("workspaces.mode", root.modeItems.indexOf(item) === 1 ? "combined" : "per_monitor")
        }

        StepperRow {
            label: qsTr("Starting workspace count")
            value: root.cfg?.workspaces.count ?? 4
            from: 1
            to: 20
            stepSize: 1
            onMoved: v => IronlandCtl.setValue("workspaces.count", String(v))
        }

        ToggleRow {
            text: qsTr("Dynamic count")
            subtext: qsTr("Navigating or moving a window past the last workspace creates a new one; empty trailing workspaces are dropped automatically")
            checked: root.cfg?.workspaces.dynamic ?? false
            onToggled: IronlandCtl.setValue("workspaces.dynamic", checked ? "true" : "false")
        }

        ToggleRow {
            text: qsTr("On-screen overlay")
            subtext: qsTr("Flash workspace indicator dots on switch")
            checked: root.cfg?.workspaces.overlay ?? true
            onToggled: IronlandCtl.setValue("workspaces.overlay", checked ? "true" : "false")
        }

        ToggleRow {
            last: true
            text: qsTr("Keep disconnected monitors' windows")
            subtext: qsTr("Unplugging a monitor, even the last one, hides its workspaces and windows instead of moving them; plugging it back in restores them")
            checked: root.cfg?.workspaces.keep_disconnected ?? true
            onToggled: IronlandCtl.setValue("workspaces.keep_disconnected", checked ? "true" : "false")
        }
    }
}
