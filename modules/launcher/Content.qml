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

    // The launcher's tabs, left to right: apps that start in a throw-away VM,
    // all apps (the default), and apps that start in a persistent VM. The VM
    // tabs list only the apps that have a VM set up, and exist only while
    // there are any.
    readonly property var tabs: ["vm", "apps", "persistent"]
    readonly property bool hasVmTabs: VmLauncher.usable && VmLauncher.programs.length > 0
    // Tabs apply to the app list only, not to wallpapers or `:` commands.
    readonly property bool onApps: !list.showWallpapers && !search.text.startsWith(GlobalConfig.launcher.actionPrefix)

    property string tab: "apps"
    readonly property string activeTab: hasVmTabs ? tab : "apps"

    // Moves to the tab `delta` places to the right (negative: left) when Left
    // or Right is pressed. Only for a plain key press on the app list while
    // there are VM tabs: otherwise the arrow keys keep moving the cursor in
    // the search box as usual.
    function switchTabFromKey(event: var, delta: int): void {
        const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier));
        if (!hasVmTabs || !plain || !onApps) {
            event.accepted = false;
            return;
        }

        tab = tabs[CUtils.clamp(tabs.indexOf(activeTab) + delta, 0, tabs.length - 1)];
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

    // The tab strip and key hints under the results, shown for apps only (not
    // for wallpapers or `:` commands, where Left/Right keep their normal
    // meaning). Says plainly when no program is set up for VMs yet, like the
    // compositor's own launcher.
    Item {
        id: hints

        implicitHeight: root.onApps ? hintColumn.implicitHeight + Tokens.spacing.small : 0

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: search.top
        anchors.leftMargin: root.padding * 2
        anchors.rightMargin: root.padding * 2

        Column {
            id: hintColumn

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            visible: root.onApps
            spacing: Tokens.spacing.small

            Row {
                spacing: Tokens.spacing.small
                visible: root.hasVmTabs

                Repeater {
                    model: [
                        {
                            id: "vm",
                            icon: "deployed_code",
                            label: qsTr("VM")
                        },
                        {
                            id: "apps",
                            icon: "apps",
                            label: qsTr("Apps")
                        },
                        {
                            id: "persistent",
                            icon: "save",
                            label: qsTr("Persistent")
                        }
                    ]

                    StyledRect {
                        id: chip

                        required property var modelData
                        readonly property bool active: root.activeTab === modelData.id

                        implicitWidth: chipRow.implicitWidth + Tokens.padding.large * 2
                        implicitHeight: chipRow.implicitHeight + Tokens.padding.small * 2
                        radius: Tokens.rounding.full
                        color: active ? Colours.palette.m3secondaryContainer : "transparent"

                        Row {
                            id: chipRow

                            anchors.centerIn: parent
                            spacing: Tokens.spacing.small

                            MaterialIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData.icon
                                color: chip.active ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3outline
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData.label
                                font: Tokens.font.body.small
                                color: chip.active ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3outline
                            }
                        }
                    }
                }
            }

            StyledText {
                id: hintText

                width: parent.width
                text: {
                    if (!root.hasVmTabs)
                        return qsTr("Enter: launch   VM tabs: no program set up");
                    switch (root.activeTab) {
                    case "vm":
                        return qsTr("Enter: start in a throw-away VM   →: back to apps");
                    case "persistent":
                        return qsTr("Enter: start in a persistent VM (keeps state)   ←: back to apps");
                    default:
                        return qsTr("Enter: launch   ←: throw-away VMs   →: persistent VMs");
                    }
                }
                color: Colours.palette.m3outline
                font: Tokens.font.label.small
                elide: Text.ElideRight
            }
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
                    if (root.activeTab === "apps")
                        Apps.launch(currentItem.modelData);
                    else
                        Apps.launchVirtual(currentItem.modelData, root.activeTab === "persistent");
                    root.screenState.launcher = false;
                }
            }
        }

        Keys.onLeftPressed: event => root.switchTabFromKey(event, -1)
        Keys.onRightPressed: event => root.switchTabFromKey(event, 1)

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
                if (!root.screenState.launcher) {
                    search.text = "";
                    root.tab = "apps";
                }
            }

            function onSessionChanged(): void {
                if (!root.screenState.session)
                    search.forceActiveFocus();
            }

            target: root.screenState
        }
    }
}
