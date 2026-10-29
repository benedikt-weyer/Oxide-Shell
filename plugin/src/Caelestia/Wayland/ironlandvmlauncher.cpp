#include "ironlandvmlauncher.hpp"

#include <utility>

namespace caelestia::wayland {

namespace {

QString errorName(uint32_t error) {
    using Protocol = QtWayland::ironland_vm_launch_v1;
    switch (error) {
    case Protocol::error_unknown_entry:
        return QStringLiteral("unknown_entry");
    case Protocol::error_not_configured:
        return QStringLiteral("not_configured");
    case Protocol::error_image_missing:
        return QStringLiteral("image_missing");
    case Protocol::error_too_many:
        return QStringLiteral("too_many");
    case Protocol::error_already_running:
        return QStringLiteral("already_running");
    case Protocol::error_no_command:
        return QStringLiteral("no_command");
    case Protocol::error_state:
        return QStringLiteral("state");
    default:
        return QStringLiteral("other");
    }
}

QString finishReasonName(uint32_t reason) {
    using Protocol = QtWayland::ironland_vm_launch_v1;
    switch (reason) {
    case Protocol::finish_reason_closed:
        return QStringLiteral("closed");
    case Protocol::finish_reason_saved:
        return QStringLiteral("saved");
    case Protocol::finish_reason_timed_out:
        return QStringLiteral("timed_out");
    default:
        return QStringLiteral("failed");
    }
}

QString programId(const QString& entry) {
    static const QString suffix = QStringLiteral(".desktop");
    return entry.endsWith(suffix) ? entry.chopped(suffix.size()) : entry;
}

} // namespace

IronlandVmLaunch::IronlandVmLaunch(IronlandVmLauncher* launcher, QString entry, bool persistent)
    : QObject(launcher)
    , m_launcher(launcher)
    , m_entry(std::move(entry))
    , m_persistent(persistent) {}

IronlandVmLaunch::~IronlandVmLaunch() {
    if (isInitialized()) {
        destroy();
    }
}

void IronlandVmLaunch::ironland_vm_launch_v1_failed(uint32_t error, const QString& message) {
    emit m_launcher->failed(m_entry, m_persistent, errorName(error), message);
    // Nothing more will come; drop the object.
    deleteLater();
}

void IronlandVmLaunch::ironland_vm_launch_v1_starting(uint32_t /*vm*/) {
    emit m_launcher->starting(m_entry, m_persistent);
}

void IronlandVmLaunch::ironland_vm_launch_v1_running() {
    emit m_launcher->running(m_entry, m_persistent);
}

void IronlandVmLaunch::ironland_vm_launch_v1_saving() {
    emit m_launcher->saving(m_entry, m_persistent);
}

void IronlandVmLaunch::ironland_vm_launch_v1_finished(uint32_t reason) {
    emit m_launcher->finished(m_entry, m_persistent, finishReasonName(reason));
    deleteLater();
}

IronlandVmLauncher::IronlandVmLauncher(QObject* parent)
    : QWaylandClientExtensionTemplate<IronlandVmLauncher>(3) {
    setParent(parent);
    connect(this, &QWaylandClientExtension::activeChanged, this, [this]() {
        if (!isActive()) {
            // Compositor gone (or restarting): nothing is configured there.
            m_configured = false;
            m_pendingPrograms.clear();
            if (!m_programs.isEmpty()) {
                m_programs.clear();
                emit programsChanged();
            }
        }
        emit availableChanged();
        updateUsable();
    });
}

IronlandVmLauncher::~IronlandVmLauncher() {
    if (isInitialized()) {
        destroy();
    }
}

bool IronlandVmLauncher::available() const {
    return isActive();
}

bool IronlandVmLauncher::configured() const {
    return m_configured;
}

bool IronlandVmLauncher::usable() const {
    return isActive() && m_configured;
}

QStringList IronlandVmLauncher::programs() const {
    return m_programs;
}

bool IronlandVmLauncher::supportsNetwork() const {
    // `launch_with_network` arrived in version 3 of the protocol.
    constexpr uint32_t sinceVersion = 3;
    return isActive() && QtWayland::ironland_vm_launcher_v1::version() >= sinceVersion;
}

void IronlandVmLauncher::launchWithNetwork(const QString& entry, bool persistent, const QString& network) {
    if (!isActive()) {
        return;
    }

    uint32_t mode = 0;
    if (network == QLatin1String("online")) {
        mode = network_online;
    } else if (network == QLatin1String("tor")) {
        mode = network_tor;
    } else if (network == QLatin1String("offline")) {
        mode = network_offline;
    } else {
        emit failed(entry, persistent, QStringLiteral("other"), tr("Unknown network mode \"%1\"").arg(network));
        return;
    }

    if (!supportsNetwork()) {
        // An old compositor can only start the VM online (or as it was left):
        // fine if that is what was asked for, refused otherwise.
        if (mode == network_online) {
            launch(entry, persistent);
        } else {
            emit failed(entry, persistent, QStringLiteral("other"),
                tr("The compositor can't choose a VM's network mode; update it"));
        }
        return;
    }

    auto* launch = new IronlandVmLaunch(this, entry, persistent);
    launch->init(
        ironland_vm_launcher_v1::launch_with_network(entry, persistent ? mode_persistent : mode_throwaway, mode));
}

void IronlandVmLauncher::launch(const QString& entry, bool persistent) {
    if (!isActive()) {
        return;
    }

    auto* launch = new IronlandVmLaunch(this, entry, persistent);
    launch->init(ironland_vm_launcher_v1::launch(entry, persistent ? mode_persistent : mode_throwaway));
}

void IronlandVmLauncher::ironland_vm_launcher_v1_availability(uint32_t configured) {
    const bool value = configured != 0;
    if (m_configured != value) {
        m_configured = value;
        emit configuredChanged();
    }
    updateUsable();
}

void IronlandVmLauncher::ironland_vm_launcher_v1_program(const QString& entry) {
    m_pendingPrograms.append(programId(entry));
}

void IronlandVmLauncher::ironland_vm_launcher_v1_programs_done() {
    // Each batch is the complete list, so it replaces the previous one.
    QStringList programs = std::exchange(m_pendingPrograms, {});
    programs.sort();
    if (programs != m_programs) {
        m_programs = std::move(programs);
        emit programsChanged();
    }
}

void IronlandVmLauncher::updateUsable() {
    if (m_wasUsable != usable()) {
        m_wasUsable = usable();
        emit usableChanged();
    }
}

} // namespace caelestia::wayland
