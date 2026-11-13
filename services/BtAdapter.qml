pragma Singleton

import Quickshell
import Quickshell.Bluetooth
import Caelestia.Config

// The Bluetooth adapter the shell uses. With several adapters (e.g. a USB
// dongle next to the built-in one) it is the one picked in Nexus, kept in
// `services.bluetoothAdapter`; when that is unset or the adapter is gone, the
// system's default adapter.
Singleton {
    id: root

    // qmllint disable unresolved-type
    readonly property var adapters: Bluetooth.adapters.values
    readonly property BluetoothAdapter adapter: adapters.find(a => a.adapterId === GlobalConfig.services.bluetoothAdapter) ?? Bluetooth.defaultAdapter
    // Only the devices of that adapter
    readonly property var devices: Bluetooth.devices.values.filter(d => d.adapter === adapter)
    // qmllint enable unresolved-type
}
