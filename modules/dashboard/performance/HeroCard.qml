import QtQuick
import QtQuick.Layouts
import M3Shapes
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

StyledRect {
    id: root

    required property string icon
    required property string label
    required property string subLabel
    required property color accent
    required property real usage
    required property real temperature
    property real frequency // MHz, 0 when unavailable
    property real maxFrequency
    property bool expandable
    property bool expanded

    signal toggled

    function formatGhz(mhz: real): string {
        return (mhz / 1000).toFixed(2);
    }

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.extraLarge

    implicitWidth: Tokens.sizes.dashboard.perfHeroCardWidth
    implicitHeight: Math.max(tempProg.implicitHeight + detailsRow.implicitHeight + Tokens.spacing.large, usageShape.implicitHeight + usageLabel.implicitHeight) + Tokens.padding.large * 2

    StateLayer {
        disabled: !root.expandable
        showHoverBackground: root.expandable
        onClicked: root.toggled()
    }

    MaterialIcon {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Tokens.padding.medium

        visible: root.expandable
        text: "expand_more"
        color: Colours.palette.m3onSurfaceVariant
        rotation: root.expanded ? 180 : 0

        Behavior on rotation {
            Anim {}
        }
    }

    CircularProgress {
        id: tempProg

        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Tokens.padding.large

        fgColour: root.accent

        spacing: Tokens.spacing.extraSmall
        strokeWidth: Tokens.padding.extraSmall
        implicitSize: Math.max(icon.implicitWidth, icon.implicitHeight) + Tokens.padding.medium * 2
        value: root.usage

        Behavior on clampedVal {
            Anim {}
        }

        MaterialIcon {
            id: icon

            anchors.centerIn: parent
            text: root.icon
            color: root.accent
            fontStyle: Tokens.font.icon.medium
        }
    }

    ColumnLayout {
        anchors.left: tempProg.right
        anchors.right: usageShape.left
        anchors.verticalCenter: tempProg.verticalCenter
        anchors.margins: Tokens.spacing.large
        spacing: Tokens.spacing.extraSmall

        StyledText {
            text: root.label
            font: Tokens.font.title.medium
            color: root.accent
        }

        StyledText {
            Layout.fillWidth: true
            text: root.subLabel
            font: Tokens.font.body.small
            color: Colours.palette.m3onSurfaceVariant
            elide: Text.ElideRight
        }
    }

    ColumnLayout {
        id: detailsRow

        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.padding.largeIncreased
        spacing: Tokens.spacing.extraSmall

        RowLayout {
            Layout.leftMargin: -Tokens.padding.extraSmall
            spacing: Tokens.spacing.extraSmall
            visible: root.frequency > 0 || root.maxFrequency > 0

            MaterialIcon {
                Layout.topMargin: Math.round(fontInfo.pointSize * 0.08)
                text: "speed"
                color: root.accent
                fontStyle: Tokens.font.icon.medium
                fill: 1
            }

            StyledText {
                Layout.preferredWidth: freqMetrics.width
                text: root.maxFrequency > 0 ? qsTr("%1 / %2 GHz").arg(root.formatGhz(root.frequency)).arg(root.formatGhz(root.maxFrequency)) : qsTr("%1 GHz").arg(root.formatGhz(root.frequency))
                font: Tokens.font.body.builders.medium.build()
            }

            TextMetrics {
                id: freqMetrics

                text: qsTr("%1 / %2 GHz").arg("8.88").arg("8.88")
                font: Tokens.font.body.builders.medium.build()
            }
        }

        RowLayout {
            Layout.leftMargin: -Tokens.padding.extraSmall
            spacing: Tokens.spacing.extraSmall

            MaterialIcon {
                Layout.topMargin: Math.round(fontInfo.pointSize * 0.08)
                text: root.temperature > 90 ? "thermometer_alert" : "thermometer"
                color: root.temperature > 90 ? Colours.palette.m3error : root.accent
                fontStyle: Tokens.font.icon.medium
                fill: 1
            }

            StyledText {
                Layout.preferredWidth: tempMetrics.width
                text: `${Math.ceil(GlobalConfig.services.useFahrenheitPerformance ? root.temperature * 1.8 + 32 : root.temperature)}°${GlobalConfig.services.useFahrenheitPerformance ? "F" : "C"}`
                font: Tokens.font.body.builders.medium.build()
            }

            TextMetrics {
                id: tempMetrics

                text: `100°${GlobalConfig.services.useFahrenheitPerformance ? "F" : "C"}`
                font: Tokens.font.body.builders.medium.build()
            }
        }

        StyledProgressBar {
            value: root.temperature / 100
            implicitHeight: Tokens.padding.small
            fgColour: root.accent
            indeterminate: isNaN(root.usage) || isNaN(root.temperature)
        }
    }

    MaterialShape {
        id: usageShape

        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Tokens.padding.medium

        implicitSize: Tokens.sizes.dashboard.perfUsageShapeSize
        color: Colours.palette.m3secondaryContainer
        shape: {
            if (root.usage >= 0.8)
                return MaterialShape.SoftBurst;
            if (root.usage >= 0.4)
                return MaterialShape.Sunny;
            return MaterialShape.Cookie4Sided;
        }

        Behavior on color {
            CAnim {}
        }

        StyledText {
            id: usageLabel

            anchors.bottom: parent.top
            anchors.horizontalCenter: parent.horizontalCenter

            text: qsTr("Usage")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
        }

        StyledText {
            anchors.centerIn: parent
            width: usageMetrics.width
            horizontalAlignment: Text.AlignHCenter
            text: isNaN(root.usage) ? "...%" : Math.round(root.usage * 100) + "%"
            color: root.accent
            font: Tokens.font.headline.builders.small.width(50).build()
        }

        TextMetrics {
            id: usageMetrics

            text: "100%"
            font: Tokens.font.headline.builders.small.width(50).build()
        }
    }
}
