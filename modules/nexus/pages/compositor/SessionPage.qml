import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var cfg: IronlandCtl.config
    readonly property bool startShell: cfg?.session.start_shell ?? false
    readonly property string shellUnit: cfg?.session.shell_unit ?? "desktop-shell.service"
    property var units: []
    property bool unitsLoaded

    title: qsTr("Session")
    isSubPage: true

    Component.onCompleted: IronlandCtl.sessionUnits(list => {
        root.units = list ?? [];
        root.unitsLoaded = list !== null;
    })

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        CompositorError {}

        ToggleRow {
            first: true
            text: qsTr("Start the shell from the compositor")
            subtext: qsTr("Starts the unit below once the session is ready, after XWayland and DISPLAY are set up. Takes effect on the next compositor start")
            checked: root.startShell
            onToggled: IronlandCtl.setValue("session.start_shell", checked ? "true" : "false")
        }

        SearchSelectRow {
            last: true
            label: qsTr("Shell unit")
            subtext: root.startShell && root.unitsLoaded && !root.units.includes(root.shellUnit) ? qsTr("No user service with this name was found; it will still be started by name") : qsTr("The systemd user service that is the desktop shell")
            placeholderText: qsTr("Search user services")
            value: root.shellUnit
            options: root.units
            disabled: !root.startShell
            onSelected: v => IronlandCtl.setValue("session.shell_unit", v)
        }
    }
}
