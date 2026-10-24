#pragma once

#include "settings/objectnode.hpp"
#include "common.hpp"

namespace caelestia::config {

// Cinema mode: darkens every output but one through the compositor's
// `ironland-cinema-mode-v1` protocol (see services/CinemaMode.qml). Whether
// it is on right now is deliberately not stored here: it is a transient
// toggle that must not come back dark after a restart.
class CinemaModeConfig : public settings::ObjectNode {
    CONFIG_NODE(CinemaModeConfig, settings::ObjectNode)

    // Let the dark outputs glow in the colours along the lit output's border.
    CONFIG_GLOBAL_PROPERTY(bool, glow, false)
    // How strong that glow is, 0 to 100 (brighter and reaching further).
    CONFIG_GLOBAL_PROPERTY(int, glowStrength, 60)
};

} // namespace caelestia::config
