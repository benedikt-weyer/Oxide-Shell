#include "pluginhost.hpp"

#include <qdir.h>
#include <qfileinfo.h>
#include <qtconcurrentrun.h>

#include <grpcpp/grpcpp.h>
#include <unistd.h>

#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <utility>

#include "caelestia_plugin.grpc.pb.h"
#include "pluginstore.hpp"

namespace caelestia::plugins {

using Qt::StringLiterals::operator""_s;

namespace wire = caelestia::plugin::v1;

// Shared between the main thread, the session thread and RPC tasks, so a
// task that outlives its host still has valid memory to look at.
struct Session {
    std::atomic<bool> cancelled = false;
    std::mutex mutex;
    std::shared_ptr<grpc::Channel> channel;
    std::shared_ptr<wire::Plugin::Stub> stub;
    grpc::ClientContext* eventsContext = nullptr; // guarded by mutex, set while the stream is open
    grpc::ClientContext* callContext = nullptr;   // guarded by mutex, set while a queued RPC runs

    // RPCs to one plugin run strictly in order on one worker: a settings
    // change must not overtake the one before it.
    std::condition_variable queueCv;
    std::deque<std::function<void()>> tasks; // guarded by mutex
    bool quit = false;                       // guarded by mutex
    std::thread worker;

    void startWorker() {
        worker = std::thread([this] {
            for (;;) {
                std::function<void()> task;
                {
                    std::unique_lock lock(mutex);
                    queueCv.wait(lock, [this] {
                        return quit || !tasks.empty();
                    });
                    if (quit) {
                        return;
                    }
                    task = std::move(tasks.front());
                    tasks.pop_front();
                }
                task();
            }
        });
    }

    // Tasks must not own a shared_ptr to the session (it owns them).
    void enqueue(std::function<void()> task) {
        {
            const std::lock_guard lock(mutex);
            tasks.push_back(std::move(task));
        }
        queueCv.notify_one();
    }

    void cancel() {
        cancelled = true;
        const std::lock_guard lock(mutex);
        if (eventsContext) {
            eventsContext->TryCancel();
        }
        if (callContext) {
            callContext->TryCancel();
        }
    }

    void stopWorker() {
        {
            const std::lock_guard lock(mutex);
            quit = true;
            tasks.clear();
        }
        queueCv.notify_all();
        if (worker.joinable()) {
            worker.join();
        }
    }

    std::shared_ptr<wire::Plugin::Stub> getStub() {
        const std::lock_guard lock(mutex);
        return stub;
    }

    // Runs `fn` with a fresh deadline-bound context that cancel() can abort.
    template <typename F> void call(F fn) {
        grpc::ClientContext ctx;
        ctx.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(5));
        {
            const std::lock_guard lock(mutex);
            if (cancelled) {
                return;
            }
            callContext = &ctx;
        }
        fn(ctx);
        const std::lock_guard lock(mutex);
        callContext = nullptr;
    }
};

namespace {

constexpr int k_maxRestarts = 3;
constexpr int k_stableMs = 60000;

QString toQString(const std::string& s) {
    return QString::fromStdString(s);
}

QString tone(wire::Tone t) {
    switch (t) {
    case wire::TONE_PRIMARY:
        return u"primary"_s;
    case wire::TONE_SECONDARY:
        return u"secondary"_s;
    case wire::TONE_TERTIARY:
        return u"tertiary"_s;
    case wire::TONE_MUTED:
        return u"muted"_s;
    case wire::TONE_ERROR:
        return u"error"_s;
    default:
        return u"default"_s;
    }
}

QString align(wire::Align a) {
    switch (a) {
    case wire::ALIGN_CENTER:
        return u"center"_s;
    case wire::ALIGN_END:
        return u"end"_s;
    default:
        return u"start"_s;
    }
}

// Nodes become plain JS-friendly maps: {type, ...props, children?}. Depth is
// bounded so a buggy plugin can't make the shell recurse without end.
QVariantMap nodeToVariant(const wire::Node& node, int depth);

QVariantList children(const wire::Box& box, int depth) {
    QVariantList list;
    list.reserve(box.children_size());
    for (const wire::Node& child : box.children()) {
        list.append(nodeToVariant(child, depth + 1));
    }
    return list;
}

QVariantMap boxToVariant(const QString& type, const wire::Box& box, int depth) {
    QString surface = u"none"_s;
    switch (box.surface()) {
    case wire::SURFACE_CARD:
        surface = u"card"_s;
        break;
    case wire::SURFACE_CARD_LOW:
        surface = u"cardLow"_s;
        break;
    default:
        break;
    }
    return { { u"type"_s, type }, { u"spacing"_s, box.spacing() }, { u"align"_s, align(box.align()) },
        { u"fill"_s, box.fill() }, { u"surface"_s, surface }, { u"padding"_s, box.padding() },
        { u"children"_s, children(box, depth) } };
}

QVariantMap nodeToVariant(const wire::Node& node, int depth) {
    constexpr int k_maxDepth = 24;
    if (depth > k_maxDepth) {
        return { { u"type"_s, u"spacer"_s }, { u"size"_s, 0 } };
    }

    switch (node.kind_case()) {
    case wire::Node::kColumn:
        return boxToVariant(u"column"_s, node.column(), depth);
    case wire::Node::kRow:
        return boxToVariant(u"row"_s, node.row(), depth);
    case wire::Node::kText: {
        const auto& t = node.text();
        QString style = u"body"_s;
        switch (t.style()) {
        case wire::TEXT_STYLE_LABEL:
            style = u"label"_s;
            break;
        case wire::TEXT_STYLE_TITLE:
            style = u"title"_s;
            break;
        case wire::TEXT_STYLE_DISPLAY:
            style = u"display"_s;
            break;
        case wire::TEXT_STYLE_MONO:
            style = u"mono"_s;
            break;
        case wire::TEXT_STYLE_HEADLINE:
            style = u"headline"_s;
            break;
        default:
            break;
        }
        QString elide = u"none"_s;
        if (t.elide() == wire::ELIDE_RIGHT) {
            elide = u"right"_s;
        } else if (t.elide() == wire::ELIDE_MIDDLE) {
            elide = u"middle"_s;
        }
        return { { u"type"_s, u"text"_s }, { u"text"_s, toQString(t.text()) }, { u"style"_s, style },
            { u"tone"_s, tone(t.tone()) }, { u"fill"_s, t.fill() }, { u"elide"_s, elide } };
    }
    case wire::Node::kIcon: {
        const auto& i = node.icon();
        return { { u"type"_s, u"icon"_s }, { u"name"_s, toQString(i.name()) }, { u"size"_s, i.size() },
            { u"tone"_s, tone(i.tone()) } };
    }
    case wire::Node::kProgress: {
        const auto& p = node.progress();
        return { { u"type"_s, u"progress"_s }, { u"fraction"_s, p.fraction() },
            { u"shape"_s, p.shape() == wire::PROGRESS_SHAPE_LINEAR ? u"linear"_s : u"circular"_s },
            { u"label"_s, toQString(p.label()) }, { u"sublabel"_s, toQString(p.sublabel()) },
            { u"tone"_s, tone(p.tone()) }, { u"size"_s, p.size() }, { u"indeterminate"_s, p.indeterminate() },
            { u"fill"_s, p.fill() } };
    }
    case wire::Node::kButton: {
        const auto& b = node.button();
        QString style = u"filled"_s;
        switch (b.style()) {
        case wire::BUTTON_STYLE_TONAL:
            style = u"tonal"_s;
            break;
        case wire::BUTTON_STYLE_TEXT:
            style = u"text"_s;
            break;
        default:
            break;
        }
        return { { u"type"_s, u"button"_s }, { u"label"_s, toQString(b.label()) }, { u"icon"_s, toQString(b.icon()) },
            { u"actionId"_s, toQString(b.action_id()) }, { u"payload"_s, toQString(b.payload()) },
            { u"style"_s, style }, { u"disabled"_s, b.disabled() }, { u"fill"_s, b.fill() } };
    }
    case wire::Node::kSpacer:
        return { { u"type"_s, u"spacer"_s }, { u"size"_s, node.spacer().size() } };
    case wire::Node::kDivider:
        return { { u"type"_s, u"divider"_s } };
    case wire::Node::kSpinner:
        return { { u"type"_s, u"spinner"_s }, { u"size"_s, node.spinner().size() } };
    case wire::Node::kLogView: {
        const auto& l = node.log_view();
        QVariantList lines;
        lines.reserve(l.lines_size());
        for (const wire::LogLine& line : l.lines()) {
            lines.append(QVariantMap{ { u"text"_s, toQString(line.text()) }, { u"isError"_s, line.is_error() } });
        }
        return { { u"type"_s, u"logView"_s }, { u"lines"_s, lines }, { u"height"_s, l.height() },
            { u"placeholder"_s, toQString(l.placeholder()) } };
    }
    case wire::Node::KIND_NOT_SET:
        break;
    }
    // Unknown (newer) widget: render nothing rather than failing the whole view.
    return { { u"type"_s, u"spacer"_s }, { u"size"_s, 0 } };
}

QVariantList schemaToVariant(const wire::SettingsSchema& schema) {
    QVariantList sections;
    for (const wire::SettingsSection& section : schema.sections()) {
        QVariantList fields;
        for (const wire::SettingField& f : section.fields()) {
            QVariantMap field{ { u"key"_s, toQString(f.key()) }, { u"label"_s, toQString(f.label()) },
                { u"description"_s, toQString(f.description()) } };
            switch (f.kind_case()) {
            case wire::SettingField::kToggle:
                field[u"type"_s] = u"toggle"_s;
                field[u"default"_s] = f.toggle().default_value();
                break;
            case wire::SettingField::kNumber: {
                const auto& n = f.number();
                field[u"type"_s] = u"number"_s;
                field[u"default"_s] = n.default_value();
                field[u"min"_s] = n.min();
                field[u"max"_s] = n.max();
                field[u"step"_s] = n.step();
                field[u"unit"_s] = toQString(n.unit());
                field[u"integer"_s] = n.integer();
                break;
            }
            case wire::SettingField::kText:
                field[u"type"_s] = u"text"_s;
                field[u"default"_s] = toQString(f.text().default_value());
                field[u"placeholder"_s] = toQString(f.text().placeholder());
                break;
            case wire::SettingField::kChoice: {
                field[u"type"_s] = u"choice"_s;
                field[u"default"_s] = toQString(f.choice().default_value());
                QVariantList options;
                for (const wire::Choice& c : f.choice().options()) {
                    options.append(
                        QVariantMap{ { u"value"_s, toQString(c.value()) }, { u"label"_s, toQString(c.label()) } });
                }
                field[u"options"_s] = options;
                break;
            }
            case wire::SettingField::KIND_NOT_SET:
                continue; // newer field kind we can't render
            }
            fields.append(field);
        }
        sections.append(QVariantMap{ { u"title"_s, toQString(section.title()) },
            { u"description"_s, toQString(section.description()) }, { u"fields"_s, fields } });
    }
    return sections;
}

QString statusMessage(const grpc::Status& s) {
    return s.error_message().empty()
               ? QString::fromStdString(
                     s.error_code() == grpc::StatusCode::UNAVAILABLE ? "plugin not reachable" : "request failed")
               : toQString(s.error_message());
}

// Raised on the main thread; only for a session that is still current.
void reportFailure(const QPointer<PluginHost>& self, const Session* session, const QString& error);

} // namespace

PluginHost::PluginHost(Params params, QObject* parent)
    : QObject(parent)
    , m_params(std::move(params)) {
    m_stableTimer.setSingleShot(true);
    m_stableTimer.setInterval(k_stableMs);
    connect(&m_stableTimer, &QTimer::timeout, this, [this] {
        m_restarts = 0;
    });
}

PluginHost::~PluginHost() {
    m_stopRequested = true;
    teardown();
}

namespace {

void reportFailure(const QPointer<PluginHost>& self, const Session* session, const QString& error) {
    if (!self) {
        return;
    }
    QMetaObject::invokeMethod(
        self.data(),
        [self, session, error] {
            PluginHost* host = self.data();
            if (host && host->isCurrent(session)) {
                emit host->actionFailed(error);
            }
        },
        Qt::QueuedConnection);
}

} // namespace

void PluginHost::setState(State state, const QString& error) {
    if (m_state == state && m_error == error) {
        return;
    }
    m_state = state;
    m_error = error;
    emit stateChanged();
}

void PluginHost::start() {
    if (m_stopRequested && m_process) {
        // A previous run is still shutting down; start once it is gone.
        m_startPending = true;
        return;
    }
    if (m_state == State::Starting || m_state == State::Running) {
        return;
    }
    m_stopRequested = false;
    setState(State::Starting);

    const QFileInfo exec(m_params.exec);
    if (!exec.isExecutable()) {
        setState(State::Failed, tr("Executable not found: %1").arg(m_params.exec));
        return;
    }

    QDir().mkpath(m_params.dataDir);
    const QString socketDir = QFileInfo(m_params.socketPath).absolutePath();
    QDir().mkpath(socketDir);
    QFile::setPermissions(socketDir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    // The socket directory may live in a shared place (/tmp fallback): don't
    // talk to a plugin through a directory somebody else could have planted.
    const QFileInfo dirInfo(socketDir);
    if (dirInfo.ownerId() != geteuid() || dirInfo.isSymLink() ||
        (dirInfo.permissions() &
            (QFileDevice::ReadGroup | QFileDevice::WriteGroup | QFileDevice::ReadOther | QFileDevice::WriteOther))) {
        setState(State::Failed, tr("Unsafe socket directory: %1").arg(socketDir));
        return;
    }
    QFile::remove(m_params.socketPath);

    m_process = new QProcess(this);
    // Plugin stderr (their logs) ends up in the shell's journal.
    m_process->setProcessChannelMode(QProcess::ForwardedErrorChannel);
    m_process->setStandardInputFile(QProcess::nullDevice());
    m_process->setWorkingDirectory(m_params.dataDir);

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(u"CAELESTIA_PLUGIN_SOCKET"_s, m_params.socketPath);
    env.insert(u"CAELESTIA_PLUGIN_ID"_s, m_params.id);
    m_process->setProcessEnvironment(env);

    connect(m_process, &QProcess::finished, this, &PluginHost::onProcessFinished);
    connect(m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError err) {
        if (err == QProcess::FailedToStart) {
            const QString message = tr("Failed to start: %1").arg(m_process ? m_process->errorString() : QString());
            teardown();
            setState(State::Failed, message);
        }
    });

    m_process->start(m_params.exec, {});
    beginSession();
}

void PluginHost::beginSession() {
    auto session = std::make_shared<Session>();
    m_session = session;
    session->startWorker();
    const QPointer<PluginHost> self(this);
    const Params params = m_params;

    m_thread = std::thread([self, session, params] {
        // Results of a session that was torn down meanwhile (e.g. restarted) are dropped.
        const auto post = [self, session](auto fn) {
            if (PluginHost* host = self.data()) {
                QMetaObject::invokeMethod(
                    host,
                    [self, session, fn = std::move(fn)] {
                        PluginHost* current = self.data();
                        if (current && current->m_session == session) {
                            fn(current);
                        }
                    },
                    Qt::QueuedConnection);
            }
        };
        const auto fail = [&](const QString& message) {
            if (!session->cancelled) {
                post([message](PluginHost* host) {
                    if (host->m_state == State::Starting) {
                        host->teardown();
                        host->setState(State::Failed, message);
                    }
                });
            }
        };

        // Unix socket paths aren't valid HTTP/2 authorities, see NixBackendClient.
        grpc::ChannelArguments args;
        args.SetString(GRPC_ARG_DEFAULT_AUTHORITY, "localhost");
        auto channel = grpc::CreateCustomChannel(
            "unix://" + params.socketPath.toStdString(), grpc::InsecureChannelCredentials(), args);

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        bool connected = false;
        while (!session->cancelled && std::chrono::steady_clock::now() < deadline) {
            if (channel->WaitForConnected(std::chrono::system_clock::now() + std::chrono::milliseconds(200))) {
                connected = true;
                break;
            }
        }
        if (session->cancelled) {
            return;
        }
        if (!connected) {
            fail(QObject::tr("The plugin did not open its socket in time"));
            return;
        }

        auto stub = std::shared_ptr<wire::Plugin::Stub>(wire::Plugin::NewStub(channel).release());
        {
            const std::lock_guard lock(session->mutex);
            session->channel = channel;
            session->stub = stub;
        }

        wire::HandshakeRequest req;
        req.mutable_host_api_version()->set_major(hostApiVersion.major);
        req.mutable_host_api_version()->set_minor(hostApiVersion.minor);
        req.set_host_version(params.hostVersion.toStdString());
        req.set_data_dir(params.dataDir.toStdString());

        wire::HandshakeReply reply;
        grpc::Status handshakeStatus;
        session->call([&](grpc::ClientContext& ctx) {
            handshakeStatus = stub->Handshake(&ctx, req, &reply);
        });
        if (!handshakeStatus.ok()) {
            fail(QObject::tr("Handshake failed: %1").arg(statusMessage(handshakeStatus)));
            return;
        }
        const ApiVersion pluginApi{ reply.api_version().major(), reply.api_version().minor() };
        if (!isCompatible(pluginApi, hostApiVersion)) {
            fail(QObject::tr("Incompatible plugin API %1.%2 (shell provides %3.%4)")
                    .arg(pluginApi.major)
                    .arg(pluginApi.minor)
                    .arg(hostApiVersion.major)
                    .arg(hostApiVersion.minor));
            return;
        }

        QVariantList tabs;
        for (const wire::DashboardTab& t : reply.contributions().dashboard_tabs()) {
            tabs.append(QVariantMap{ { u"viewId"_s, toQString(t.view_id()) }, { u"title"_s, toQString(t.title()) },
                { u"icon"_s, toQString(t.icon()) } });
        }
        const QVariantList schema = schemaToVariant(reply.settings_schema());
        const QString version = toQString(reply.plugin_version());

        // Subscribe before anything is fetched so no update falls in a gap.
        grpc::ClientContext eventsCtx;
        {
            const std::lock_guard lock(session->mutex);
            if (session->cancelled) {
                return;
            }
            session->eventsContext = &eventsCtx;
        }
        auto reader = stub->Events(&eventsCtx, wire::EventsRequest());

        post([version, tabs, schema](PluginHost* host) {
            if (host->m_state != State::Starting) {
                return;
            }
            host->setState(State::Running);
            host->m_stableTimer.start();
            emit host->handshaken(version, tabs, schema);
        });

        wire::PluginEvent event;
        while (reader->Read(&event)) {
            if (event.has_view_update()) {
                const wire::View& view = event.view_update().view();
                const QString viewId = toQString(view.view_id());
                const QVariantMap tree = nodeToVariant(view.root(), 0);
                post([viewId, tree](PluginHost* host) {
                    emit host->viewUpdated(viewId, tree);
                });
            } else if (event.has_notification()) {
                const wire::Notification& n = event.notification();
                QString urgency = u"normal"_s;
                if (n.urgency() == wire::URGENCY_LOW) {
                    urgency = u"low"_s;
                } else if (n.urgency() == wire::URGENCY_CRITICAL) {
                    urgency = u"critical"_s;
                }
                const QVariantMap map{ { u"title"_s, toQString(n.title()) }, { u"body"_s, toQString(n.body()) },
                    { u"icon"_s, toQString(n.icon()) }, { u"urgency"_s, urgency } };
                post([map](PluginHost* host) {
                    emit host->notification(map);
                });
            }
        }

        {
            const std::lock_guard lock(session->mutex);
            session->eventsContext = nullptr;
        }
        reader->Finish(); // the process's own exit is reported through QProcess
    });
}

void PluginHost::applySettings(const QVariantMap& values) {
    if (m_state != State::Running || !m_session) {
        return;
    }
    wire::ApplySettingsRequest req;
    for (auto it = values.cbegin(); it != values.cend(); ++it) {
        wire::SettingValue value;
        switch (it.value().typeId()) {
        case QMetaType::Bool:
            value.set_bool_value(it.value().toBool());
            break;
        case QMetaType::QString:
            value.set_string_value(it.value().toString().toStdString());
            break;
        default:
            value.set_number_value(it.value().toDouble());
            break;
        }
        (*req.mutable_values())[it.key().toStdString()] = std::move(value);
    }

    Session* const session = m_session.get();
    const QPointer<PluginHost> self(this);
    session->enqueue([session, self, req = std::move(req)] {
        const auto stub = session->getStub();
        if (!stub) {
            return;
        }
        QString error;
        session->call([&](grpc::ClientContext& ctx) {
            wire::ApplySettingsReply reply;
            const grpc::Status status = stub->ApplySettings(&ctx, req, &reply);
            error = status.ok() ? toQString(reply.error()) : statusMessage(status);
        });
        if (!error.isEmpty() && !session->cancelled) {
            reportFailure(self, session, error);
        }
    });
}

void PluginHost::fetchView(const QString& viewId) {
    if (m_state != State::Running || !m_session) {
        return;
    }
    Session* const session = m_session.get();
    const QPointer<PluginHost> self(this);
    session->enqueue([session, self, viewId] {
        const auto stub = session->getStub();
        if (!stub) {
            return;
        }
        wire::GetViewRequest req;
        req.set_view_id(viewId.toStdString());
        wire::View view;
        bool ok = false;
        session->call([&](grpc::ClientContext& ctx) {
            ok = stub->GetView(&ctx, req, &view).ok();
        });
        if (!ok || session->cancelled || !self) {
            return;
        }
        const QVariantMap tree = nodeToVariant(view.root(), 0);
        QMetaObject::invokeMethod(
            self.data(),
            [self, session, viewId, tree] {
                PluginHost* host = self.data();
                if (host && host->isCurrent(session)) {
                    emit host->viewUpdated(viewId, tree);
                }
            },
            Qt::QueuedConnection);
    });
}

void PluginHost::invokeAction(const QString& viewId, const QString& actionId, const QString& payload) {
    if (m_state != State::Running || !m_session) {
        return;
    }
    Session* const session = m_session.get();
    const QPointer<PluginHost> self(this);
    session->enqueue([session, self, viewId, actionId, payload] {
        const auto stub = session->getStub();
        if (!stub) {
            return;
        }
        wire::InvokeActionRequest req;
        req.set_view_id(viewId.toStdString());
        req.set_action_id(actionId.toStdString());
        req.set_payload(payload.toStdString());
        QString error;
        session->call([&](grpc::ClientContext& ctx) {
            wire::InvokeActionReply reply;
            const grpc::Status status = stub->InvokeAction(&ctx, req, &reply);
            error = status.ok() ? toQString(reply.error()) : statusMessage(status);
        });
        if (!error.isEmpty() && !session->cancelled) {
            reportFailure(self, session, error);
        }
    });
}

void PluginHost::stop() {
    m_startPending = false;
    m_stopRequested = true;
    m_stableTimer.stop();

    if (!m_process || m_process->state() == QProcess::NotRunning) {
        teardown();
        setState(State::Stopped);
        return;
    }

    // Polite first: the plugin gets to persist state. The session stays up
    // until the process is gone (finished() -> teardown()).
    if (m_state == State::Running && m_session) {
        const auto stub = m_session->getStub();
        if (stub) {
            (void)QtConcurrent::run([stub] {
                wire::ShutdownReply reply;
                grpc::ClientContext ctx;
                ctx.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(2));
                stub->Shutdown(&ctx, wire::ShutdownRequest(), &reply);
            });
        }
    } else {
        m_process->terminate();
    }

    const QPointer<QProcess> proc(m_process);
    QTimer::singleShot(2500, this, [proc] {
        if (proc && proc->state() != QProcess::NotRunning) {
            proc->kill();
        }
    });
}

void PluginHost::onProcessFinished(int code, QProcess::ExitStatus status) {
    const bool requested = m_stopRequested;
    teardown();

    if (requested) {
        setState(State::Stopped);
        if (std::exchange(m_startPending, false)) {
            start();
        }
        return;
    }

    const QString reason =
        status == QProcess::CrashExit ? tr("Crashed") : tr("Exited unexpectedly (code %1)").arg(code);
    if (m_restarts < k_maxRestarts) {
        ++m_restarts;
        setState(State::Starting);
        // Back off a little so a plugin that dies on startup doesn't spin.
        QTimer::singleShot(1000 * m_restarts, this, [this] {
            if (!m_stopRequested && m_state == State::Starting) {
                m_state = State::Stopped;
                start();
            }
        });
        return;
    }
    setState(State::Failed, reason);
}

void PluginHost::teardown() {
    m_stableTimer.stop();

    if (m_session) {
        m_session->cancel();
        m_session->stopWorker();
    }
    if (m_thread.joinable()) {
        m_thread.join();
    }
    m_session.reset();

    if (m_process) {
        QProcess* proc = m_process;
        m_process = nullptr;
        proc->disconnect(this);
        if (proc->state() != QProcess::NotRunning) {
            proc->terminate();
            if (!proc->waitForFinished(1000)) {
                proc->kill();
                proc->waitForFinished(1000);
            }
        }
        proc->deleteLater();
    }
    QFile::remove(m_params.socketPath);
}

} // namespace caelestia::plugins
