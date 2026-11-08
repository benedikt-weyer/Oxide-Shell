import QtQuick
import Caelestia.Config
import qs.components
import qs.services

// The bar button of a plugin panel (a `panels` contribution of a plugin),
// next to the notifications button. Toggles the panel on this screen.
Item {
    id: root

    required property ScreenState screenState
    // { pluginId, pluginName, viewId, title, icon }
    required property var panel

    readonly property string panelKey: `${panel.pluginId}/${panel.viewId}`
    readonly property bool open: screenState.pluginPanel === panelKey

    implicitWidth: icon.implicitHeight + Tokens.padding.small
    implicitHeight: icon.implicitHeight

    StateLayer {
        // Cursed workaround to make the height larger than the parent
        anchors.fill: undefined
        anchors.centerIn: parent
        implicitWidth: implicitHeight
        implicitHeight: icon.implicitHeight + Tokens.padding.small
        radius: Tokens.rounding.full
        onClicked: {
            if (root.open) {
                root.screenState.pluginPanel = "";
                return;
            }
            // These share the top of the screen with the panel
            root.screenState.clipboardHistory = false;
            root.screenState.dashboard = false;
            root.screenState.pluginPanel = root.panelKey;
        }
    }

    MaterialIcon {
        id: icon

        anchors.centerIn: parent

        text: root.panel.icon || "extension"
        color: root.open ? Colours.palette.m3primary : Colours.palette.m3onSurface
        fontStyle: Tokens.font.icon.builders.small.weight(Font.Bold).build()
    }
}
