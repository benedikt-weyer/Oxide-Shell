pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// The settings page every plugin gets for free: rendered from the schema the
// plugin declares (plugin-sdk/proto/caelestia_plugin.proto, SettingsSchema).
PageBase {
    id: root

    readonly property var plugin: Plugins.installed.find(p => p.id === nState.selectedPluginId) ?? null
    readonly property string pluginId: nState.selectedPluginId
    property var schema: Plugins.settingsSchema(pluginId)
    property var values: Plugins.settingValues(pluginId)

    function refresh(): void {
        schema = Plugins.settingsSchema(pluginId);
        values = Plugins.settingValues(pluginId);
    }

    onPluginChanged: {
        // Auto close when the plugin went away (removed)
        if (!plugin)
            nState.closeSubPage();
    }

    title: qsTr("%1 settings").arg(plugin?.name ?? qsTr("Plugin"))
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Connections {
            function onSettingsChanged(pluginId: string): void {
                if (pluginId === root.pluginId)
                    root.refresh();
            }

            target: Plugins
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.bottomMargin: Tokens.padding.medium
            visible: !root.schema || root.schema.length === 0
            wrapMode: Text.WordWrap
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            text: qsTr("This plugin has no settings.")
        }

        StyledText {
            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.largeIncreased
            Layout.rightMargin: Tokens.padding.largeIncreased
            Layout.bottomMargin: Tokens.padding.medium
            visible: root.plugin && root.plugin.state !== "running" && root.schema.length > 0
            wrapMode: Text.WordWrap
            color: Colours.palette.m3outline
            font: Tokens.font.label.small
            text: qsTr("The plugin isn't running. Your changes are saved and applied when it starts.")
        }

        Repeater {
            model: root.schema

            delegate: ColumnLayout {
                id: section

                required property var modelData
                required property int index

                Layout.fillWidth: true
                spacing: Tokens.spacing.extraSmall / 2

                SectionHeader {
                    first: section.index === 0
                    text: section.modelData.title
                    visible: text
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.leftMargin: Tokens.padding.small
                    Layout.bottomMargin: Tokens.padding.small
                    visible: text
                    text: section.modelData.description
                    wrapMode: Text.WordWrap
                    color: Colours.palette.m3outline
                    font: Tokens.font.label.small
                }

                Repeater {
                    model: section.modelData.fields

                    delegate: Loader {
                        id: fieldLoader

                        required property var modelData
                        required property int index

                        readonly property var field: modelData
                        readonly property bool isFirst: index === 0
                        readonly property bool isLast: index === section.modelData.fields.length - 1
                        readonly property var value: root.values[field.key]

                        Layout.fillWidth: true

                        sourceComponent: {
                            switch (field.type) {
                            case "toggle":
                                return toggleComp;
                            case "number":
                                return field.integer ? stepperComp : sliderComp;
                            case "text":
                                return textComp;
                            case "choice":
                                return choiceComp;
                            default:
                                return null;
                            }
                        }

                        Component {
                            id: toggleComp

                            ToggleRow {
                                first: fieldLoader.isFirst
                                last: fieldLoader.isLast
                                text: fieldLoader.field.label
                                subtext: fieldLoader.field.description
                                checked: fieldLoader.value ?? false
                                onToggled: Plugins.setSetting(root.pluginId, fieldLoader.field.key, checked)
                            }
                        }

                        Component {
                            id: stepperComp

                            StepperRow {
                                first: fieldLoader.isFirst
                                last: fieldLoader.isLast
                                label: fieldLoader.field.unit ? `${fieldLoader.field.label} (${fieldLoader.field.unit})` : fieldLoader.field.label
                                subtext: fieldLoader.field.description
                                value: fieldLoader.value ?? fieldLoader.field.default
                                from: fieldLoader.field.min
                                to: fieldLoader.field.max
                                stepSize: fieldLoader.field.step || 1
                                onMoved: v => Plugins.setSetting(root.pluginId, fieldLoader.field.key, v)
                            }
                        }

                        Component {
                            id: sliderComp

                            SliderRow {
                                readonly property real span: fieldLoader.field.max - fieldLoader.field.min
                                readonly property real current: fieldLoader.value ?? fieldLoader.field.default

                                first: fieldLoader.isFirst
                                last: fieldLoader.isLast
                                label: fieldLoader.field.label
                                valueLabel: `${(Math.round(current * 100) / 100)}${fieldLoader.field.unit ? " " + fieldLoader.field.unit : ""}`
                                value: span > 0 ? (current - fieldLoader.field.min) / span : 0
                                onMoved: v => Plugins.setSetting(root.pluginId, fieldLoader.field.key, fieldLoader.field.min + v * span)
                            }
                        }

                        Component {
                            id: textComp

                            TextFieldRow {
                                first: fieldLoader.isFirst
                                last: fieldLoader.isLast
                                label: fieldLoader.field.label
                                subtext: fieldLoader.field.description
                                placeholderText: fieldLoader.field.placeholder
                                value: fieldLoader.value ?? ""
                                showReset: value !== fieldLoader.field.default
                                onEditingFinished: v => Plugins.setSetting(root.pluginId, fieldLoader.field.key, v)
                                onResetRequested: {
                                    Plugins.setSetting(root.pluginId, fieldLoader.field.key, fieldLoader.field.default);
                                    clear();
                                }
                            }
                        }

                        Component {
                            id: choiceComp

                            SelectRow {
                                id: select

                                first: fieldLoader.isFirst
                                last: fieldLoader.isLast
                                label: fieldLoader.field.label
                                subtext: fieldLoader.field.description
                                menuItems: options.instances
                                active: menuItems.find(i => i.optionValue === fieldLoader.value) ?? null
                                fallbackText: fieldLoader.value ?? ""
                                onSelected: item => Plugins.setSetting(root.pluginId, fieldLoader.field.key, item.optionValue)

                                Variants {
                                    id: options

                                    model: fieldLoader.field.options

                                    MenuItem {
                                        required property var modelData
                                        readonly property string optionValue: modelData.value

                                        text: modelData.label
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        RowButton {
            Layout.topMargin: Tokens.spacing.largeIncreased
            visible: root.schema && root.schema.length > 0
            first: true
            last: true
            icon: "restart_alt"
            text: qsTr("Reset to defaults")
            onClicked: Plugins.resetSettings(root.pluginId)
        }
    }
}
