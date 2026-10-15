#include "pluginmanager.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qfuturewatcher.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qnetworkreply.h>
#include <qnetworkrequest.h>
#include <qstandardpaths.h>
#include <qtconcurrentrun.h>
#include <qtemporaryfile.h>
#include <qtimer.h>
#include <qurl.h>

#include <unistd.h>

#include <algorithm>
#include <cmath>

namespace caelestia::plugins {

using Qt::StringLiterals::operator""_s;

namespace {

constexpr auto k_bundledUrl = "bundled:";
constexpr auto k_bundledName = "Caelestia";

QString dataHome() {
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + u"/caelestia"_s;
}

QString configHome() {
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + u"/caelestia"_s;
}

QVariant readJson(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QJsonDocument::fromJson(file.readAll()).toVariant();
}

bool writeJson(const QString& path, const QVariant& value) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    // Atomic replace: a crash mid-write must not wipe the user's settings.
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return false;
    }
    file.write(QJsonDocument::fromVariant(value).toJson(QJsonDocument::Indented));
    return file.flush();
}

// Splits "1.2.3" into numbers for ordering; non-numeric parts compare as 0.
QList<int> versionParts(const QString& v) {
    QList<int> parts;
    for (const QString& p : v.split(u'.')) {
        parts.append(p.toInt());
    }
    return parts;
}

bool isNewer(const QString& candidate, const QString& installed) {
    return std::lexicographical_compare(versionParts(installed).begin(), versionParts(installed).end(),
        versionParts(candidate).begin(), versionParts(candidate).end());
}

// Resolves a source URL to a local path, or an empty string for remote ones.
QString localSourcePath(const QString& url) {
    if (url.startsWith(u"file://"_s)) {
        return QUrl(url).toLocalFile();
    }
    if (url.startsWith(u"http://"_s) || url.startsWith(u"https://"_s)) {
        return {};
    }
    return url;
}

bool isRemote(const QString& url) {
    return url.startsWith(u"http://"_s) || url.startsWith(u"https://"_s);
}

// The field description for `key`, or an empty map.
QVariantMap fieldFor(const QVariantList& schema, const QString& key) {
    for (const QVariant& section : schema) {
        const QVariantList fields = section.toMap().value(u"fields"_s).toList();
        for (const QVariant& f : fields) {
            const QVariantMap field = f.toMap();
            if (field.value(u"key"_s).toString() == key) {
                return field;
            }
        }
    }
    return {};
}

// Coerces `value` to what `field` accepts. Returns an invalid QVariant if it can't be.
QVariant coerce(const QVariantMap& field, const QVariant& value) {
    const QString type = field.value(u"type"_s).toString();
    if (type == u"toggle"_s) {
        return value.typeId() == QMetaType::Bool ? value : QVariant();
    }
    if (type == u"number"_s) {
        bool ok = false;
        double n = value.toDouble(&ok);
        if (!ok || !std::isfinite(n)) {
            return {};
        }
        if (field.value(u"integer"_s).toBool()) {
            n = std::round(n);
        }
        const double lo = field.value(u"min"_s).toDouble();
        const double hi = field.value(u"max"_s).toDouble();
        if (hi >= lo) {
            n = std::clamp(n, lo, hi);
        }
        return n;
    }
    if (type == u"text"_s) {
        return value.typeId() == QMetaType::QString ? value : QVariant();
    }
    if (type == u"choice"_s) {
        const QString s = value.toString();
        const QVariantList options = field.value(u"options"_s).toList();
        const bool known = std::any_of(options.begin(), options.end(), [&](const QVariant& o) {
            return o.toMap().value(u"value"_s).toString() == s;
        });
        return known ? QVariant(s) : QVariant();
    }
    return {};
}

} // namespace

PluginManager::PluginManager(QObject* parent)
    : QObject(parent)
    , m_net(new QNetworkAccessManager(this)) {
    m_sources.append({ QString::fromLatin1(k_bundledName), QString::fromLatin1(k_bundledUrl), true, {}, {} });

    loadState();
    scanInstalled();
    for (int i = 0; i < m_sources.size(); ++i) {
        refreshSource(i);
    }

    // Let the QML engine finish coming up before child processes appear.
    QTimer::singleShot(0, this, [this] {
        for (auto& plugin : m_plugins) {
            startPlugin(plugin);
        }
    });
}

PluginManager::~PluginManager() {
    for (auto& plugin : m_plugins) {
        delete plugin.host; // terminates the process, see ~PluginHost
        plugin.host = nullptr;
    }
}

QString PluginManager::apiVersion() const {
    return QString::number(hostApiVersion.major) + u'.' + QString::number(hostApiVersion.minor);
}

// ------------------------------------------------------------------ paths

QString PluginManager::pluginsDir() const {
    return dataHome() + u"/plugins"_s;
}

QString PluginManager::dataDirFor(const QString& id) const {
    return dataHome() + u"/plugin-data/"_s + id;
}

QString PluginManager::settingsDirFor(const QString& id) const {
    return configHome() + u"/plugins/"_s + id;
}

QString PluginManager::socketFor(const QString& id) const {
    // sun_path holds 108 bytes including the terminator.
    constexpr qsizetype k_maxPath = 100;

    QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (!runtime.isEmpty()) {
        const QString path = runtime + u"/caelestia-plugins/"_s + id + u".sock"_s;
        if (path.toUtf8().size() <= k_maxPath) {
            return path;
        }
    }
    // No runtime dir or an unusually deep one: a short per-user directory
    // (PluginHost checks that it is ours and private).
    return QDir::tempPath() + u"/caelestia-plugins-"_s + QString::number(::geteuid()) + u'/' + id + u".sock"_s;
}

QString PluginManager::bundledDir() const {
    const QString env = qEnvironmentVariable("CAELESTIA_BUNDLED_PLUGINS_DIR");
    if (!env.isEmpty()) {
        return env;
    }
    const QStringList dirs = QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation);
    for (const QString& dir : dirs) {
        const QString candidate = dir + u"/caelestia-shell/plugins"_s;
        if (QFileInfo(candidate).isDir()) {
            return candidate;
        }
    }
    return {};
}

// ------------------------------------------------------------------ state

void PluginManager::loadState() {
    const QVariantMap state = readJson(configHome() + u"/plugins.json"_s).toMap();

    for (const QVariant& s : state.value(u"sources"_s).toList()) {
        const QVariantMap map = s.toMap();
        const QString url = map.value(u"url"_s).toString();
        const QString name = map.value(u"name"_s).toString();
        if (!url.isEmpty() && !name.isEmpty() && url != QString::fromLatin1(k_bundledUrl)) {
            m_sources.append({ name, url, false, {}, {} });
        }
    }

    m_disabled.clear();
    for (const QVariant& id : state.value(u"disabled"_s).toList()) {
        m_disabled.insert(id.toString());
    }
}

void PluginManager::saveState() const {
    QVariantList sources;
    for (const Source& s : m_sources) {
        if (!s.builtin) {
            sources.append(QVariantMap{ { u"name"_s, s.name }, { u"url"_s, s.url } });
        }
    }
    QVariantList disabled;
    for (const QString& id : m_disabled) {
        disabled.append(id);
    }
    writeJson(configHome() + u"/plugins.json"_s, QVariantMap{ { u"sources"_s, sources }, { u"disabled"_s, disabled } });
}

void PluginManager::scanInstalled() {
    m_scanErrors.clear();
    const QList<InstalledPlugin> found = plugins::scanInstalled(pluginsDir(), &m_scanErrors);

    QSet<QString> seen;
    for (const InstalledPlugin& info : found) {
        const QString id = info.manifest.id;
        seen.insert(id);

        Plugin& plugin = m_plugins[id];
        plugin.info = info;
        plugin.enabled = !m_disabled.contains(id);
        plugin.incompatible = isCompatible(info.manifest.api, hostApiVersion)
                                  ? QString()
                                  : tr("Needs plugin API %1.%2, this shell provides %3")
                                        .arg(info.manifest.api.major)
                                        .arg(info.manifest.api.minor)
                                        .arg(apiVersion());
        plugin.overrides = readJson(settingsDirFor(id) + u"/settings.json"_s).toMap();
        loadSchemaCache(plugin);
    }

    for (auto it = m_plugins.begin(); it != m_plugins.end();) {
        if (!seen.contains(it.key())) {
            delete it->host;
            it = m_plugins.erase(it);
        } else {
            ++it;
        }
    }

    rebuildInstalled();
    rebuildAvailable();
    rebuildTabs();
}

void PluginManager::loadSchemaCache(Plugin& plugin) const {
    // So the settings page works while the plugin isn't running.
    if (plugin.schema.isEmpty()) {
        plugin.schema = readJson(settingsDirFor(plugin.info.manifest.id) + u"/schema.json"_s).toList();
    }
}

// -------------------------------------------------------------- lifecycle

void PluginManager::startPlugin(Plugin& plugin) {
    if (!plugin.enabled || !plugin.incompatible.isEmpty()) {
        return;
    }
    if (!plugin.host) {
        createHost(plugin);
    }
    plugin.host->start(); // no-op while it is starting or running
}

void PluginManager::createHost(Plugin& plugin) {
    const QString id = plugin.info.manifest.id;
    plugin.host = new PluginHost({ id, plugin.info.dir + u'/' + plugin.info.manifest.exec, dataDirFor(id),
                                     socketFor(id), QStringLiteral(CAELESTIA_VERSION) },
        this);

    connect(plugin.host, &PluginHost::stateChanged, this, [this, id] {
        auto it = m_plugins.find(id);
        if (it != m_plugins.end() && it->host && it->host->state() != PluginHost::State::Running) {
            // Tabs/views of a plugin that went away are gone with it.
            it->views.clear();
            it->tabs.clear();
            rebuildTabs();
        }
        rebuildInstalled();
    });
    connect(plugin.host, &PluginHost::handshaken, this,
        [this, id](const QString& version, const QVariantList& tabs, const QVariantList& schema) {
            onHandshaken(id, version, tabs, schema);
        });
    connect(plugin.host, &PluginHost::viewUpdated, this, [this, id](const QString& viewId, const QVariantMap& tree) {
        auto it = m_plugins.find(id);
        if (it == m_plugins.end()) {
            return;
        }
        it->views.insert(viewId, tree);
        emit viewUpdated(id, viewId);
    });
    connect(plugin.host, &PluginHost::notification, this, [this, id](const QVariantMap& n) {
        const auto it = m_plugins.constFind(id);
        if (it == m_plugins.constEnd()) {
            return;
        }
        emit notificationRequested(id, it->info.manifest.name, n.value(u"title"_s).toString(),
            n.value(u"body"_s).toString(), n.value(u"icon"_s).toString(), n.value(u"urgency"_s).toString());
    });
    connect(plugin.host, &PluginHost::actionFailed, this, [this, id](const QString& message) {
        qWarning().noquote() << "plugin" << id << ":" << message;
        setError(tr("%1: %2").arg(id, message));
    });
}

void PluginManager::destroyHost(Plugin& plugin) {
    if (plugin.host) {
        delete plugin.host;
        plugin.host = nullptr;
    }
    plugin.views.clear();
    plugin.tabs.clear();
}

void PluginManager::onHandshaken(
    const QString& id, const QString& version, const QVariantList& tabs, const QVariantList& schema) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end() || !it->host) {
        return;
    }
    Plugin& plugin = *it;
    plugin.runtimeVersion = version;
    plugin.tabs = tabs;
    plugin.schema = schema;
    writeJson(settingsDirFor(id) + u"/schema.json"_s, schema);

    // Settings first so the very first view already reflects them.
    plugin.host->applySettings(effectiveSettings(plugin));
    for (const QVariant& t : tabs) {
        plugin.host->fetchView(t.toMap().value(u"viewId"_s).toString());
    }

    rebuildInstalled();
    rebuildTabs();
    emit settingsChanged(id);
}

void PluginManager::setEnabled(const QString& id, bool enabled) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end() || it->enabled == enabled) {
        return;
    }
    it->enabled = enabled;
    if (enabled) {
        m_disabled.remove(id);
    } else {
        m_disabled.insert(id);
    }
    saveState();

    if (enabled) {
        startPlugin(*it);
    } else if (it->host) {
        // Graceful, asynchronous stop; the host reports Stopped when done.
        it->host->stop();
        it->views.clear();
        it->tabs.clear();
        rebuildTabs();
    }
    rebuildInstalled();
}

void PluginManager::restart(const QString& id) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end() || !it->enabled) {
        return;
    }
    destroyHost(*it);
    rebuildTabs();
    startPlugin(*it);
    rebuildInstalled();
}

void PluginManager::remove(const QString& id) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end() || m_busy) {
        return;
    }
    destroyHost(*it);

    const QString error = removeInstalled(id, pluginsDir());
    if (!error.isEmpty()) {
        setError(error);
        return;
    }
    // A removed plugin leaves nothing behind: its settings and data go too.
    QDir(settingsDirFor(id)).removeRecursively();
    QDir(dataDirFor(id)).removeRecursively();
    m_disabled.remove(id);
    m_plugins.erase(it);
    saveState();

    rebuildInstalled();
    rebuildAvailable();
    rebuildTabs();
}

void PluginManager::install(const QString& id, const QString& sourceName) {
    if (m_busy) {
        return;
    }

    const SourceEntry* entry = nullptr;
    for (const Source& source : std::as_const(m_sources)) {
        if (source.name != sourceName) {
            continue;
        }
        for (const SourceEntry& e : source.entries) {
            if (e.manifest.id == id) {
                entry = &e;
            }
        }
    }
    if (!entry) {
        setError(tr("Plugin '%1' is not available from '%2'").arg(id, sourceName));
        return;
    }
    if (!isCompatible(entry->manifest.api, hostApiVersion)) {
        setError(tr("'%1' needs plugin API %2.%3, this shell provides %4")
                .arg(entry->manifest.name)
                .arg(entry->manifest.api.major)
                .arg(entry->manifest.api.minor)
                .arg(apiVersion()));
        return;
    }

    setError({});
    setBusy(id);

    // Updating: the old process must be gone before its files are swapped.
    if (auto it = m_plugins.find(id); it != m_plugins.end()) {
        destroyHost(*it);
        rebuildTabs();
    }

    const SourceEntry copy = *entry;
    if (!copy.dir.isEmpty()) {
        auto* watcher = new QFutureWatcher<QString>(this);
        connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, id] {
            finishInstall(id, watcher->result());
            watcher->deleteLater();
        });
        watcher->setFuture(QtConcurrent::run([copy, dir = pluginsDir()] {
            return installFromDir(copy.dir, copy.manifest.id, dir);
        }));
    } else {
        downloadAndInstall(copy);
    }
}

void PluginManager::downloadAndInstall(const SourceEntry& entry) {
    const QString id = entry.manifest.id;

    const auto installFile = [this, id, entry](const QString& path, bool temporary) {
        auto* watcher = new QFutureWatcher<QString>(this);
        connect(watcher, &QFutureWatcher<QString>::finished, this, [this, watcher, id, path, temporary] {
            if (temporary) {
                QFile::remove(path);
            }
            finishInstall(id, watcher->result());
            watcher->deleteLater();
        });
        watcher->setFuture(QtConcurrent::run([entry, path, dir = pluginsDir()] {
            return installFromArchive(path, entry.manifest.id, entry.sha256, dir);
        }));
    };

    if (!isRemote(entry.archive)) {
        installFile(localSourcePath(entry.archive), false);
        return;
    }

    QNetworkReply* reply = m_net->get(QNetworkRequest(QUrl(entry.archive)));
    connect(reply, &QNetworkReply::finished, this, [this, reply, id, installFile] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            finishInstall(id, tr("Download failed: %1").arg(reply->errorString()));
            return;
        }
        QTemporaryFile tmp(QDir::tempPath() + u"/caelestia-plugin-XXXXXX.tar.gz"_s);
        tmp.setAutoRemove(false);
        if (!tmp.open() || tmp.write(reply->readAll()) < 0) {
            finishInstall(id, tr("Cannot store the download"));
            return;
        }
        const QString path = tmp.fileName();
        tmp.close();
        installFile(path, true);
    });
}

void PluginManager::finishInstall(const QString& id, const QString& error) {
    if (!error.isEmpty()) {
        setError(error);
    }
    scanInstalled();
    if (error.isEmpty()) {
        if (auto it = m_plugins.find(id); it != m_plugins.end()) {
            startPlugin(*it);
            rebuildInstalled();
        }
    }
    setBusy({});
}

// ---------------------------------------------------------------- sources

void PluginManager::addSource(const QString& name, const QString& url) {
    const QString trimmedName = name.trimmed();
    const QString trimmedUrl = url.trimmed();
    if (trimmedName.isEmpty() || trimmedUrl.isEmpty()) {
        setError(tr("A source needs a name and a location"));
        return;
    }
    const bool duplicate = std::any_of(m_sources.begin(), m_sources.end(), [&](const Source& s) {
        return s.name == trimmedName || s.url == trimmedUrl;
    });
    if (duplicate) {
        setError(tr("That source already exists"));
        return;
    }

    setError({});
    m_sources.append({ trimmedName, trimmedUrl, false, {}, {} });
    saveState();
    rebuildSources();
    refreshSource(static_cast<int>(m_sources.size()) - 1);
}

void PluginManager::removeSource(const QString& url) {
    for (int i = 0; i < m_sources.size(); ++i) {
        if (m_sources[i].url == url && !m_sources[i].builtin) {
            m_sources.removeAt(i);
            saveState();
            rebuildSources();
            rebuildAvailable();
            return;
        }
    }
}

void PluginManager::refreshAvailable() {
    for (int i = 0; i < m_sources.size(); ++i) {
        refreshSource(i);
    }
}

void PluginManager::refreshSource(int index) {
    const Source& source = m_sources.at(index);
    const QString name = source.name;

    if (source.builtin) {
        const QString dir = bundledDir();
        finishSource(index, dir.isEmpty() ? SourceListing{ {}, tr("Bundled plugin directory not found") }
                                          : listDirectorySource(dir, name));
        return;
    }

    if (!isRemote(source.url)) {
        const QString path = localSourcePath(source.url);
        if (QFileInfo(path).isDir()) {
            finishSource(index, listDirectorySource(path, name));
        } else if (QFile file(path); file.open(QIODevice::ReadOnly)) {
            finishSource(index, parseIndex(file.readAll(), QFileInfo(path).absolutePath(), false, name));
        } else {
            finishSource(index, { {}, tr("Cannot read %1").arg(path) });
        }
        return;
    }

    const QString url = source.url;
    QNetworkReply* reply = m_net->get(QNetworkRequest(QUrl(url)));
    connect(reply, &QNetworkReply::finished, this, [this, reply, url, name] {
        reply->deleteLater();
        // The list may have changed while the request was in flight.
        const auto it = std::find_if(m_sources.begin(), m_sources.end(), [&](const Source& s) {
            return s.url == url;
        });
        if (it == m_sources.end()) {
            return;
        }
        const int sourceIndex = static_cast<int>(it - m_sources.begin());
        if (reply->error() != QNetworkReply::NoError) {
            finishSource(sourceIndex, { {}, reply->errorString() });
        } else {
            finishSource(sourceIndex, parseIndex(reply->readAll(), url, true, name));
        }
    });
}

void PluginManager::finishSource(int index, SourceListing listing) {
    Source& source = m_sources[index];
    source.entries = std::move(listing.entries);
    source.error = listing.error;
    rebuildSources();
    rebuildAvailable();
}

// --------------------------------------------------------------- settings

QVariantMap PluginManager::effectiveSettings(const Plugin& plugin) const {
    QVariantMap values;
    for (const QVariant& section : plugin.schema) {
        for (const QVariant& f : section.toMap().value(u"fields"_s).toList()) {
            const QVariantMap field = f.toMap();
            const QString key = field.value(u"key"_s).toString();
            QVariant value = coerce(field, plugin.overrides.value(key));
            if (!value.isValid()) {
                value = field.value(u"default"_s);
                // The proto's number default is a double; keep types stable.
                if (field.value(u"type"_s).toString() == u"number"_s) {
                    value = value.toDouble();
                }
            }
            values.insert(key, value);
        }
    }
    return values;
}

QVariantList PluginManager::settingsSchema(const QString& id) const {
    return m_plugins.value(id).schema;
}

QVariantMap PluginManager::settingValues(const QString& id) const {
    const auto it = m_plugins.constFind(id);
    return it == m_plugins.constEnd() ? QVariantMap() : effectiveSettings(*it);
}

void PluginManager::setSetting(const QString& id, const QString& key, const QVariant& value) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end()) {
        return;
    }
    const QVariantMap field = fieldFor(it->schema, key);
    if (field.isEmpty()) {
        return;
    }
    const QVariant coerced = coerce(field, value);
    if (!coerced.isValid()) {
        return;
    }

    // Storing a value equal to the default would pin it against future default changes.
    const QVariant def = field.value(u"default"_s);
    if (coerced == def ||
        (coerced.typeId() == QMetaType::Double && qFuzzyCompare(coerced.toDouble() + 1.0, def.toDouble() + 1.0))) {
        it->overrides.remove(key);
    } else {
        it->overrides.insert(key, coerced);
    }
    saveOverrides(id);

    if (it->host) {
        it->host->applySettings(effectiveSettings(*it));
    }
    emit settingsChanged(id);
}

void PluginManager::resetSettings(const QString& id) {
    auto it = m_plugins.find(id);
    if (it == m_plugins.end()) {
        return;
    }
    it->overrides.clear();
    saveOverrides(id);
    if (it->host) {
        it->host->applySettings(effectiveSettings(*it));
    }
    emit settingsChanged(id);
}

void PluginManager::saveOverrides(const QString& id) const {
    const QString path = settingsDirFor(id) + u"/settings.json"_s;
    const auto it = m_plugins.constFind(id);
    if (it == m_plugins.constEnd() || it->overrides.isEmpty()) {
        QFile::remove(path);
        return;
    }
    writeJson(path, it->overrides);
}

// ------------------------------------------------------------------ views

QVariantMap PluginManager::view(const QString& pluginId, const QString& viewId) const {
    return m_plugins.value(pluginId).views.value(viewId);
}

void PluginManager::invokeAction(
    const QString& pluginId, const QString& viewId, const QString& actionId, const QString& payload) {
    const auto it = m_plugins.constFind(pluginId);
    if (it != m_plugins.constEnd() && it->host) {
        it->host->invokeAction(viewId, actionId, payload);
    }
}

QVariantMap PluginManager::plugin(const QString& id) const {
    for (const QVariant& v : m_installedCache) {
        if (v.toMap().value(u"id"_s).toString() == id) {
            return v.toMap();
        }
    }
    return {};
}

// ------------------------------------------------------------ cache views

QString PluginManager::stateName(const Plugin& plugin) {
    if (!plugin.incompatible.isEmpty()) {
        return u"incompatible"_s;
    }
    if (!plugin.enabled) {
        return u"disabled"_s;
    }
    if (!plugin.host) {
        return u"stopped"_s;
    }
    switch (plugin.host->state()) {
    case PluginHost::State::Starting:
        return u"starting"_s;
    case PluginHost::State::Running:
        return u"running"_s;
    case PluginHost::State::Failed:
        return u"failed"_s;
    case PluginHost::State::Stopped:
        break;
    }
    return u"stopped"_s;
}

void PluginManager::rebuildInstalled() {
    QVariantList list;
    for (auto it = m_plugins.cbegin(); it != m_plugins.cend(); ++it) {
        const Plugin& p = *it;
        const Manifest& m = p.info.manifest;

        QString error = p.incompatible;
        if (error.isEmpty() && p.host) {
            error = p.host->error();
        }

        bool update = false;
        for (const Source& s : m_sources) {
            for (const SourceEntry& e : s.entries) {
                update = update || (e.manifest.id == m.id && isNewer(e.manifest.version, m.version));
            }
        }

        // Prefer what the running process reports for the tab/settings hints, else the cache.
        list.append(QVariantMap{ { u"id"_s, m.id }, { u"name"_s, m.name }, { u"version"_s, m.version },
            { u"description"_s, m.description }, { u"author"_s, m.author }, { u"icon"_s, m.icon },
            { u"homepage"_s, m.homepage }, { u"enabled"_s, p.enabled }, { u"state"_s, stateName(p) },
            { u"error"_s, error }, { u"hasSettings"_s, !p.schema.isEmpty() }, { u"hasDashboard"_s, !p.tabs.isEmpty() },
            { u"updateAvailable"_s, update } });
    }
    for (auto it = m_scanErrors.cbegin(); it != m_scanErrors.cend(); ++it) {
        list.append(QVariantMap{ { u"id"_s, it.key() }, { u"name"_s, it.key() }, { u"version"_s, QString() },
            { u"description"_s, QString() }, { u"author"_s, QString() }, { u"icon"_s, u"error"_s },
            { u"homepage"_s, QString() }, { u"enabled"_s, false }, { u"state"_s, u"broken"_s },
            { u"error"_s, it.value().toString() }, { u"hasSettings"_s, false }, { u"hasDashboard"_s, false },
            { u"updateAvailable"_s, false } });
    }
    m_installedCache = list;
    emit installedChanged();
}

void PluginManager::rebuildAvailable() {
    QVariantList list;
    for (const Source& source : std::as_const(m_sources)) {
        for (const SourceEntry& e : source.entries) {
            const Manifest& m = e.manifest;
            const auto installed = m_plugins.constFind(m.id);
            const bool isInstalled = installed != m_plugins.constEnd();
            const QString installedVersion = isInstalled ? installed->info.manifest.version : QString();
            list.append(QVariantMap{ { u"id"_s, m.id }, { u"name"_s, m.name }, { u"version"_s, m.version },
                { u"description"_s, m.description }, { u"author"_s, m.author }, { u"icon"_s, m.icon },
                { u"source"_s, source.name }, { u"installed"_s, isInstalled },
                { u"installedVersion"_s, installedVersion },
                { u"updateAvailable"_s, isInstalled && isNewer(m.version, installedVersion) },
                { u"compatible"_s, isCompatible(m.api, hostApiVersion) } });
        }
    }
    m_availableCache = list;
    emit availableChanged();
    // "update available" lives on the installed entries too.
    rebuildInstalled();
}

void PluginManager::rebuildSources() {
    QVariantList list;
    for (const Source& s : std::as_const(m_sources)) {
        list.append(QVariantMap{ { u"name"_s, s.name }, { u"url"_s, s.url }, { u"builtin"_s, s.builtin },
            { u"error"_s, s.error }, { u"count"_s, static_cast<int>(s.entries.size()) } });
    }
    m_sourcesCache = list;
    emit sourcesChanged();
}

void PluginManager::rebuildTabs() {
    QVariantList list;
    for (auto it = m_plugins.cbegin(); it != m_plugins.cend(); ++it) {
        if (!it->enabled || !it->host || it->host->state() != PluginHost::State::Running) {
            continue;
        }
        for (const QVariant& t : it->tabs) {
            const QVariantMap tab = t.toMap();
            list.append(QVariantMap{ { u"pluginId"_s, it.key() }, { u"viewId"_s, tab.value(u"viewId"_s) },
                { u"text"_s, tab.value(u"title"_s) }, { u"iconName"_s, tab.value(u"icon"_s) } });
        }
    }
    if (list != m_tabsCache) {
        m_tabsCache = list;
        emit dashboardTabsChanged();
    }
}

void PluginManager::setBusy(const QString& id) {
    m_busy = !id.isEmpty();
    m_busyId = id;
    emit busyChanged();
}

void PluginManager::setError(const QString& error) {
    if (m_lastError == error) {
        return;
    }
    m_lastError = error;
    emit lastErrorChanged();
}

} // namespace caelestia::plugins
