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

    title: qsTr("Plugins")

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        SectionHeader {
            first: true
            text: qsTr("Installed")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            Layout.bottomMargin: Tokens.padding.medium
            visible: Plugins.installed.length === 0
            wrapMode: Text.WordWrap
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            text: qsTr("No plugins installed yet. Browse the available plugins to add dashboard tabs and more.")
        }

        Repeater {
            model: ScriptModel {
                values: Plugins.installed
            }

            delegate: NavRow {
                id: row

                required property var modelData
                required property int index

                first: index === 0
                last: index === Plugins.installed.length - 1
                icon: modelData.icon || "extension"
                text: modelData.name
                subtext: modelData.version ? `v${modelData.version} · ${Plugins.stateText(modelData)}` : Plugins.stateText(modelData)
                onClicked: {
                    root.nState.selectedPluginId = modelData.id;
                    root.nState.openSubPage(1);
                }
            }
        }

        SectionHeader {
            text: qsTr("Get plugins")
        }

        NavRow {
            first: true
            icon: "storefront"
            text: qsTr("Browse plugins")
            subtext: qsTr("%n plugin(s) available", "", Plugins.available.length)
            onClicked: root.nState.openSubPage(3)
        }

        NavRow {
            last: true
            icon: "dns"
            text: qsTr("Plugin sources")
            subtext: qsTr("%n source(s)", "", Plugins.sources.length)
            onClicked: root.nState.openSubPage(4)
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.largeIncreased
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            wrapMode: Text.WordWrap
            color: Colours.palette.m3outline
            font: Tokens.font.label.small
            text: qsTr("Plugins are programs that run with your user's permissions. Only install plugins from sources you trust. Plugin API version %1.").arg(Plugins.apiVersion)
        }
    }
}
