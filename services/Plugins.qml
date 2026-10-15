pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Plugins

// Thin QML-facing wrapper around the native PluginManager (Caelestia.Plugins,
// see plugin/src/Caelestia/Plugins) - the one place the dashboard and the
// Nexus pages talk to, so none of them needs to import the module. Also turns
// the toasts plugins ask for into shell toasts.
Singleton {
    id: root

    // [{id, name, version, description, author, icon, homepage, enabled, state, error, hasSettings, hasDashboard, updateAvailable}]
    readonly property var installed: PluginManager.installed
    // [{id, name, version, description, author, icon, source, installed, installedVersion, updateAvailable, compatible}]
    readonly property var available: PluginManager.available
    // [{name, url, builtin, error, count}]
    readonly property var sources: PluginManager.sources
    // [{pluginId, viewId, text, iconName}]
    readonly property var dashboardTabs: PluginManager.dashboardTabs
    readonly property bool busy: PluginManager.busy
    readonly property string busyId: PluginManager.busyId
    readonly property string lastError: PluginManager.lastError
    readonly property string apiVersion: PluginManager.apiVersion

    // Scroll state of plugin log views, {"<plugin>/<view>": {follow, y}}: a view
    // update rebuilds the whole widget tree, so the widget can't keep it itself.
    property var logScroll: ({})

    signal viewUpdated(pluginId: string, viewId: string)
    signal settingsChanged(pluginId: string)

    // Human-readable status of an installed plugin entry.
    function stateText(plugin: var): string {
        switch (plugin?.state) {
        case "running":
            return qsTr("Running");
        case "starting":
            return qsTr("Starting…");
        case "failed":
            return qsTr("Failed");
        case "disabled":
            return qsTr("Disabled");
        case "incompatible":
            return qsTr("Incompatible");
        case "broken":
            return qsTr("Broken");
        default:
            return qsTr("Stopped");
        }
    }

    function plugin(id: string): var {
        return PluginManager.plugin(id);
    }

    function install(id: string, source: string): void {
        PluginManager.install(id, source);
    }

    function remove(id: string): void {
        PluginManager.remove(id);
    }

    function setEnabled(id: string, enabled: bool): void {
        PluginManager.setEnabled(id, enabled);
    }

    function restart(id: string): void {
        PluginManager.restart(id);
    }

    function refreshAvailable(): void {
        PluginManager.refreshAvailable();
    }

    function addSource(name: string, url: string): void {
        PluginManager.addSource(name, url);
    }

    function removeSource(url: string): void {
        PluginManager.removeSource(url);
    }

    function view(pluginId: string, viewId: string): var {
        return PluginManager.view(pluginId, viewId);
    }

    function invokeAction(pluginId: string, viewId: string, actionId: string, payload: string): void {
        PluginManager.invokeAction(pluginId, viewId, actionId, payload);
    }

    function settingsSchema(id: string): var {
        return PluginManager.settingsSchema(id);
    }

    function settingValues(id: string): var {
        return PluginManager.settingValues(id);
    }

    function setSetting(id: string, key: string, value: var): void {
        PluginManager.setSetting(id, key, value);
    }

    function resetSettings(id: string): void {
        PluginManager.resetSettings(id);
    }

    Connections {
        function onViewUpdated(pluginId: string, viewId: string): void {
            root.viewUpdated(pluginId, viewId);
        }

        function onSettingsChanged(pluginId: string): void {
            root.settingsChanged(pluginId);
        }

        function onNotificationRequested(pluginId: string, pluginName: string, title: string, body: string, icon: string, urgency: string): void {
            Toaster.toast(title || pluginName, body, icon || "extension", urgency === "critical" ? Toast.Warning : Toast.Info);
        }

        target: PluginManager
    }
}
