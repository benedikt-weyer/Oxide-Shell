pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services

// Renders one node of a plugin view tree (see plugin-sdk/proto/caelestia_plugin.proto
// for the widget vocabulary) and, recursively, its children. Unknown node
// types render nothing so a newer plugin never breaks an older shell.
Loader {
    id: root

    property var node
    property string pluginId
    property string viewId

    function toneColour(tone: string): color {
        switch (tone) {
        case "primary":
            return Colours.palette.m3primary;
        case "secondary":
            return Colours.palette.m3secondary;
        case "tertiary":
            return Colours.palette.m3tertiary;
        case "muted":
            return Colours.palette.m3outline;
        case "error":
            return Colours.palette.m3error;
        default:
            return Colours.palette.m3onSurface;
        }
    }

    sourceComponent: {
        switch (node?.type) {
        case "column":
            return columnComp;
        case "row":
            return rowComp;
        case "text":
            return textComp;
        case "icon":
            return iconComp;
        case "progress":
            return node.shape === "linear" ? linearComp : circularComp;
        case "button":
            return buttonComp;
        case "spacer":
            return spacerComp;
        case "divider":
            return dividerComp;
        default:
            return null;
        }
    }

    Component {
        id: columnComp

        ColumnLayout {
            spacing: root.node.spacing

            Repeater {
                model: root.node.children

                delegate: Child {
                    inColumn: true
                    align: root.node.align
                }
            }
        }
    }

    Component {
        id: rowComp

        RowLayout {
            spacing: root.node.spacing

            Repeater {
                model: root.node.children

                delegate: Child {
                    inColumn: false
                    align: root.node.align
                }
            }
        }
    }

    Component {
        id: textComp

        StyledText {
            text: root.node.text
            color: root.toneColour(root.node.tone)
            wrapMode: Text.WordWrap
            font: {
                switch (root.node.style) {
                case "label":
                    return Tokens.font.label.medium;
                case "title":
                    return Tokens.font.title.large;
                case "display":
                    return Tokens.font.body.builders.large.size(48).weight(Font.DemiBold).build();
                default:
                    return Tokens.font.body.medium;
                }
            }
        }
    }

    Component {
        id: iconComp

        MaterialIcon {
            text: root.node.name
            color: root.toneColour(root.node.tone)
            fill: 1
            fontStyle: root.node.size > 0 ? Tokens.font.icon.size(root.node.size).build() : Tokens.font.icon.small
        }
    }

    Component {
        id: circularComp

        CircularProgress {
            implicitSize: root.node.size > 0 ? root.node.size : 160
            strokeWidth: Math.max(4, Math.round(implicitSize / 16))
            value: root.node.fraction
            fgColour: root.toneColour(root.node.tone === "default" ? "primary" : root.node.tone)
            bgColour: Colours.palette.m3secondaryContainer

            Behavior on clampedVal {
                Anim {}
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 0

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: text.length > 0
                    text: root.node.label
                    font: Tokens.font.body.builders.large.size(Math.max(14, parent.parent.implicitSize / 5)).weight(Font.DemiBold).build()
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: text.length > 0
                    text: root.node.sublabel
                    color: Colours.palette.m3outline
                    font: Tokens.font.label.medium
                }
            }
        }
    }

    Component {
        id: linearComp

        ColumnLayout {
            implicitWidth: root.node.size > 0 ? root.node.size : 300
            spacing: Tokens.spacing.extraSmall

            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.node.label
                font: Tokens.font.body.small
            }

            StyledProgressBar {
                Layout.fillWidth: true
                value: root.node.fraction
                fgColour: root.toneColour(root.node.tone === "default" ? "primary" : root.node.tone)
            }

            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.node.sublabel
                color: Colours.palette.m3outline
                font: Tokens.font.label.small
            }
        }
    }

    Component {
        id: buttonComp

        IconTextButton {
            readonly property var types: ({
                    filled: IconTextButton.Filled,
                    tonal: IconTextButton.Tonal,
                    text: IconTextButton.Text
                })

            icon: root.node.icon
            text: root.node.label
            type: types[root.node.style] ?? IconTextButton.Filled
            disabled: root.node.disabled
            onClicked: Plugins.invokeAction(root.pluginId, root.viewId, root.node.actionId, root.node.payload)
        }
    }

    Component {
        id: spacerComp

        Item {
            implicitWidth: root.node.size
            implicitHeight: root.node.size
        }
    }

    Component {
        id: dividerComp

        StyledRect {
            implicitHeight: 1
            color: Colours.palette.m3outlineVariant
        }
    }

    // A node inside a container. QML can't instantiate a component from inside
    // itself by type name, so the recursion goes through Loader.source.
    component Child: Loader {
        id: child

        required property var modelData
        property bool inColumn: true
        property string align: "start"

        readonly property bool isSpacer: modelData?.type === "spacer"
        readonly property bool flexible: isSpacer && modelData.size === 0

        Layout.alignment: {
            if (inColumn)
                return align === "center" ? Qt.AlignHCenter : align === "end" ? Qt.AlignRight : Qt.AlignLeft;
            return align === "center" ? Qt.AlignVCenter : align === "end" ? Qt.AlignBottom : Qt.AlignTop;
        }
        Layout.fillWidth: (modelData?.fill ?? false) || modelData?.type === "divider" || (flexible && !inColumn)
        Layout.fillHeight: flexible && inColumn

        source: Qt.resolvedUrl("PluginNode.qml")
        onLoaded: {
            item.node = Qt.binding(() => child.modelData);
            item.pluginId = Qt.binding(() => root.pluginId);
            item.viewId = Qt.binding(() => root.viewId);
        }
    }
}
