#!/usr/bin/env sh
# Builds the first-party plugins (plugins/*) and assembles them into the
# directory the shell reads its default plugin source from:
#
#   <out>/<id>/manifest.json
#   <out>/<id>/<manifest "exec">
#
# Usage: scripts/build-plugins.sh [out-dir]   (default: build/plugins)
#
# Point CAELESTIA_BUNDLED_PLUGINS_DIR at <out> to make the shell offer them
# (.envrc does that for the dev shell).

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=${1:-$root/build/plugins}

for dir in "$root"/plugins/*/; do
    [ -f "$dir/manifest.json" ] || continue

    id=$(basename "$dir")
    exec_rel=$(sed -n 's/.*"exec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/manifest.json")
    [ -n "$exec_rel" ] || { echo "$id: manifest.json has no \"exec\"" >&2; exit 1; }

    cargo build --release --manifest-path "$dir/Cargo.toml"

    # The binary is named like the manifest's executable.
    mkdir -p "$out/$id/$(dirname "$exec_rel")"
    cp "$dir/manifest.json" "$out/$id/manifest.json"
    cp "$dir/target/release/$(basename "$exec_rel")" "$out/$id/$exec_rel"
    echo "built plugin $id -> $out/$id"
done
