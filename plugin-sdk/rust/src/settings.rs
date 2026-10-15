//! Declarative settings pages. The shell renders the schema in Nexus, stores
//! the values and hands them to the plugin through
//! [`Plugin::settings_changed`](crate::Plugin::settings_changed).

use std::collections::HashMap;

use crate::proto;

/// The full schema of a plugin's settings page.
#[derive(Clone, Debug, Default)]
pub struct SettingsSchema(pub(crate) proto::SettingsSchema);

impl SettingsSchema {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn section(mut self, section: Section) -> Self {
        self.0.sections.push(section.0);
        self
    }
}

#[derive(Clone, Debug)]
pub struct Section(proto::SettingsSection);

impl Section {
    pub fn new(title: impl Into<String>) -> Self {
        Self(proto::SettingsSection {
            title: title.into(),
            ..Default::default()
        })
    }

    pub fn description(mut self, description: impl Into<String>) -> Self {
        self.0.description = description.into();
        self
    }

    pub fn field(mut self, field: Field) -> Self {
        self.0.fields.push(field.0);
        self
    }
}

#[derive(Clone, Debug)]
pub struct Field(proto::SettingField);

impl Field {
    fn new(key: &str, label: &str, kind: proto::setting_field::Kind) -> Self {
        Self(proto::SettingField {
            key: key.into(),
            label: label.into(),
            description: String::new(),
            kind: Some(kind),
        })
    }

    pub fn toggle(key: &str, label: &str, default: bool) -> Self {
        Self::new(
            key,
            label,
            proto::setting_field::Kind::Toggle(proto::ToggleField {
                default_value: default,
            }),
        )
    }

    /// A number in `min..=max`. Chain [`step`](Self::step), [`unit`](Self::unit), [`integer`](Self::integer).
    pub fn number(key: &str, label: &str, default: f64, min: f64, max: f64) -> Self {
        Self::new(
            key,
            label,
            proto::setting_field::Kind::Number(proto::NumberField {
                default_value: default,
                min,
                max,
                ..Default::default()
            }),
        )
    }

    pub fn text(key: &str, label: &str, default: &str) -> Self {
        Self::new(
            key,
            label,
            proto::setting_field::Kind::Text(proto::TextField {
                default_value: default.into(),
                placeholder: String::new(),
            }),
        )
    }

    /// `options` are `(value, label)` pairs.
    pub fn choice(key: &str, label: &str, default: &str, options: &[(&str, &str)]) -> Self {
        Self::new(
            key,
            label,
            proto::setting_field::Kind::Choice(proto::ChoiceField {
                default_value: default.into(),
                options: options
                    .iter()
                    .map(|(v, l)| proto::Choice {
                        value: (*v).into(),
                        label: (*l).into(),
                    })
                    .collect(),
            }),
        )
    }

    pub fn description(mut self, description: impl Into<String>) -> Self {
        self.0.description = description.into();
        self
    }

    pub fn step(mut self, step: f64) -> Self {
        if let Some(proto::setting_field::Kind::Number(n)) = &mut self.0.kind {
            n.step = step;
        }
        self
    }

    pub fn unit(mut self, unit: impl Into<String>) -> Self {
        if let Some(proto::setting_field::Kind::Number(n)) = &mut self.0.kind {
            n.unit = unit.into();
        }
        self
    }

    pub fn integer(mut self) -> Self {
        if let Some(proto::setting_field::Kind::Number(n)) = &mut self.0.kind {
            n.integer = true;
        }
        self
    }

    pub fn placeholder(mut self, placeholder: impl Into<String>) -> Self {
        if let Some(proto::setting_field::Kind::Text(t)) = &mut self.0.kind {
            t.placeholder = placeholder.into();
        }
        self
    }
}

/// The current setting values. The shell always sends a complete set (schema
/// defaults filled in), so the getters only fall back to their argument for
/// keys that aren't in the schema or have another type.
#[derive(Clone, Debug, Default)]
pub struct Settings(HashMap<String, proto::SettingValue>);

impl Settings {
    pub(crate) fn from_proto(values: HashMap<String, proto::SettingValue>) -> Self {
        Self(values)
    }

    pub fn bool(&self, key: &str, default: bool) -> bool {
        match self.0.get(key).and_then(|v| v.value.as_ref()) {
            Some(proto::setting_value::Value::BoolValue(b)) => *b,
            _ => default,
        }
    }

    pub fn f64(&self, key: &str, default: f64) -> f64 {
        match self.0.get(key).and_then(|v| v.value.as_ref()) {
            Some(proto::setting_value::Value::NumberValue(n)) => *n,
            _ => default,
        }
    }

    pub fn u32(&self, key: &str, default: u32) -> u32 {
        let v = self.f64(key, f64::from(default)).round();
        if v.is_finite() && v >= 0.0 {
            v.min(f64::from(u32::MAX)) as u32
        } else {
            default
        }
    }

    pub fn string(&self, key: &str, default: &str) -> String {
        match self.0.get(key).and_then(|v| v.value.as_ref()) {
            Some(proto::setting_value::Value::StringValue(s)) => s.clone(),
            _ => default.to_owned(),
        }
    }
}
