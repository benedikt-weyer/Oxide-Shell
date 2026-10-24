pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.services
import qs.modules.dock

Variants {
    model: Screens.screens

    Scope {
        id: scope

        required property ShellScreen modelData

        Exclusions {
            screen: scope.modelData
            bar: content.bar
            dockHeight: content.dockHeight
        }

        ContentWindow {
            id: content

            screen: scope.modelData
        }

        // After the drawers window, so it is stacked above it.
        Dock {
            targetScreen: scope.modelData
        }
    }
}
