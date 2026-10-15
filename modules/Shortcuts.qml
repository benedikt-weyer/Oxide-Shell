import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import qs.components
import qs.components.misc
import qs.services
import qs.modules.nexus

Scope {
    id: root

    property bool launcherInterrupted
    // Captured from the "launcher" shortcut's onPressed (see below) so the
    // toggle - which only happens on release, to allow interrupting a tap -
    // still opens on whichever output had the pointer at press time.
    property string launcherOutputName
    readonly property bool hasFullscreen: Hypr.hasFullscreenOn(Hypr.focusedMonitor)

    // The screen the "launcher" shortcut should open on: wherever the
    // pointer was when it fired, falling back to the focused screen if the
    // compositor couldn't tell us (or that output is no longer connected).
    function launcherScreen(): ScreenState {
        const screen = root.launcherShellScreen();
        return (screen && ShellState.forScreen(screen)) ?? ShellState.forActive();
    }

    // The ShellScreen launcherScreen() resolves to, so the fullscreen check
    // below looks at the output the launcher would open on rather than the
    // focused one (a fullscreen window on another monitor must not block it).
    function launcherShellScreen(): ShellScreen {
        return Quickshell.screens.find(s => s.name === root.launcherOutputName) ?? Hypr.focusedMonitor;
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "nexus"
        description: "Open nexus"
        onPressed: WindowFactory.create()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "showall"
        description: "Toggle launcher, dashboard and osd"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const v = ShellState.forActive();
            v.launcher = v.dashboard = v.osd = v.utilities = !(v.launcher || v.dashboard || v.osd || v.utilities);
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "dashboard"
        description: "Toggle dashboard"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.dashboard = !screenState.dashboard;
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "session"
        description: "Toggle session menu"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.session = !screenState.session;
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "launcher"
        description: "Toggle launcher"
        onPressed: output => {
            root.launcherInterrupted = false;
            root.launcherOutputName = output;
        }
        onReleased: {
            if (!root.launcherInterrupted && !Hypr.hasFullscreenOn(root.launcherShellScreen())) {
                const screenState = root.launcherScreen();
                screenState.launcher = !screenState.launcher;
            }
            root.launcherInterrupted = false;
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "launcherInterrupt"
        description: "Interrupt launcher keybind"
        onPressed: root.launcherInterrupted = true
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "sidebar"
        description: "Toggle sidebar"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.sidebar = !screenState.sidebar;
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "utilities"
        description: "Toggle utilities"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.utilities = !screenState.utilities;
        }
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "volumeUp"
        description: "Increase volume"
        onPressed: Audio.incrementVolume()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "volumeDown"
        description: "Decrease volume"
        onPressed: Audio.decrementVolume()
    }

    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "volumeMute"
        description: "Toggle mute"
        onPressed: Audio.toggleMute()
    }

    // Owned entirely by the shell (via `ironland-shortcuts-v1`'s `bind`
    // request, not the compositor's `[shortcuts]` config - see
    // CustomShortcut/IronlandShortcut) since this only ever toggles this
    // shell's own clipboard-history overlay, nothing compositor-side.
    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        modifiers: ["super"]
        key: "v"
        description: "Toggle clipboard history"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.clipboardHistory = !screenState.clipboardHistory;
        }
    }

    IpcHandler {
        function toggle(drawer: string): void {
            if (list().split("\n").includes(drawer)) {
                if (root.hasFullscreen && ["launcher", "session", "dashboard"].includes(drawer))
                    return;
                const screenState = ShellState.forActive();
                screenState[drawer] = !screenState[drawer];
            } else {
                console.warn(lc, `Drawer "${drawer}" does not exist`);
            }
        }

        function list(): string {
            const screenState = ShellState.forActive();
            return Object.keys(screenState).filter(k => typeof screenState[k] === "boolean").join("\n");
        }

        function isOpen(drawer: string): string {
            const screenState = ShellState.forActive();
            if (typeof screenState[drawer] !== "boolean")
                return "unknown";
            return screenState[drawer] ? "1" : "0";
        }

        target: "drawers"
    }

    IpcHandler {
        function open(): void {
            WindowFactory.create();
        }

        target: "nexus"
    }

    IpcHandler {
        function info(title: string, message: string, icon: string): void {
            Toaster.toast(title, message, icon, Toast.Info);
        }

        function success(title: string, message: string, icon: string): void {
            Toaster.toast(title, message, icon, Toast.Success);
        }

        function warn(title: string, message: string, icon: string): void {
            Toaster.toast(title, message, icon, Toast.Warning);
        }

        function error(title: string, message: string, icon: string): void {
            Toaster.toast(title, message, icon, Toast.Error);
        }

        target: "toaster"
    }

    LoggingCategory {
        id: lc

        name: "caelestia.qml.shortcuts"
        defaultLogLevel: LoggingCategory.Info
    }
}
