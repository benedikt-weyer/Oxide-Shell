import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    title: qsTr("Cinema mode")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            visible: !CinemaMode.available
            text: qsTr("The compositor doesn't support cinema mode, so it has no effect.")
            color: Colours.palette.m3error
            font: Tokens.font.label.small
            wrapMode: Text.WordWrap
        }

        SectionHeader {
            first: true
            text: qsTr("Cinema mode")
        }

        ToggleRow {
            first: true
            last: true
            text: qsTr("Enable cinema mode")
            subtext: qsTr("Darkens every screen except the one you are working on. It always ends when the shell restarts")
            checked: CinemaMode.enabled
            onToggled: CinemaMode.enabled = checked
        }

        SectionHeader {
            text: qsTr("Glow")
        }

        ToggleRow {
            first: true
            last: !GlobalConfig.cinemaMode.glow
            text: qsTr("Glow on the dark screens")
            subtext: qsTr("Lets the colours along the lit screen's border spill onto them")
            checked: GlobalConfig.cinemaMode.glow
            onToggled: GlobalConfig.cinemaMode.glow = checked
        }

        SliderRow {
            last: true
            visible: GlobalConfig.cinemaMode.glow
            icon: "blur_on"
            label: qsTr("Glow strength")
            valueLabel: GlobalConfig.cinemaMode.glowStrength + "%"
            value: GlobalConfig.cinemaMode.glowStrength / 100
            onMoved: v => GlobalConfig.cinemaMode.glowStrength = Math.round(v * 100)
        }
    }
}
