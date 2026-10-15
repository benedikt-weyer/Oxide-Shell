pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var plugin: Plugins.installed.find(p => p.id === nState.selectedPluginId) ?? null
    // The catalogue entry offering a newer version, if any
    readonly property var update: plugin?.updateAvailable ? Plugins.available.find(a => a.id === plugin.id && a.updateAvailable) ?? null : null
    readonly property bool installing: Plugins.busy && Plugins.busyId === plugin?.id
    property bool confirmRemove

    onPluginChanged: {
        // Auto close when the plugin went away (removed)
        if (!plugin)
            nState.closeSubPage();
    }

    title: plugin?.name ?? qsTr("Plugin")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Timer {
            id: confirmTimer

            interval: 4000
            onTriggered: root.confirmRemove = false
        }

        // Header
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.small
            Layout.bottomMargin: Tokens.spacing.large
            spacing: Tokens.spacing.large

            MaterialIcon {
                text: root.plugin?.icon || "extension"
                color: Colours.palette.m3primary
                fill: 1
                fontStyle: Tokens.font.icon.extraLarge
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.extraSmall / 2

                StyledText {
                    Layout.fillWidth: true
                    text: root.plugin?.name ?? ""
                    font: Tokens.font.title.medium
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: text
                    text: root.plugin?.description ?? ""
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                    wrapMode: Text.WordWrap
                }
            }
        }

        ToggleRow {
            first: true
            text: qsTr("Enabled")
            subtext: qsTr("Runs the plugin and shows what it adds to the shell")
            checked: root.plugin?.enabled ?? false
            disabled: root.plugin?.state === "incompatible" || root.plugin?.state === "broken"
            onToggled: Plugins.setEnabled(root.plugin.id, checked)
        }

        InfoRow {
            label: qsTr("Status")
            value: Plugins.stateText(root.plugin)
            icon: root.plugin?.state === "failed" || root.plugin?.state === "incompatible" || root.plugin?.state === "broken" ? "error" : root.plugin?.state === "running" ? "check_circle" : "pause_circle"
            iconColour: root.plugin?.state === "running" ? Colours.palette.m3primary : root.plugin?.error ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
        }

        InfoRow {
            visible: root.plugin?.error ?? false
            label: qsTr("Problem")
            subtext: root.plugin?.error ?? ""
            icon: "warning"
            iconColour: Colours.palette.m3error
        }

        InfoRow {
            label: qsTr("Version")
            value: root.plugin?.version ?? ""
        }

        InfoRow {
            visible: root.plugin?.author ?? false
            label: qsTr("Author")
            value: root.plugin?.author ?? ""
        }

        InfoRow {
            last: true
            visible: root.plugin?.hasDashboard ?? false
            label: qsTr("Adds")
            value: qsTr("Dashboard tab")
        }

        SectionHeader {
            text: qsTr("Manage")
        }

        NavRow {
            first: true
            visible: root.plugin?.hasSettings ?? false
            icon: "tune"
            text: qsTr("Settings")
            subtext: qsTr("Configure this plugin")
            onClicked: root.nState.openSubPage(2)
        }

        RowButton {
            visible: root.update !== null
            icon: "system_update_alt"
            text: root.installing ? qsTr("Updating…") : qsTr("Update to v%1").arg(root.update?.version ?? "")
            subtext: root.update?.source ?? ""
            disabled: Plugins.busy
            onClicked: Plugins.install(root.plugin.id, root.update.source)
        }

        RowButton {
            visible: root.plugin?.enabled && root.plugin?.state !== "incompatible"
            icon: "restart_alt"
            text: qsTr("Restart")
            disabled: Plugins.busy
            onClicked: Plugins.restart(root.plugin.id)
        }

        RowButton {
            id: removeButton

            last: true
            icon: "delete"
            text: root.confirmRemove ? qsTr("Press again to remove") : qsTr("Remove")
            subtext: root.confirmRemove ? qsTr("Deletes the plugin together with its settings and data") : ""
            disabled: Plugins.busy
            onClicked: {
                if (!root.confirmRemove) {
                    root.confirmRemove = true;
                    confirmTimer.restart();
                } else {
                    Plugins.remove(root.plugin.id);
                }
            }

            Binding {
                target: removeButton.iconLabel
                property: "color"
                value: Colours.palette.m3error
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.large
            Layout.leftMargin: Tokens.padding.largeIncreased
            visible: Plugins.lastError
            wrapMode: Text.WordWrap
            text: Plugins.lastError
            color: Colours.palette.m3error
            font: Tokens.font.label.small
        }
    }
}
