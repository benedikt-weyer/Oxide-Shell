import QtQuick.Layouts
import Caelestia.Config
import qs.services
import qs.modules.nexus.common
import qs.modules.nexus.pages.compositor

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config

    title: qsTr("Compositor")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        NavRow {
            first: true
            icon: "keyboard"
            text: qsTr("Keyboard")
            subtext: root.cfg?.keyboard.layout ? qsTr("Layout: %1").arg(root.cfg.keyboard.layout) : qsTr("System default")
            onClicked: root.nState.openSubPage(1)
        }

        NavRow {
            icon: "keyboard_command_key"
            text: qsTr("Shortcuts")
            subtext: qsTr("Keybindings and shell events")
            onClicked: root.nState.openSubPage(2)
        }

        NavRow {
            icon: "grid_view"
            text: qsTr("Workspaces")
            subtext: root.cfg?.workspaces.mode === "combined" ? qsTr("Combined across monitors") : qsTr("Split per monitor")
            onClicked: root.nState.openSubPage(3)
        }

        NavRow {
            icon: "center_focus_strong"
            text: qsTr("Focus")
            subtext: (root.cfg?.focus.follows_mouse || root.cfg?.focus.mouse_follows_focus) ? qsTr("Customised") : qsTr("Click to focus")
            onClicked: root.nState.openSubPage(4)
        }

        NavRow {
            icon: "palette"
            text: qsTr("Appearance")
            subtext: qsTr("Dark mode, wallpaper, blur, corners, cursor")
            onClicked: root.nState.openSubPage(5)
        }

        NavRow {
            icon: "speed"
            text: qsTr("Performance")
            subtext: root.cfg?.performance.fps_overlay ? qsTr("FPS overlay on") : qsTr("FPS overlay off")
            onClicked: root.nState.openSubPage(6)
        }

        NavRow {
            icon: "power_settings_new"
            text: qsTr("Session")
            subtext: root.cfg?.session.start_shell ? qsTr("Compositor starts %1").arg(root.cfg.session.shell_unit) : qsTr("Shell started externally")
            onClicked: root.nState.openSubPage(7)
        }

        NavRow {
            last: true
            icon: "deployed_code"
            text: qsTr("Virtual machines")
            subtext: VmLauncher.usable ? qsTr("Launch apps in a VM from the launcher") : qsTr("Not set up")
            onClicked: root.nState.openSubPage(8)
        }
    }
}
