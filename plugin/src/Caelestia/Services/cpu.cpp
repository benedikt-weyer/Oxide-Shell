#include "cpu.hpp"

#include <qdir.h>
#include <qfile.h>
#include <qmap.h>
#include <qpair.h>
#include <qregularexpression.h>
#include <qset.h>

#include <algorithm>
#include <cmath>

#include "sensorslib.hpp"

namespace caelestia::services {

using Qt::StringLiterals::operator""_s;

namespace {

[[nodiscard]] QByteArray readSysfs(const QString& path) {
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return {};
    }
    return f.readAll().trimmed();
}

// Parses a kernel cpu list such as "0-3,8,10-11"
[[nodiscard]] QSet<int> parseCpuList(const QByteArray& list) {
    QSet<int> cpus;
    for (const QByteArray& part : list.split(',')) {
        const QList<QByteArray> range = part.trimmed().split('-');
        bool okFrom = false;
        const int from = range.value(0).toInt(&okFrom);
        if (!okFrom) {
            continue;
        }
        bool okTo = false;
        const int to = range.size() > 1 ? range.at(1).toInt(&okTo) : from;
        for (int i = from; i <= (okTo ? to : from); ++i) {
            cpus.insert(i);
        }
    }
    return cpus;
}

[[nodiscard]] QString cpuPath(int cpu, const QString& file) {
    return u"/sys/devices/system/cpu/cpu%1/%2"_s.arg(cpu).arg(file);
}

} // namespace

CpuCoreModel::CpuCoreModel(QObject* parent)
    : QAbstractListModel(parent) {
    enumerate();
    refresh();
}

int CpuCoreModel::rowCount(const QModelIndex& parent) const {
    return parent.isValid() ? 0 : static_cast<int>(m_cores.size());
}

QVariant CpuCoreModel::data(const QModelIndex& index, int role) const {
    if (!index.isValid() || index.row() < 0 || index.row() >= m_cores.size()) {
        return {};
    }

    const Core& core = m_cores.at(index.row());
    switch (role) {
    case LabelRole:
        return core.label;
    case TypeRole:
        return static_cast<int>(core.type);
    case TemperatureRole:
        return core.temperature;
    case FrequencyRole:
        return core.frequency;
    case MaxFrequencyRole:
        return core.maxFrequency;
    default:
        return {};
    }
}

QHash<int, QByteArray> CpuCoreModel::roleNames() const {
    return {
        { LabelRole, "label" },
        { TypeRole, "type" },
        { TemperatureRole, "temperature" },
        { FrequencyRole, "frequency" },
        { MaxFrequencyRole, "maxFrequency" },
    };
}

bool CpuCoreModel::hybrid() const {
    return m_hybrid;
}

void CpuCoreModel::enumerate() {
    const QSet<int> pCpus = parseCpuList(readSysfs(u"/sys/devices/cpu_core/cpus"_s));
    const QSet<int> eCpus = parseCpuList(readSysfs(u"/sys/devices/cpu_atom/cpus"_s));
    m_hybrid = !pCpus.isEmpty() && !eCpus.isEmpty();

    // Group SMT siblings into physical cores
    QMap<QPair<int, int>, Core> cores;
    const QStringList entries = QDir(u"/sys/devices/system/cpu"_s).entryList({ u"cpu[0-9]*"_s }, QDir::Dirs);
    for (const QString& entry : entries) {
        bool ok = false;
        const int cpu = entry.mid(3).toInt(&ok);
        if (!ok) {
            continue;
        }

        bool idOk = false;
        const int coreId = readSysfs(cpuPath(cpu, u"topology/core_id"_s)).toInt(&idOk);
        if (!idOk) {
            continue;
        }
        const int pkg = readSysfs(cpuPath(cpu, u"topology/physical_package_id"_s)).toInt();

        Core& core = cores[{ pkg, coreId }];
        core.coreId = coreId;
        core.cpus << cpu;
        if (m_hybrid) {
            core.type = eCpus.contains(cpu) ? Type::Efficiency : Type::Performance;
        }
    }

    // Performance cores first, then efficiency cores, each ordered by core id
    QList<Core> sorted = cores.values();
    std::stable_sort(sorted.begin(), sorted.end(), [](const Core& a, const Core& b) {
        return a.type < b.type;
    });

    int perfIdx = 0;
    int effIdx = 0;
    int uniformIdx = 0;
    for (Core& core : sorted) {
        switch (core.type) {
        case Type::Performance:
            core.label = u"P%1"_s.arg(perfIdx++);
            break;
        case Type::Efficiency:
            core.label = u"E%1"_s.arg(effIdx++);
            break;
        case Type::Uniform:
            core.label = tr("Core %1").arg(uniformIdx++);
            break;
        }

        for (const int cpu : std::as_const(core.cpus)) {
            core.maxFrequency =
                std::max(core.maxFrequency, readSysfs(cpuPath(cpu, u"cpufreq/cpuinfo_max_freq"_s)).toDouble() / 1000.0);
        }
    }

    m_cores = std::move(sorted);
}

void CpuCoreModel::refresh() {
    if (m_cores.isEmpty()) {
        return;
    }

    const QHash<int, double> temps = sensorslib::cpuCoreTemps();

    for (int row = 0; row < m_cores.size(); ++row) {
        Core& core = m_cores[row];

        qreal freq = 0.0;
        for (const int cpu : std::as_const(core.cpus)) {
            freq = std::max(freq, readSysfs(cpuPath(cpu, u"cpufreq/scaling_cur_freq"_s)).toDouble() / 1000.0);
        }
        const qreal temp = temps.value(core.coreId, -1.0);

        QList<int> changed;
        if (std::abs(freq - core.frequency) > 0.5) {
            core.frequency = freq;
            changed << FrequencyRole;
        }
        if (std::abs(temp - core.temperature) > 0.05) {
            core.temperature = temp;
            changed << TemperatureRole;
        }
        if (!changed.isEmpty()) {
            const QModelIndex idx = index(row);
            emit dataChanged(idx, idx, changed);
        }
    }
}

Cpu::Cpu(QObject* parent)
    : TickingService(parent)
    , m_cores(new CpuCoreModel(this)) {
    readNameOnce();
}

QString Cpu::name() const {
    return m_name;
}

qreal Cpu::percentage() const {
    return m_percentage;
}

qreal Cpu::temperature() const {
    return m_temperature;
}

CpuCoreModel* Cpu::cores() const {
    return m_cores;
}

bool Cpu::hybrid() const {
    return m_cores->hybrid();
}

void Cpu::tick() {
    if (!m_nameLoaded) {
        readNameOnce();
    }
    refreshPercentage();
    refreshTemperature();
    m_cores->refresh();
}

void Cpu::readNameOnce() {
    QFile f(u"/proc/cpuinfo"_s);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return;
    }
    const QByteArray data = f.readAll();
    f.close();

    static const QRegularExpression k_re(u"model name\\s*:\\s*(.+)"_s);
    const auto match = k_re.match(QString::fromLatin1(data));
    if (!match.hasMatch()) {
        return;
    }

    const QString cleaned = cleanName(match.captured(1));
    m_nameLoaded = true;
    if (cleaned == m_name) {
        return;
    }
    m_name = cleaned;
    emit nameChanged();
}

void Cpu::refreshPercentage() {
    QFile f(u"/proc/stat"_s);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return;
    }
    const QByteArray data = f.readAll();
    f.close();

    static const QRegularExpression k_re(
        u"^cpu\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)\\s+(\\d+)"_s);
    const auto match = k_re.match(QString::fromLatin1(data));
    if (!match.hasMatch()) {
        return;
    }

    quint64 total = 0;
    quint64 idle = 0;
    for (int i = 1; i <= 7; ++i) {
        const quint64 v = match.captured(i).toULongLong();
        total += v;
        if (i == 4 || i == 5) {
            idle += v;
        }
    }

    const quint64 totalDiff = total > m_lastTotal ? total - m_lastTotal : 0;
    const quint64 idleDiff = idle > m_lastIdle ? idle - m_lastIdle : 0;
    const qreal newPerc = totalDiff > 0 ? 1.0 - static_cast<qreal>(idleDiff) / static_cast<qreal>(totalDiff) : 0.0;

    m_lastTotal = total;
    m_lastIdle = idle;

    if (std::abs(newPerc - m_percentage) > 0.0001) {
        m_percentage = newPerc;
        emit percentageChanged();
    }
}

void Cpu::refreshTemperature() {
    const auto t = sensorslib::cpuPackageTemp();
    const qreal newTemp = t.value_or(0.0);
    if (std::abs(newTemp - m_temperature) > 0.05) {
        m_temperature = newTemp;
        emit temperatureChanged();
    }
}

QString Cpu::cleanName(QString s) {
    static const QRegularExpression k_noise(
        u"\\(R\\)|\\(TM\\)|CPU|\\d+(?:th|nd|rd|st) Gen |Core |Processor"_s, QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression k_spaces(u"\\s+"_s);

    s.replace(k_noise, QString());
    s.replace(k_spaces, u" "_s);
    return s.trimmed();
}

} // namespace caelestia::services
