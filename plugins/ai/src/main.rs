//! AI chat: a bar button that opens a panel for chatting with OpenAI or
//! Anthropic models. The API keys are settings of this plugin (Nexus >
//! Plugins > AI Chat); provider, model, thinking effort, context size and
//! presets are chosen in the panel itself and remembered.

mod chat;
mod net;
mod provider;
mod view;

use std::sync::{Arc, OnceLock};

use caelestia_plugin_sdk::settings::{Field, Section, SettingsSchema};
use caelestia_plugin_sdk::{async_trait, ui, Context, Panel, Plugin, PluginInfo, Settings};

use chat::{Chat, Kind, Persisted};
use net::Shared;
use provider::{Effort, Provider};
use view::{chat_view, CHAT_VIEW};

struct AiChat {
    shared: Arc<Shared>,
    started: OnceLock<()>,
}

impl AiChat {
    fn new() -> Self {
        Self {
            shared: Shared::new(Chat::new(Persisted::default(), Default::default())),
            started: OnceLock::new(),
        }
    }
}

#[async_trait]
impl Plugin for AiChat {
    fn info(&self) -> PluginInfo {
        PluginInfo::new(env!("CARGO_PKG_VERSION"))
            .panel(Panel::new(CHAT_VIEW, "AI chat", "auto_awesome"))
            .settings(
                SettingsSchema::new()
                    .section(
                        Section::new("Anthropic")
                            .description("Claude models. The key is kept in the shell's plugin settings file.")
                            .field(
                                Field::text("anthropic_api_key", "API key", "")
                                    .placeholder("sk-ant-…")
                                    .secret()
                                    .description("From console.anthropic.com"),
                            ),
                    )
                    .section(
                        Section::new("OpenAI")
                            .description("GPT and o-series models. The key is kept in the shell's plugin settings file.")
                            .field(
                                Field::text("openai_api_key", "API key", "")
                                    .placeholder("sk-…")
                                    .secret()
                                    .description("From platform.openai.com"),
                            ),
                    )
                    .section(
                        Section::new("Chat").field(
                            Field::text("system_prompt", "System prompt", "")
                                .placeholder("Instructions for every conversation")
                                .description("A preset with a system prompt of its own uses that one instead"),
                        ),
                    ),
            )
    }

    async fn start(&self, ctx: Context) {
        // Only the first handshake of a run
        if self.started.set(()).is_err() {
            return;
        }
        let dir = ctx.data_dir();
        {
            let mut chat = self.shared.chat();
            chat.restore(Persisted::load(&dir), dir);
        }
        self.shared.set_pusher(move |view| ctx.push_view(view));
        self.shared.push_view();
    }

    async fn view(&self, view_id: &str) -> Option<ui::View> {
        (view_id == CHAT_VIEW).then(|| chat_view(&self.shared.chat()))
    }

    async fn settings_changed(&self, settings: &Settings) {
        let changed = {
            let mut chat = self.shared.chat();
            let anthropic = settings.string("anthropic_api_key", "");
            let openai = settings.string("openai_api_key", "");
            chat.system_prompt = settings.string("system_prompt", "");

            let mut changed = Vec::new();
            if anthropic.trim() != chat.anthropic_key.trim() {
                changed.push(Provider::Anthropic);
            }
            if openai.trim() != chat.openai_key.trim() {
                changed.push(Provider::OpenAi);
            }
            chat.anthropic_key = anthropic;
            chat.openai_key = openai;
            changed
        };
        // A new key means a new list of models
        for provider in changed {
            if !self.shared.chat().key(provider).is_empty() {
                self.shared.refresh_models(provider);
            }
        }
        self.shared.push_view();
    }

    async fn action(&self, view_id: &str, action_id: &str, payload: &str) -> Result<(), String> {
        if view_id != CHAT_VIEW {
            return Ok(());
        }
        let shared = &self.shared;
        match action_id {
            "send" => {
                shared.send(payload);
                return Ok(());
            }
            "stop" => {
                shared.stop();
                return Ok(());
            }
            "clear" => {
                shared.clear();
                return Ok(());
            }
            _ => {}
        }

        let mut load_models = None;
        {
            let mut chat = shared.chat();
            match action_id {
                "provider" => {
                    if let Some(p) = Provider::from_id(payload) {
                        chat.set_provider(p);
                        if !chat.key(p).is_empty() {
                            load_models = Some(p);
                        }
                    }
                }
                "model" => chat.set_model(payload),
                "effort" => {
                    if let Some(e) = Effort::from_id(payload) {
                        chat.set_effort(e);
                    }
                }
                "context" => {
                    if let Ok(size) = payload.parse::<u32>() {
                        chat.set_context(size);
                    }
                }
                "preset" => {
                    if chat.apply_preset(payload) {
                        let p = chat.provider;
                        if !chat.key(p).is_empty() {
                            load_models = Some(p);
                        }
                    }
                }
                "preset_begin" => chat.naming_preset = true,
                "preset_cancel" => chat.naming_preset = false,
                "preset_save" => chat.save_preset(payload),
                "preset_delete" => chat.delete_preset(),
                "toggle_thinking" => {
                    if let Some(m) = payload
                        .parse::<usize>()
                        .ok()
                        .and_then(|i| chat.messages.get_mut(i))
                    {
                        if m.kind == Kind::Assistant {
                            m.show_thinking = !m.show_thinking;
                        }
                    }
                }
                other => return Err(format!("unknown action '{other}'")),
            }
        }
        if let Some(p) = load_models {
            shared.refresh_models(p);
        }
        shared.push_view();
        Ok(())
    }

    async fn shutdown(&self) {
        self.shared.stop();
    }
}

fn main() {
    caelestia_plugin_sdk::main(AiChat::new());
}
