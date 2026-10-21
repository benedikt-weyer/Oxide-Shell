pragma ComponentBehavior: Bound

import QtQuick
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.modules.launcher.services

Item {
    id: root

    required property ScreenState screenState
    required property var panels
    required property real maxHeight

    readonly property int padding: Tokens.padding.large
    readonly property int rounding: Tokens.rounding.extraLarge

    // Starts the highlighted app in a VM when Left (throw-away) or Right
    // (persistent) is pressed. Only while the compositor can actually do
    // that, and only for a plain key press on an app: otherwise the arrow
    // keys keep moving the cursor in the search box as usual.
    function launchVirtualFromKey(event: var, persistent: bool): void {
        const item = list.currentList?.currentItem;
        const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier));
        const onApps = !list.showWallpapers && !search.text.startsWith(GlobalConfig.launcher.actionPrefix);
        if (!VmLauncher.usable || !plain || !onApps || !item) {
            event.accepted = false;
            return;
        }

        Apps.launchVirtual(item.modelData, persistent);
        root.screenState.launcher = false;
    }

    implicitWidth: listWrapper.width + padding * 2
    implicitHeight: search.height + hints.height + listWrapper.height + padding + search.anchors.bottomMargin

    Item {
        id: listWrapper

        implicitWidth: list.width
        implicitHeight: list.height + root.padding

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: hints.top
        anchors.bottomMargin: root.padding

        ContentList {
            id: list

            content: root
            screenState: root.screenState
            panels: root.panels
            maxHeight: root.maxHeight - search.implicitHeight - hints.height - root.padding * 3
            search: search
            padding: root.padding
            rounding: root.rounding
        }
    }

    // Key hints under the results, shown for apps only (not for wallpapers or
    // `:` commands, where Left/Right keep their normal meaning). Says plainly
    // when the VM keys can't work yet, like the compositor's own launcher.
    Item {
        id: hints

        readonly property bool shown: !list.showWallpapers && !search.text.startsWith(GlobalConfig.launcher.actionPrefix)

        implicitHeight: shown ? hintText.implicitHeight + Tokens.spacing.small : 0

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: search.top
        anchors.leftMargin: root.padding * 2
        anchors.rightMargin: root.padding * 2

        StyledText {
            id: hintText

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            visible: hints.shown
            text: VmLauncher.usable ? qsTr("Enter: launch   ←: throw-away VM   →: persistent VM (keeps state)") : qsTr("Enter: launch   VM keys: not set up")
            color: Colours.palette.m3outline
            font: Tokens.font.label.small
            elide: Text.ElideRight
        }
    }

    SearchBar {
        id: search

        objectName: "launcherSearch"

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: root.padding
        anchors.bottomMargin: CUtils.clamp(root.padding - Config.border.thickness, 0, root.padding)

        topPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)
        bottomPadding: Math.round((Tokens.padding.medium + Tokens.padding.large) / 2)

        placeholderText: qsTr("Type \"%1\" for commands").arg(GlobalConfig.launcher.actionPrefix)

        onAccepted: {
            const currentItem = list.currentList?.currentItem;
            if (currentItem) {
                if (list.showWallpapers) {
                    if (Colours.scheme === "dynamic" && currentItem.modelData.path !== Wallpapers.actualCurrent)
                        Wallpapers.previewColourLock = true;
                    Wallpapers.setWallpaper(currentItem.modelData.path);
                    root.screenState.launcher = false;
                } else if (text.startsWith(GlobalConfig.launcher.actionPrefix)) {
                    if (text.startsWith(`${GlobalConfig.launcher.actionPrefix}calc `))
                        currentItem.onClicked();
                    else
                        currentItem.modelData.onClicked(list.currentList);
                } else {
                    Apps.launch(currentItem.modelData);
                    root.screenState.launcher = false;
                }
            }
        }

        Keys.onLeftPressed: event => root.launchVirtualFromKey(event, false)
        Keys.onRightPressed: event => root.launchVirtualFromKey(event, true)

        Keys.onUpPressed: list.currentList?.decrementCurrentIndex()
        Keys.onDownPressed: list.currentList?.incrementCurrentIndex()

        Keys.onEscapePressed: root.screenState.launcher = false

        Keys.onPressed: event => {
            if (!GlobalConfig.launcher.vimKeybinds)
                return;

            if (event.modifiers & Qt.ControlModifier) {
                if (event.key === Qt.Key_J || event.key === Qt.Key_N) {
                    list.currentList?.incrementCurrentIndex();
                    event.accepted = true;
                } else if (event.key === Qt.Key_K || event.key === Qt.Key_P) {
                    list.currentList?.decrementCurrentIndex();
                    event.accepted = true;
                }
            } else if (event.key === Qt.Key_Tab) {
                list.currentList?.incrementCurrentIndex();
                event.accepted = true;
            } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                list.currentList?.decrementCurrentIndex();
                event.accepted = true;
            }
        }

        Component.onCompleted: forceActiveFocus()

        Connections {
            function onLauncherChanged(): void {
                if (!root.screenState.launcher)
                    search.text = "";
            }

            function onSessionChanged(): void {
                if (!root.screenState.session)
                    search.forceActiveFocus();
            }

            target: root.screenState
        }
    }
}
