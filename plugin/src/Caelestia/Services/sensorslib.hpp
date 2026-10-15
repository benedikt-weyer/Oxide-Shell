#pragma once

#include <qhash.h>

#include <optional>

namespace caelestia::services::sensorslib {

void ensureInit();

[[nodiscard]] std::optional<double> cpuPackageTemp();
[[nodiscard]] std::optional<double> gpuPciAverageTemp();

// Per-core temperatures keyed by the kernel core id (the N of coretemp's "Core N" labels)
[[nodiscard]] QHash<int, double> cpuCoreTemps();

} // namespace caelestia::services::sensorslib
