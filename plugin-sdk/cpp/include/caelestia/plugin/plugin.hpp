#pragma once

#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "settings.hpp"
#include "ui.hpp"

// SDK for caelestia-shell plugins, API version 1.
//
// A plugin is an executable that implements Plugin and passes it to run().
// The SDK serves the gRPC contract from plugin-sdk/proto, performs the
// version handshake and turns the protocol into virtual calls. The shell
// starts the process with:
//
//   CAELESTIA_PLUGIN_SOCKET   unix socket path to serve on
//   CAELESTIA_PLUGIN_ID       the id from the plugin's manifest
//
// Plugin methods are called from gRPC worker threads, possibly concurrently:
// guard your state.
namespace caelestia::plugin {

struct ApiVersion {
    unsigned major;
    unsigned minor;
};

// The API version this SDK implements. Bumped together with
// plugin-sdk/proto/caelestia_plugin.proto, see the versioning rules there.
inline constexpr ApiVersion kApiVersion{ 1, 0 };

// A plugin built against `plugin` can run on a host implementing `host`.
[[nodiscard]] constexpr bool isCompatible(ApiVersion plugin, ApiVersion host) {
    return plugin.major == host.major && plugin.minor <= host.minor;
}

struct DashboardTab {
    // Passed back to Plugin::view() / Plugin::action().
    std::string viewId;
    std::string title;
    // Material Symbols name.
    std::string icon;
};

struct PluginInfo {
    std::string version;
    std::vector<DashboardTab> dashboardTabs;
    SettingsSchema settings;
};

namespace detail {

struct Hub;

}

// Handle for talking to the shell outside of a request. Cheap to copy, safe
// to use from any thread.
class Context {
public:
    // Replaces what the shell shows for a view. Call after any state change.
    void pushView(const ui::View& view) const;
    // Shows a toast.
    void notify(const ui::Notification& notification) const;
    // The latest setting values.
    [[nodiscard]] Settings settings() const;
    // Directory the plugin may keep state in (empty before the handshake).
    [[nodiscard]] std::filesystem::path dataDir() const;

private:
    friend struct detail::Hub;

    explicit Context(std::shared_ptr<detail::Hub> hub)
        : m_hub(std::move(hub)) {}

    std::shared_ptr<detail::Hub> m_hub;
};

class Plugin {
public:
    virtual ~Plugin() = default;

    virtual PluginInfo info() const = 0;

    // Called once the handshake succeeded. Keep the Context to push updates.
    virtual void start(Context) {}

    // Renders `viewId`, one of the ids declared in info().
    virtual std::optional<ui::View> view(std::string_view viewId) = 0;

    // A widget with an action id was used. Return an error message to report
    // a failure.
    virtual std::optional<std::string> action(
        std::string_view viewId, std::string_view actionId, std::string_view payload) {
        (void)viewId;
        (void)actionId;
        (void)payload;
        return std::nullopt;
    }

    // New setting values arrived (also once right after start()).
    virtual void settingsChanged(const Settings&) {}

    // The shell asked the plugin to exit; persist state here.
    virtual void shutdown() {}
};

// Serves `plugin` on $CAELESTIA_PLUGIN_SOCKET until the shell asks it to
// shut down or the process gets SIGTERM/SIGINT. Returns the exit code.
int run(Plugin& plugin);

// Like run() with an explicit socket path (used by tests).
int serve(Plugin& plugin, const std::filesystem::path& socket);

} // namespace caelestia::plugin
