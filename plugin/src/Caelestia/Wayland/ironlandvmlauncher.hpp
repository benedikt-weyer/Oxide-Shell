#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qstringlist.h>

#include <QtWaylandClient/QWaylandClientExtensionTemplate>

#include "qwayland-ironland-vm-launch-v1.h"

namespace caelestia::wayland {

class IronlandVmLauncher;

// One launch, i.e one `ironland_vm_launch_v1` object: forwards the
// compositor's progress reports for a single VM to its IronlandVmLauncher as
// signals tagged with the desktop entry. Not exposed to QML; owned by (and
// deleted with) the launcher, and deleted early once the launch is over.
class IronlandVmLaunch : public QObject, public QtWayland::ironland_vm_launch_v1 {
    Q_OBJECT

public:
    IronlandVmLaunch(IronlandVmLauncher* launcher, QString entry, bool persistent);
    ~IronlandVmLaunch() override;

protected:
    void ironland_vm_launch_v1_failed(uint32_t error, const QString& message) override;
    void ironland_vm_launch_v1_starting(uint32_t vm) override;
    void ironland_vm_launch_v1_running() override;
    void ironland_vm_launch_v1_saving() override;
    void ironland_vm_launch_v1_finished(uint32_t reason) override;

private:
    IronlandVmLauncher* m_launcher;
    QString m_entry;
    bool m_persistent;
};

// QML-facing handle on the `ironland-vm-launch-v1` global (see
// plugin/protocols/ironland-vm-launch-v1.xml): starts an installed
// application in a VM, whose windows then appear on the desktop like any
// other (badged by the compositor). The application is named by its desktop
// entry id - the compositor resolves it itself, so this can't run arbitrary
// commands.
//
// Not every compositor has the global and, when it does, it only works for
// the programs that have a VM set up (one program per VM, each with its own
// guest image): offer VM launching only while `usable` is true, and only for
// the entries in `programs`. Each `launch` reports back through the signals
// below, all of which carry the `entry` they are about; the VMs themselves
// keep running if this object goes away.
class IronlandVmLauncher : public QWaylandClientExtensionTemplate<IronlandVmLauncher>,
                           public QtWayland::ironland_vm_launcher_v1 {
    Q_OBJECT
    QML_ELEMENT

    // Whether the compositor advertises the protocol at all.
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    // Whether the compositor has any program set up for VMs (updates live).
    Q_PROPERTY(bool configured READ configured NOTIFY configuredChanged)
    // available && configured: launches can be attempted.
    Q_PROPERTY(bool usable READ usable NOTIFY usableChanged)
    // The desktop entry ids (without ".desktop") that can be started in a VM;
    // anything else is refused. Updates live.
    Q_PROPERTY(QStringList programs READ programs NOTIFY programsChanged)

public:
    explicit IronlandVmLauncher(QObject* parent = nullptr);
    ~IronlandVmLauncher() override;

    [[nodiscard]] bool available() const;
    [[nodiscard]] bool configured() const;
    [[nodiscard]] bool usable() const;
    [[nodiscard]] QStringList programs() const;

    // Starts desktop entry `entry` (its id, with or without ".desktop") in a
    // VM: a throw-away one, or with `persistent` one that keeps the
    // application's disk and memory between launches. Does nothing if the
    // compositor doesn't offer the protocol.
    Q_INVOKABLE void launch(const QString& entry, bool persistent);

signals:
    void availableChanged();
    void configuredChanged();
    void usableChanged();
    void programsChanged();

    // The compositor refused the launch. `error` is one of "unknown_entry",
    // "not_configured", "image_missing", "too_many", "already_running",
    // "no_command", "state" or "other"; `message` is a short explanation
    // fit to show the user.
    void failed(const QString& entry, bool persistent, const QString& error, const QString& message);
    // The VM was started; its window will follow once the guest has booted.
    void starting(const QString& entry, bool persistent);
    // The program's window is (about to be) on screen.
    void running(const QString& entry, bool persistent);
    // The program exited and a persistent VM's state is being saved.
    void saving(const QString& entry, bool persistent);
    // The VM is gone. `reason` is "closed", "saved", "failed" or "timed_out".
    void finished(const QString& entry, bool persistent, const QString& reason);

protected:
    void ironland_vm_launcher_v1_availability(uint32_t configured) override;
    void ironland_vm_launcher_v1_program(const QString& entry) override;
    void ironland_vm_launcher_v1_programs_done() override;

private:
    friend class IronlandVmLaunch;

    bool m_configured = false;
    bool m_wasUsable = false;
    // The list being received (a batch of `program` events up to
    // `programs_done`) and the last complete one.
    QStringList m_pendingPrograms;
    QStringList m_programs;

    void updateUsable();
};

} // namespace caelestia::wayland
