#pragma once

#include <qobject.h>
#include <qqmlintegration.h>

#include <QtWaylandClient/QWaylandClientExtensionTemplate>

#include "qwayland-ironland-cinema-mode-v1.h"

namespace caelestia::wayland {

// QML-facing handle on the `ironland-cinema-mode-v1` global (see
// plugin/protocols/ironland-cinema-mode-v1.xml): while `enabled`, the
// compositor keeps one output lit (the one the user is working on) and turns
// all others dark, with a `glow` of the lit output's border colours on them
// if its strength is above 0.
//
// The compositor withdraws the mode as soon as this object (or the whole
// client) goes away, so a crashed shell can't leave screens black. Changes
// made before the compositor advertises the global (e.g. the shell starting
// first) are remembered and sent once it appears.
class IronlandCinemaMode : public QWaylandClientExtensionTemplate<IronlandCinemaMode>,
                           public QtWayland::ironland_cinema_mode_v1 {
    Q_OBJECT
    QML_ELEMENT

    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    // Glow strength on the dark outputs, 0 (off) to 100.
    Q_PROPERTY(int glow READ glow WRITE setGlow NOTIFY glowChanged)
    // Whether the compositor supports the protocol.
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)

public:
    explicit IronlandCinemaMode(QObject* parent = nullptr);
    ~IronlandCinemaMode() override;

    [[nodiscard]] bool enabled() const;
    void setEnabled(bool enabled);
    [[nodiscard]] int glow() const;
    void setGlow(int glow);
    [[nodiscard]] bool available() const;

signals:
    void enabledChanged();
    void glowChanged();
    void availableChanged();

private:
    bool m_enabled = false;
    int m_glow = 0;

    // What the compositor has been told on the current binding. The mode is
    // only switched off explicitly if it was on, so that merely starting the
    // shell never overrides another client's cinema mode.
    bool m_sentEnabled = false;
    int m_sentGlow = 0;

    void apply();
};

} // namespace caelestia::wayland
