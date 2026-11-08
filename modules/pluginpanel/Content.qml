pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.dashboard as Dashboard
import qs.modules.nexus

// A plugin's panel: a header the shell draws (title, the plugin's settings,
// close) over the view the plugin contributed, see Dashboard.PluginNode.
StyledRect {
    id: root

    required property ScreenState screenState
    // "<plugin id>/<view id>"
    required property string panelKey

    readonly property int split: panelKey.indexOf("/")
    readonly property string pluginId: split < 0 ? panelKey : panelKey.slice(0, split)
    readonly property string viewId: split < 0 ? "" : panelKey.slice(split + 1)
    readonly property var panel: Plugins.panels.find(p => p.pluginId === pluginId && p.viewId === viewId) ?? null
    readonly property var plugin: Plugins.installed.find(p => p.id === pluginId) ?? null
    property var tree: Plugins.view(pluginId, viewId)

    function close(): void {
        screenState.pluginPanel = "";
    }

    function openSettings(): void {
        close();
        // Nexus > Plugins > this plugin > its settings
        WindowFactory.create(null, {
            initialPage: 6,
            initialStack: [1, 2],
            initialPluginId: pluginId
        });
    }

    radius: Tokens.rounding.large
    color: Colours.tPalette.m3surfaceContainer
    focus: true

    Keys.onEscapePressed: close()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Tokens.padding.largeIncreased
        spacing: Tokens.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.small

            MaterialIcon {
                text: root.panel?.icon || "extension"
                color: Colours.palette.m3primary
                font: Tokens.font.icon.medium
            }

            StyledText {
                Layout.fillWidth: true
                text: root.panel?.title ?? root.plugin?.name ?? root.pluginId
                color: Colours.palette.m3onSurface
                font: Tokens.font.title.small
                elide: Text.ElideRight
            }

            IconButton {
                visible: root.plugin?.hasSettings ?? false
                isRound: true
                type: IconButton.Text
                icon: "settings"
                onClicked: root.openSettings()
            }

            IconButton {
                isRound: true
                type: IconButton.Text
                icon: "close"
                onClicked: root.close()
            }
        }

        Loader {
            Layout.fillWidth: true
            Layout.fillHeight: true

            active: !!root.tree && !!root.tree.type
            sourceComponent: Dashboard.PluginNode {
                node: root.tree
                pluginId: root.pluginId
                viewId: root.viewId
            }
        }

        StyledText {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.tree || !root.tree.type
            text: root.panel ? qsTr("Loading…") : qsTr("This plugin isn't running.")
            color: Colours.palette.m3outline
            font: Tokens.font.body.medium
        }
    }

    Connections {
        function onViewUpdated(pluginId: string, viewId: string): void {
            if (pluginId === root.pluginId && viewId === root.viewId)
                root.tree = Plugins.view(pluginId, viewId);
        }

        target: Plugins
    }
}
