pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Wayland

// Starts launcher entries inside virtual machines, through the compositor's
// `ironland-vm-launch-v1` protocol (see the sibling ironland-compositor
// repo's `[vm]` config and `src/shell/vm.rs`): the program runs in a VM but
// its windows appear on this desktop like any other, marked with a badge.
//
// Two flavours: a throw-away VM, and a persistent one that keeps the
// application's disk and memory between launches. The compositor does the
// work; this only asks, and turns its progress reports into toasts - VMs
// take a few seconds to boot, so "starting" feedback matters.
Singleton {
    id: root

    // Whether VM launching can work right now: the compositor offers the
    // protocol and has a guest image configured. Offer the feature only
    // while this is true.
    readonly property bool usable: launcher.usable

    // Runs `entry` in a VM: `persistent` keeps its state for next time.
    function launch(entry: DesktopEntry, persistent: bool): void {
        launcher.launch(entry.id, persistent);
    }

    function appName(entryId: string): string {
        return DesktopEntries.byId(entryId)?.name ?? entryId;
    }

    // qmllint disable unresolved-type
    IronlandVmLauncher {
        // qmllint enable unresolved-type
        id: launcher

        onStarting: (entry, persistent) => Toaster.toast(qsTr("Starting a VM"), persistent ? qsTr("%1 is starting in a persistent virtual machine").arg(root.appName(entry)) : qsTr("%1 is starting in a virtual machine").arg(root.appName(entry)), "deployed_code")

        onSaving: entry => Toaster.toast(qsTr("Saving VM state"), qsTr("Saving %1's virtual machine so it resumes quickly next time").arg(root.appName(entry)), "save")

        onFailed: (entry, persistent, error, message) => Toaster.toast(qsTr("Couldn't start VM"), `${root.appName(entry)}: ${message}`, "error", Toast.Error)

        onFinished: (entry, persistent, reason) => {
            if (reason === "failed")
                Toaster.toast(qsTr("VM stopped unexpectedly"), qsTr("%1's virtual machine died").arg(root.appName(entry)), "error", Toast.Error);
            else if (reason === "timed_out")
                Toaster.toast(qsTr("VM didn't start in time"), qsTr("%1 never opened a window").arg(root.appName(entry)), "error", Toast.Error);
        }
    }
}
