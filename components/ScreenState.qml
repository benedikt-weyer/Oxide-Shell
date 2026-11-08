import Quickshell

PersistentProperties {
    required property ShellScreen modelData

    // Drawer visibilities
    property bool bar
    property bool osd
    property bool session
    property bool launcher
    property bool dashboard
    property bool utilities
    property bool sidebar
    property bool clipboardHistory
    // "<plugin id>/<view id>" of the plugin panel that is open, empty for none
    property string pluginPanel

    // Dashboard state
    property int dashboardTab
    property date dashboardDate: new Date()
}
