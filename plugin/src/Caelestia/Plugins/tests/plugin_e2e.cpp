// End-to-end check of the host side of the plugin system: installs the
// bundled pomodoro plugin from a directory source, runs it, drives it through
// gRPC and removes it again.
//
//   CAELESTIA_BUNDLED_PLUGINS_DIR=build/plugins ctest -R plugins-e2e
//
// Runs with a private XDG_* so it never touches the user's real plugins.

#include <qcoreapplication.h>
#include <qcryptographichash.h>
#include <qdir.h>
#include <qelapsedtimer.h>
#include <qeventloop.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qprocess.h>
#include <qtemporarydir.h>
#include <qtest.h>
#include <qtimer.h>

#include "pluginmanager.hpp"

using namespace caelestia::plugins;
using Qt::StringLiterals::operator""_s;

class PluginE2E : public QObject {
    Q_OBJECT

private:
    // Spins the event loop until `cond` holds (or 10s pass).
    template <typename F> static bool waitFor(F cond, int timeoutMs = 10000) {
        QElapsedTimer t;
        t.start();
        while (!cond() && t.elapsed() < timeoutMs) {
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
            QTest::qWait(10);
        }
        return cond();
    }

    static QVariantMap pluginState(PluginManager& m, const QString& id) { return m.plugin(id); }

private slots:

    void idRules() {
        QVERIFY(isValidPluginId(u"pomodoro"_s));
        QVERIFY(isValidPluginId(u"my-plugin.2"_s));
        QVERIFY(!isValidPluginId(u""_s));
        QVERIFY(!isValidPluginId(u"../evil"_s));
        QVERIFY(!isValidPluginId(u"Upper"_s));
        QVERIFY(!isValidPluginId(u"a..b"_s));
        QVERIFY(!isValidPluginId(u"has space"_s));
    }

    void manifestRules() {
        QString err;
        QJsonObject ok{ { u"id"_s, u"x"_s }, { u"version"_s, u"1"_s }, { u"exec"_s, u"bin/x"_s },
            { u"api"_s, QJsonObject{ { u"major"_s, 1 } } } };
        QVERIFY(parseManifest(ok, &err).has_value());

        for (const QString& bad : { u"/abs/x"_s, u"../x"_s, u""_s, u"a//b"_s }) {
            QJsonObject o = ok;
            o[u"exec"_s] = bad;
            QVERIFY2(!parseManifest(o, &err).has_value(), qPrintable(bad));
        }
        QJsonObject noApi = ok;
        noApi.remove(u"api"_s);
        QVERIFY(!parseManifest(noApi, &err).has_value());
    }

    void fullLifecycle() {
        QVERIFY2(!qEnvironmentVariable("CAELESTIA_BUNDLED_PLUGINS_DIR").isEmpty(),
            "set CAELESTIA_BUNDLED_PLUGINS_DIR to the dir built by scripts/build-plugins.sh");

        QTemporaryDir home;
        QVERIFY(home.isValid());
        qputenv("XDG_DATA_HOME", (home.path() + u"/data"_s).toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (home.path() + u"/config"_s).toLocal8Bit());
        qputenv("XDG_RUNTIME_DIR", (home.path() + u"/run"_s).toLocal8Bit());
        QDir().mkpath(home.path() + u"/run"_s);

        PluginManager m;

        // The first-party source is there by default and lists pomodoro.
        QVERIFY(waitFor([&] {
            return !m.available().isEmpty();
        }));
        QCOMPARE(m.sources().size(), 1);
        QVERIFY(m.sources().at(0).toMap().value(u"builtin"_s).toBool());
        const QVariantMap avail = m.available().at(0).toMap();
        QCOMPARE(avail.value(u"id"_s).toString(), u"pomodoro"_s);
        QVERIFY(!avail.value(u"installed"_s).toBool());
        QVERIFY(avail.value(u"compatible"_s).toBool());
        QVERIFY(m.installed().isEmpty());

        // Install.
        m.install(u"pomodoro"_s, avail.value(u"source"_s).toString());
        QVERIFY(m.busy());
        QVERIFY(waitFor([&] {
            return !m.busy();
        }));
        QVERIFY2(m.lastError().isEmpty(), qPrintable(m.lastError()));
        QCOMPARE(m.installed().size(), 1);

        // It starts on its own and contributes a dashboard tab.
        QVERIFY2(waitFor([&] {
            return pluginState(m, u"pomodoro"_s).value(u"state"_s) == u"running"_s;
        }),
            qPrintable(pluginState(m, u"pomodoro"_s).value(u"error"_s).toString()));
        QVERIFY(waitFor([&] {
            return !m.dashboardTabs().isEmpty();
        }));
        const QVariantMap tab = m.dashboardTabs().at(0).toMap();
        QCOMPARE(tab.value(u"pluginId"_s).toString(), u"pomodoro"_s);
        QCOMPARE(tab.value(u"text"_s).toString(), u"Pomodoro"_s);
        const QString viewId = tab.value(u"viewId"_s).toString();

        // Initial view arrives and is a widget tree.
        QVERIFY(waitFor([&] {
            return !m.view(u"pomodoro"_s, viewId).isEmpty();
        }));
        QCOMPARE(m.view(u"pomodoro"_s, viewId).value(u"type"_s).toString(), u"column"_s);

        // Settings schema + defaults are available.
        QVERIFY(pluginState(m, u"pomodoro"_s).value(u"hasSettings"_s).toBool());
        QVariantMap values = m.settingValues(u"pomodoro"_s);
        QCOMPARE(values.value(u"focus_minutes"_s).toDouble(), 25.0);
        QCOMPARE(values.value(u"auto_start"_s).toBool(), false);

        const auto findText = [](const auto& self, const QVariantMap& node, const QString& needle) -> bool {
            if (node.value(u"text"_s).toString() == needle || node.value(u"label"_s).toString() == needle) {
                return true;
            }
            for (const QVariant& c : node.value(u"children"_s).toList()) {
                if (self(self, c.toMap(), needle)) {
                    return true;
                }
            }
            return false;
        };
        QVERIFY(findText(findText, m.view(u"pomodoro"_s, viewId), u"25:00"_s));

        // Changing a setting reaches the plugin and re-renders the view.
        m.setSetting(u"pomodoro"_s, u"focus_minutes"_s, 40);
        QVERIFY(waitFor([&] {
            return findText(findText, m.view(u"pomodoro"_s, viewId), u"40:00"_s);
        }));
        QCOMPARE(m.settingValues(u"pomodoro"_s).value(u"focus_minutes"_s).toDouble(), 40.0);
        // Out-of-range values are clamped, wrong types ignored.
        m.setSetting(u"pomodoro"_s, u"focus_minutes"_s, 100000);
        QCOMPARE(m.settingValues(u"pomodoro"_s).value(u"focus_minutes"_s).toDouble(), 180.0);
        m.setSetting(u"pomodoro"_s, u"auto_start"_s, u"yes"_s);
        QCOMPARE(m.settingValues(u"pomodoro"_s).value(u"auto_start"_s).toBool(), false);
        m.setSetting(u"pomodoro"_s, u"nope"_s, 1);
        m.resetSettings(u"pomodoro"_s);
        QVERIFY(waitFor([&] {
            return findText(findText, m.view(u"pomodoro"_s, viewId), u"25:00"_s);
        }));

        // Actions: start -> the timer ticks.
        QVERIFY(findText(findText, m.view(u"pomodoro"_s, viewId), u"Start"_s));
        m.invokeAction(u"pomodoro"_s, viewId, u"toggle"_s, {});
        QVERIFY(waitFor([&] {
            return findText(findText, m.view(u"pomodoro"_s, viewId), u"Pause"_s);
        }));
        QVERIFY(waitFor(
            [&] {
                return findText(findText, m.view(u"pomodoro"_s, viewId), u"24:58"_s);
            },
            6000));
        m.invokeAction(u"pomodoro"_s, viewId, u"reset"_s, {});
        QVERIFY(waitFor([&] {
            return findText(findText, m.view(u"pomodoro"_s, viewId), u"Start"_s);
        }));

        // Settings survive a restart of the plugin.
        m.setSetting(u"pomodoro"_s, u"focus_minutes"_s, 30);
        m.restart(u"pomodoro"_s);
        QVERIFY(waitFor([&] {
            return findText(findText, m.view(u"pomodoro"_s, viewId), u"30:00"_s);
        }));

        // Disable stops it and removes the tab; enable brings both back.
        m.setEnabled(u"pomodoro"_s, false);
        QVERIFY(waitFor([&] {
            return m.dashboardTabs().isEmpty();
        }));
        QVERIFY(waitFor([&] {
            return pluginState(m, u"pomodoro"_s).value(u"state"_s) == u"disabled"_s;
        }));
        m.setEnabled(u"pomodoro"_s, true);
        QVERIFY2(waitFor([&] {
            return !m.dashboardTabs().isEmpty();
        }),
            qPrintable(u"state=%1 error=%2"_s.arg(pluginState(m, u"pomodoro"_s).value(u"state"_s).toString(),
                pluginState(m, u"pomodoro"_s).value(u"error"_s).toString())));

        // Remove: gone from disk, settings and the lists.
        const QString pluginDir = home.path() + u"/data/caelestia/plugins/pomodoro"_s;
        QVERIFY(QDir(pluginDir).exists());
        m.remove(u"pomodoro"_s);
        QVERIFY(m.installed().isEmpty());
        QVERIFY(m.dashboardTabs().isEmpty());
        QVERIFY(!QDir(pluginDir).exists());
        QVERIFY(!QDir(home.path() + u"/config/caelestia/plugins/pomodoro"_s).exists());
        QVERIFY(!m.available().at(0).toMap().value(u"installed"_s).toBool());
    }

    void archiveInstall() {
        QTemporaryDir home;
        qputenv("XDG_DATA_HOME", (home.path() + u"/data"_s).toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (home.path() + u"/config"_s).toLocal8Bit());
        qputenv("XDG_RUNTIME_DIR", (home.path() + u"/run"_s).toLocal8Bit());
        const QString bundled = qEnvironmentVariable("CAELESTIA_BUNDLED_PLUGINS_DIR");

        // Package the real plugin like a release would: <id>/manifest.json + bin/...
        const QString src = home.path() + u"/src"_s;
        QDir().mkpath(src);
        QProcess tar;
        tar.start(u"tar"_s, { u"-czf"_s, src + u"/pomodoro.tar.gz"_s, u"-C"_s, bundled, u"pomodoro"_s });
        QVERIFY(tar.waitForFinished());
        QCOMPARE(tar.exitCode(), 0);

        QFile archive(src + u"/pomodoro.tar.gz"_s);
        QVERIFY(archive.open(QIODevice::ReadOnly));
        const QString sha =
            QString::fromLatin1(QCryptographicHash::hash(archive.readAll(), QCryptographicHash::Sha256).toHex());
        archive.close();

        const auto writeIndex = [&](const QString& digest) {
            QFile index(src + u"/index.json"_s);
            QVERIFY(index.open(QIODevice::WriteOnly | QIODevice::Truncate));
            index.write(QJsonDocument(
                QJsonObject{ { u"plugins"_s,
                    QJsonArray{ QJsonObject{ { u"id"_s, u"pomodoro"_s }, { u"name"_s, u"Pomodoro Timer"_s },
                        { u"version"_s, u"0.1.0"_s }, { u"exec"_s, u"bin/caelestia-plugin-pomodoro"_s },
                        { u"api"_s, QJsonObject{ { u"major"_s, 1 }, { u"minor"_s, 0 } } },
                        { u"archive"_s, u"pomodoro.tar.gz"_s }, { u"sha256"_s, digest } } } } })
                    .toJson());
        };

        // Point the bundled source nowhere so only the custom one is in play.
        qputenv("CAELESTIA_BUNDLED_PLUGINS_DIR", (home.path() + u"/none"_s).toLocal8Bit());
        PluginManager m;
        writeIndex(QString(64, u'0')); // wrong checksum
        m.addSource(u"Local"_s, src + u"/index.json"_s);
        QVERIFY(waitFor([&] {
            return !m.available().isEmpty();
        }));

        m.install(u"pomodoro"_s, u"Local"_s);
        QVERIFY(waitFor([&] {
            return !m.busy();
        }));
        QVERIFY2(m.lastError().contains(u"Checksum"_s), qPrintable(m.lastError()));
        QVERIFY(m.installed().isEmpty());

        // Right checksum installs and runs.
        writeIndex(sha);
        m.refreshAvailable();
        QVERIFY(waitFor([&] {
            return m.available().at(0).toMap().value(u"id"_s) == u"pomodoro"_s;
        }));
        m.install(u"pomodoro"_s, u"Local"_s);
        QVERIFY(waitFor([&] {
            return !m.busy();
        }));
        QVERIFY2(m.lastError().isEmpty(), qPrintable(m.lastError()));
        QVERIFY(waitFor([&] {
            return m.plugin(u"pomodoro"_s).value(u"state"_s) == u"running"_s;
        }));
        m.remove(u"pomodoro"_s);
        QVERIFY(m.installed().isEmpty());
        qputenv("CAELESTIA_BUNDLED_PLUGINS_DIR", bundled.toLocal8Bit());
    }

    void archiveWithTraversalIsRejected() {
        QTemporaryDir dir;
        // tar refuses to *create* "../" members by default; -P keeps the name as is.
        QDir().mkpath(dir.path() + u"/pkg"_s);
        QVERIFY(QFile(dir.path() + u"/pkg/f"_s).open(QIODevice::WriteOnly));
        QProcess tar;
        tar.setWorkingDirectory(dir.path() + u"/pkg"_s);
        tar.start(u"tar"_s, { u"-czPf"_s, dir.path() + u"/evil.tar.gz"_s, u"--transform=s,^f$,../escape,"_s, u"f"_s });
        QVERIFY(tar.waitForFinished());
        QCOMPARE(tar.exitCode(), 0);

        const QString err =
            installFromArchive(dir.path() + u"/evil.tar.gz"_s, u"evil"_s, {}, dir.path() + u"/plugins"_s);
        QVERIFY2(err.contains(u"unsafe"_s), qPrintable(err));
        QVERIFY(!QFileInfo::exists(dir.path() + u"/escape"_s));
    }

    void customSourcesAndIncompatible() {
        QTemporaryDir home;
        qputenv("XDG_DATA_HOME", (home.path() + u"/data"_s).toLocal8Bit());
        qputenv("XDG_CONFIG_HOME", (home.path() + u"/config"_s).toLocal8Bit());
        qputenv("XDG_RUNTIME_DIR", (home.path() + u"/run"_s).toLocal8Bit());

        // An index with one plugin that needs a newer API than the shell has.
        QDir().mkpath(home.path() + u"/src/future"_s);
        QFile index(home.path() + u"/src/index.json"_s);
        QVERIFY(index.open(QIODevice::WriteOnly));
        index.write(R"({"plugins":[{"id":"future","name":"Future","version":"1.0.0","exec":"bin/f",
            "api":{"major":99,"minor":0},"path":"future"}]})");
        index.close();

        PluginManager m;
        m.addSource(u"Local"_s, home.path() + u"/src/index.json"_s);
        QCOMPARE(m.sources().size(), 2);
        QVERIFY(waitFor([&] {
            for (const QVariant& a : m.available()) {
                if (a.toMap().value(u"id"_s) == u"future"_s) {
                    return true;
                }
            }
            return false;
        }));
        m.install(u"future"_s, u"Local"_s);
        QVERIFY(!m.lastError().isEmpty());
        QVERIFY(m.installed().isEmpty());

        // Duplicates are rejected, the built-in source can't be removed.
        m.addSource(u"Local"_s, u"/elsewhere"_s);
        QCOMPARE(m.sources().size(), 2);
        m.removeSource(u"bundled:"_s);
        QCOMPARE(m.sources().size(), 2);
        m.removeSource(home.path() + u"/src/index.json"_s);
        QCOMPARE(m.sources().size(), 1);
    }
};

QTEST_MAIN(PluginE2E)
#include "plugin_e2e.moc"
