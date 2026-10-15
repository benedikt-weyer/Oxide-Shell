#include "ironlanddisplayfilter.hpp"

#include <algorithm>

namespace caelestia::wayland {

IronlandDisplayFilter::IronlandDisplayFilter(QObject* parent)
    : QWaylandClientExtensionTemplate<IronlandDisplayFilter>(1) {
    setParent(parent);
    connect(this, &QWaylandClientExtension::activeChanged, this, [this]() {
        emit availableChanged();
        apply();
    });
}

IronlandDisplayFilter::~IronlandDisplayFilter() {
    if (isInitialized()) {
        destroy();
    }
}

int IronlandDisplayFilter::temperature() const {
    return m_temperature;
}

void IronlandDisplayFilter::setTemperature(int temperature) {
    if (m_temperature == temperature) {
        return;
    }

    m_temperature = temperature;
    emit temperatureChanged();
    apply();
}

bool IronlandDisplayFilter::available() const {
    return isActive();
}

void IronlandDisplayFilter::apply() {
    if (!isActive()) {
        return;
    }

    set_color_temperature(static_cast<uint32_t>(std::max(0, m_temperature)));
}

} // namespace caelestia::wayland
