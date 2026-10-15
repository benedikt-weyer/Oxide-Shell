#!/usr/bin/env bash
# Like run.sh, but stops the systemd-managed caelestia-shell first so it
# doesn't fight over the compositor with the local dev instance, then
# restarts it once the dev instance exits (including on Ctrl+C).
#
# Usage: run-dev.sh [qs args...]
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

unit="caelestia.service"
was_active=0
if systemctl --user is-active --quiet "$unit"; then
    was_active=1
    echo "Stopping $unit..."
    systemctl --user stop "$unit"
fi

restart_unit() {
    if [ "$was_active" -eq 1 ]; then
        echo "Restarting $unit..."
        systemctl --user start "$unit"
    fi
}
trap restart_unit EXIT

cmake --build build

# The first-party plugins (plugins/*) are the shell's default plugin source.
"$repo_root/scripts/build-plugins.sh" "$repo_root/build/plugins"
export CAELESTIA_BUNDLED_PLUGINS_DIR="$repo_root/build/plugins"

export QML2_IMPORT_PATH="$repo_root/build/qml${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"

qs -n -p "$repo_root" "$@"
