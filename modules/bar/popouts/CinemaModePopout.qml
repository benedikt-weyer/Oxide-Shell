import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

ColumnLayout {
    spacing: Tokens.spacing.small

    StyledText {
        text: qsTr("Cinema mode: %1").arg(CinemaMode.enabled ? qsTr("On") : qsTr("Off"))
    }

    StyledText {
        text: CinemaMode.glow ? qsTr("Glow: %1%").arg(CinemaMode.glowStrength) : qsTr("Glow: Off")
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.label.small
    }
}
