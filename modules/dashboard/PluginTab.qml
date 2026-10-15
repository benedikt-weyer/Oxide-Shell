import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

// A dashboard tab whose content is a plugin's view, see PluginNode.
Item {
    id: root

    property string pluginId
    property string viewId
    property var tree: Plugins.view(pluginId, viewId)

    implicitWidth: 840
    implicitHeight: content.implicitHeight + Tokens.padding.large * 2

    Loader {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Tokens.padding.large
        anchors.rightMargin: Tokens.padding.large
        anchors.verticalCenter: parent.verticalCenter

        active: !!root.tree && !!root.tree.type
        sourceComponent: PluginNode {
            node: root.tree
            pluginId: root.pluginId
            viewId: root.viewId
        }
    }

    StyledText {
        anchors.centerIn: parent
        visible: !content.active
        text: qsTr("Loading…")
        color: Colours.palette.m3outline
        font: Tokens.font.body.medium
    }

    Connections {
        function onViewUpdated(pluginId: string, viewId: string): void {
            if (pluginId === root.pluginId && viewId === root.viewId)
                root.tree = Plugins.view(pluginId, viewId);
        }

        target: Plugins
    }
}
