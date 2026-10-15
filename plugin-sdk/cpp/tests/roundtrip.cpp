// Starts a plugin from the SDK on a temp socket and drives it with the raw
// generated client, the way the shell does.

#include <caelestia/plugin/plugin.hpp>
#include <grpcpp/grpcpp.h>
#include <unistd.h>

#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <thread>

#include "caelestia_plugin.grpc.pb.h"

namespace wire = caelestia::plugin::v1;
using namespace caelestia::plugin;

#define CHECK(cond)                                                                                                    \
    do {                                                                                                               \
        if (!(cond)) {                                                                                                 \
            std::cerr << "CHECK failed: " #cond " (" << __FILE__ << ":" << __LINE__ << ")\n";                          \
            std::exit(1);                                                                                              \
        }                                                                                                              \
    } while (0)

class Demo final : public Plugin {
public:
    PluginInfo info() const override {
        return { .version = "0.3.1",
            .dashboardTabs = { { "main", "Demo", "star" } },
            .settings = { .sections = { Section{
                              .title = "General",
                              .fields = { NumberField{
                                  .key = "n", .label = "N", .defaultValue = 5, .min = 1, .max = 10, .integer = true } },
                          } } } };
    }

    void start(Context context) override {
        const std::lock_guard lock(mutex);
        ctx = std::move(context);
    }

    std::optional<ui::View> view(std::string_view id) override {
        if (id != "main") {
            return std::nullopt;
        }
        return ui::View{ "main", ui::Column{ .children = { ui::Text{ .text = "hi" } } } };
    }

    std::optional<std::string> action(std::string_view, std::string_view action, std::string_view payload) override {
        if (action == "fail") {
            return "nope";
        }
        const std::lock_guard lock(mutex);
        seen.push_back(std::string(action) + ":" + std::string(payload));
        ctx->pushView({ "main", ui::Text{ .text = "updated" } });
        ctx->notify({ .title = "t", .body = "b" });
        return std::nullopt;
    }

    void settingsChanged(const Settings& s) override {
        const std::lock_guard lock(mutex);
        seen.push_back("n=" + std::to_string(static_cast<int>(s.getNumber("n", 0))));
    }

    std::mutex mutex;
    std::optional<Context> ctx;
    std::vector<std::string> seen;
};

static wire::HandshakeRequest handshake(unsigned major, unsigned minor) {
    wire::HandshakeRequest req;
    req.mutable_host_api_version()->set_major(major);
    req.mutable_host_api_version()->set_minor(minor);
    req.set_data_dir("/tmp/x");
    return req;
}

int main() {
    static_assert(isCompatible({ 1, 0 }, { 1, 4 }));
    static_assert(!isCompatible({ 1, 2 }, { 1, 1 }));
    static_assert(!isCompatible({ 1, 0 }, { 2, 0 }));

    const auto dir = std::filesystem::temp_directory_path() / ("caelestia-sdk-cpp-test-" + std::to_string(::getpid()));
    std::filesystem::create_directories(dir);
    const auto socket = dir / "p.sock";

    Demo demo;
    std::thread server([&] {
        CHECK(serve(demo, socket) == 0);
    });

    grpc::ChannelArguments args;
    args.SetString(GRPC_ARG_DEFAULT_AUTHORITY, "localhost");
    auto channel = grpc::CreateCustomChannel("unix://" + socket.string(), grpc::InsecureChannelCredentials(), args);
    CHECK(channel->WaitForConnected(std::chrono::system_clock::now() + std::chrono::seconds(5)));
    auto stub = wire::Plugin::NewStub(channel);

    {
        grpc::ClientContext ctx;
        wire::HandshakeReply reply;
        const auto status = stub->Handshake(&ctx, handshake(2, 0), &reply);
        CHECK(status.error_code() == grpc::StatusCode::FAILED_PRECONDITION);
    }

    {
        grpc::ClientContext ctx;
        wire::HandshakeReply reply;
        CHECK(stub->Handshake(&ctx, handshake(1, 0), &reply).ok());
        CHECK(reply.plugin_version() == "0.3.1");
        CHECK(reply.api_version().major() == kApiVersion.major);
        CHECK(reply.contributions().dashboard_tabs(0).title() == "Demo");
        CHECK(reply.settings_schema().sections(0).fields(0).key() == "n");
        CHECK(reply.settings_schema().sections(0).fields(0).number().integer());
    }

    grpc::ClientContext eventsCtx;
    auto events = stub->Events(&eventsCtx, wire::EventsRequest());
    std::this_thread::sleep_for(std::chrono::milliseconds(100)); // let the subscription register

    {
        grpc::ClientContext ctx;
        wire::ApplySettingsRequest req;
        wire::SettingValue v;
        v.set_number_value(7);
        (*req.mutable_values())["n"] = v;
        wire::ApplySettingsReply reply;
        CHECK(stub->ApplySettings(&ctx, req, &reply).ok());
    }

    {
        grpc::ClientContext ctx;
        wire::GetViewRequest req;
        req.set_view_id("main");
        wire::View view;
        CHECK(stub->GetView(&ctx, req, &view).ok());
        CHECK(view.root().has_column());
        grpc::ClientContext ctx2;
        req.set_view_id("x");
        CHECK(stub->GetView(&ctx2, req, &view).error_code() == grpc::StatusCode::NOT_FOUND);
    }

    auto invoke = [&](const char* action, const char* payload) {
        grpc::ClientContext ctx;
        wire::InvokeActionRequest req;
        req.set_view_id("main");
        req.set_action_id(action);
        req.set_payload(payload);
        wire::InvokeActionReply reply;
        CHECK(stub->InvokeAction(&ctx, req, &reply).ok());
        return reply.error();
    };
    CHECK(invoke("fail", "") == "nope");
    CHECK(invoke("go", "1").empty());

    wire::PluginEvent event;
    CHECK(events->Read(&event) && event.has_view_update());
    CHECK(event.view_update().view().root().has_text());
    CHECK(events->Read(&event) && event.has_notification());

    {
        const std::lock_guard lock(demo.mutex);
        CHECK((demo.seen == std::vector<std::string>{ "n=7", "go:1" }));
    }

    {
        grpc::ClientContext ctx;
        wire::ShutdownReply reply;
        CHECK(stub->Shutdown(&ctx, wire::ShutdownRequest(), &reply).ok());
    }
    CHECK(!events->Read(&event)); // stream ends on shutdown
    server.join();
    CHECK(!std::filesystem::exists(socket));

    std::filesystem::remove_all(dir);
    std::cout << "ok\n";
    return 0;
}
