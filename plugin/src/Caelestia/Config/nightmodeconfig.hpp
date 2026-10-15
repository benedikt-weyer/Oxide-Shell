#pragma once

#include <qstring.h>

#include "settings/objectnode.hpp"
#include "common.hpp"

namespace caelestia::config {

// Night mode: warms the whole display through the compositor's
// `ironland-display-filter-v1` protocol (see services/NightMode.qml).
class NightModeConfig : public settings::ObjectNode {
    CONFIG_NODE(NightModeConfig, settings::ObjectNode)

    // Manual switch. With `scheduled` off, this alone decides whether the tint is on.
    CONFIG_GLOBAL_PROPERTY(bool, enabled, false)
    // When on, `enabled` is ignored and the tint follows startTime..endTime instead.
    CONFIG_GLOBAL_PROPERTY(bool, scheduled, false)
    // "HH:mm", 24-hour. The window may wrap past midnight (e.g. 21:00 to 07:00).
    CONFIG_GLOBAL_PROPERTY(QString, startTime, u"21:00"_s)
    CONFIG_GLOBAL_PROPERTY(QString, endTime, u"07:00"_s)
    // Colour temperature in kelvin while active; 6500 is neutral, lower is warmer.
    CONFIG_GLOBAL_PROPERTY(int, temperature, 3400)
};

} // namespace caelestia::config
