import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common

PageBase {
    id: root

    readonly property var timeValidator: RegularExpressionValidator {
        regularExpression: /^([01]\d|2[0-3]):[0-5]\d$/
    }

    function isTime(v: string): bool {
        return NightMode.minutesOf(v) >= 0;
    }

    title: qsTr("Night mode")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        StyledText {
            Layout.fillWidth: true
            Layout.bottomMargin: Tokens.spacing.small
            visible: !NightMode.available
            text: qsTr("The compositor doesn't support display filters, so night mode has no effect.")
            color: Colours.palette.m3error
            font: Tokens.font.label.small
            wrapMode: Text.WordWrap
        }

        SectionHeader {
            first: true
            text: qsTr("Night mode")
        }

        ToggleRow {
            first: true
            last: !GlobalConfig.nightMode.scheduled
            text: qsTr("Enable night mode")
            subtext: GlobalConfig.nightMode.scheduled ? qsTr("Turned on by the schedule below instead") : qsTr("Tints the display orange, which is easier on the eyes at night")
            checked: GlobalConfig.nightMode.scheduled ? NightMode.active : GlobalConfig.nightMode.enabled
            enabled: !GlobalConfig.nightMode.scheduled
            onToggled: GlobalConfig.nightMode.enabled = checked
        }

        SectionHeader {
            text: qsTr("Schedule")
        }

        ToggleRow {
            first: true
            last: !GlobalConfig.nightMode.scheduled
            text: qsTr("Use a schedule")
            subtext: qsTr("Turn night mode on and off automatically every day")
            checked: GlobalConfig.nightMode.scheduled
            onToggled: GlobalConfig.nightMode.scheduled = checked
        }

        TextFieldRow {
            visible: GlobalConfig.nightMode.scheduled
            label: qsTr("Turn on at")
            subtext: qsTr("24-hour time, e.g. 21:00")
            value: GlobalConfig.nightMode.startTime
            validator: root.timeValidator
            onEditingFinished: v => {
                if (root.isTime(v))
                    GlobalConfig.nightMode.startTime = v;
            }
        }

        TextFieldRow {
            last: true
            visible: GlobalConfig.nightMode.scheduled
            label: qsTr("Turn off at")
            subtext: qsTr("May be after midnight, e.g. 07:00")
            value: GlobalConfig.nightMode.endTime
            validator: root.timeValidator
            onEditingFinished: v => {
                if (root.isTime(v))
                    GlobalConfig.nightMode.endTime = v;
            }
        }

        SectionHeader {
            text: qsTr("Warmth")
        }

        StepperRow {
            first: true
            last: true
            label: qsTr("Colour temperature (K)")
            subtext: qsTr("Lower is more orange; 6500 is no tint")
            value: GlobalConfig.nightMode.temperature
            from: 1000
            to: 6500
            stepSize: 100
            onMoved: v => GlobalConfig.nightMode.temperature = v
        }
    }
}
