#pragma once

#include <map>
#include <string>
#include <variant>
#include <vector>

// Declarative settings page. The shell renders the schema in Nexus, persists
// the values and hands them to Plugin::settingsChanged().
namespace caelestia::plugin {

struct ToggleField {
    std::string key;
    std::string label;
    std::string description;
    bool defaultValue = false;
};

struct NumberField {
    std::string key;
    std::string label;
    std::string description;
    double defaultValue = 0;
    double min = 0;
    double max = 100;
    // 0: 1 for integer fields, continuous otherwise.
    double step = 0;
    // Shown next to the value, e.g. "min".
    std::string unit;
    bool integer = false;
};

struct TextField {
    std::string key;
    std::string label;
    std::string description;
    std::string defaultValue;
    std::string placeholder;
};

struct Choice {
    std::string value;
    std::string label;
};

struct ChoiceField {
    std::string key;
    std::string label;
    std::string description;
    std::string defaultValue;
    std::vector<Choice> options;
};

using Field = std::variant<ToggleField, NumberField, TextField, ChoiceField>;

struct Section {
    std::string title;
    std::string description;
    std::vector<Field> fields;
};

struct SettingsSchema {
    std::vector<Section> sections;
};

using SettingValue = std::variant<bool, double, std::string>;

// Current values. The shell always sends a complete set (schema defaults
// filled in); the fallbacks only matter for keys outside the schema or of
// another type.
class Settings {
public:
    Settings() = default;

    explicit Settings(std::map<std::string, SettingValue> values)
        : m_values(std::move(values)) {}

    [[nodiscard]] bool getBool(const std::string& key, bool fallback = false) const;
    [[nodiscard]] double getNumber(const std::string& key, double fallback = 0) const;
    [[nodiscard]] std::string getString(const std::string& key, const std::string& fallback = {}) const;

private:
    std::map<std::string, SettingValue> m_values;
};

} // namespace caelestia::plugin
