#include "pluginstore.hpp"

#include <qcryptographichash.h>
#include <qdir.h>
#include <qdiriterator.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qprocess.h>
#include <qregularexpression.h>
#include <qtemporarydir.h>
#include <qurl.h>

namespace caelestia::plugins {

using Qt::StringLiterals::operator""_s;

bool isValidPluginId(const QString& id) {
    // Also becomes a directory and a socket name, so keep it boring.
    static const QRegularExpression k_idPattern(u"^[a-z0-9][a-z0-9._-]{0,47}$"_s);
    return k_idPattern.match(id).hasMatch() && !id.contains(u".."_s);
}

namespace {

bool isSafeRelativePath(const QString& path) {
    if (path.isEmpty() || path.startsWith(u'/') || path.contains(u'\\')) {
        return false;
    }
    const QStringList parts = path.split(u'/');
    return std::none_of(parts.begin(), parts.end(), [](const QString& p) {
        return p == u".."_s || p.isEmpty();
    });
}

QString shellQuote(const QString& arg) {
    QString quoted = arg;
    quoted.replace(u'\'', u"'\\''"_s);
    return u"'"_s + quoted + u"'"_s;
}

// Runs a command through the login shell: under desktop-shell.service the
// inherited PATH doesn't contain the user's profile (see Gpu::runProcess).
QString runInLoginShell(const QStringList& command, QByteArray* out = nullptr) {
    const QString envShell = qEnvironmentVariable("SHELL");
    const QString shell = envShell.isEmpty() ? u"/bin/sh"_s : envShell;

    QStringList quoted;
    for (const QString& arg : command) {
        quoted << shellQuote(arg);
    }

    QProcess proc;
    proc.start(shell, { u"-lc"_s, quoted.join(u' ') });
    if (!proc.waitForFinished(60000)) {
        proc.kill();
        return QObject::tr("%1 timed out").arg(command.value(0));
    }
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        const QString err = QString::fromLocal8Bit(proc.readAllStandardError()).trimmed();
        return QObject::tr("%1 failed: %2")
            .arg(command.value(0), err.isEmpty() ? QString::number(proc.exitCode()) : err);
    }
    if (out) {
        *out = proc.readAllStandardOutput();
    }
    return {};
}

QString copyRecursively(const QString& from, const QString& to) {
    const QDir src(from);
    if (!QDir().mkpath(to)) {
        return QObject::tr("Cannot create %1").arg(to);
    }

    const QFileInfoList entries =
        src.entryInfoList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System);
    for (const QFileInfo& info : entries) {
        const QString target = to + u'/' + info.fileName();
        if (info.isSymLink()) {
            // A plugin has no business pointing outside its own directory.
            return QObject::tr("Plugin contains a symbolic link (%1)").arg(info.fileName());
        }
        if (info.isDir()) {
            if (const QString err = copyRecursively(info.filePath(), target); !err.isEmpty()) {
                return err;
            }
        } else if (!QFile::copy(info.filePath(), target)) {
            return QObject::tr("Cannot copy %1").arg(info.fileName());
        }
    }
    return {};
}

std::optional<Manifest> readManifestFile(const QString& dir, QString* error) {
    QFile file(dir + u"/manifest.json"_s);
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QObject::tr("No manifest.json");
        return std::nullopt;
    }
    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(file.readAll(), &parseError);
    if (!doc.isObject()) {
        *error = QObject::tr("manifest.json: %1").arg(parseError.errorString());
        return std::nullopt;
    }
    return parseManifest(doc.object(), error);
}

} // namespace

std::optional<Manifest> parseManifest(const QJsonObject& obj, QString* error) {
    const auto fail = [&](const QString& msg) -> std::optional<Manifest> {
        if (error) {
            *error = msg;
        }
        return std::nullopt;
    };

    Manifest m;
    m.id = obj.value(u"id"_s).toString();
    if (!isValidPluginId(m.id)) {
        return fail(QObject::tr("Invalid plugin id '%1'").arg(m.id));
    }
    m.name = obj.value(u"name"_s).toString();
    if (m.name.isEmpty()) {
        m.name = m.id;
    }
    m.version = obj.value(u"version"_s).toString();
    if (m.version.isEmpty()) {
        return fail(QObject::tr("Missing version"));
    }
    m.description = obj.value(u"description"_s).toString();
    m.author = obj.value(u"author"_s).toString();
    m.icon = obj.value(u"icon"_s).toString(u"extension"_s);
    m.homepage = obj.value(u"homepage"_s).toString();

    m.exec = obj.value(u"exec"_s).toString();
    if (!isSafeRelativePath(m.exec)) {
        return fail(QObject::tr("'exec' must be a relative path inside the plugin"));
    }

    const QJsonObject api = obj.value(u"api"_s).toObject();
    const int major = api.value(u"major"_s).toInt(-1);
    const int minor = api.value(u"minor"_s).toInt(0);
    if (major < 0 || minor < 0) {
        return fail(QObject::tr("Missing API version"));
    }
    m.api = { static_cast<quint32>(major), static_cast<quint32>(minor) };
    return m;
}

SourceListing listDirectorySource(const QString& dirPath, const QString& sourceName) {
    const QDir dir(dirPath);
    if (!dir.exists()) {
        return { {}, QObject::tr("Directory not found: %1").arg(dirPath) };
    }

    if (QFile index(dir.filePath(u"index.json"_s)); index.exists()) {
        if (!index.open(QIODevice::ReadOnly)) {
            return { {}, QObject::tr("Cannot read %1").arg(index.fileName()) };
        }
        return parseIndex(index.readAll(), dir.absolutePath(), false, sourceName);
    }

    SourceListing listing;
    const QFileInfoList subdirs = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QFileInfo& sub : subdirs) {
        QString error;
        const auto manifest = readManifestFile(sub.absoluteFilePath(), &error);
        if (!manifest) {
            continue; // not a plugin directory
        }
        listing.entries.append({ *manifest, sub.absoluteFilePath(), {}, {}, sourceName });
    }
    return listing;
}

SourceListing parseIndex(
    const QByteArray& json, const QString& baseDirOrUrl, bool baseIsRemote, const QString& sourceName) {
    QJsonParseError parseError;
    const auto doc = QJsonDocument::fromJson(json, &parseError);
    if (!doc.isObject()) {
        return { {}, QObject::tr("Invalid index: %1").arg(parseError.errorString()) };
    }

    SourceListing listing;
    const QJsonArray plugins = doc.object().value(u"plugins"_s).toArray();
    for (const QJsonValue& value : plugins) {
        const QJsonObject obj = value.toObject();
        QString error;
        const auto manifest = parseManifest(obj, &error);
        if (!manifest) {
            continue; // one bad entry must not hide the others
        }

        SourceEntry entry{ *manifest, {}, {}, obj.value(u"sha256"_s).toString().toLower(), sourceName };

        const QString path = obj.value(u"path"_s).toString();
        const QString archive = obj.value(u"archive"_s).toString();
        if (!path.isEmpty() && !baseIsRemote) {
            if (!isSafeRelativePath(path)) {
                continue;
            }
            entry.dir = QDir(baseDirOrUrl).absoluteFilePath(path);
        } else if (!archive.isEmpty()) {
            if (archive.startsWith(u"http://"_s) || archive.startsWith(u"https://"_s)) {
                entry.archive = archive;
            } else if (baseIsRemote) {
                entry.archive = QUrl(baseDirOrUrl).resolved(QUrl(archive)).toString();
            } else {
                entry.archive = QDir(baseDirOrUrl).absoluteFilePath(archive);
            }
        } else {
            continue;
        }
        listing.entries.append(entry);
    }
    return listing;
}

QList<InstalledPlugin> scanInstalled(const QString& pluginsDir, QVariantMap* errors) {
    QList<InstalledPlugin> out;
    const QDir dir(pluginsDir);
    const QFileInfoList subdirs = dir.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
    for (const QFileInfo& sub : subdirs) {
        if (sub.fileName().startsWith(u'.')) {
            continue; // in-flight installs
        }
        QString error;
        const auto manifest = readManifestFile(sub.absoluteFilePath(), &error);
        if (!manifest) {
            if (errors) {
                errors->insert(sub.fileName(), error);
            }
        } else if (manifest->id != sub.fileName()) {
            if (errors) {
                errors->insert(
                    sub.fileName(), QObject::tr("Directory name does not match plugin id '%1'").arg(manifest->id));
            }
        } else {
            out.append({ *manifest, sub.absoluteFilePath() });
        }
    }
    return out;
}

namespace {

// Validates a staged plugin directory and swaps it into place.
QString commit(const QString& stagedDir, const QString& expectedId, const QString& pluginsDir) {
    QString error;
    const auto manifest = readManifestFile(stagedDir, &error);
    if (!manifest) {
        return error;
    }
    if (manifest->id != expectedId) {
        return QObject::tr("Package contains plugin '%1', expected '%2'").arg(manifest->id, expectedId);
    }

    const QFileInfo exec(stagedDir + u'/' + manifest->exec);
    if (!exec.isFile()) {
        return QObject::tr("Executable '%1' is missing from the package").arg(manifest->exec);
    }
    if (!QFile::setPermissions(exec.filePath(), exec.permissions() | QFileDevice::ExeOwner)) {
        return QObject::tr("Cannot make '%1' executable").arg(manifest->exec);
    }

    const QString target = pluginsDir + u'/' + expectedId;
    // Keep the old version until the new one is in place so a failure
    // doesn't leave the user without the plugin.
    const QString backup = pluginsDir + u"/."_s + expectedId + u".old"_s;
    QDir(backup).removeRecursively();
    const bool hadOld = QFileInfo::exists(target);
    if (hadOld && !QDir().rename(target, backup)) {
        return QObject::tr("Cannot replace the installed version");
    }
    if (!QDir().rename(stagedDir, target)) {
        if (hadOld) {
            QDir().rename(backup, target);
        }
        return QObject::tr("Cannot move the plugin into place");
    }
    QDir(backup).removeRecursively();
    return {};
}

} // namespace

QString installFromDir(const QString& srcDir, const QString& expectedId, const QString& pluginsDir) {
    if (!isValidPluginId(expectedId)) {
        return QObject::tr("Invalid plugin id");
    }
    if (!QDir().mkpath(pluginsDir)) {
        return QObject::tr("Cannot create %1").arg(pluginsDir);
    }

    const QString staged = pluginsDir + u"/."_s + expectedId + u".new"_s;
    QDir(staged).removeRecursively();
    if (const QString err = copyRecursively(srcDir, staged); !err.isEmpty()) {
        QDir(staged).removeRecursively();
        return err;
    }
    const QString err = commit(staged, expectedId, pluginsDir);
    if (!err.isEmpty()) {
        QDir(staged).removeRecursively();
    }
    return err;
}

QString installFromArchive(
    const QString& archivePath, const QString& expectedId, const QString& expectedSha256, const QString& pluginsDir) {
    if (!isValidPluginId(expectedId)) {
        return QObject::tr("Invalid plugin id");
    }

    if (!expectedSha256.isEmpty()) {
        QFile file(archivePath);
        if (!file.open(QIODevice::ReadOnly)) {
            return QObject::tr("Cannot read the downloaded archive");
        }
        QCryptographicHash hash(QCryptographicHash::Sha256);
        hash.addData(&file);
        if (QString::fromLatin1(hash.result().toHex()) != expectedSha256.toLower()) {
            return QObject::tr("Checksum mismatch, refusing to install");
        }
    }

    // Reject anything that could write outside the staging directory before
    // extracting a single byte.
    QByteArray listing;
    if (const QString err = runInLoginShell({ u"tar"_s, u"-tzf"_s, archivePath }, &listing); !err.isEmpty()) {
        return err;
    }
    for (const QByteArray& line : listing.split('\n')) {
        const QString entry = QString::fromLocal8Bit(line).trimmed();
        if (entry.startsWith(u'/') || entry.split(u'/').contains(u".."_s)) {
            return QObject::tr("Archive contains an unsafe path (%1)").arg(entry);
        }
    }

    if (!QDir().mkpath(pluginsDir)) {
        return QObject::tr("Cannot create %1").arg(pluginsDir);
    }
    QTemporaryDir tmp(pluginsDir + u"/.extract-XXXXXX"_s);
    if (!tmp.isValid()) {
        return QObject::tr("Cannot create a temporary directory");
    }
    if (const QString err =
            runInLoginShell({ u"tar"_s, u"-xzf"_s, archivePath, u"-C"_s, tmp.path(), u"--no-same-owner"_s });
        !err.isEmpty()) {
        return err;
    }

    // The package root is either the archive root or its only directory.
    QString root = tmp.path();
    if (!QFileInfo::exists(root + u"/manifest.json"_s)) {
        const QStringList subs = QDir(root).entryList(QDir::Dirs | QDir::NoDotAndDotDot);
        if (subs.size() != 1) {
            return QObject::tr("Archive has no manifest.json");
        }
        root = tmp.filePath(subs.first());
    }
    return installFromDir(root, expectedId, pluginsDir); // copies, so the temp dir can go away
}

QString removeInstalled(const QString& id, const QString& pluginsDir) {
    if (!isValidPluginId(id)) {
        return QObject::tr("Invalid plugin id");
    }
    const QString target = pluginsDir + u'/' + id;
    if (!QFileInfo::exists(target)) {
        return {};
    }
    return QDir(target).removeRecursively() ? QString() : QObject::tr("Cannot remove %1").arg(target);
}

} // namespace caelestia::plugins
