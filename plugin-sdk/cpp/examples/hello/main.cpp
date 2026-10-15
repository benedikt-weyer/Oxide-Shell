// Minimal C++ plugin: a dashboard tab with a click counter and one setting.
//
// Install it by copying the binary next to a manifest.json, see
// plugin-sdk/README.md.

#include <caelestia/plugin/plugin.hpp>

#include <mutex>
#include <optional>

using namespace caelestia::plugin;

class Hello final : public Plugin {
public:
    PluginInfo info() const override {
        return {
            .version = "0.1.0",
            .dashboardTabs = { { .viewId = "main", .title = "Hello", .icon = "waving_hand" } },
            .settings = { .sections = { Section{
                              .title = "Greeting",
                              .fields = { TextField{ .key = "name", .label = "Name", .defaultValue = "world" } },
                          } } },
        };
    }

    void start(Context ctx) override {
        const std::lock_guard lock(m_mutex);
        m_ctx = std::move(ctx);
    }

    std::optional<ui::View> view(std::string_view viewId) override {
        if (viewId != "main") {
            return std::nullopt;
        }
        const std::lock_guard lock(m_mutex);
        return render();
    }

    std::optional<std::string> action(std::string_view, std::string_view actionId, std::string_view) override {
        const std::lock_guard lock(m_mutex);
        if (actionId != "click") {
            return "unknown action";
        }
        ++m_clicks;
        push();
        return std::nullopt;
    }

    void settingsChanged(const Settings& settings) override {
        const std::lock_guard lock(m_mutex);
        m_name = settings.getString("name", "world");
        push();
    }

private:
    ui::View render() const {
        using namespace ui;
        return View{ "main",
            Column{ .spacing = 12,
                .align = Align::Center,
                .children = {
                    Text{ .text = "Hello, " + m_name + "!", .style = TextStyle::Title },
                    Text{ .text = "Clicked " + std::to_string(m_clicks) + " times", .tone = Tone::Muted },
                    Button{ .label = "Click me", .icon = "ads_click", .actionId = "click" },
                } } };
    }

    void push() const {
        if (m_ctx) {
            m_ctx->pushView(render());
        }
    }

    mutable std::mutex m_mutex;
    std::optional<Context> m_ctx;
    std::string m_name = "world";
    int m_clicks = 0;
};

int main() {
    Hello plugin;
    return run(plugin);
}
