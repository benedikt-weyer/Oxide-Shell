pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    title: qsTr("Browse plugins")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            Layout.bottomMargin: Tokens.padding.medium
            visible: Plugins.available.length === 0
            wrapMode: Text.WordWrap
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            text: qsTr("No plugins found in your sources.")
        }

        Repeater {
            model: ScriptModel {
                values: Plugins.available
            }

            delegate: RowButton {
                id: row

                required property var modelData
                required property int index

                readonly property bool installing: Plugins.busy && Plugins.busyId === modelData.id
                readonly property bool actionable: modelData.compatible && (!modelData.installed || modelData.updateAvailable)

                first: index === 0
                last: index === Plugins.available.length - 1
                icon: modelData.icon || "extension"
                text: modelData.name
                subtext: {
                    if (installing)
                        return qsTr("Installing…");
                    if (!modelData.compatible)
                        return qsTr("Needs a newer shell · %1").arg(modelData.source);
                    const base = `v${modelData.version} · ${modelData.source}`;
                    return modelData.description ? `${base} — ${modelData.description}` : base;
                }
                trailingIcon: {
                    if (!modelData.compatible)
                        return "block";
                    if (modelData.updateAvailable)
                        return "update";
                    return modelData.installed ? "check" : "download";
                }
                disabled: !actionable || Plugins.busy
                onClicked: Plugins.install(modelData.id, modelData.source)
            }
        }

        RowButton {
            Layout.topMargin: Tokens.spacing.largeIncreased
            first: true
            last: true
            icon: "refresh"
            text: qsTr("Refresh sources")
            disabled: Plugins.busy
            onClicked: Plugins.refreshAvailable()
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
