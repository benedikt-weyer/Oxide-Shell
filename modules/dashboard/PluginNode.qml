pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.containers
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

    readonly property bool hasSurface: (node?.surface ?? "none") !== "none"

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
            return hasSurface ? cardComp : columnComp;
        case "row":
            return hasSurface ? cardComp : rowComp;
        case "text":
            return textComp;
        case "icon":
            return iconComp;
        case "progress":
            return node.shape === "linear" ? linearComp : circularComp;
        case "button":
            return node.label === "" && node.icon !== "" ? iconButtonComp : buttonComp;
        case "spacer":
            return spacerComp;
        case "divider":
            return dividerComp;
        case "spinner":
            return spinnerComp;
        case "logView":
            return logComp;
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
        id: cardComp

        StyledRect {
            implicitWidth: cardContent.implicitWidth + root.node.padding * 2
            implicitHeight: cardContent.implicitHeight + root.node.padding * 2

            radius: Tokens.rounding.large
            color: root.node.surface === "cardLow" ? Colours.tPalette.m3surfaceContainerLow : Colours.tPalette.m3surfaceContainer

            Loader {
                id: cardContent

                anchors.fill: parent
                anchors.margins: root.node.padding

                sourceComponent: root.node.type === "row" ? rowComp : columnComp
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
            wrapMode: root.node.elide === "none" ? Text.WordWrap : Text.NoWrap
            elide: root.node.elide === "right" ? Text.ElideRight : root.node.elide === "middle" ? Text.ElideMiddle : Text.ElideNone
            font: {
                switch (root.node.style) {
                case "label":
                    return Tokens.font.label.medium;
                case "title":
                    return Tokens.font.title.large;
                case "headline":
                    return Tokens.font.body.builders.large.size(28).weight(Font.DemiBold).build();
                case "mono":
                    return Tokens.font.mono.small;
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
                indeterminate: root.node.indeterminate
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
        id: iconButtonComp

        IconButton {
            icon: root.node.icon
            type: root.node.style === "filled" ? IconButton.Filled : root.node.style === "tonal" ? IconButton.Tonal : IconButton.Text
            isRound: true
            font: Tokens.font.icon.medium
            disabled: root.node.disabled
            onClicked: Plugins.invokeAction(root.pluginId, root.viewId, root.node.actionId, root.node.payload)
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

    Component {
        id: spinnerComp

        LoadingIndicator {
            animated: true
            implicitWidth: root.node.size > 0 ? root.node.size : 20
            implicitHeight: implicitWidth
        }
    }

    Component {
        id: logComp

        Item {
            id: log

            readonly property string scrollKey: `${root.pluginId}/${root.viewId}`
            readonly property var lines: root.node.lines ?? []

            // Keeps the model in step with the pushed lines: a view update
            // replaces the whole tree, so appending only the new lines (rather
            // than resetting) is what preserves the user's scroll position.
            function sync(): void {
                const n = lines.length;
                let prefix = logModel.count <= n;
                if (prefix && logModel.count > 0) {
                    const last = logModel.get(logModel.count - 1);
                    prefix = last.message === lines[logModel.count - 1].text && last.isError === lines[logModel.count - 1].isError;
                }
                if (!prefix)
                    logModel.clear();
                for (let i = logModel.count; i < n; i++)
                    logModel.append({
                        message: lines[i].text,
                        isError: lines[i].isError
                    });
            }

            implicitWidth: 300
            implicitHeight: root.node.height > 0 ? root.node.height : 200

            onLinesChanged: sync()
            Component.onCompleted: sync()

            ListModel {
                id: logModel
            }

            VerticalFadeListView {
                id: logView

                property bool followBottom: Plugins.logScroll[log.scrollKey]?.follow ?? true

                function remember(): void {
                    Plugins.logScroll[log.scrollKey] = {
                        follow: followBottom,
                        y: contentY
                    };
                }

                anchors.fill: parent
                clip: true
                spacing: Tokens.spacing.extraSmall / 2
                model: logModel

                Component.onCompleted: {
                    const saved = Plugins.logScroll[log.scrollKey];
                    if (followBottom || !saved)
                        positionViewAtEnd();
                    else
                        contentY = saved.y;
                }
                onCountChanged: if (followBottom)
                    positionViewAtEnd()
                onDragStarted: followBottom = false
                onFlickStarted: followBottom = false
                onAtYEndChanged: if (atYEnd)
                    followBottom = true
                onContentYChanged: remember()
                onFollowBottomChanged: remember()

                delegate: StyledText {
                    id: line

                    required property string message
                    required property bool isError

                    width: ListView.view ? ListView.view.width : implicitWidth

                    text: line.message
                    wrapMode: Text.Wrap
                    font: Tokens.font.mono.small
                    color: line.isError ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: logView.count === 0
                    text: root.node.placeholder
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.small
                }
            }
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
