import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.Services
import qs.components
import qs.components.controls
import qs.services

StyledRect {
    id: root

    required property color accent

    readonly property bool fahrenheit: GlobalConfig.services.useFahrenheitPerformance
    readonly property int maxRowsPerColumn: 8

    function formatTemp(celsius: real): string {
        if (celsius < 0)
            return "--";
        return `${Math.round(fahrenheit ? celsius * 1.8 + 32 : celsius)}°`;
    }

    function formatGhz(mhz: real): string {
        return mhz > 0 ? (mhz / 1000).toFixed(2) : "--";
    }

    color: Colours.tPalette.m3surfaceContainer
    radius: Tokens.rounding.extraLarge

    implicitWidth: layout.implicitWidth + Tokens.padding.large * 2
    implicitHeight: layout.implicitHeight + Tokens.padding.large * 2

    RowLayout {
        id: layout

        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.large

        CoreGroup {
            title: Cpu.hybrid ? qsTr("Performance cores") : qsTr("Cores")
            efficiency: false
        }

        StyledRect {
            Layout.fillHeight: true
            Layout.preferredWidth: 1
            visible: Cpu.hybrid
            color: Colours.palette.m3outlineVariant
        }

        CoreGroup {
            visible: Cpu.hybrid
            title: qsTr("Efficiency cores")
            efficiency: true
        }
    }

    TextMetrics {
        id: labelMetrics

        text: qsTr("Core 99")
        font: Tokens.font.body.builders.small.build()
    }

    TextMetrics {
        id: tempMetrics

        text: "100°"
        font: Tokens.font.body.builders.small.build()
    }

    TextMetrics {
        id: freqMetrics

        text: "8.88 GHz"
        font: Tokens.font.body.builders.small.build()
    }

    component CoreGroup: ColumnLayout {
        id: group

        required property string title
        required property bool efficiency

        Layout.fillWidth: true
        Layout.alignment: Qt.AlignTop
        spacing: Tokens.spacing.small

        StyledText {
            text: group.title
            font: Tokens.font.body.builders.small.weight(Font.Medium).build()
            color: root.accent
        }

        GridLayout {
            flow: GridLayout.TopToBottom
            rows: root.maxRowsPerColumn
            rowSpacing: Tokens.spacing.extraSmall
            columnSpacing: Tokens.spacing.large

            Repeater {
                model: Cpu.cores

                RowLayout {
                    id: core

                    required property string label
                    required property int type
                    required property real temperature
                    required property real frequency
                    required property real maxFrequency

                    // Type 2 is CpuCoreModel.Efficiency
                    visible: (type === 2) === group.efficiency
                    spacing: Tokens.spacing.small

                    StyledText {
                        Layout.preferredWidth: labelMetrics.width
                        text: core.label
                        font: Tokens.font.body.small
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    StyledText {
                        Layout.preferredWidth: tempMetrics.width
                        horizontalAlignment: Text.AlignRight
                        text: root.formatTemp(core.temperature)
                        font: Tokens.font.body.small
                        color: core.temperature >= 90 ? Colours.palette.m3error : Colours.palette.m3onSurface
                    }

                    StyledProgressBar {
                        Layout.fillWidth: true
                        Layout.minimumWidth: Tokens.sizes.dashboard.perfHeroCardWidth / 6
                        implicitHeight: Tokens.padding.small
                        value: core.maxFrequency > 0 ? core.frequency / core.maxFrequency : 0
                        fgColour: root.accent
                    }

                    StyledText {
                        Layout.preferredWidth: freqMetrics.width
                        horizontalAlignment: Text.AlignRight
                        text: qsTr("%1 GHz").arg(root.formatGhz(core.frequency))
                        font: Tokens.font.body.small
                    }
                }
            }
        }
    }
}
