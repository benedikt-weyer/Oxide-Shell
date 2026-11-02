import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

ColumnLayout {
    id: root

    required property PopoutState popouts

    spacing: Tokens.spacing.small

    StyledText {
        text: qsTr("Cinema mode: %1").arg(CinemaMode.enabled ? qsTr("On") : qsTr("Off"))
    }

    StyledText {
        text: CinemaMode.glow ? qsTr("Glow: %1%").arg(CinemaMode.glowStrength) : qsTr("Glow: Off")
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.label.small
    }

    IconTextButton {
        Layout.fillWidth: true
        Layout.topMargin: Tokens.spacing.medium
        enabled: CinemaMode.available || CinemaMode.enabled
        verticalPadding: Tokens.padding.extraSmall
        text: CinemaMode.enabled ? qsTr("Disable cinema mode") : qsTr("Enable cinema mode")
        icon: CinemaMode.enabled ? "videocam_off" : "movie"

        onClicked: CinemaMode.toggle()
    }

    IconTextButton {
        Layout.fillWidth: true
        inactiveColour: Colours.palette.m3primaryContainer
        inactiveOnColour: Colours.palette.m3onPrimaryContainer
        verticalPadding: Tokens.padding.extraSmall
        text: qsTr("Open settings")
        icon: "settings"

        onClicked: root.popouts.detachRequested("cinema")
    }
}
