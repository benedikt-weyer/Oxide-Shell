#pragma once

#include <qbytearray.h>
#include <qjsonobject.h>
#include <qlist.h>
#include <qstring.h>
#include <qvariant.h>

#include <optional>

// Filesystem side of the plugin system: manifests, plugin sources (where
// installable plugins are listed) and installing/removing them. No gRPC and
// no QML in here, see pluginhost/pluginmanager for those.
namespace caelestia::plugins {

// The plugin API version the shell implements (see
// plugin-sdk/proto/caelestia_plugin.proto for the rules). Keep in sync with
// the SDKs' API_VERSION / kApiVersion.
struct ApiVersion {
    quint32 major;
    quint32 minor;
};

inline constexpr ApiVersion hostApiVersion{ 1, 1 };

[[nodiscard]] constexpr bool isCompatible(ApiVersion plugin, ApiVersion host) {
    return plugin.major == host.major && plugin.minor <= host.minor;
}

[[nodiscard]] bool isValidPluginId(const QString& id);

// manifest.json, shipped at the root of every plugin directory (and used as
// the entry format of a source index).
struct Manifest {
    QString id;
    QString name;
    QString version;
    QString description;
    QString author;
    QString icon;
    QString homepage;
    // Relative to the plugin directory.
    QString exec;
    ApiVersion api{ 0, 0 };
};

[[nodiscard]] std::optional<Manifest> parseManifest(const QJsonObject& obj, QString* error);

// What a plugin shows up as in the "available" list.
struct SourceEntry {
    Manifest manifest;
    // Exactly one of these locates the package: a directory laid out like an
    // installed plugin, or a .tar.gz (local path or http(s) URL).
    QString dir;
    QString archive;
    // Optional hex digest of the archive.
    QString sha256;
    QString sourceName;
};

struct SourceListing {
    QList<SourceEntry> entries;
    QString error;
};

// A source is either a directory (every subdirectory with a manifest.json is
// a plugin, unless it has an index.json) or a JSON index:
//   { "plugins": [ { <manifest fields>, "path": "dir" | "archive": "x.tar.gz", "sha256": "..." } ] }
// Relative paths resolve against the index location.
[[nodiscard]] SourceListing listDirectorySource(const QString& dirPath, const QString& sourceName);
[[nodiscard]] SourceListing parseIndex(
    const QByteArray& json, const QString& baseDirOrUrl, bool baseIsRemote, const QString& sourceName);

// Reads <pluginsDir>/*/manifest.json. Broken plugins are reported through
// `errors` (id/dir name -> message) instead of being dropped silently.
struct InstalledPlugin {
    Manifest manifest;
    QString dir;
};

[[nodiscard]] QList<InstalledPlugin> scanInstalled(const QString& pluginsDir, QVariantMap* errors = nullptr);

// Blocking; run off the main thread. All return an empty string on success,
// else a message for the user.
[[nodiscard]] QString installFromDir(const QString& srcDir, const QString& expectedId, const QString& pluginsDir);
[[nodiscard]] QString installFromArchive(
    const QString& archivePath, const QString& expectedId, const QString& expectedSha256, const QString& pluginsDir);
[[nodiscard]] QString removeInstalled(const QString& id, const QString& pluginsDir);

} // namespace caelestia::plugins
