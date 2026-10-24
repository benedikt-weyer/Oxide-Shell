#include "ironlandcinemamode.hpp"

#include <algorithm>

namespace caelestia::wayland {

IronlandCinemaMode::IronlandCinemaMode(QObject* parent)
    : QWaylandClientExtensionTemplate<IronlandCinemaMode>(1) {
    setParent(parent);
    connect(this, &QWaylandClientExtension::activeChanged, this, [this]() {
        // A new binding knows nothing of what the old one was told.
        m_sentEnabled = false;
        m_sentGlow = 0;
        emit availableChanged();
        apply();
    });
}

IronlandCinemaMode::~IronlandCinemaMode() {
    if (isInitialized()) {
        destroy();
    }
}

bool IronlandCinemaMode::enabled() const {
    return m_enabled;
}

void IronlandCinemaMode::setEnabled(bool enabled) {
    if (m_enabled == enabled) {
        return;
    }

    m_enabled = enabled;
    emit enabledChanged();
    apply();
}

int IronlandCinemaMode::glow() const {
    return m_glow;
}

void IronlandCinemaMode::setGlow(int glow) {
    glow = std::clamp(glow, 0, 100);
    if (m_glow == glow) {
        return;
    }

    m_glow = glow;
    emit glowChanged();
    apply();
}

bool IronlandCinemaMode::available() const {
    return isActive();
}

void IronlandCinemaMode::apply() {
    if (!isActive()) {
        return;
    }

    // The glow first, so it is already right when the mode switches on.
    if (m_glow != m_sentGlow) {
        set_glow(static_cast<uint32_t>(m_glow));
        m_sentGlow = m_glow;
    }

    if (m_enabled != m_sentEnabled) {
        if (m_enabled) {
            // No output: the compositor lights the one the user is working on.
            enable(nullptr);
        } else {
            disable();
        }
        m_sentEnabled = m_enabled;
    }
}

} // namespace caelestia::wayland
