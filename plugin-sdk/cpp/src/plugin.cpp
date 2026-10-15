#include "caelestia/plugin/plugin.hpp"

#include <grpcpp/grpcpp.h>
#include <sys/stat.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <deque>
#include <iostream>
#include <list>
#include <mutex>
#include <string>
#include <thread>

#include "caelestia_plugin.grpc.pb.h"

namespace caelestia::plugin {

namespace wire = caelestia::plugin::v1;

// ---------------------------------------------------------------- settings

namespace {

template <typename T> const T* valueOf(const std::map<std::string, SettingValue>& m, const std::string& key) {
    const auto it = m.find(key);
    return it == m.end() ? nullptr : std::get_if<T>(&it->second);
}

} // namespace

bool Settings::getBool(const std::string& key, bool fallback) const {
    const bool* v = valueOf<bool>(m_values, key);
    return v ? *v : fallback;
}

double Settings::getNumber(const std::string& key, double fallback) const {
    const double* v = valueOf<double>(m_values, key);
    return v ? *v : fallback;
}

std::string Settings::getString(const std::string& key, const std::string& fallback) const {
    const std::string* v = valueOf<std::string>(m_values, key);
    return v ? *v : fallback;
}

// -------------------------------------------------------------------- hub

namespace detail {

struct Subscriber {
    std::mutex mutex;
    std::condition_variable cv;
    std::deque<wire::PluginEvent> queue;
    bool closed = false;
};

// State shared between the gRPC service and every Context copy.
struct Hub : std::enable_shared_from_this<Hub> {
    std::mutex mutex;
    std::list<std::shared_ptr<Subscriber>> subscribers;
    Settings settings;
    std::filesystem::path dataDir;

    std::mutex stopMutex;
    std::condition_variable stopCv;
    bool stopping = false;

    Context context() { return Context(shared_from_this()); }

    void publish(const wire::PluginEvent& event) {
        const std::lock_guard lock(mutex);
        for (const auto& sub : subscribers) {
            const std::lock_guard subLock(sub->mutex);
            // A shell that stopped reading must not make the plugin grow
            // without bound; it re-fetches views when it reconnects.
            if (sub->queue.size() >= 64) {
                sub->queue.pop_front();
            }
            sub->queue.push_back(event);
            sub->cv.notify_one();
        }
    }

    void stop() {
        {
            const std::lock_guard lock(stopMutex);
            stopping = true;
        }
        stopCv.notify_all();
        const std::lock_guard lock(mutex);
        for (const auto& sub : subscribers) {
            const std::lock_guard subLock(sub->mutex);
            sub->closed = true;
            sub->cv.notify_all();
        }
    }
};

} // namespace detail

namespace {

// ------------------------------------------------------------ conversions

wire::Tone toProto(ui::Tone t) {
    switch (t) {
    case ui::Tone::Primary:
        return wire::TONE_PRIMARY;
    case ui::Tone::Secondary:
        return wire::TONE_SECONDARY;
    case ui::Tone::Tertiary:
        return wire::TONE_TERTIARY;
    case ui::Tone::Muted:
        return wire::TONE_MUTED;
    case ui::Tone::Error:
        return wire::TONE_ERROR;
    case ui::Tone::Default:
        break;
    }
    return wire::TONE_DEFAULT;
}

wire::Align toProto(ui::Align a) {
    switch (a) {
    case ui::Align::Center:
        return wire::ALIGN_CENTER;
    case ui::Align::End:
        return wire::ALIGN_END;
    case ui::Align::Start:
        break;
    }
    return wire::ALIGN_START;
}

wire::TextStyle toProto(ui::TextStyle s) {
    switch (s) {
    case ui::TextStyle::Label:
        return wire::TEXT_STYLE_LABEL;
    case ui::TextStyle::Title:
        return wire::TEXT_STYLE_TITLE;
    case ui::TextStyle::Display:
        return wire::TEXT_STYLE_DISPLAY;
    case ui::TextStyle::Body:
        break;
    }
    return wire::TEXT_STYLE_BODY;
}

wire::ButtonStyle toProto(ui::ButtonStyle s) {
    switch (s) {
    case ui::ButtonStyle::Tonal:
        return wire::BUTTON_STYLE_TONAL;
    case ui::ButtonStyle::Text:
        return wire::BUTTON_STYLE_TEXT;
    case ui::ButtonStyle::Filled:
        break;
    }
    return wire::BUTTON_STYLE_FILLED;
}

wire::Urgency toProto(ui::Urgency u) {
    switch (u) {
    case ui::Urgency::Low:
        return wire::URGENCY_LOW;
    case ui::Urgency::Critical:
        return wire::URGENCY_CRITICAL;
    case ui::Urgency::Normal:
        break;
    }
    return wire::URGENCY_NORMAL;
}

void fill(wire::Node* out, const ui::Node& node);

template <typename Box> void fillBox(wire::Box* out, const Box& box) {
    out->set_spacing(box.spacing);
    out->set_align(toProto(box.align));
    out->set_fill(box.fill);
    for (const ui::Node& child : box.children) {
        fill(out->add_children(), child);
    }
}

struct NodeFiller {
    wire::Node* out;

    void operator()(const ui::Column& v) const { fillBox(out->mutable_column(), v); }

    void operator()(const ui::Row& v) const { fillBox(out->mutable_row(), v); }

    void operator()(const ui::Text& v) const {
        auto* t = out->mutable_text();
        t->set_text(v.text);
        t->set_style(toProto(v.style));
        t->set_tone(toProto(v.tone));
    }

    void operator()(const ui::Icon& v) const {
        auto* i = out->mutable_icon();
        i->set_name(v.name);
        i->set_size(v.size);
        i->set_tone(toProto(v.tone));
    }

    void operator()(const ui::Progress& v) const {
        auto* p = out->mutable_progress();
        // NaN compares false both ways, so it ends up 0.
        p->set_fraction(v.fraction > 1.0 ? 1.0 : (v.fraction > 0.0 ? v.fraction : 0.0));
        p->set_shape(
            v.shape == ui::ProgressShape::Linear ? wire::PROGRESS_SHAPE_LINEAR : wire::PROGRESS_SHAPE_CIRCULAR);
        p->set_label(v.label);
        p->set_sublabel(v.sublabel);
        p->set_tone(toProto(v.tone));
        p->set_size(v.size);
    }

    void operator()(const ui::Button& v) const {
        auto* b = out->mutable_button();
        b->set_label(v.label);
        b->set_icon(v.icon);
        b->set_action_id(v.actionId);
        b->set_payload(v.payload);
        b->set_style(toProto(v.style));
        b->set_disabled(v.disabled);
    }

    void operator()(const ui::Spacer& v) const { out->mutable_spacer()->set_size(v.size); }

    void operator()(const ui::Divider&) const { out->mutable_divider(); }
};

void fill(wire::Node* out, const ui::Node& node) {
    std::visit(NodeFiller{ out }, node.value);
}

void fill(wire::View* out, const ui::View& view) {
    out->set_view_id(view.id);
    fill(out->mutable_root(), view.root);
}

struct FieldFiller {
    wire::SettingField* out;

    template <typename F> void common(const F& f) const {
        out->set_key(f.key);
        out->set_label(f.label);
        out->set_description(f.description);
    }

    void operator()(const ToggleField& f) const {
        common(f);
        out->mutable_toggle()->set_default_value(f.defaultValue);
    }

    void operator()(const NumberField& f) const {
        common(f);
        auto* n = out->mutable_number();
        n->set_default_value(f.defaultValue);
        n->set_min(f.min);
        n->set_max(f.max);
        n->set_step(f.step);
        n->set_unit(f.unit);
        n->set_integer(f.integer);
    }

    void operator()(const TextField& f) const {
        common(f);
        auto* t = out->mutable_text();
        t->set_default_value(f.defaultValue);
        t->set_placeholder(f.placeholder);
    }

    void operator()(const ChoiceField& f) const {
        common(f);
        auto* c = out->mutable_choice();
        c->set_default_value(f.defaultValue);
        for (const Choice& option : f.options) {
            auto* o = c->add_options();
            o->set_value(option.value);
            o->set_label(option.label);
        }
    }
};

Settings fromProto(const google::protobuf::Map<std::string, wire::SettingValue>& values) {
    std::map<std::string, SettingValue> out;
    for (const auto& [key, value] : values) {
        switch (value.value_case()) {
        case wire::SettingValue::kBoolValue:
            out.emplace(key, value.bool_value());
            break;
        case wire::SettingValue::kNumberValue:
            out.emplace(key, value.number_value());
            break;
        case wire::SettingValue::kStringValue:
            out.emplace(key, value.string_value());
            break;
        case wire::SettingValue::VALUE_NOT_SET:
            break;
        }
    }
    return Settings(std::move(out));
}

// ---------------------------------------------------------------- service

class Service final : public wire::Plugin::Service {
public:
    Service(Plugin& plugin, std::shared_ptr<detail::Hub> hub)
        : m_plugin(plugin)
        , m_hub(std::move(hub)) {}

    grpc::Status Handshake(
        grpc::ServerContext*, const wire::HandshakeRequest* req, wire::HandshakeReply* reply) override {
        const ApiVersion host{ req->host_api_version().major(), req->host_api_version().minor() };
        if (!isCompatible(kApiVersion, host)) {
            return { grpc::StatusCode::FAILED_PRECONDITION,
                "plugin needs API " + std::to_string(kApiVersion.major) + "." + std::to_string(kApiVersion.minor) +
                    " but the shell provides " + std::to_string(host.major) + "." + std::to_string(host.minor) };
        }

        {
            const std::lock_guard lock(m_hub->mutex);
            m_hub->dataDir = req->data_dir();
        }

        const PluginInfo info = m_plugin.info();
        reply->mutable_api_version()->set_major(kApiVersion.major);
        reply->mutable_api_version()->set_minor(kApiVersion.minor);
        reply->set_plugin_version(info.version);
        for (const DashboardTab& tab : info.dashboardTabs) {
            auto* t = reply->mutable_contributions()->add_dashboard_tabs();
            t->set_view_id(tab.viewId);
            t->set_title(tab.title);
            t->set_icon(tab.icon);
        }
        auto* schema = reply->mutable_settings_schema();
        for (const Section& section : info.settings.sections) {
            auto* s = schema->add_sections();
            s->set_title(section.title);
            s->set_description(section.description);
            for (const Field& field : section.fields) {
                std::visit(FieldFiller{ s->add_fields() }, field);
            }
        }

        if (!m_started.exchange(true)) {
            m_plugin.start(m_hub->context());
        }
        return grpc::Status::OK;
    }

    grpc::Status ApplySettings(
        grpc::ServerContext*, const wire::ApplySettingsRequest* req, wire::ApplySettingsReply*) override {
        Settings settings = fromProto(req->values());
        {
            const std::lock_guard lock(m_hub->mutex);
            m_hub->settings = settings;
        }
        m_plugin.settingsChanged(settings);
        return grpc::Status::OK;
    }

    grpc::Status GetView(grpc::ServerContext*, const wire::GetViewRequest* req, wire::View* reply) override {
        const auto view = m_plugin.view(req->view_id());
        if (!view) {
            return { grpc::StatusCode::NOT_FOUND, "no view '" + req->view_id() + "'" };
        }
        fill(reply, *view);
        return grpc::Status::OK;
    }

    grpc::Status InvokeAction(
        grpc::ServerContext*, const wire::InvokeActionRequest* req, wire::InvokeActionReply* reply) override {
        if (const auto error = m_plugin.action(req->view_id(), req->action_id(), req->payload())) {
            reply->set_error(*error);
        }
        return grpc::Status::OK;
    }

    grpc::Status Events(
        grpc::ServerContext* ctx, const wire::EventsRequest*, grpc::ServerWriter<wire::PluginEvent>* writer) override {
        auto sub = std::make_shared<detail::Subscriber>();
        {
            const std::lock_guard lock(m_hub->mutex);
            m_hub->subscribers.push_back(sub);
        }

        for (;;) {
            wire::PluginEvent event;
            {
                std::unique_lock lock(sub->mutex);
                // Wake up periodically to notice a vanished client.
                sub->cv.wait_for(lock, std::chrono::milliseconds(250), [&] {
                    return !sub->queue.empty() || sub->closed;
                });
                if (sub->queue.empty()) {
                    if (sub->closed || ctx->IsCancelled()) {
                        break;
                    }
                    continue;
                }
                event = std::move(sub->queue.front());
                sub->queue.pop_front();
            }
            if (!writer->Write(event)) {
                break;
            }
        }

        const std::lock_guard lock(m_hub->mutex);
        m_hub->subscribers.remove(sub);
        return grpc::Status::OK;
    }

    grpc::Status Shutdown(grpc::ServerContext*, const wire::ShutdownRequest*, wire::ShutdownReply*) override {
        m_plugin.shutdown();
        m_hub->stop();
        return grpc::Status::OK;
    }

private:
    Plugin& m_plugin;
    std::shared_ptr<detail::Hub> m_hub;
    std::atomic<bool> m_started = false;
};

// Set from the signal handler (lock-free atomics are async-signal-safe) and
// polled by the watcher thread, which does the real stop.
std::atomic<bool> g_signalled = false;

void onSignal(int) {
    g_signalled = true;
}

} // namespace

// ---------------------------------------------------------------- context

void Context::pushView(const ui::View& view) const {
    wire::PluginEvent event;
    fill(event.mutable_view_update()->mutable_view(), view);
    m_hub->publish(event);
}

void Context::notify(const ui::Notification& n) const {
    wire::PluginEvent event;
    auto* out = event.mutable_notification();
    out->set_title(n.title);
    out->set_body(n.body);
    out->set_icon(n.icon);
    out->set_urgency(toProto(n.urgency));
    m_hub->publish(event);
}

Settings Context::settings() const {
    const std::lock_guard lock(m_hub->mutex);
    return m_hub->settings;
}

std::filesystem::path Context::dataDir() const {
    const std::lock_guard lock(m_hub->mutex);
    return m_hub->dataDir;
}

// -------------------------------------------------------------------- run

int serve(Plugin& plugin, const std::filesystem::path& socket) {
    std::error_code ec;
    std::filesystem::remove(socket, ec); // left behind by a previous run

    auto hub = std::make_shared<detail::Hub>();
    Service service(plugin, hub);

    grpc::ServerBuilder builder;
    builder.AddListeningPort("unix:" + socket.string(), grpc::InsecureServerCredentials());
    builder.RegisterService(&service);
    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server) {
        std::cerr << "failed to listen on " << socket << '\n';
        return 1;
    }
    // The plugin acts for the user: nobody else may connect.
    ::chmod(socket.c_str(), 0600);

    g_signalled = false;
    std::signal(SIGTERM, onSignal);
    std::signal(SIGINT, onSignal);

    // Translates the signal flag / Shutdown RPC into a server shutdown.
    std::thread watcher([&] {
        std::unique_lock lock(hub->stopMutex);
        while (!hub->stopCv.wait_for(lock, std::chrono::milliseconds(100), [&] {
            return hub->stopping || g_signalled.load();
        })) {
        }
        lock.unlock();
        hub->stop();
        server->Shutdown(std::chrono::system_clock::now() + std::chrono::seconds(2));
    });

    server->Wait();
    {
        const std::lock_guard lock(hub->stopMutex);
        hub->stopping = true;
    }
    hub->stopCv.notify_all();
    watcher.join();

    std::filesystem::remove(socket, ec);
    return 0;
}

int run(Plugin& plugin) {
    const char* socket = std::getenv("CAELESTIA_PLUGIN_SOCKET");
    if (!socket || !*socket) {
        std::cerr << "CAELESTIA_PLUGIN_SOCKET is not set: plugins are started by caelestia-shell\n";
        return 1;
    }
    return serve(plugin, socket);
}

} // namespace caelestia::plugin
