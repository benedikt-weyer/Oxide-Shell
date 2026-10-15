#pragma once

#include <qobject.h>
#include <qpointer.h>
#include <qprocess.h>
#include <qstring.h>
#include <qtimer.h>
#include <qvariant.h>

#include <atomic>
#include <memory>
#include <thread>

namespace caelestia::plugins {

struct Session;

// One running plugin: owns its process and its gRPC session, and translates
// between protobuf and QVariant so nothing outside pluginhost.cpp needs
// gRPC/protobuf headers.
//
// Lives on the main thread. The blocking gRPC work (connect, handshake and
// the Events stream) runs on a session thread and RPCs on the global thread
// pool; results come back through queued calls.
class PluginHost : public QObject {
    Q_OBJECT

public:
    enum class State : quint8 {
        Stopped,
        Starting,
        Running,
        Failed
    };
    Q_ENUM(State)

    struct Params {
        QString id;
        // Absolute path of the executable.
        QString exec;
        QString dataDir;
        QString socketPath;
        QString hostVersion;
    };

    explicit PluginHost(Params params, QObject* parent = nullptr);
    ~PluginHost() override;

    [[nodiscard]] State state() const { return m_state; }

    [[nodiscard]] QString error() const { return m_error; }

    [[nodiscard]] QString id() const { return m_params.id; }

    // Whether `session` is the one this host currently runs (results of older ones are dropped).
    [[nodiscard]] bool isCurrent(const Session* session) const { return m_session.get() == session; }

    void start();
    // Asks the plugin to exit and kills it if it doesn't.
    void stop();

    // `values`: key -> bool | double | QString. Complete set.
    void applySettings(const QVariantMap& values);
    void fetchView(const QString& viewId);
    void invokeAction(const QString& viewId, const QString& actionId, const QString& payload);

signals:
    void stateChanged();
    // `tabs`: [{viewId, title, icon}]; `schema`: see PluginManager::settingsSchema().
    void handshaken(const QString& pluginVersion, const QVariantList& tabs, const QVariantList& schema);
    void viewUpdated(const QString& viewId, const QVariantMap& tree);
    // {title, body, icon, urgency}
    void notification(const QVariantMap& notification);
    void actionFailed(const QString& message);

private:
    void setState(State state, const QString& error = {});
    void beginSession();
    void teardown();
    void onProcessFinished(int code, QProcess::ExitStatus status);

    Params m_params;
    State m_state = State::Stopped;
    QString m_error;
    QProcess* m_process = nullptr;
    std::shared_ptr<Session> m_session;
    std::thread m_thread;
    bool m_stopRequested = false;
    bool m_startPending = false;
    int m_restarts = 0;
    QTimer m_stableTimer;
};

} // namespace caelestia::plugins
