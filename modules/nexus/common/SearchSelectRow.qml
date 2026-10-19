pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// A "dropdown with search": a text field that, while focused, shows the
// options matching what's been typed in a scrollable list underneath. Picking
// an entry - or typing a name that isn't listed and pressing enter - emits
// `selected`. Unlike SelectRow's menu this copes with hundreds of options.
ConnectedRect {
    id: root

    property alias label: label.text
    property string subtext
    // The currently chosen option, shown in the field while it isn't focused.
    property string value
    property var options: []
    property string placeholderText
    property bool disabled
    property int maxVisibleRows: 6

    property string query
    property string lastEmitted
    readonly property real rowHeight: Math.round(Tokens.font.body.small.pointSize * 2.8)
    readonly property var filtered: {
        const q = query.trim().toLowerCase();
        const all = options ?? [];
        if (!q)
            return all;
        // An exact match means the user just picked it: keep the whole list
        // available rather than collapsing to that single entry.
        if (all.some(o => o.toLowerCase() === q))
            return all;
        return all.filter(o => o.toLowerCase().includes(q));
    }
    readonly property bool listOpen: input.activeFocus && !disabled && filtered.length > 0

    signal selected(value: string)

    function choose(chosen: string): void {
        input.text = chosen;
        lastEmitted = chosen;
        selected(chosen);
        input.focus = false;
    }

    function commit(typed: string): void {
        const trimmed = typed.trim();
        if (!trimmed) {
            input.text = value;
            return;
        }
        if (trimmed !== value && trimmed !== lastEmitted) {
            lastEmitted = trimmed;
            selected(trimmed);
        }
    }

    Layout.fillWidth: true
    implicitHeight: column.implicitHeight + column.anchors.margins * 2
    clip: false
    z: listOpen ? 1 : 0
    opacity: disabled ? 0.5 : 1

    Component.onCompleted: input.text = value

    onValueChanged: {
        lastEmitted = "";
        if (!input.activeFocus)
            input.text = value;
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Tokens.padding.medium
        anchors.leftMargin: Tokens.padding.largeIncreased
        anchors.rightMargin: Tokens.padding.largeIncreased
        spacing: Tokens.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    id: label

                    Layout.fillWidth: true
                    font: Tokens.font.body.small
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: root.subtext
                    text: root.subtext
                    color: Colours.palette.m3outline
                    font: Tokens.font.label.small
                    elide: Text.ElideRight
                }
            }

            StyledTextField {
                id: input

                Layout.preferredWidth: Tokens.sizes.nexus.textFieldWidth
                Layout.maximumWidth: root.width / 2
                Layout.alignment: Qt.AlignVCenter
                verticalPadding: Tokens.padding.small

                enabled: !root.disabled
                placeholderText: root.placeholderText

                onTextEdited: root.query = text
                onActiveFocusChanged: {
                    if (activeFocus)
                        root.query = "";
                }
                onEditingFinished: root.commit(text)
                Keys.onEscapePressed: {
                    text = root.value;
                    focus = false;
                }
            }
        }

        StyledRect {
            Layout.fillWidth: true
            Layout.preferredHeight: root.listOpen ? Math.min(list.contentHeight, root.maxVisibleRows * root.rowHeight) : 0
            visible: Layout.preferredHeight > 0
            radius: Tokens.rounding.large
            color: Colours.palette.m3surfaceContainerLow
            clip: true

            Behavior on Layout.preferredHeight {
                Anim {}
            }

            ListView {
                id: list

                anchors.fill: parent
                model: root.filtered
                boundsBehavior: Flickable.StopAtBounds

                StyledScrollBar.vertical: StyledScrollBar {
                    flickable: list
                }

                delegate: Item {
                    id: entry

                    required property string modelData

                    width: ListView.view.width
                    height: root.rowHeight

                    StateLayer {
                        onClicked: root.choose(entry.modelData)
                    }

                    StyledText {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Tokens.padding.large
                        anchors.rightMargin: Tokens.padding.large

                        text: entry.modelData
                        color: entry.modelData === root.value ? Colours.palette.m3primary : Colours.palette.m3onSurface
                        font: Tokens.font.body.small
                        elide: Text.ElideMiddle
                    }
                }
            }
        }
    }
}
