pragma Singleton

import Quickshell
import Caelestia.Config
import Caelestia.Models
import qs.services
import qs.utils

Searcher {
    id: root

    // Wraps a command in the user's login shell, so it inherits a real PATH.
    // This shell is commonly started by a systemd user unit whose own
    // Environment=PATH is minimal (just enough for the shell itself), so
    // launching by bare command name - as every DesktopEntry's Exec= does -
    // would otherwise fail to find apps that aren't on that stripped-down
    // PATH, even though they're installed and on the user's normal one.
    function loginShellWrap(command: list<string>): list<string> {
        const shell = Quickshell.env("SHELL") || "/bin/sh";
        const quoted = command.map(arg => `'${arg.replace(/'/g, `'\\''`)}'`).join(" ");
        return [shell, "-lc", quoted];
    }

    function launch(entry: DesktopEntry): void {
        appDb.incrementFrequency(entry.id);

        const command = entry.runInTerminal ? [...GlobalConfig.general.apps.terminal, `${Quickshell.shellDir}/assets/wrap_term_launch.sh`, ...entry.command] : entry.command;

        Quickshell.execDetached({
            command: loginShellWrap(command),
            workingDirectory: entry.workingDirectory
        });
    }

    // Runs the entry inside a virtual machine instead (see VmLauncher): a
    // throw-away one, or with `persistent` one that keeps the app's state.
    function launchVirtual(entry: DesktopEntry, persistent: bool): void {
        appDb.incrementFrequency(entry.id);
        VmLauncher.launch(entry, persistent);
    }

    function search(search: string): var {
        const prefix = GlobalConfig.launcher.specialPrefix;

        if (search.startsWith(`${prefix}i `)) {
            keys = ["id", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}c `)) {
            keys = ["categories", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}d `)) {
            keys = ["comment", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}e `)) {
            keys = ["execString", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}w `)) {
            keys = ["startupClass", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}g `)) {
            keys = ["genericName", "name"];
            weights = [0.9, 0.1];
        } else if (search.startsWith(`${prefix}k `)) {
            keys = ["keywords", "name"];
            weights = [0.9, 0.1];
        } else {
            keys = ["name"];
            weights = [1];

            if (!search.startsWith(`${prefix}t `))
                return query(search).map(e => e.entry);
        }

        const results = query(search.slice(prefix.length + 2)).map(e => e.entry);
        if (search.startsWith(`${prefix}t `))
            return results.filter(a => a.runInTerminal);
        return results;
    }

    function selector(item: var): string {
        return keys.map(k => item[k]).join(" ");
    }

    list: appDb.apps
    useFuzzy: GlobalConfig.launcher.useFuzzy.apps

    AppDb {
        id: appDb

        path: `${Paths.state}/apps.sqlite`
        favouriteApps: GlobalConfig.launcher.favouriteApps
        entries: DesktopEntries.applications.values.filter(a => !Strings.testRegexList(GlobalConfig.launcher.hiddenApps, a.id))
    }
}
