#pragma once

#include <qabstractitemmodel.h>
#include <qlist.h>
#include <qqmlintegration.h>

#include "tickingservice.hpp"

namespace caelestia::services {

class CpuCoreModel : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("CpuCoreModel can only be retrieved from Cpu")

public:
    enum class Type : int {
        Uniform, // Not a hybrid CPU
        Performance,
        Efficiency
    };
    Q_ENUM(Type)

    enum Roles {
        LabelRole = Qt::UserRole + 1,
        TypeRole,
        TemperatureRole, // Celsius, negative when unavailable
        FrequencyRole,   // MHz, 0 when unavailable
        MaxFrequencyRole // MHz, 0 when unavailable
    };

    struct Core {
        int coreId = 0;
        QList<int> cpus; // Logical cpus (SMT siblings) sharing this core
        Type type = Type::Uniform;
        QString label;
        qreal temperature = -1.0;
        qreal frequency = 0.0;
        qreal maxFrequency = 0.0;
    };

    explicit CpuCoreModel(QObject* parent = nullptr);

    [[nodiscard]] int rowCount(const QModelIndex& parent = QModelIndex()) const override;
    [[nodiscard]] QVariant data(const QModelIndex& index, int role) const override;
    [[nodiscard]] QHash<int, QByteArray> roleNames() const override;

    [[nodiscard]] bool hybrid() const;

    // Re-reads temperatures and frequencies, notifying only the rows that changed
    void refresh();

private:
    void enumerate();

    QList<Core> m_cores;
    bool m_hybrid = false;
};

class Cpu : public TickingService {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(QString name READ name NOTIFY nameChanged)
    Q_PROPERTY(qreal percentage READ percentage NOTIFY percentageChanged)
    Q_PROPERTY(qreal temperature READ temperature NOTIFY temperatureChanged)
    Q_PROPERTY(caelestia::services::CpuCoreModel* cores READ cores CONSTANT)
    Q_PROPERTY(bool hybrid READ hybrid CONSTANT)

public:
    explicit Cpu(QObject* parent = nullptr);

    [[nodiscard]] QString name() const;
    [[nodiscard]] qreal percentage() const;
    [[nodiscard]] qreal temperature() const;
    [[nodiscard]] CpuCoreModel* cores() const;
    [[nodiscard]] bool hybrid() const;

signals:
    void nameChanged();
    void percentageChanged();
    void temperatureChanged();

protected:
    void tick() override;

private:
    void readNameOnce();
    void refreshPercentage();
    void refreshTemperature();

    [[nodiscard]] static QString cleanName(QString s);

    QString m_name;
    qreal m_percentage = 0.0;
    qreal m_temperature = 0.0;
    CpuCoreModel* m_cores;
    quint64 m_lastIdle = 0;
    quint64 m_lastTotal = 0;
    bool m_nameLoaded = false;
};

} // namespace caelestia::services
