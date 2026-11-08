//! What differs between the providers: which requests are sent, how a model
//! list and a stream of events are read. Nothing in here does I/O, so all of
//! it is unit-tested.

use std::collections::HashMap;

use serde_json::{json, Value};

pub const ANTHROPIC_VERSION: &str = "2026-10-21";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Provider {
    Anthropic,
    OpenAi,
}

impl Provider {
    pub const ALL: [Provider; 2] = [Provider::Anthropic, Provider::OpenAi];

    pub fn id(self) -> &'static str {
        match self {
            Provider::Anthropic => "anthropic",
            Provider::OpenAi => "openai",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Provider::Anthropic => "Anthropic",
            Provider::OpenAi => "OpenAI",
        }
    }

    pub fn icon(self) -> &'static str {
        match self {
            Provider::Anthropic => "psychology",
            Provider::OpenAi => "auto_awesome",
        }
    }

    pub fn from_id(id: &str) -> Option<Provider> {
        Provider::ALL.into_iter().find(|p| p.id() == id)
    }

    /// Models offered until (or unless) the provider's own list has been read.
    pub fn fallback_models(self) -> Vec<ModelInfo> {
        let list: &[(&str, &str)] = match self {
            Provider::Anthropic => &[
                ("claude-opus-5-5", "Claude Opus 5.5"),
                ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
                ("claude-haiku-5-5", "Claude Haiku 5.5"),
                ("claude-fable-5-1", "Claude Fable 5.1"),
            ],
            Provider::OpenAi => &[
                ("gpt-5", "gpt-5"),
                ("gpt-5-mini", "gpt-5-mini"),
                ("gpt-4.1", "gpt-4.1"),
                ("o3", "o3"),
                ("o4-mini", "o4-mini"),
            ],
        };
        list.iter()
            .map(|(id, label)| ModelInfo {
                id: (*id).into(),
                label: (*label).into(),
            })
            .collect()
    }

    /// The model picked when switching to this provider.
    pub fn default_model(self) -> &'static str {
        match self {
            Provider::Anthropic => "claude-sonnet-5-5",
            Provider::OpenAi => "gpt-5",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effort {
    Off,
    Low,
    Medium,
    High,
    Max,
}

impl Effort {
    pub const ALL: [Effort; 5] = [
        Effort::Off,
        Effort::Low,
        Effort::Medium,
        Effort::High,
        Effort::Max,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Effort::Off => "off",
            Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High => "high",
            Effort::Max => "max",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Effort::Off => "Off",
            Effort::Low => "Low",
            Effort::Medium => "Medium",
            Effort::High => "High",
            Effort::Max => "Max",
        }
    }

    pub fn from_id(id: &str) -> Option<Effort> {
        Effort::ALL.into_iter().find(|e| e.id() == id)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelInfo {
    pub id: String,
    pub label: String,
}

/// What an Anthropic model says it supports (from its models endpoint).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Caps {
    pub adaptive: bool,
    pub budget: bool,
    pub effort: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    User,
    Assistant,
}

impl Role {
    fn id(self) -> &'static str {
        match self {
            Role::User => "user",
            Role::Assistant => "assistant",
        }
    }
}

pub struct ChatRequest<'a> {
    pub model: &'a str,
    pub effort: Effort,
    pub system: &'a str,
    pub history: &'a [(Role, String)],
    pub caps: Option<Caps>,
}

pub fn estimate_tokens(text: &str) -> u32 {
    if text.is_empty() {
        0
    } else {
        (text.chars().count() as f64 / 3.5).ceil() as u32 + 4
    }
}

/// The part of `messages` that fits in `context` tokens (leaving room for the
/// system prompt and an answer): the newest messages, starting at a user one.
pub fn trim_history(
    messages: &[(Role, String)],
    context: u32,
    system: &str,
) -> Vec<(Role, String)> {
    let budget = context
        .saturating_sub(estimate_tokens(system))
        .saturating_sub(2048)
        .max(1024);
    let mut used = 0u32;
    let mut start = messages.len();
    for (i, (_, text)) in messages.iter().enumerate().rev() {
        let cost = estimate_tokens(text);
        // The newest message always goes along, however long
        if start < messages.len() && used.saturating_add(cost) > budget {
            break;
        }
        used = used.saturating_add(cost);
        start = i;
    }
    // Providers want the conversation to open with the user
    while start + 1 < messages.len() && messages[start].0 != Role::User {
        start += 1;
    }
    messages[start..].to_vec()
}

fn messages_json(req: &ChatRequest) -> Vec<Value> {
    req.history
        .iter()
        .map(|(role, text)| json!({ "role": role.id(), "content": text }))
        .collect()
}

// ------------------------------------------------------------------ Anthropic

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThinkingMode {
    /// Effort decides how much the model thinks.
    Adaptive,
    /// An explicit token budget (older models).
    Budget,
    None,
}

pub fn thinking_mode(model: &str, caps: Option<Caps>) -> ThinkingMode {
    if let Some(c) = caps {
        return if c.adaptive {
            ThinkingMode::Adaptive
        } else if c.budget {
            ThinkingMode::Budget
        } else {
            ThinkingMode::None
        };
    }
    const OLD: [&str; 7] = [
        "haiku-4-5",
        "sonnet-4-5",
        "opus-4-5",
        "opus-4-1",
        "claude-3",
        "sonnet-4-2",
        "opus-4-2",
    ];
    if OLD.iter().any(|o| model.contains(o)) {
        ThinkingMode::Budget
    } else {
        ThinkingMode::Adaptive
    }
}

/// The body of a messages request. `attempt` 0 carries the thinking settings;
/// a retry (after the API refused them) carries none.
pub fn anthropic_body(req: &ChatRequest, attempt: u8) -> Value {
    let mut body = json!({
        "model": req.model,
        "stream": true,
        "messages": messages_json(req),
    });
    if !req.system.is_empty() {
        body["system"] = json!(req.system);
    }

    let mut max_tokens = 16000;
    if attempt == 0 {
        match thinking_mode(req.model, req.caps) {
            ThinkingMode::Adaptive => {
                if req.effort == Effort::Off {
                    // Some models can't switch thinking off: they get the
                    // lowest effort, or just the thinking between tool calls
                    if ["fable", "mythos", "opus-5-5"]
                        .iter()
                        .any(|m| req.model.contains(m))
                    {
                        body["output_config"] = json!({ "effort": "low" });
                    } else if req.model.contains("sonnet-5-5") {
                        body["thinking"] = json!({ "type": "between_tools" });
                    } else {
                        body["thinking"] = json!({ "type": "disabled" });
                    }
                } else {
                    body["thinking"] = json!({ "type": "adaptive", "display": "summarized" });
                    if req.caps.map_or(true, |c| c.effort) {
                        body["output_config"] = json!({ "effort": req.effort.id() });
                    }
                    max_tokens = 32000;
                }
            }
            ThinkingMode::Budget if req.effort != Effort::Off => {
                let budget = match req.effort {
                    Effort::Low => 2048,
                    Effort::Medium => 8192,
                    Effort::High => 16384,
                    _ => 32000,
                };
                body["thinking"] = json!({ "type": "enabled", "budget_tokens": budget });
                max_tokens = budget + 8192;
            }
            _ => {}
        }
    }
    body["max_tokens"] = json!(max_tokens);
    body
}

/// Models and what they support, from `GET /v1/models`.
pub fn parse_anthropic_models(body: &str) -> Option<(Vec<ModelInfo>, HashMap<String, Caps>)> {
    let data = serde_json::from_str::<Value>(body).ok()?;
    let mut models = Vec::new();
    let mut caps = HashMap::new();
    for m in data.get("data")?.as_array()? {
        let Some(id) = m.get("id").and_then(Value::as_str) else {
            continue;
        };
        let label = m
            .get("display_name")
            .and_then(Value::as_str)
            .filter(|l| !l.is_empty())
            .unwrap_or(id);
        models.push(ModelInfo {
            id: id.into(),
            label: label.into(),
        });
        if let Some(c) = m.get("capabilities") {
            let flag = |path: &[&str]| {
                path.iter()
                    .try_fold(c, |v, k| v.get(k))
                    .and_then(|v| v.get("supported"))
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            };
            caps.insert(
                id.to_owned(),
                Caps {
                    adaptive: flag(&["thinking", "types", "adaptive"]),
                    budget: flag(&["thinking", "types", "enabled"]),
                    effort: flag(&["effort"]),
                },
            );
        }
    }
    Some((models, caps))
}

// --------------------------------------------------------------------- OpenAI

fn openai_reasoning(model: &str) -> bool {
    let o_series =
        model.starts_with('o') && model.chars().nth(1).is_some_and(|c| c.is_ascii_digit());
    (o_series || model.starts_with("gpt-5")) && !model.contains("-chat")
}

pub fn openai_body(req: &ChatRequest, attempt: u8) -> Value {
    let mut messages = messages_json(req);
    if !req.system.is_empty() {
        messages.insert(0, json!({ "role": "system", "content": req.system }));
    }
    let mut body = json!({ "model": req.model, "stream": true, "messages": messages });

    // Only the reasoning models take it, and not the chat-tuned variants of them
    if attempt == 0 && openai_reasoning(req.model) {
        body["reasoning_effort"] = json!(match req.effort {
            Effort::Off if req.model.starts_with("gpt-5") => "minimal",
            Effort::Off | Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High | Effort::Max => "high",
        });
    }
    body
}

/// Chat models out of `GET /v1/models`, newest first.
pub fn parse_openai_models(body: &str) -> Option<Vec<ModelInfo>> {
    const EXCLUDE: [&str; 17] = [
        "audio",
        "realtime",
        "transcribe",
        "tts",
        "image",
        "search",
        "embedding",
        "moderation",
        "instruct",
        "codex",
        "whisper",
        "dall-e",
        "davinci",
        "babbage",
        "computer-use",
        "deep-research",
        "omni-moderation",
    ];
    let data = serde_json::from_str::<Value>(body).ok()?;
    let mut found: Vec<(i64, String)> = data
        .get("data")?
        .as_array()?
        .iter()
        .filter_map(|m| {
            let id = m.get("id")?.as_str()?;
            let chat = id.starts_with("gpt-")
                || id.starts_with("chatgpt-")
                || (id.starts_with('o') && id.chars().nth(1).is_some_and(|c| c.is_ascii_digit()));
            let excluded = EXCLUDE.iter().any(|e| id.contains(e));
            (chat && !excluded).then(|| {
                (
                    m.get("created").and_then(Value::as_i64).unwrap_or(0),
                    id.to_owned(),
                )
            })
        })
        .collect();
    found.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    Some(
        found
            .into_iter()
            .map(|(_, id)| ModelInfo {
                label: id.clone(),
                id,
            })
            .collect(),
    )
}

// ------------------------------------------------------------------- streaming

/// What one server-sent event means for the answer being written.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Delta {
    pub text: String,
    pub thinking: String,
    pub stop_reason: Option<String>,
    pub error: Option<String>,
}

/// Reads one line of a stream. Only `data:` lines carry anything.
pub fn parse_stream_line(provider: Provider, line: &str) -> Delta {
    let mut delta = Delta::default();
    let Some(payload) = line.strip_prefix("data:") else {
        return delta;
    };
    let payload = payload.trim();
    if payload.is_empty() || payload == "[DONE]" {
        return delta;
    }
    let Ok(ev) = serde_json::from_str::<Value>(payload) else {
        return delta;
    };

    let error_message = |e: &Value| {
        e.get("message")
            .and_then(Value::as_str)
            .unwrap_or("Unknown error")
            .to_owned()
    };

    match provider {
        Provider::OpenAi => {
            if let Some(e) = ev.get("error") {
                delta.error = Some(error_message(e));
                return delta;
            }
            if let Some(choice) = ev.get("choices").and_then(|c| c.get(0)) {
                let d = choice.get("delta");
                delta.text = d
                    .and_then(|d| d.get("content"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                delta.thinking = d
                    .and_then(|d| d.get("reasoning_content"))
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned();
                delta.stop_reason = choice
                    .get("finish_reason")
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
        }
        Provider::Anthropic => match ev.get("type").and_then(Value::as_str) {
            Some("content_block_delta") => {
                let d = ev.get("delta");
                match d.and_then(|d| d.get("type")).and_then(Value::as_str) {
                    Some("text_delta") => {
                        delta.text = d
                            .and_then(|d| d.get("text"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned();
                    }
                    Some("thinking_delta") => {
                        delta.thinking = d
                            .and_then(|d| d.get("thinking"))
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_owned();
                    }
                    _ => {}
                }
            }
            Some("message_delta") => {
                delta.stop_reason = ev
                    .get("delta")
                    .and_then(|d| d.get("stop_reason"))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
            }
            Some("error") => {
                delta.error = Some(error_message(ev.get("error").unwrap_or(&Value::Null)));
            }
            _ => {}
        },
    }
    delta
}

/// The message out of a provider's error body (`{ "error": { "message" } }` on both).
pub fn error_message(body: &str) -> Option<String> {
    let v = serde_json::from_str::<Value>(body).ok()?;
    v.get("error")
        .and_then(|e| e.get("message"))
        .or_else(|| v.get("message"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

/// Whether an error is the API refusing the thinking settings, worth asking again without them.
pub fn is_thinking_error(message: &str) -> bool {
    let m = message.to_lowercase();
    ["thinking", "effort", "reasoning", "output_config", "budget"]
        .iter()
        .any(|k| m.contains(k))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req<'a>(model: &'a str, effort: Effort, history: &'a [(Role, String)]) -> ChatRequest<'a> {
        ChatRequest {
            model,
            effort,
            system: "",
            history,
            caps: None,
        }
    }

    fn user(text: &str) -> (Role, String) {
        (Role::User, text.into())
    }

    #[test]
    fn adaptive_models_get_effort_and_summarised_thinking() {
        let h = [user("hi")];
        let b = anthropic_body(&req("claude-sonnet-5-5", Effort::Medium, &h), 0);
        assert_eq!(
            b["thinking"],
            json!({ "type": "adaptive", "display": "summarized" })
        );
        assert_eq!(b["output_config"], json!({ "effort": "medium" }));
        assert_eq!(b["max_tokens"], 32000);
        assert_eq!(b["stream"], true);
        assert_eq!(b["messages"], json!([{ "role": "user", "content": "hi" }]));
        assert!(b.get("system").is_none());
    }

    #[test]
    fn thinking_off_depends_on_what_the_model_can_do() {
        let h = [user("hi")];
        let opus = anthropic_body(&req("claude-opus-5-5", Effort::Off, &h), 0);
        assert!(opus.get("thinking").is_none());
        assert_eq!(opus["output_config"], json!({ "effort": "low" }));

        let sonnet = anthropic_body(&req("claude-sonnet-5-5", Effort::Off, &h), 0);
        assert_eq!(sonnet["thinking"], json!({ "type": "between_tools" }));

        let other = anthropic_body(&req("claude-opus-4-8", Effort::Off, &h), 0);
        assert_eq!(other["thinking"], json!({ "type": "disabled" }));
        assert_eq!(other["max_tokens"], 16000);
    }

    #[test]
    fn older_models_get_a_token_budget() {
        let h = [user("hi")];
        let b = anthropic_body(&req("claude-haiku-4-5", Effort::Medium, &h), 0);
        assert_eq!(
            b["thinking"],
            json!({ "type": "enabled", "budget_tokens": 8192 })
        );
        assert_eq!(b["max_tokens"], 8192 + 8192);
        assert!(b.get("output_config").is_none());

        let off = anthropic_body(&req("claude-haiku-4-5", Effort::Off, &h), 0);
        assert!(off.get("thinking").is_none());
    }

    #[test]
    fn capabilities_from_the_api_win_over_the_name() {
        let h = [user("hi")];
        let mut r = req("claude-future-1", Effort::High, &h);
        r.caps = Some(Caps {
            adaptive: false,
            budget: true,
            effort: false,
        });
        let b = anthropic_body(&r, 0);
        assert_eq!(b["thinking"]["type"], "enabled");

        r.caps = Some(Caps {
            adaptive: true,
            budget: false,
            effort: false,
        });
        let b = anthropic_body(&r, 0);
        assert_eq!(b["thinking"]["type"], "adaptive");
        assert!(b.get("output_config").is_none());
    }

    #[test]
    fn a_retry_sends_no_thinking_settings() {
        let h = [user("hi")];
        let b = anthropic_body(&req("claude-sonnet-5-5", Effort::High, &h), 1);
        assert!(b.get("thinking").is_none());
        assert!(b.get("output_config").is_none());
    }

    #[test]
    fn the_system_prompt_goes_where_each_provider_wants_it() {
        let h = [user("hi")];
        let mut r = req("claude-sonnet-5-5", Effort::Low, &h);
        r.system = "be brief";
        assert_eq!(anthropic_body(&r, 0)["system"], "be brief");

        let b = openai_body(&r, 0);
        assert_eq!(
            b["messages"][0],
            json!({ "role": "system", "content": "be brief" })
        );
        assert_eq!(b["messages"][1]["role"], "user");
    }

    #[test]
    fn openai_reasoning_effort_only_for_reasoning_models() {
        let h = [user("hi")];
        assert_eq!(
            openai_body(&req("gpt-5", Effort::Max, &h), 0)["reasoning_effort"],
            "high"
        );
        assert_eq!(
            openai_body(&req("gpt-5", Effort::Off, &h), 0)["reasoning_effort"],
            "minimal"
        );
        assert_eq!(
            openai_body(&req("o3", Effort::Off, &h), 0)["reasoning_effort"],
            "low"
        );
        assert_eq!(
            openai_body(&req("o4-mini", Effort::Medium, &h), 0)["reasoning_effort"],
            "medium"
        );
        assert!(openai_body(&req("gpt-4.1", Effort::High, &h), 0)
            .get("reasoning_effort")
            .is_none());
        assert!(openai_body(&req("gpt-5-chat-latest", Effort::High, &h), 0)
            .get("reasoning_effort")
            .is_none());
        assert!(openai_body(&req("gpt-5", Effort::High, &h), 1)
            .get("reasoning_effort")
            .is_none());
    }

    #[test]
    fn history_is_cut_from_the_old_end() {
        let long = "x".repeat(3500 * 3); // ~3000 tokens
        let msgs = vec![
            user(&long),
            (Role::Assistant, long.clone()),
            user(&long),
            (Role::Assistant, long.clone()),
            user("last"),
        ];
        // Room for about 2048 + 3500 tokens of conversation
        let kept = trim_history(&msgs, 2048 + 4096 + 3000, "");
        assert_eq!(kept.last().unwrap().1, "last");
        assert!(kept.len() < msgs.len());
        assert_eq!(kept[0].0, Role::User);

        // Everything fits
        assert_eq!(trim_history(&msgs, 1_000_000, "").len(), msgs.len());
        // The newest message always goes, however small the context
        let kept = trim_history(&msgs, 100, "");
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].1, "last");
    }

    #[test]
    fn history_starts_with_a_user_message() {
        let msgs = vec![
            (Role::Assistant, "a".into()),
            user("u"),
            (Role::Assistant, "b".into()),
        ];
        let kept = trim_history(&msgs, 1_000_000, "");
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].0, Role::User);
        // Only dropped when something follows to start from
        let alone = vec![(Role::Assistant, "a".into())];
        assert_eq!(trim_history(&alone, 1_000_000, "").len(), 1);
    }

    #[test]
    fn anthropic_model_list_with_capabilities() {
        let body = r#"{"data":[
            {"id":"claude-a","display_name":"Claude A","capabilities":{
                "thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true}}},
                "effort":{"supported":true,"low":{"supported":true}}}},
            {"id":"claude-b","display_name":"","capabilities":{
                "thinking":{"supported":true,"types":{"enabled":{"supported":true},"adaptive":{"supported":false}}},
                "effort":{"supported":false}}},
            {"id":"claude-c"}
        ]}"#;
        let (models, caps) = parse_anthropic_models(body).unwrap();
        assert_eq!(
            models.iter().map(|m| m.label.as_str()).collect::<Vec<_>>(),
            ["Claude A", "claude-b", "claude-c"]
        );
        assert_eq!(
            caps["claude-a"],
            Caps {
                adaptive: true,
                budget: false,
                effort: true
            }
        );
        assert_eq!(
            caps["claude-b"],
            Caps {
                adaptive: false,
                budget: true,
                effort: false
            }
        );
        assert!(!caps.contains_key("claude-c"));
        assert!(parse_anthropic_models("not json").is_none());
    }

    #[test]
    fn openai_model_list_keeps_chat_models_newest_first() {
        let body = r#"{"data":[
            {"id":"text-embedding-3-small","created":5},
            {"id":"gpt-4o","created":10},
            {"id":"gpt-4o-audio-preview","created":30},
            {"id":"o3","created":40},
            {"id":"gpt-5","created":50},
            {"id":"whisper-1","created":60},
            {"id":"gpt-5-codex","created":70},
            {"id":"omni-moderation-latest","created":80}
        ]}"#;
        let ids: Vec<String> = parse_openai_models(body)
            .unwrap()
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(ids, ["gpt-5", "o3", "gpt-4o"]);
    }

    #[test]
    fn anthropic_stream_events() {
        let text = parse_stream_line(
            Provider::Anthropic,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
        );
        assert_eq!(text.text, "Hel");
        let think = parse_stream_line(
            Provider::Anthropic,
            r#"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hm"}}"#,
        );
        assert_eq!(think.thinking, "hm");
        let stop = parse_stream_line(
            Provider::Anthropic,
            r#"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":1}}"#,
        );
        assert_eq!(stop.stop_reason.as_deref(), Some("max_tokens"));
        let err = parse_stream_line(
            Provider::Anthropic,
            r#"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        );
        assert_eq!(err.error.as_deref(), Some("Overloaded"));
        // Not data, or not for us
        assert_eq!(
            parse_stream_line(Provider::Anthropic, "event: ping"),
            Delta::default()
        );
        assert_eq!(
            parse_stream_line(Provider::Anthropic, "data: {\"type\":\"ping\"}"),
            Delta::default()
        );
        assert_eq!(
            parse_stream_line(Provider::Anthropic, "data: {broken"),
            Delta::default()
        );
    }

    #[test]
    fn openai_stream_events() {
        let text = parse_stream_line(
            Provider::OpenAi,
            r#"data: {"choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}"#,
        );
        assert_eq!(text.text, "Hi");
        assert!(text.stop_reason.is_none());
        let stop = parse_stream_line(
            Provider::OpenAi,
            r#"data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#,
        );
        assert_eq!(stop.stop_reason.as_deref(), Some("length"));
        assert_eq!(
            parse_stream_line(Provider::OpenAi, "data: [DONE]"),
            Delta::default()
        );
        let err = parse_stream_line(Provider::OpenAi, r#"data: {"error":{"message":"boom"}}"#);
        assert_eq!(err.error.as_deref(), Some("boom"));
    }

    #[test]
    fn error_bodies() {
        assert_eq!(
            error_message(r#"{"type":"error","error":{"type":"invalid_request_error","message":"bad thinking"}}"#).as_deref(),
            Some("bad thinking")
        );
        assert_eq!(
            error_message(r#"{"message":"nope"}"#).as_deref(),
            Some("nope")
        );
        assert!(error_message("<html>").is_none());
        assert!(is_thinking_error("thinking: Input should be 'adaptive'"));
        assert!(is_thinking_error("Unsupported value: 'reasoning_effort'"));
        assert!(!is_thinking_error("invalid x-api-key"));
    }
}
