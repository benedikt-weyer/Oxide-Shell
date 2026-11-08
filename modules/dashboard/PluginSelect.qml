pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.components.effects
import qs.services
import qs.modules.drawers

// The `select` widget of plugin views: a chip that opens a list to pick from.
// The list is drawn over the whole window (like Menu, whose lists can't scroll,
// which a long list of models has to).
StyledRect {
    id: root

    // { id, label, icon?, sub? }
    property var items: []
    property string current
    property string icon
    property string text
    property string title
    property bool expanded

    signal picked(id: string)

    function open(): void {
        const layer = popupLayer.parent;
        const pos = mapToItem(layer, 0, height + Tokens.spacing.extraSmall);
        popup.x = Math.max(Tokens.padding.small, Math.min(pos.x, layer.width - popup.width - Tokens.padding.small));
        popup.y = pos.y;
        expanded = true;
    }

    implicitWidth: row.implicitWidth + Tokens.padding.medium * 2
    implicitHeight: row.implicitHeight + Tokens.padding.small * 2

    radius: Tokens.rounding.full
    color: expanded ? Colours.palette.m3secondaryContainer : Colours.tPalette.m3surfaceContainerHigh

    StateLayer {
        color: root.expanded ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
        onClicked: root.expanded ? root.expanded = false : root.open()
    }

    RowLayout {
        id: row

        anchors.centerIn: parent
        spacing: Tokens.spacing.extraSmall

        MaterialIcon {
            visible: root.icon.length > 0
            text: root.icon
            color: root.expanded ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3primary
            font: Tokens.font.icon.small
        }

        StyledText {
            Layout.maximumWidth: 180
            text: root.text
            color: root.expanded ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
            font: Tokens.font.label.medium
            elide: Text.ElideRight
        }

        MaterialIcon {
            text: "expand_more"
            rotation: root.expanded ? 180 : 0
            color: root.expanded ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurfaceVariant
            font: Tokens.font.icon.small

            Behavior on rotation {
                Anim {}
            }
        }
    }

    Item {
        id: popupLayer

        // Inside the drawers window the interaction wrapper is what gets pointer events
        parent: {
            const win = QsWindow.window;
            const contentWin = win as ContentWindow;
            return contentWin ? contentWin.interactionWrapper : (win as QsWindow).contentItem;
        }
        anchors.fill: parent
        z: 100
        visible: root.expanded

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = false
        }

        Elevation {
            anchors.fill: popup
            radius: popup.radius
            level: 2
        }

        StyledRect {
            id: popup

            implicitWidth: Math.max(220, list.maxRowWidth + Tokens.padding.small * 2)
            implicitHeight: Math.min(content.implicitHeight + Tokens.padding.small * 2, Math.max(120, popupLayer.height - y - Tokens.padding.large))

            radius: Tokens.rounding.large
            color: Colours.palette.m3surfaceContainerLow

            opacity: root.expanded ? 1 : 0
            scale: root.expanded ? 1 : 0.95
            transformOrigin: Item.TopLeft

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on scale {
                Anim {}
            }

            ColumnLayout {
                id: content

                anchors.fill: parent
                anchors.margins: Tokens.padding.small
                spacing: 0

                StyledText {
                    Layout.leftMargin: Tokens.padding.small
                    Layout.bottomMargin: Tokens.padding.extraSmall
                    visible: root.title.length > 0
                    text: root.title
                    color: Colours.palette.m3outline
                    font: Tokens.font.label.small
                }

                StyledListView {
                    id: list

                    // Rows are sized by the widest label so the popup fits the list rather than the first screenful
                    property real maxRowWidth: 0

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredHeight: contentHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 0

                    model: root.items

                    delegate: StyledRect {
                        id: entry

                        required property var modelData
                        readonly property bool active: modelData.id === root.current

                        width: ListView.view.width
                        implicitHeight: entryRow.implicitHeight + Tokens.padding.small * 2

                        radius: Tokens.rounding.medium
                        color: active ? Colours.palette.m3tertiaryContainer : "transparent"

                        Component.onCompleted: list.maxRowWidth = Math.max(list.maxRowWidth, entryRow.implicitWidth + Tokens.padding.medium * 2)

                        StateLayer {
                            color: entry.active ? Colours.palette.m3onTertiaryContainer : Colours.palette.m3onSurface
                            onClicked: {
                                root.expanded = false;
                                root.picked(entry.modelData.id);
                            }
                        }

                        RowLayout {
                            id: entryRow

                            anchors.fill: parent
                            anchors.margins: Tokens.padding.small
                            anchors.leftMargin: Tokens.padding.medium
                            anchors.rightMargin: Tokens.padding.medium
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                visible: (entry.modelData.icon ?? "").length > 0
                                text: entry.modelData.icon ?? ""
                                color: entry.active ? Colours.palette.m3onTertiaryContainer : Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.icon.small
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                StyledText {
                                    Layout.fillWidth: true
                                    text: entry.modelData.label
                                    color: entry.active ? Colours.palette.m3onTertiaryContainer : Colours.palette.m3onSurface
                                    font: Tokens.font.body.small
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    visible: (entry.modelData.sub ?? "").length > 0
                                    text: entry.modelData.sub ?? ""
                                    color: entry.active ? Colours.palette.m3onTertiaryContainer : Colours.palette.m3outline
                                    font: Tokens.font.label.small
                                    elide: Text.ElideRight
                                }
                            }

                            MaterialIcon {
                                visible: entry.active
                                text: "check"
                                color: Colours.palette.m3onTertiaryContainer
                                font: Tokens.font.icon.small
                            }
                        }
                    }

                    StyledScrollBar.vertical: StyledScrollBar {
                        flickable: list
                    }
                }
            }
        }
    }
}
