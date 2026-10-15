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

    property string newName
    property string newUrl

    title: qsTr("Plugin sources")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        SectionHeader {
            first: true
            text: qsTr("Sources")
        }

        Repeater {
            model: ScriptModel {
                values: Plugins.sources
            }

            delegate: RowButton {
                id: row

                required property var modelData
                required property int index

                first: index === 0
                last: index === Plugins.sources.length - 1
                icon: modelData.builtin ? "verified" : "dns"
                text: modelData.builtin ? qsTr("%1 (default)").arg(modelData.name) : modelData.name
                subtext: {
                    if (modelData.error)
                        return qsTr("Error: %1").arg(modelData.error);
                    const count = qsTr("%n plugin(s)", "", modelData.count);
                    return modelData.builtin ? count : `${modelData.url} · ${count} · ${qsTr("click to remove")}`;
                }
                trailingIcon: modelData.builtin ? "lock" : "delete"
                disabled: modelData.builtin
                onClicked: Plugins.removeSource(modelData.url)
            }
        }

        SectionHeader {
            text: qsTr("Add a source")
        }

        TextFieldRow {
            first: true
            label: qsTr("Name")
            placeholderText: qsTr("My plugins")
            value: root.newName
            onValueEdited: v => root.newName = v
        }

        TextFieldRow {
            id: urlField

            label: qsTr("Location")
            subtext: qsTr("A directory or index.json, local path or https:// URL")
            placeholderText: "https://example.com/plugins/index.json"
            value: root.newUrl
            onValueEdited: v => root.newUrl = v
        }

        RowButton {
            last: true
            icon: "add"
            text: qsTr("Add source")
            disabled: !root.newName.trim() || !root.newUrl.trim()
            onClicked: {
                Plugins.addSource(root.newName, root.newUrl);
                if (!Plugins.lastError) {
                    root.newName = "";
                    root.newUrl = "";
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.large
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            visible: Plugins.lastError
            wrapMode: Text.WordWrap
            text: Plugins.lastError
            color: Colours.palette.m3error
            font: Tokens.font.label.small
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.large
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            wrapMode: Text.WordWrap
            color: Colours.palette.m3outline
            font: Tokens.font.label.small
            text: qsTr("A source is either a directory with one sub-directory per plugin, or an index.json listing plugins as directories or .tar.gz archives (with an optional sha256). Plugins run with your user's permissions: only add sources you trust.")
        }
    }
}
