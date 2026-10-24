pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.utils
import qs.modules.launcher.services

// The dock of one screen. It is created by that screen's drawers scope (see
// modules/drawers/Drawers.qml), right after the drawers window: both are on
// the top layer, where layer-shell stacks surfaces in the order they were
// mapped, and the full-screen drawers window paints the border band the dock
// sits in. As a separate `Variants` over all screens the dock was mapped
// before the drawers window whenever the screens were recreated (all
// monitors disconnected and reconnected), and stayed hidden behind it until
// the shell was restarted. Created from the same scope, the order is fixed.
Variants {
    id: root

    required property ShellScreen targetScreen

    model: [root.targetScreen].filter(s => GlobalConfig.forScreen(s.name).dock.enabled && !Strings.testRegexList(GlobalConfig.forScreen(s.name).dock.excludedScreens, s.name))

    StyledWindow {
        id: win

        required property ShellScreen modelData

        readonly property int iconSize: contentItem.Config.dock.iconSize
        readonly property bool showBackground: contentItem.Config.dock.showBackground
        // The DockIcon currently showing its context menu, or null. Kept here
        // (rather than one popup per icon) so opening a menu always closes
        // whichever other one was open.
        property var menuTarget: null

        // Which running windows count as "on this dock", per Config.dock.scope:
        // - Monitor: only this screen's own active workspace.
        // - SharedWorkspace: every screen's active workspace, combined - so
        //   every dock shows the same set, for setups where matching
        //   workspace numbers across monitors are treated as one desktop.
        // - Global: every running window, everywhere.
        readonly property var scopedToplevels: {
            const scope = contentItem.Config.dock.scope;

            if (scope === DockScope.Global)
                return Hypr.toplevels.values.filter(t => !Hypr.isToplevelIgnored(t));

            if (scope === DockScope.SharedWorkspace) {
                let combined = [];
                for (const s of Quickshell.screens) {
                    const ws = Hypr.workspacesFor(s).find(w => w.active);
                    if (ws)
                        combined = combined.concat(Hypr.toplevelsForWs(s, ws.index));
                }
                return combined;
            }

            const ws = Hypr.workspacesFor(win.modelData).find(w => w.active);
            return ws ? Hypr.toplevelsForWs(win.modelData, ws.index) : [];
        }

        // Pinned apps are always shown (even with no window in scope, in
        // which case clicking launches a new instance) and always come first,
        // in pinned order; any other in-scope running app follows in
        // discovery order.
        readonly property var groups: {
            const pinned = GlobalConfig.dock.pinnedApps;

            const running = [];
            for (const t of win.scopedToplevels) {
                const group = running.find(g => g.appId === t.appId);
                if (group)
                    group.windows.push(t);
                else
                    running.push({
                        appId: t.appId,
                        windows: [t]
                    });
            }

            const pinnedGroups = pinned.map(appId => ({
                        appId: appId,
                        windows: running.find(g => g.appId === appId)?.windows ?? [],
                        pinned: true
                    }));
            const unpinnedGroups = running.filter(g => !pinned.includes(g.appId)).map(g => ({
                        appId: g.appId,
                        windows: g.windows,
                        pinned: false
                    }));

            return pinnedGroups.concat(unpinnedGroups);
        }

        screen: modelData
        name: "dock"
        // Space for the dock is reserved by a dedicated exclusion window
        // instead (see modules/drawers/Exclusions.qml), same as the bar on
        // the left - otherwise this window's own auto-computed exclusive
        // zone would stack with that one's on the same (bottom) edge, and
        // this surface would end up positioned short of the actual screen
        // edge by the latter's reservation.
        WlrLayershell.exclusionMode: ExclusionMode.Ignore

        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        implicitHeight: content.height + Tokens.padding.small * 2
        mask: Region {
            x: (win.width - content.width) / 2
            y: (win.height - content.height) / 2
            width: content.width
            height: content.height
        }

        ShellState.ComponentRef {
            screen: win.modelData
            slot: "dock"
            component: win
        }

        StyledRect {
            id: content

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter

            radius: Tokens.rounding.extraLarge
            color: win.showBackground ? Colours.tPalette.m3surfaceContainer : "transparent"

            width: row.implicitWidth + Tokens.padding.large * 2
            height: row.implicitHeight + Tokens.padding.small * 2

            RowLayout {
                id: row

                // Which sibling icon (if any) currently occupies screen x
                // `x` - used on drop to figure out where a dragged icon
                // landed.
                function hitTest(x: real): var {
                    for (let i = 0; i < rep.count; i++) {
                        const it = rep.itemAt(i);
                        if (it && x >= it.x && x < it.x + it.width)
                            return it;
                    }
                    return null;
                }

                // Moves `appId` to index `to` within the pinned segment
                // (pinned apps always occupy the front of the dock, in this
                // order) and persists it - a no-op if `appId` isn't pinned.
                function movePinned(appId: string, to: int): void {
                    const order = [...GlobalConfig.dock.pinnedApps];
                    const from = order.indexOf(appId);
                    if (from === -1 || to < 0 || to >= order.length || from === to)
                        return;
                    order.splice(to, 0, order.splice(from, 1)[0]);
                    GlobalConfig.dock.pinnedApps = order;
                }

                anchors.centerIn: parent
                spacing: Tokens.spacing.large

                Repeater {
                    id: rep

                    // Wrapped in a ScriptModel so a reorder (from dragging,
                    // below) only moves the affected delegates instead of
                    // destroying and recreating every icon.
                    model: ScriptModel {
                        values: win.groups
                        objectProp: "appId"
                    }

                    DockIcon {
                        required property var modelData
                        required property int index

                        dock: win
                        group: modelData
                        pinned: modelData.pinned
                        iconSize: win.iconSize
                    }
                }
            }
        }

        PopupWindow {
            id: contextMenu

            readonly property var target: win.menuTarget
            // The app's own jump-list entries (XDG "Desktop Actions", e.g. a
            // browser's "New Private Window") - empty for an app with none,
            // or one Apps/DesktopEntries doesn't know about (not running
            // from a .desktop file).
            readonly property var desktopEntry: target ? DesktopEntries.byId(target.group.appId) : null
            readonly property var actionItems: {
                const items = [];
                for (let i = 0; i < actionInstantiator.count; i++)
                    items.push(actionInstantiator.objectAt(i));
                return items;
            }
            readonly property list<MenuItem> menuItems: target ? (target.group.windows.length > 0 ? [target.openItem, target.pinItem, ...contextMenu.actionItems, target.floatItem, target.quitItem] : [target.openItem, target.pinItem, ...contextMenu.actionItems]) : []

            visible: target !== null
            color: "transparent"

            anchor.item: target?.anchorItem ?? null
            anchor.edges: Edges.Top
            anchor.gravity: Edges.Top
            anchor.adjustment: PopupAdjustment.Slide | PopupAdjustment.Flip
            anchor.margins.bottom: Tokens.spacing.small

            grabFocus: true

            implicitWidth: Math.max(180, column.implicitWidth + column.anchors.margins * 2)
            implicitHeight: column.implicitHeight + column.anchors.margins * 2

            onVisibleChanged: {
                if (!visible)
                    win.menuTarget = null;
            }

            Instantiator {
                id: actionInstantiator

                model: contextMenu.desktopEntry?.actions ?? []

                delegate: MenuItem {
                    id: actionMenuItem

                    required property DesktopAction modelData

                    text: modelData.name
                    // modelData.icon is a freedesktop icon name/path, not a
                    // Material Symbols ligature like every other entry here
                    // (see MaterialIcon below) - a generic glyph reads
                    // better than mismatched or missing icon text.
                    icon: "arrow_outward"

                    onClicked: actionMenuItem.modelData.execute()
                }
            }

            Item {
                anchors.fill: parent
                focus: contextMenu.visible

                Keys.onEscapePressed: win.menuTarget = null

                StyledRect {
                    anchors.fill: parent
                    radius: Tokens.rounding.large
                    color: Colours.palette.m3surfaceContainerLow

                    ColumnLayout {
                        id: column

                        anchors.fill: parent
                        anchors.margins: Tokens.padding.extraSmall
                        spacing: 0

                        Repeater {
                            model: contextMenu.menuItems

                            StyledRect {
                                id: menuRow

                                required property MenuItem modelData
                                required property int index

                                Layout.fillWidth: true
                                implicitWidth: menuRowLayout.implicitWidth + Tokens.padding.medium * 2
                                implicitHeight: menuRowLayout.implicitHeight + Tokens.padding.medium * 2

                                radius: Tokens.rounding.extraSmall
                                color: "transparent"

                                StateLayer {
                                    color: Colours.palette.m3onSurface
                                    onClicked: {
                                        menuRow.modelData.clicked();
                                        win.menuTarget = null;
                                    }
                                }

                                RowLayout {
                                    id: menuRowLayout

                                    anchors.fill: parent
                                    anchors.margins: Tokens.padding.medium
                                    spacing: Tokens.spacing.small

                                    MaterialIcon {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: menuRow.modelData.icon
                                        color: Colours.palette.m3onSurfaceVariant
                                    }

                                    StyledText {
                                        Layout.alignment: Qt.AlignVCenter
                                        Layout.fillWidth: true
                                        text: menuRow.modelData.text
                                        color: Colours.palette.m3onSurface
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // The root is a plain Item (rather than the ColumnLayout that's its
    // only real child, `content`) so `content.x` is free for the drag
    // offset below while `icon`'s own x/y - set by the RowLayout that
    // arranges dock icons - stays untouched.
    component DockIcon: Item {
        id: icon

        required property var dock
        required property var group
        required property bool pinned
        required property int iconSize
        // Only pinned icons are draggable: their order is the only one
        // that's actually persisted (GlobalConfig.dock.pinnedApps) -
        // running-app icons are ordered by discovery and would just
        // snap back to that order on the next window/workspace change.
        property bool dragging
        property real grabOffsetX

        readonly property alias anchorItem: iconRoot
        readonly property alias openItem: openItem
        readonly property alias pinItem: pinItem
        readonly property alias floatItem: floatItem
        readonly property alias quitItem: quitItem

        readonly property bool active: group.windows.some(w => w.activated)
        // Whether toggling right now would float (true) or tile (false) the
        // group's windows - if they're a mix, treat any-floating as "still
        // floating" so the action always reads as "put everything back".
        readonly property bool anyFloating: group.windows.some(w => Hypr.isFloating(w))

        function primaryAction(): void {
            if (group.windows.length > 0)
                activate();
            else
                launch();
        }

        function activate(): void {
            const idx = group.windows.findIndex(w => w.activated);
            const next = group.windows[(idx + 1) % group.windows.length];
            next.activate();
        }

        function launch(): void {
            const entry = DesktopEntries.byId(icon.group.appId);
            if (entry)
                Apps.launch(entry);
        }

        function togglePin(): void {
            const pinnedApps = GlobalConfig.dock.pinnedApps;
            GlobalConfig.dock.pinnedApps = icon.pinned ? pinnedApps.filter(a => a !== icon.group.appId) : [...pinnedApps, icon.group.appId];
        }

        function quit(): void {
            for (const w of icon.group.windows)
                w.close();
        }

        // Toggles every window of this app between floating and tiled
        // together, so the menu label always reflects what the action is
        // about to do (see anyFloating).
        function toggleFloating(): void {
            const floating = !icon.anyFloating;
            for (const w of icon.group.windows)
                Hypr.setFloating(w, floating);
        }

        implicitWidth: content.implicitWidth
        implicitHeight: content.implicitHeight
        z: icon.dragging ? 1 : 0

        Behavior on x {
            enabled: !icon.dragging

            Anim {}
        }

        Anim {
            id: returnAnim

            target: content
            property: "x"
            to: 0
        }

        ColumnLayout {
            id: content

            spacing: Tokens.spacing.extraSmall / 2

            Item {
                id: iconRoot

                Layout.alignment: Qt.AlignHCenter
                implicitWidth: icon.iconSize
                implicitHeight: icon.iconSize

                IconImage {
                    anchors.centerIn: parent
                    asynchronous: true
                    implicitSize: icon.iconSize
                    source: Icons.getAppIcon(icon.group.appId, "image-missing")
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    preventStealing: true
                    cursorShape: icon.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                    onPressed: e => {
                        if (icon.pinned && e.button === Qt.LeftButton)
                            icon.grabOffsetX = e.x;
                    }

                    onPositionChanged: e => {
                        if (!icon.pinned || !(pressedButtons & Qt.LeftButton))
                            return;

                        const abs = iconRoot.mapToItem(row, e.x, 0).x;
                        if (!icon.dragging) {
                            // Small dead zone so a plain click doesn't nudge
                            // the icon.
                            if (Math.abs(abs - icon.grabOffsetX - icon.x) < 4)
                                return;
                            icon.dragging = true;
                        }
                        content.x = abs - icon.grabOffsetX - icon.x;
                    }

                    onReleased: e => {
                        if (icon.dragging) {
                            icon.dragging = false;
                            returnAnim.start();
                            const hit = row.hitTest(icon.x + content.x + content.width / 2);
                            if (hit && hit !== icon && hit.pinned)
                                row.movePinned(icon.group.appId, hit.index);
                        } else if (e.button === Qt.RightButton) {
                            icon.dock.menuTarget = icon.dock.menuTarget === icon ? null : icon;
                        } else if (e.button === Qt.MiddleButton) {
                            icon.launch();
                        } else {
                            icon.primaryAction();
                        }
                    }
                }

                MenuItem {
                    id: openItem

                    icon: "open_in_new"
                    text: icon.group.windows.length > 0 ? qsTr("New window") : qsTr("Open")

                    onClicked: icon.launch()
                }

                MenuItem {
                    id: pinItem

                    icon: icon.pinned ? "keep_off" : "keep"
                    text: icon.pinned ? qsTr("Unpin from dock") : qsTr("Pin to dock")

                    onClicked: icon.togglePin()
                }

                MenuItem {
                    id: floatItem

                    icon: icon.anyFloating ? "dock_to_bottom" : "picture_in_picture"
                    text: icon.anyFloating ? qsTr("Tile") : qsTr("Float")

                    onClicked: icon.toggleFloating()
                }

                MenuItem {
                    id: quitItem

                    icon: "close"
                    text: qsTr("Quit")

                    onClicked: icon.quit()
                }
            }

            StyledRect {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: icon.active ? icon.iconSize * 0.5 : 4
                Layout.preferredHeight: icon.active ? 3 : 4
                radius: icon.active ? 1.5 : 2
                color: icon.active ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                opacity: icon.group.windows.length > 0 ? 1 : 0

                Behavior on Layout.preferredWidth {
                    Anim {}
                }

                Behavior on Layout.preferredHeight {
                    Anim {}
                }

                Behavior on radius {
                    Anim {}
                }

                Behavior on opacity {
                    Anim {}
                }
            }
        }
    }
}
