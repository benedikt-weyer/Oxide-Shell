#pragma once

#include <qhash.h>
#include <qnetworkaccessmanager.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qset.h>
#include <qvariant.h>

#include "pluginhost.hpp"
#include "pluginstore.hpp"

namespace caelestia::plugins {

// QML-facing plugin system: knows which plugins are installed and available,
// runs the enabled ones and exposes their dashboard tabs, views and settings.
//
// Everything QML needs is plain QVariant data (lists/maps), so the Nexus pages
// and the dashboard stay free of protocol details. See plugin-sdk/README.md
// for the plugin side of the contract.
class PluginManager : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    // [{id, name, version, description, author, icon, homepage, enabled, state, error, hasSettings, hasDashboard,
    //   updateAvailable}]
    // state: "disabled" | "stopped" | "starting" | "running" | "failed" | "incompatible"
    Q_PROPERTY(QVariantList installed READ installed NOTIFY installedChanged)
    // [{id, name, version, description, author, icon, source, installed, installedVersion, updateAvailable,
    // compatible}]
    Q_PROPERTY(QVariantList available READ available NOTIFY availableChanged)
    // [{name, url, builtin, error, count}]
    Q_PROPERTY(QVariantList sources READ sources NOTIFY sourcesChanged)
    // [{pluginId, viewId, text, iconName}]
    Q_PROPERTY(QVariantList dashboardTabs READ dashboardTabs NOTIFY dashboardTabsChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)
    // Id of the plugin (or source) an operation is running for.
    Q_PROPERTY(QString busyId READ busyId NOTIFY busyChanged)
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)
    Q_PROPERTY(QString apiVersion READ apiVersion CONSTANT)

public:
    explicit PluginManager(QObject* parent = nullptr);
    ~PluginManager() override;

    [[nodiscard]] QVariantList installed() const { return m_installedCache; }

    [[nodiscard]] QVariantList available() const { return m_availableCache; }

    [[nodiscard]] QVariantList sources() const { return m_sourcesCache; }

    [[nodiscard]] QVariantList dashboardTabs() const { return m_tabsCache; }

    [[nodiscard]] bool busy() const { return m_busy; }

    [[nodiscard]] QString busyId() const { return m_busyId; }

    [[nodiscard]] QString lastError() const { return m_lastError; }

    [[nodiscard]] QString apiVersion() const;

    // Lifecycle
    Q_INVOKABLE void install(const QString& id, const QString& sourceName);
    Q_INVOKABLE void remove(const QString& id);
    Q_INVOKABLE void setEnabled(const QString& id, bool enabled);
    Q_INVOKABLE void restart(const QString& id);
    Q_INVOKABLE void refreshAvailable();

    // Sources
    Q_INVOKABLE void addSource(const QString& name, const QString& url);
    Q_INVOKABLE void removeSource(const QString& url);

    // Views (dashboard)
    Q_INVOKABLE QVariantMap view(const QString& pluginId, const QString& viewId) const;
    Q_INVOKABLE void invokeAction(
        const QString& pluginId, const QString& viewId, const QString& actionId, const QString& payload);

    // Settings pages. `schema`: [{title, description, fields: [{key, label, description, type, default, ...}]}]
    Q_INVOKABLE QVariantList settingsSchema(const QString& id) const;
    Q_INVOKABLE QVariantMap settingValues(const QString& id) const;
    Q_INVOKABLE void setSetting(const QString& id, const QString& key, const QVariant& value);
    Q_INVOKABLE void resetSettings(const QString& id);
    Q_INVOKABLE QVariantMap plugin(const QString& id) const;

signals:
    void installedChanged();
    void availableChanged();
    void sourcesChanged();
    void dashboardTabsChanged();
    void busyChanged();
    void lastErrorChanged();
    void viewUpdated(const QString& pluginId, const QString& viewId);
    void settingsChanged(const QString& pluginId);
    // urgency: "low" | "normal" | "critical"
    void notificationRequested(const QString& pluginId, const QString& pluginName, const QString& title,
        const QString& body, const QString& icon, const QString& urgency);

private:
    struct Plugin {
        InstalledPlugin info;
        bool enabled = true;
        QString incompatible;
        PluginHost* host = nullptr;
        QString runtimeVersion;
        QVariantList tabs;
        QVariantList schema;
        QVariantMap overrides;
        QHash<QString, QVariantMap> views;
    };

    struct Source {
        QString name;
        QString url;
        bool builtin = false;
        QString error;
        QList<SourceEntry> entries;
    };

    void loadState();
    void saveState() const;
    void scanInstalled();
    void startPlugin(Plugin& plugin);
    void createHost(Plugin& plugin);
    void destroyHost(Plugin& plugin);
    void onHandshaken(const QString& id, const QString& version, const QVariantList& tabs, const QVariantList& schema);
    void loadSchemaCache(Plugin& plugin) const;

    void refreshSource(int index);
    void finishSource(int index, SourceListing listing);
    void setBusy(const QString& id);
    void setError(const QString& error);
    void finishInstall(const QString& id, const QString& error);
    void downloadAndInstall(const SourceEntry& entry);

    void rebuildInstalled();
    void rebuildAvailable();
    void rebuildSources();
    void rebuildTabs();

    [[nodiscard]] QString pluginsDir() const;
    [[nodiscard]] QString dataDirFor(const QString& id) const;
    [[nodiscard]] QString settingsDirFor(const QString& id) const;
    [[nodiscard]] QString socketFor(const QString& id) const;
    [[nodiscard]] QString bundledDir() const;
    [[nodiscard]] QVariantMap effectiveSettings(const Plugin& plugin) const;
    void saveOverrides(const QString& id) const;
    static QString stateName(const Plugin& plugin);

    QMap<QString, Plugin> m_plugins;
    // Ids the user switched off; also remembered for plugins that aren't installed right now.
    QSet<QString> m_disabled;
    QList<Source> m_sources;
    QNetworkAccessManager* m_net = nullptr;

    bool m_busy = false;
    QString m_busyId;
    QString m_lastError;
    // Plugins that failed to even load (broken manifest), id -> message.
    QVariantMap m_scanErrors;

    QVariantList m_installedCache;
    QVariantList m_availableCache;
    QVariantList m_sourcesCache;
    QVariantList m_tabsCache;
};

} // namespace caelestia::plugins
