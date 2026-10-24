pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.Wayland

// Cinema mode: keeps one screen lit (the one being worked on) and turns all
// the others dark through the compositor's `ironland-cinema-mode-v1`,
// optionally with a glow on the dark ones made of the colours along the lit
// screen's border. Only a transient toggle (like game mode): it is kept over
// shell reloads, but never comes back after a restart, and the compositor
// ends it by itself if the shell dies.
Singleton {
    id: root

    property alias enabled: props.enabled

    readonly property bool available: cinema.available
    readonly property bool glow: GlobalConfig.cinemaMode.glow
    readonly property int glowStrength: GlobalConfig.cinemaMode.glowStrength

    function toggle(): void {
        enabled = !enabled;
    }

    // qmllint disable unresolved-type
    IronlandCinemaMode {
        // qmllint enable unresolved-type
        id: cinema

        enabled: root.enabled
        // 0 turns the glow off.
        glow: root.glow ? root.glowStrength : 0
    }

    PersistentProperties {
        id: props

        property bool enabled: false

        reloadableId: "cinemaMode"
    }

    IpcHandler {
        function isEnabled(): bool {
            return props.enabled;
        }

        function toggle(): void {
            props.enabled = !props.enabled;
        }

        function enable(): void {
            props.enabled = true;
        }

        function disable(): void {
            props.enabled = false;
        }

        target: "cinemaMode"
    }
}
