import QtQuick
import qs.components
import qs.services

// Shown in the bar's status icons only while cinema mode is on (the entry
// collapses to nothing otherwise, see StatusIcons.collapsed).
Item {
    id: root

    required property color colour

    implicitWidth: icon.implicitWidth
    implicitHeight: CinemaMode.enabled ? icon.implicitHeight : 0

    MaterialIcon {
        id: icon

        anchors.centerIn: parent

        scale: CinemaMode.enabled ? 1 : 0.5
        opacity: CinemaMode.enabled ? 1 : 0

        text: "movie"
        color: root.colour
        fill: 1

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on scale {
            Anim {}
        }
    }

    Behavior on implicitHeight {
        Anim {
            type: Anim.SlowEffects
        }
    }
}
