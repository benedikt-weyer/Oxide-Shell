pragma ComponentBehavior: Bound

import QtQuick
import qs.components

// Slides a plugin's panel (Content.qml) down from the top of the screen while
// `screenState.pluginPanel` names one ("<plugin id>/<view id>", set by the
// plugin's button in the bar) - same offsetScale/Loader pattern as the
// dashboard and the clipboard history.
Item {
    id: root

    required property ScreenState screenState

    // Kept while the panel slides out, when screenState has already forgotten it
    property string panelKey

    readonly property bool shouldBeActive: screenState.pluginPanel.length > 0
    property real offsetScale: shouldBeActive ? 0 : 1

    visible: offsetScale < 1
    anchors.topMargin: (-implicitHeight - 5) * offsetScale
    implicitHeight: Math.max(320, Math.min((parent?.height ?? 800) - Tokens.padding.large * 2, 780))
    implicitWidth: 680
    opacity: 1 - offsetScale

    onShouldBeActiveChanged: {
        if (shouldBeActive)
            panelKey = screenState.pluginPanel;
    }

    Connections {
        function onPluginPanelChanged(): void {
            if (root.screenState.pluginPanel.length > 0)
                root.panelKey = root.screenState.pluginPanel;
        }

        target: root.screenState
    }

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        anchors.fill: parent

        active: root.shouldBeActive || root.visible

        sourceComponent: Content {
            screenState: root.screenState
            panelKey: root.panelKey
        }
    }
}
