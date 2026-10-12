pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Talks to `ironlandctl` (see the sibling ironland-compositor repo's
// ironlandctl/ crate) to read and edit ironland-compositor's config.toml -
// keyboard, shortcuts, monitors, workspaces, focus and appearance settings
// that live outside this shell's own Caelestia.Config tree entirely. Mainly
// consumed by the Nexus "Compositor" page (modules/nexus/pages/compositor)
// for editing; Bar.qml also reads `config.workspaces.dynamic` to decide
// whether scrolling past the last workspace should request a new one.
Singleton {
    id: root

    // The effective config (file merged over ironlandctl's built-in
    // defaults), as `ironlandctl show --json` returns it, or null before
    // the first refresh() completes.
    property var config: null
    property bool loading: true
    // Non-empty once a command has failed (including ironlandctl missing
    // from PATH entirely) - pages should show this instead of a stale/empty
    // settings form.
    property string lastError: ""
    readonly property bool available: !root.lastError

    // Human-readable labels for known compositor actions - GUI-only
    // presentation, kept here rather than in ironlandctl itself the same
    // way gui-settings' actionLabels does. Falls back to the raw action
    // name for one not listed here.
    readonly property var actionLabels: ({
            quit: qsTr("Quit compositor"),
            run_terminal: qsTr("Open terminal"),
            toggle_launcher: qsTr("Toggle app launcher"),
            open_browser: qsTr("Open browser"),
            open_file_manager: qsTr("Open file manager"),
            toggle_floating: qsTr("Toggle floating/tiled"),
            kill_window: qsTr("Kill active window"),
            focus_left: qsTr("Focus window: left"),
            focus_right: qsTr("Focus window: right"),
            focus_up: qsTr("Focus window: up"),
            focus_down: qsTr("Focus window: down"),
            swap_left: qsTr("Swap window: left"),
            swap_right: qsTr("Swap window: right"),
            swap_up: qsTr("Swap window: up"),
            swap_down: qsTr("Swap window: down"),
            resize_left: qsTr("Resize tiled window: left"),
            resize_right: qsTr("Resize tiled window: right"),
            resize_up: qsTr("Resize tiled window: up"),
            resize_down: qsTr("Resize tiled window: down"),
            workspace_left: qsTr("Switch workspace: previous"),
            workspace_right: qsTr("Switch workspace: next"),
            move_workspace_left: qsTr("Move window to workspace: previous"),
            move_workspace_right: qsTr("Move window to workspace: next"),
            move_workspace_left_follow: qsTr("Move window to workspace and follow: previous"),
            move_workspace_right_follow: qsTr("Move window to workspace and follow: next"),
            move_monitor_left: qsTr("Move window to monitor: left"),
            move_monitor_right: qsTr("Move window to monitor: right"),
            move_monitor_up: qsTr("Move window to monitor: up"),
            move_monitor_down: qsTr("Move window to monitor: down"),
            scale_up: qsTr("Increase output scale"),
            scale_down: qsTr("Decrease output scale"),
            toggle_preview: qsTr("Toggle window preview"),
            rotate_output: qsTr("Rotate output"),
            toggle_tint: qsTr("Toggle debug tint"),
            toggle_decorations: qsTr("Toggle window decorations")
        })

    function actionLabel(action: string): string {
        return root.actionLabels[action] ?? action;
    }

    // Re-reads the effective config. Safe to call repeatedly; every
    // mutating function below already calls this once its edit lands.
    function refresh(callback: var): void {
        root.loading = true;
        run(["show", "--json"], result => {
            root.loading = false;
            if (result.success) {
                root.lastError = "";
                try {
                    root.config = JSON.parse(result.output);
                } catch (e) {
                    root.lastError = `Failed to parse ironlandctl output: ${e}`;
                }
            } else {
                root.lastError = result.error || "ironlandctl failed";
            }
            if (callback)
                callback(result.success);
        });
    }

    function loadDefaults(callback: var): void {
        run(["defaults", "--json"], result => {
            if (!result.success) {
                if (callback)
                    callback(null);
                return;
            }
            try {
                callback?.(JSON.parse(result.output));
            } catch (e) {
                console.warn(lc, "Failed to parse ironlandctl defaults:", e);
                callback?.(null);
            }
        });
    }

    function setValue(key: string, value: string, callback: var): void {
        run(["set", key, value], result => finishEdit(result, callback));
    }

    function unsetValue(key: string, callback: var): void {
        run(["unset", key], result => finishEdit(result, callback));
    }

    function shortcutsEventsList(callback: var): void {
        run(["shortcuts", "events", "list", "--json"], result => {
            if (!result.success) {
                callback?.(null);
                return;
            }
            try {
                callback?.(JSON.parse(result.output));
            } catch (e) {
                callback?.(null);
            }
        });
    }

    function shortcutsSet(action: string, combos: string, callback: var): void {
        run(["shortcuts", "set", action, combos], result => finishEdit(result, callback));
    }

    function shortcutsUnset(action: string, callback: var): void {
        run(["shortcuts", "unset", action], result => finishEdit(result, callback));
    }

    function eventAdd(name: string, combos: string, callback: var): void {
        const args = ["shortcuts", "events", "add", name];
        if (combos)
            args.push(combos);
        run(args, result => finishEdit(result, callback));
    }

    function eventRemove(name: string, callback: var): void {
        run(["shortcuts", "events", "remove", name], result => finishEdit(result, callback));
    }

    function outputsSet(name: string, extraArgs: list<string>, callback: var): void {
        run(["outputs", "set", name, ...extraArgs], result => finishEdit(result, callback));
    }

    function outputsRemove(name: string, callback: var): void {
        run(["outputs", "remove", name], result => finishEdit(result, callback));
    }

    // Currently connected monitors, via `wayland-info`. `callback` gets
    // `null` if detection isn't available (no wayland-info, no monitors).
    function detectOutputs(callback: var): void {
        run(["outputs", "detect", "--json"], result => {
            if (!result.success) {
                callback?.(null);
                return;
            }
            try {
                callback?.(JSON.parse(result.output));
            } catch (e) {
                callback?.(null);
            }
        });
    }

    function finishEdit(result: var, callback: var): void {
        if (!result.success) {
            root.lastError = result.error || "ironlandctl failed";
            callback?.(false, root.lastError);
            return;
        }
        root.refresh(() => callback?.(true, ""));
    }

    // Runs `ironlandctl <args>`, invoking `callback` with
    // `{success, output, error, exitCode}`.
    function run(args: list<string>, callback: var): void {
        const proc = procComp.createObject(root, {
            cmdArgs: ["ironlandctl", ...args],
            callback
        });
        Qt.callLater(() => proc.running = true);
    }

    Component.onCompleted: root.refresh()

    Component {
        id: procComp

        Process {
            id: proc

            required property list<string> cmdArgs
            required property var callback
            property bool finished
            // Covers a spawn failure (ironlandctl missing from PATH), which
            // may never fire `exited` at all depending on how the process
            // backend reports it. Assigned to a plain named property
            // (rather than declared as a default-property child, which
            // Process doesn't have one of) so it still gets a Timer
            // instance without needing its own top-level Item/Component.
            property Timer timeoutTimer: Timer {
                interval: 5000
                running: true
                onTriggered: proc.finish({
                    success: false,
                    output: "",
                    error: "ironlandctl did not respond (is it installed and on PATH?)",
                    exitCode: -1
                })
            }

            function finish(result: var): void {
                if (proc.finished)
                    return;
                proc.finished = true;
                proc.timeoutTimer.stop();
                proc.callback?.(result);
                proc.destroy();
            }

            command: cmdArgs
            stdout: StdioCollector {
                id: stdout
            }
            stderr: StdioCollector {
                id: stderr
            }

            onExited: code => // qmllint disable signal-handler-parameters
                Qt.callLater(() => proc.finish({
                        success: code === 0,
                        output: stdout.text ?? "",
                        error: stderr.text || (code !== 0 ? `ironlandctl exited with code ${code}` : ""),
                        exitCode: code
                    }))
        }
    }

    LoggingCategory {
        id: lc

        name: "caelestia.qml.services.ironlandctl"
        defaultLogLevel: LoggingCategory.Info
    }
}
