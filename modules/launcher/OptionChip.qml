import QtQuick
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// A rounded label with an icon, highlighted while `active`: the launcher's
// tab and network-mode choices.
StyledRect {
    id: root

    required property string icon
    required property string label
    required property bool active

    implicitWidth: row.implicitWidth + Tokens.padding.large * 2
    implicitHeight: row.implicitHeight + Tokens.padding.small * 2
    radius: Tokens.rounding.full
    color: active ? Colours.palette.m3secondaryContainer : "transparent"

    Row {
        id: row

        anchors.centerIn: parent
        spacing: Tokens.spacing.small

        MaterialIcon {
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.active ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3outline
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label
            font: Tokens.font.body.small
            color: root.active ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3outline
        }
    }
}
