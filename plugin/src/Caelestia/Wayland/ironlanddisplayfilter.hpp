#pragma once

#include <qobject.h>
#include <qqmlintegration.h>

#include <QtWaylandClient/QWaylandClientExtensionTemplate>

#include "qwayland-ironland-display-filter-v1.h"

namespace caelestia::wayland {

// QML-facing handle on the `ironland-display-filter-v1` global (see
// plugin/protocols/ironland-display-filter-v1.xml): tints the whole display
// warmer the lower `temperature` is, 6500 meaning no tint.
//
// The compositor drops the filter as soon as this object (or the whole
// client) goes away, so a crashed shell can't leave the screen orange.
// Requests made before the compositor advertises the global (e.g. the shell
// starting first) are remembered and sent once it appears.
class IronlandDisplayFilter : public QWaylandClientExtensionTemplate<IronlandDisplayFilter>,
                              public QtWayland::ironland_display_filter_v1 {
    Q_OBJECT
    QML_ELEMENT

    // Colour temperature in kelvin; 6500 (or more) is neutral.
    Q_PROPERTY(int temperature READ temperature WRITE setTemperature NOTIFY temperatureChanged)
    // Whether the compositor supports the protocol.
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)

public:
    explicit IronlandDisplayFilter(QObject* parent = nullptr);
    ~IronlandDisplayFilter() override;

    [[nodiscard]] int temperature() const;
    void setTemperature(int temperature);
    [[nodiscard]] bool available() const;

signals:
    void temperatureChanged();
    void availableChanged();

private:
    int m_temperature = 6500;

    void apply();
};

} // namespace caelestia::wayland
