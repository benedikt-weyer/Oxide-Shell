# Caelestia plugin SDK

Plugins extend the shell without touching its code: a plugin is a separate
program that talks to the shell over gRPC (on a unix socket) and can

- add a **tab to the dashboard**, described declaratively (the shell draws it,
  so it always matches the theme),
- add a **button to the bar** (next to the notifications button) that opens a
  **panel** drawn from a view of its own (API 1.2),
- get a **settings page in Nexus** generated from a schema it declares,
- show **toasts**.

Plugins are installed, enabled, restarted and removed from
**Nexus → Plugins**, and come from *sources* (a directory or an `index.json`).
The first-party source that ships with the shell is always present; see
[`plugins/pomodoro`](../plugins/pomodoro) for a complete example.

```
plugin-sdk/
  proto/caelestia_plugin.proto   the API: single source of truth for everything below
  rust/                          caelestia-plugin-sdk   (crate)
  cpp/                           Caelestia::PluginSdk    (CMake library) + example + test
plugins/
  pomodoro/                      first-party plugin (Rust): a timer on the dashboard
  nix/                           first-party plugin (Rust): flake update / rebuild on the dashboard
  ai/                            first-party plugin (Rust): AI chat in a bar panel
plugin/src/Caelestia/Plugins/    the shell side (import Caelestia.Plugins)
```

> **Security:** a plugin runs with your user's permissions, like any program
> you start. Only install plugins from sources you trust.

## How it works

```
 shell (PluginManager)                         plugin process
 ─────────────────────                         ───────────────
 spawn exec, env:
   CAELESTIA_PLUGIN_SOCKET=$XDG_RUNTIME_DIR/caelestia-plugins/<id>.sock
   CAELESTIA_PLUGIN_ID=<id>
 Handshake(host api, data dir)  ───────────▶   version check, returns tabs + settings schema
 Events()  (server stream)      ◀═══════════   ViewUpdate / Notification, whenever it likes
 ApplySettings(all values)      ───────────▶   on start and whenever the user changes one
 GetView(view)                  ───────────▶   current widget tree
 InvokeAction(view, action)     ───────────▶   a button was pressed
 Shutdown()                     ───────────▶   exit cleanly (SIGTERM does the same)
```

The plugin is the gRPC *server*; the shell is its only client. Everything the
plugin wants to push goes through the `Events` stream, so it never has to find
the shell. The socket is `0600`.

## API versioning

`caelestia_plugin.proto` is versioned like a library:

| change                                                       | version                     |
|--------------------------------------------------------------|-----------------------------|
| breaking (remove/renumber a field, change semantics)         | new package `v2`, major + 1 |
| additive (new field, oneof member, enum value, RPC, widget)  | minor + 1                   |

Both sides send their version in `Handshake`. A plugin built against
`major.minor` runs on a shell providing `M.m` iff `major == M && minor <= m`.
Unknown fields, widgets, setting kinds and enum values must be ignored, which
is what makes additive changes safe for old plugins *and* old shells.

The constants live in `caelestia_plugin_sdk::API_VERSION` (Rust),
`caelestia::plugin::kApiVersion` (C++) and `hostApiVersion` in
`plugin/src/Caelestia/Plugins/pluginstore.hpp`; bump them together with the
proto. The manifest declares the API a plugin needs, so the shell can refuse
(and Nexus can explain) an incompatible plugin before starting it.

## Package layout and manifest

An installed plugin is a directory `~/.local/share/caelestia/plugins/<id>/`:

```
manifest.json
bin/my-plugin          # whatever "exec" says, relative to the directory
```

```json
{
    "id": "pomodoro",
    "name": "Pomodoro Timer",
    "version": "0.1.0",
    "description": "Focus/break timer with its own dashboard tab.",
    "author": "Caelestia",
    "icon": "timer",
    "api": { "major": 1, "minor": 0 },
    "exec": "bin/caelestia-plugin-pomodoro"
}
```

`id` is `[a-z0-9][a-z0-9._-]*` (max 48), `exec` must be a relative path inside
the package. Settings live in `~/.config/caelestia/plugins/<id>/settings.json`
(only values the user changed), state you want to keep goes in the data
directory the shell passes in the handshake
(`~/.local/share/caelestia/plugin-data/<id>`, also the working directory).

## Sources

A source is added in *Nexus → Plugins → Plugin sources* and is one of

- a **directory** with one sub-directory per plugin (each with a
  `manifest.json`) — this is how the bundled source works,
- an **`index.json`** (local path, `file://` or `https://`):

```json
{
    "plugins": [
        {
            "id": "pomodoro", "name": "Pomodoro Timer", "version": "0.1.0",
            "exec": "bin/caelestia-plugin-pomodoro", "api": { "major": 1, "minor": 0 },
            "archive": "pomodoro-0.1.0.tar.gz",
            "sha256": "…"
        },
        { "id": "local-one", "version": "1", "exec": "bin/x", "api": { "major": 1 }, "path": "local-one" }
    ]
}
```

Entries are a manifest plus either `path` (a directory next to the index,
local sources only) or `archive` (`.tar.gz`, relative to the index or a full
URL; optional `sha256` is verified before anything is extracted). Archives
are listed first and rejected if any member is absolute or contains `..`; the
package root is the archive root or its only directory. Installing an id that
is already installed updates it.

The default source reads `$CAELESTIA_BUNDLED_PLUGINS_DIR` (set by the Nix
wrapper; `scripts/build-plugins.sh` fills `build/plugins` for development).

## Writing a plugin in Rust

```toml
[dependencies]
caelestia-plugin-sdk = { path = "../../plugin-sdk/rust" }   # or a git dependency
tokio = { version = "1", features = ["rt-multi-thread", "macros", "time"] }
```

```rust
use caelestia_plugin_sdk::settings::{Field, Section, SettingsSchema};
use caelestia_plugin_sdk::{async_trait, ui, Context, DashboardTab, Plugin, PluginInfo, Settings};

struct Hello;

#[async_trait]
impl Plugin for Hello {
    fn info(&self) -> PluginInfo {
        PluginInfo::new(env!("CARGO_PKG_VERSION"))
            .dashboard_tab(DashboardTab::new("main", "Hello", "waving_hand"))
            .settings(SettingsSchema::new().section(
                Section::new("Greeting").field(Field::text("name", "Name", "world")),
            ))
    }

    async fn view(&self, view_id: &str) -> Option<ui::View> {
        (view_id == "main").then(|| {
            ui::View::new("main", ui::column().spacing(12.0)
                .child(ui::text("Hello!").style(ui::TextStyle::Title))
                .child(ui::button("Click").action("click")))
        })
    }

    async fn action(&self, _view: &str, action: &str, _payload: &str) -> Result<(), String> {
        println!("{action}");           // plugin stderr/stdout ends up in the shell's journal
        Ok(())
    }
}

fn main() {
    caelestia_plugin_sdk::main(Hello);
}
```

To change what is shown later, keep the `Context` from `Plugin::start` and
call `ctx.push_view(view)` (or `ctx.notify(..)` for a toast). Tests that
drive a plugin through the real protocol: `plugin-sdk/rust/tests/roundtrip.rs`.

## Writing a plugin in C++

```cmake
add_subdirectory(plugin-sdk/cpp)            # or enable it with ENABLE_MODULES=…;plugin-sdk-cpp
target_link_libraries(my-plugin PRIVATE Caelestia::PluginSdk)
```

Views and schemas are C++20 designated-initializer literals, see
[`cpp/examples/hello/main.cpp`](cpp/examples/hello/main.cpp):

```cpp
#include <caelestia/plugin/plugin.hpp>
using namespace caelestia::plugin;

class Hello final : public Plugin {
    PluginInfo info() const override {
        return {.version = "0.1.0", .dashboardTabs = {{"main", "Hello", "waving_hand"}}};
    }
    std::optional<ui::View> view(std::string_view id) override {
        if (id != "main") return std::nullopt;
        return ui::View{"main", ui::Column{.spacing = 12, .children = {
            ui::Text{.text = "Hello!", .style = ui::TextStyle::Title},
            ui::Button{.label = "Click", .actionId = "click"}}}};
    }
};

int main() { Hello plugin; return run(plugin); }
```

Plugin methods are called from gRPC worker threads, possibly concurrently.
`-Wextra` warns about omitted designated fields (clang:
`-Wmissing-designated-field-initializers`, gcc: `-Wmissing-field-initializers`);
disable that warning for plugin code.

## Widgets

| widget     | purpose / main fields                                                        |
|------------|-------------------------------------------------------------------------------|
| `column`, `row` | containers: `spacing`, cross-axis `align`, `fill`, children; 1.1: `surface` (`card`/`card_low`) + `padding` |
| `text`     | `text`, style (`body`/`label`/`title`/`display`; 1.1: `mono`/`headline`), tone; 1.1: `fill` + `elide` |
| `icon`     | Material Symbols `name`, `size`, tone                                         |
| `progress` | `fraction` 0‥1, circular or linear, `label`/`sublabel`, tone, `size`; 1.1: `indeterminate`, `fill` |
| `button`   | `label`, `icon`, `action_id`, `payload`, style (`filled`/`tonal`/`text`), `disabled`; 1.1: `fill`; an icon without a label is a round icon button |
| `spacer`   | fixed `size` px, or flexible when 0                                           |
| `divider`  | thin line                                                                     |
| `spinner`  | 1.1: small animated activity indicator, `size`                                |
| `log_view` | 1.1: scrolling monospace `lines` (`text`, `is_error`), `height`, `placeholder`; follows the newest line |
| `markdown` | 1.2: Markdown `text` (selectable, links open), tone |
| `text_input` | 1.2: a text field. Enter / the submit button send the text as the payload of `action_id` and empty the field; the plugin only changes it through `reset_token`. `placeholder`, `multiline` (Shift+Enter = line break), `max_lines`, `submit_icon`, `disabled`, `autofocus` |
| `select` | 1.2: a chip that opens a scrolling list of `options` (`value`, `label`, `icon`, `description`); the picked value is the payload of `action_id`. `selected`, `icon`, `placeholder`, `title`, `disabled` |
| `scroll` | 1.2: scrolls its `child` vertically. `height` px, or `expand` to take the rest of the parent column; `stick_to_end` follows new content until the user scrolls up |

Tones: default, primary, secondary, tertiary, muted, error.

### Keys (API 1.2)

A view update replaces the whole tree, but the shell matches the nodes of the
new tree to the old one and only updates the widgets that changed. Nodes are
matched by `Node.key` among their siblings (by position when it is empty), so
give a key to everything that has state of its own or whose position can change
(a list of messages, a text field, a scroll area). That is what keeps what the
user is typing and where they scrolled to while a view is pushed ten times a
second. `ui::keyed("name", widget)` sets it on any builder.

## Panels (API 1.2)

```rust
PluginInfo::new(env!("CARGO_PKG_VERSION"))
    .panel(Panel::new("chat", "AI chat", "auto_awesome"))
```

adds a button with that icon to the bar, next to the notifications button
(switch them all off with `bar.pluginButtons`). It opens a panel at the top of
the screen with a header drawn by the shell (title, a button for the plugin's
settings page, a close button) and the view `chat` below it. The view is
fetched with `Plugin::view` like a dashboard tab's, pushed with
`Context::push_view`, and its root column is as big as the panel, so a
`scroll(..).expand()` in it reaches the bottom. Button, `text_input` and
`select` report through `Plugin::action`.

## Settings schema

Declared in the handshake, rendered by Nexus (toggle, number as stepper or
slider, text, choice), stored by the shell, delivered as a complete set of
values (defaults filled in, numbers clamped to their range) through
`ApplySettings`. Because the shell caches the schema, the settings page also
works while the plugin is stopped; edits are applied at the next start.

A text field can be `secret` (1.2): shown as dots while typing, for API keys.
The value is still stored as plain text in
`~/.config/caelestia/plugins/<id>/settings.json`, so keep that file private.

## Testing

```sh
cargo test --manifest-path plugin-sdk/rust/Cargo.toml          # SDK against a real server
cargo test --manifest-path plugins/pomodoro/Cargo.toml         # timer logic
cargo test --manifest-path plugins/nix/Cargo.toml              # build/rebuild state and view
cargo test --manifest-path plugins/ai/Cargo.toml               # providers, chat state, view, and streaming against a fake server
cmake -S plugin-sdk/cpp -B /tmp/sdk && cmake --build /tmp/sdk && ctest --test-dir /tmp/sdk
scripts/build-plugins.sh                                       # fills build/plugins
cmake -B build -DCAELESTIA_BUILD_PLUGIN_TESTS=ON && cmake --build build
ctest --test-dir build/plugin/src/Caelestia/Plugins            # shell side, real pomodoro binary
```

`nix build .#plugin-pomodoro .#plugin-nix .#plugin-ai` and `nix build .#plugin-sdk-cpp` run the same
unit tests inside the sandbox.
