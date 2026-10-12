pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services
import qs.modules.nexus

VerticalFadeFlickable {
    id: root

    required property NexusState nState
    required property string query

    readonly property var results: {
        const terms = query.toLowerCase().split(/\s+/).filter(t => t.length > 0);
        if (terms.length === 0)
            return [];

        const scored = [];
        for (const e of SearchIndex.entries) {
            const label = e.label.toLowerCase();
            const haystack = `${label} ${e.sub.toLowerCase()} ${e.path.toLowerCase()}`;
            if (!terms.every(t => haystack.includes(t)))
                continue;

            const inLabel = terms.every(t => label.includes(t));
            const score = (label.startsWith(terms[0]) ? 0 : inLabel ? 1 : 2) * 100 + label.length;
            scored.push({
                score,
                entry: e
            });
        }
        scored.sort((a, b) => a.score - b.score);
        return scored.slice(0, 40).map(s => s.entry);
    }

    signal activated

    function open(entry: var): void {
        const state = root.nState;
        if (state.currentPageIdx === entry.page) {
            // Already on that page: unwind to its root, then walk down.
            while (state.subPageIdxStack.length > 0)
                state.closeSubPage();
            for (const sub of entry.stack)
                state.openSubPage(sub);
        } else {
            // The page loads after its switch animation and replays the stack.
            state.currentPageIdx = entry.page;
            for (const sub of entry.stack)
                state.subPageIdxStack.push(sub);
        }
        activated();
    }

    topMargin: Tokens.padding.large
    bottomMargin: Tokens.padding.large
    contentHeight: content.implicitHeight

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Tokens.spacing.extraSmall

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.padding.large
            visible: root.results.length === 0
            horizontalAlignment: Text.AlignHCenter
            text: qsTr("No settings found")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.medium
        }

        Repeater {
            model: root.results

            StyledRect {
                id: item

                required property var modelData
                required property int index

                Layout.fillWidth: true
                implicitHeight: layout.implicitHeight + Tokens.padding.large * 2

                color: Colours.layer(Colours.palette.m3surfaceContainerHigh, 2)
                radius: Tokens.rounding.large

                StateLayer {
                    anchors.fill: parent
                    radius: parent.radius
                    onClicked: root.open(item.modelData)
                }

                ColumnLayout {
                    id: layout

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.large
                    spacing: 0

                    StyledText {
                        Layout.fillWidth: true
                        text: item.modelData.label
                        font: Tokens.font.body.medium
                        elide: Text.ElideRight
                    }

                    StyledText {
                        Layout.fillWidth: true
                        text: item.modelData.path
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
