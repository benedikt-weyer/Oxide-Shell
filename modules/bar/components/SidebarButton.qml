import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property ScreenState screenState

    implicitWidth: icon.implicitHeight + Tokens.padding.small
    implicitHeight: icon.implicitHeight

    StateLayer {
        // Cursed workaround to make the height larger than the parent
        anchors.fill: undefined
        anchors.centerIn: parent
        implicitWidth: implicitHeight
        implicitHeight: icon.implicitHeight + Tokens.padding.small
        radius: Tokens.rounding.full
        onClicked: root.screenState.sidebar = !root.screenState.sidebar
    }

    MaterialIcon {
        id: icon

        anchors.centerIn: parent

        text: "notifications"
        color: root.screenState.sidebar ? Colours.palette.m3primary : Colours.palette.m3onSurface
        fontStyle: Tokens.font.icon.builders.small.weight(Font.Bold).build()
    }
}
