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

    // What a VM's network can be, chosen in the options one more Left/Right
    // press past the VM tabs opens. "online" is the first and the default.
    readonly property var networks: [
        {
            id: "online",
            icon: "public",
            label: qsTr("Online"),
            note: qsTr("Through your network")
        },
        {
            id: "tor",
            icon: "vpn_lock",
            label: qsTr("Tor"),
            note: qsTr("Only through Tor, which runs on this computer outside the VM")
        },
        {
            id: "offline",
            icon: "wifi_off",
            label: qsTr("Offline"),
            note: qsTr("No network at all")
        }
    ]
    // Whether the options for the highlighted app are open instead of the
    // tabs, and the network chosen in them.
    property bool customizing: false
    property string network: "online"
    readonly property var networkInfo: networks.find(n => n.id === network)
    readonly property string highlightedName: list.currentList?.currentItem?.modelData?.name ?? ""

    // Moves to the tab `delta` places to the right (negative: left) when Left
    // or Right is pressed. Pressing it once more at the last VM tab opens the
    // options for the app to launch there (where Left/Right then choose the
    // network). Only for a plain key press on the app list while there are VM
    // tabs: otherwise the arrow keys keep moving the cursor in the search box
    // as usual.
    function switchTabFromKey(event: var, delta: int): void {
        const plain = !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.ShiftModifier | Qt.MetaModifier));
        if (!hasVmTabs || !plain || !onApps) {
            event.accepted = false;
            return;
        }

        if (customizing) {
            network = networks[CUtils.clamp(networks.findIndex(n => n.id === network) + delta, 0, networks.length - 1)].id;
            return;
        }

        const target = tabs.indexOf(activeTab) + delta;
        if (target >= 0 && target < tabs.length)
            tab = tabs[target];
        else if (activeTab !== "apps" && VmLauncher.canChooseNetwork)
            customizing = true;
    }

    // Starts the highlighted app in the VM the tab stands for, with the
    // network chosen in the options if they are open.
    function launchVirtual(entry: var): void {
        Apps.launchVirtual(entry, activeTab === "persistent", customizing ? network : "");
        screenState.launcher = false;
    }

    onActiveTabChanged: customizing = false
    onOnAppsChanged: {
        if (!onApps)
            customizing = false;
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
                visible: root.hasVmTabs && !root.customizing

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

                    OptionChip {
                        required property var modelData

                        icon: modelData.icon
                        label: modelData.label
                        active: root.activeTab === modelData.id
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.customizing
                text: qsTr("%1 in a %2 VM").arg(root.highlightedName).arg(root.activeTab === "persistent" ? qsTr("persistent") : qsTr("throw-away"))
                font: Tokens.font.body.small
                elide: Text.ElideRight
            }

            Row {
                spacing: Tokens.spacing.small
                visible: root.customizing

                Repeater {
                    model: root.networks

                    OptionChip {
                        required property var modelData

                        icon: modelData.icon
                        label: modelData.label
                        active: root.network === modelData.id
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.customizing
                text: root.networkInfo?.note ?? ""
                color: Colours.palette.m3outline
                font: Tokens.font.label.small
                elide: Text.ElideRight
            }

            StyledText {
                id: hintText

                width: parent.width
                text: {
                    if (!root.hasVmTabs)
                        return qsTr("Enter: launch   VM tabs: no program set up");
                    if (root.customizing)
                        return qsTr("Enter: start with this network   ←/→: choose   Esc: back");
                    const more = VmLauncher.canChooseNetwork ? qsTr("   %1: options") : "";
                    switch (root.activeTab) {
                    case "vm":
                        return qsTr("Enter: start in a throw-away VM   →: back to apps") + more.arg("←");
                    case "persistent":
                        return qsTr("Enter: start in a persistent VM (keeps state)   ←: back to apps") + more.arg("→");
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
                    if (root.activeTab === "apps") {
                        Apps.launch(currentItem.modelData);
                        root.screenState.launcher = false;
                    } else {
                        root.launchVirtual(currentItem.modelData);
                    }
                }
            }
        }

        Keys.onLeftPressed: event => root.switchTabFromKey(event, -1)
        Keys.onRightPressed: event => root.switchTabFromKey(event, 1)

        Keys.onUpPressed: list.currentList?.decrementCurrentIndex()
        Keys.onDownPressed: list.currentList?.incrementCurrentIndex()

        Keys.onEscapePressed: {
            // The options close first; the launcher itself with the next press.
            if (root.customizing)
                root.customizing = false;
            else
                root.screenState.launcher = false;
        }

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
                    root.customizing = false;
                    root.network = "online";
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
