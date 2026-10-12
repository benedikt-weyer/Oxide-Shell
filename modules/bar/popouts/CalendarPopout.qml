import "../../dashboard/dash"
import QtQuick
import qs.components

// The dashboard's calendar, shown when hovering the bar clock. Shares the
// screen's `dashboardDate`, so month navigation carries over between the two.
Item {
    id: root

    required property ScreenState screenState

    implicitWidth: 300
    implicitHeight: calendar.implicitHeight

    Calendar {
        id: calendar

        screenState: root.screenState
    }
}
