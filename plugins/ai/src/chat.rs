//! The state behind the panel: the conversation, what is selected, the
//! presets. Pure data and rules; the network and the view live elsewhere.

use std::collections::HashMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::provider::{trim_history, Caps, Effort, ModelInfo, Provider, Role};

pub const CONTEXT_SIZES: [u32; 7] = [8192, 16384, 32768, 65536, 131072, 200_000, 1_000_000];

pub fn context_label(size: u32) -> String {
    if size >= 1_000_000 {
        "1M".into()
    } else {
        format!("{}k", (f64::from(size) / 1024.0).round() as u32)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    User,
    Assistant,
    Error,
}

#[derive(Clone, Debug)]
pub struct Message {
    pub kind: Kind,
    pub text: String,
    pub thinking: String,
    pub show_thinking: bool,
}

impl Message {
    pub fn new(kind: Kind, text: impl Into<String>) -> Self {
        Self {
            kind,
            text: text.into(),
            thinking: String::new(),
            show_thinking: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Preset {
    pub name: String,
    pub provider: String,
    pub model: String,
    pub effort: String,
    pub context: u32,
    #[serde(default)]
    pub system_prompt: String,
}

impl Preset {
    pub fn summary(&self) -> String {
        let provider = Provider::from_id(&self.provider)
            .map_or_else(|| self.provider.clone(), |p| p.label().to_owned());
        format!(
            "{provider} · {} · {}",
            self.model,
            context_label(self.context)
        )
    }
}

pub fn default_presets() -> Vec<Preset> {
    let p = |name: &str, model: &str, effort: &str, context: u32, system: &str| Preset {
        name: name.into(),
        provider: "anthropic".into(),
        model: model.into(),
        effort: effort.into(),
        context,
        system_prompt: system.into(),
    };
    vec![
        p(
            "Quick",
            "claude-haiku-5-5",
            "low",
            16384,
            "Answer briefly and to the point.",
        ),
        p("Balanced", "claude-sonnet-5-5", "medium", 32768, ""),
        p(
            "Deep",
            "claude-opus-5-5",
            "high",
            65536,
            "Think things through carefully and explain your reasoning.",
        ),
    ]
}

/// What is kept between runs (in the plugin's data directory).
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Persisted {
    pub provider: String,
    pub model: String,
    pub effort: String,
    pub context: u32,
    pub preset: String,
    pub presets: Vec<Preset>,
}

impl Default for Persisted {
    fn default() -> Self {
        Self {
            provider: Provider::Anthropic.id().into(),
            model: Provider::Anthropic.default_model().into(),
            effort: Effort::Medium.id().into(),
            context: 32768,
            preset: String::new(),
            presets: default_presets(),
        }
    }
}

const STATE_FILE: &str = "state.json";

impl Persisted {
    pub fn load(dir: &std::path::Path) -> Self {
        std::fs::read_to_string(dir.join(STATE_FILE))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    fn save(&self, dir: &std::path::Path) {
        if dir.as_os_str().is_empty() {
            return;
        }
        let result = serde_json::to_string_pretty(self)
            .map_err(|e| e.to_string())
            .and_then(|s| std::fs::write(dir.join(STATE_FILE), s).map_err(|e| e.to_string()));
        if let Err(e) = result {
            tracing::warn!("couldn't save the chat state: {e}");
        }
    }
}

pub struct Chat {
    pub messages: Vec<Message>,
    pub busy: bool,
    /// Bumped for every request, so a task that was stopped can't touch a newer answer.
    pub generation: u64,

    pub provider: Provider,
    pub model: String,
    pub effort: Effort,
    pub context: u32,
    pub preset: String,
    pub presets: Vec<Preset>,
    pub naming_preset: bool,

    pub models: HashMap<Provider, Vec<ModelInfo>>,
    pub caps: HashMap<String, Caps>,
    pub loading_models: bool,
    pub models_error: String,

    pub anthropic_key: String,
    pub openai_key: String,
    pub system_prompt: String,

    /// Changes whenever the text field should be emptied.
    pub input_token: u64,
    pub data_dir: PathBuf,
}

impl Chat {
    pub fn new(saved: Persisted, data_dir: PathBuf) -> Self {
        let mut chat = Self {
            messages: Vec::new(),
            busy: false,
            generation: 0,
            provider: Provider::Anthropic,
            model: String::new(),
            effort: Effort::Medium,
            context: 32768,
            preset: String::new(),
            presets: Vec::new(),
            naming_preset: false,
            models: Provider::ALL
                .into_iter()
                .map(|p| (p, p.fallback_models()))
                .collect(),
            caps: HashMap::new(),
            loading_models: false,
            models_error: String::new(),
            anthropic_key: String::new(),
            openai_key: String::new(),
            system_prompt: String::new(),
            input_token: 0,
            data_dir: PathBuf::new(),
        };
        chat.restore(saved, data_dir);
        chat
    }

    /// Takes the selection and presets that were kept (the keys and the
    /// conversation are left alone).
    pub fn restore(&mut self, saved: Persisted, data_dir: PathBuf) {
        self.provider = Provider::from_id(&saved.provider).unwrap_or(Provider::Anthropic);
        self.model = if saved.model.is_empty() {
            self.provider.default_model().into()
        } else {
            saved.model
        };
        self.effort = Effort::from_id(&saved.effort).unwrap_or(Effort::Medium);
        self.context = saved.context.max(1024);
        self.preset = if saved.presets.iter().any(|p| p.name == saved.preset) {
            saved.preset
        } else {
            String::new()
        };
        self.presets = saved.presets;
        self.data_dir = data_dir;
    }

    fn persist(&self) {
        Persisted {
            provider: self.provider.id().into(),
            model: self.model.clone(),
            effort: self.effort.id().into(),
            context: self.context,
            preset: self.preset.clone(),
            presets: self.presets.clone(),
        }
        .save(&self.data_dir);
    }

    pub fn key(&self, provider: Provider) -> &str {
        match provider {
            Provider::Anthropic => self.anthropic_key.trim(),
            Provider::OpenAi => self.openai_key.trim(),
        }
    }

    pub fn has_key(&self) -> bool {
        !self.key(self.provider).is_empty()
    }

    /// The system prompt in effect: the active preset's, else the one from the settings.
    pub fn system(&self) -> String {
        self.presets
            .iter()
            .find(|p| p.name == self.preset)
            .map(|p| p.system_prompt.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| self.system_prompt.trim())
            .to_owned()
    }

    /// Models to offer: the provider's list, with the selected one always in it.
    pub fn available_models(&self) -> Vec<ModelInfo> {
        let mut list = self.models.get(&self.provider).cloned().unwrap_or_default();
        if !self.model.is_empty() && !list.iter().any(|m| m.id == self.model) {
            list.insert(
                0,
                ModelInfo {
                    id: self.model.clone(),
                    label: self.model.clone(),
                },
            );
        }
        list
    }

    /// The conversation to send, cut to the context size. Errors and an empty
    /// answer in progress aren't part of it.
    pub fn history(&self) -> Vec<(Role, String)> {
        let all: Vec<(Role, String)> = self
            .messages
            .iter()
            .filter(|m| !m.text.is_empty())
            .filter_map(|m| match m.kind {
                Kind::User => Some((Role::User, m.text.clone())),
                Kind::Assistant => Some((Role::Assistant, m.text.clone())),
                Kind::Error => None,
            })
            .collect();
        trim_history(&all, self.context, &self.system())
    }

    // ----------------------------------------------------------- selection

    pub fn set_provider(&mut self, provider: Provider) {
        if provider == self.provider {
            return;
        }
        self.provider = provider;
        // The previous model means nothing to the other provider
        let models = self.models.get(&provider);
        self.model = models
            .and_then(|l| {
                l.iter()
                    .find(|m| m.id == provider.default_model())
                    .or_else(|| l.first())
            })
            .map_or_else(|| provider.default_model().to_owned(), |m| m.id.clone());
        self.preset.clear();
        self.persist();
    }

    pub fn set_model(&mut self, model: &str) {
        self.model = model.to_owned();
        self.preset.clear();
        self.persist();
    }

    pub fn set_effort(&mut self, effort: Effort) {
        self.effort = effort;
        self.preset.clear();
        self.persist();
    }

    pub fn set_context(&mut self, context: u32) {
        self.context = context.max(1024);
        self.preset.clear();
        self.persist();
    }

    // ------------------------------------------------------------- presets

    /// Returns whether there was such a preset.
    pub fn apply_preset(&mut self, name: &str) -> bool {
        let Some(p) = self.presets.iter().find(|p| p.name == name).cloned() else {
            return false;
        };
        self.provider = Provider::from_id(&p.provider).unwrap_or(self.provider);
        self.model = p.model;
        self.effort = Effort::from_id(&p.effort).unwrap_or(self.effort);
        self.context = p.context.max(1024);
        self.preset = p.name;
        self.persist();
        true
    }

    /// Saves the current selection under `name`, replacing a preset of that name.
    pub fn save_preset(&mut self, name: &str) {
        let name = name.trim();
        if name.is_empty() {
            return;
        }
        let preset = Preset {
            name: name.into(),
            provider: self.provider.id().into(),
            model: self.model.clone(),
            effort: self.effort.id().into(),
            context: self.context,
            system_prompt: self.system(),
        };
        match self.presets.iter_mut().find(|p| p.name == name) {
            Some(existing) => *existing = preset,
            None => self.presets.push(preset),
        }
        self.preset = name.into();
        self.naming_preset = false;
        self.persist();
    }

    pub fn delete_preset(&mut self) {
        let active = std::mem::take(&mut self.preset);
        self.presets.retain(|p| p.name != active);
        self.persist();
    }

    // --------------------------------------------------------- conversation

    /// Ends the conversation (and any request in flight, which the caller aborts).
    pub fn clear(&mut self) {
        self.messages.clear();
        self.busy = false;
        self.generation += 1;
        self.input_token += 1;
    }

    /// Drops the answer being written if nothing came of it.
    pub fn drop_empty_answer(&mut self) {
        if self.messages.last().is_some_and(|m| {
            m.kind == Kind::Assistant && m.text.is_empty() && m.thinking.is_empty()
        }) {
            self.messages.pop();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chat() -> Chat {
        Chat::new(Persisted::default(), PathBuf::new())
    }

    #[test]
    fn context_labels() {
        assert_eq!(context_label(8192), "8k");
        assert_eq!(context_label(200_000), "195k");
        assert_eq!(context_label(1_000_000), "1M");
    }

    #[test]
    fn switching_provider_picks_a_model_of_that_provider() {
        let mut c = chat();
        assert_eq!(c.model, "claude-sonnet-5-5");
        c.set_provider(Provider::OpenAi);
        assert_eq!(c.model, "gpt-5");
        c.set_provider(Provider::Anthropic);
        assert_eq!(c.model, "claude-sonnet-5-5");
    }

    #[test]
    fn changing_the_selection_leaves_the_preset() {
        let mut c = chat();
        assert!(c.apply_preset("Deep"));
        assert_eq!(c.preset, "Deep");
        assert_eq!(c.model, "claude-opus-5-5");
        assert_eq!(c.effort, Effort::High);
        assert_eq!(c.context, 65536);
        c.set_effort(Effort::Low);
        assert_eq!(c.preset, "");
        assert!(!c.apply_preset("Nope"));
    }

    #[test]
    fn presets_are_saved_replaced_and_deleted() {
        let mut c = chat();
        c.set_model("claude-opus-5-5");
        c.set_effort(Effort::Max);
        c.system_prompt = "global".into();
        c.save_preset("  Mine ");
        assert_eq!(c.preset, "Mine");
        let p = c.presets.iter().find(|p| p.name == "Mine").unwrap();
        assert_eq!(
            (
                p.model.as_str(),
                p.effort.as_str(),
                p.system_prompt.as_str()
            ),
            ("claude-opus-5-5", "max", "global")
        );

        c.set_context(8192);
        c.save_preset("Mine");
        assert_eq!(c.presets.iter().filter(|p| p.name == "Mine").count(), 1);
        assert_eq!(
            c.presets.iter().find(|p| p.name == "Mine").unwrap().context,
            8192
        );

        c.save_preset("   ");
        assert_eq!(c.presets.len(), 4);
        c.delete_preset();
        assert_eq!(c.presets.len(), 3);
        assert_eq!(c.preset, "");
    }

    #[test]
    fn a_preset_system_prompt_beats_the_setting() {
        let mut c = chat();
        c.system_prompt = "from settings".into();
        assert_eq!(c.system(), "from settings");
        c.apply_preset("Quick");
        assert_eq!(c.system(), "Answer briefly and to the point.");
        c.apply_preset("Balanced"); // has none
        assert_eq!(c.system(), "from settings");
    }

    #[test]
    fn the_selected_model_is_always_offered() {
        let mut c = chat();
        c.set_model("claude-custom");
        let list = c.available_models();
        assert_eq!(list[0].id, "claude-custom");
        assert!(list.len() > 1);
    }

    #[test]
    fn history_skips_errors_and_empty_answers() {
        let mut c = chat();
        c.messages.push(Message::new(Kind::User, "hi"));
        c.messages.push(Message::new(Kind::Error, "boom"));
        c.messages.push(Message::new(Kind::User, "again"));
        c.messages.push(Message::new(Kind::Assistant, ""));
        let h = c.history();
        assert_eq!(h.len(), 2);
        assert!(h.iter().all(|(r, _)| *r == Role::User));
        c.drop_empty_answer();
        assert_eq!(c.messages.len(), 3);
    }

    #[test]
    fn state_survives_a_restart() {
        let dir = std::env::temp_dir().join(format!("ai-plugin-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut c = Chat::new(Persisted::default(), dir.clone());
        c.set_provider(Provider::OpenAi);
        c.set_effort(Effort::High);
        c.save_preset("Keep");

        let again = Chat::new(Persisted::load(&dir), dir.clone());
        assert_eq!(again.provider, Provider::OpenAi);
        assert_eq!(again.effort, Effort::High);
        assert_eq!(again.preset, "Keep");
        assert!(again.presets.iter().any(|p| p.name == "Keep"));
        std::fs::remove_dir_all(&dir).ok();

        // Nothing there yet: the defaults
        assert_eq!(Persisted::load(&dir).provider, "anthropic");
    }
}
