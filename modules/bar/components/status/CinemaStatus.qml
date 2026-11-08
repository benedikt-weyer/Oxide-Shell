import QtQuick
import qs.components
import qs.services

// Shown in the bar's status icons whenever the entry is added there; dimmed
// while cinema mode is off.
Item {
    id: root

    required property color colour

    implicitWidth: icon.implicitWidth
    implicitHeight: icon.implicitHeight

    MaterialIcon {
        id: icon

        anchors.centerIn: parent

        opacity: CinemaMode.enabled ? 1 : 0.5

        text: "movie"
        color: root.colour
        fill: CinemaMode.enabled ? 1 : 0

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }
}
