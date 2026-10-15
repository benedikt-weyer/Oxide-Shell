pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.Wayland
import qs.services

// Warms the display (via the compositor's `ironland-display-filter-v1`) so
// it's easier on the eyes in the evening. Either a plain on/off switch, or -
// with `scheduled` - on between `startTime` and `endTime` every day; the
// compositor itself knows nothing of clocks, it only applies the
// temperature this asks for (and drops it if the shell dies).
Singleton {
    id: root

    readonly property bool scheduled: GlobalConfig.nightMode.scheduled
    readonly property bool inSchedule: {
        const start = root.minutesOf(GlobalConfig.nightMode.startTime);
        const end = root.minutesOf(GlobalConfig.nightMode.endTime);
        const now = Time.hours * 60 + Time.minutes;
        if (start < 0 || end < 0 || start === end)
            return false;
        // A window like 21:00-07:00 wraps past midnight.
        return start < end ? (now >= start && now < end) : (now >= start || now < end);
    }
    readonly property bool active: scheduled ? inSchedule : GlobalConfig.nightMode.enabled
    readonly property bool available: filter.available

    // "HH:mm" to minutes since midnight, or -1 if malformed.
    function minutesOf(time: string): int {
        const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(time ?? "");
        return m ? parseInt(m[1]) * 60 + parseInt(m[2]) : -1;
    }

    // qmllint disable unresolved-type
    IronlandDisplayFilter {
        // qmllint enable unresolved-type
        id: filter

        // 6500K is neutral, i.e. no filter.
        temperature: root.active ? GlobalConfig.nightMode.temperature : 6500
    }

    IpcHandler {
        function isActive(): bool {
            return root.active;
        }

        function toggle(): void {
            GlobalConfig.nightMode.enabled = !GlobalConfig.nightMode.enabled;
        }

        function enable(): void {
            GlobalConfig.nightMode.enabled = true;
        }

        function disable(): void {
            GlobalConfig.nightMode.enabled = false;
        }

        target: "nightMode"
    }
}
