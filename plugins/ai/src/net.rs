//! The I/O of the plugin: sending a message and reading the answer as it
//! streams in, and asking the providers which models they have.

use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};

use caelestia_plugin_sdk::ui::View;
use futures_util::StreamExt;
use tokio::task::AbortHandle;

use crate::chat::{Chat, Kind, Message};
use crate::provider::{
    anthropic_body, error_message, is_thinking_error, openai_body, parse_anthropic_models,
    parse_openai_models, parse_stream_line, ChatRequest, Provider, ANTHROPIC_VERSION,
};
use crate::view::chat_view;

/// How often the view is pushed while an answer streams in.
const PUSH_INTERVAL: Duration = Duration::from_millis(80);

pub struct Shared {
    chat: Mutex<Chat>,
    http: reqwest::Client,
    anthropic_base: String,
    openai_base: String,
    push: OnceLock<Box<dyn Fn(View) + Send + Sync>>,
    task: Mutex<Option<AbortHandle>>,
}

impl Shared {
    /// `CAELESTIA_AI_ANTHROPIC_URL` / `CAELESTIA_AI_OPENAI_URL` point a provider at another
    /// endpoint (a proxy, a compatible server), without a trailing `/v1`.
    pub fn new(chat: Chat) -> Arc<Self> {
        let base = |var: &str, default: &str| {
            std::env::var(var)
                .ok()
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| default.to_owned())
        };
        Self::with_bases(
            chat,
            &base("CAELESTIA_AI_ANTHROPIC_URL", "https://api.anthropic.com"),
            &base("CAELESTIA_AI_OPENAI_URL", "https://api.openai.com"),
        )
    }

    pub fn with_bases(chat: Chat, anthropic_base: &str, openai_base: &str) -> Arc<Self> {
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(15))
            // Reasoning models can be silent for a long while before the first token
            .read_timeout(Duration::from_secs(600))
            .build()
            .expect("the HTTP client can be built");
        Arc::new(Self {
            chat: Mutex::new(chat),
            http,
            anthropic_base: anthropic_base.trim_end_matches('/').to_owned(),
            openai_base: openai_base.trim_end_matches('/').to_owned(),
            push: OnceLock::new(),
            task: Mutex::new(None),
        })
    }

    /// Where views go once there is a shell to show them.
    pub fn set_pusher(&self, push: impl Fn(View) + Send + Sync + 'static) {
        let _ = self.push.set(Box::new(push));
    }

    pub fn chat(&self) -> MutexGuard<'_, Chat> {
        // A panic while holding the lock leaves plain data behind; keep going
        self.chat.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Pushes the current view.
    pub fn push_view(&self) {
        if let Some(push) = self.push.get() {
            let view = chat_view(&self.chat());
            push(view);
        }
    }

    fn set_task(&self, handle: Option<AbortHandle>) {
        *self.task.lock().unwrap_or_else(|e| e.into_inner()) = handle;
    }

    fn abort_task(&self) {
        if let Some(handle) = self.task.lock().unwrap_or_else(|e| e.into_inner()).take() {
            handle.abort();
        }
    }

    // -------------------------------------------------------------- chatting

    /// Sends `text` as the next message and starts reading the answer.
    pub fn send(self: &Arc<Self>, text: &str) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let generation = {
            let mut chat = self.chat();
            if chat.busy {
                return;
            }
            if !chat.has_key() {
                let message = format!(
                    "There's no {} API key yet. Add one in this plugin's settings.",
                    chat.provider.label()
                );
                chat.messages.push(Message::new(Kind::Error, message));
                drop(chat);
                self.push_view();
                return;
            }
            chat.messages.push(Message::new(Kind::User, text));
            chat.messages.push(Message::new(Kind::Assistant, ""));
            chat.busy = true;
            chat.generation += 1;
            chat.generation
        };
        self.push_view();

        let shared = self.clone();
        let handle = tokio::spawn(async move { run_chat(shared, generation).await });
        self.set_task(Some(handle.abort_handle()));
    }

    /// Ends the answer in progress, keeping what has arrived.
    pub fn stop(&self) {
        self.abort_task();
        {
            let mut chat = self.chat();
            if !chat.busy {
                return;
            }
            chat.busy = false;
            chat.generation += 1;
            chat.drop_empty_answer();
        }
        self.push_view();
    }

    /// Ends the conversation.
    pub fn clear(&self) {
        self.abort_task();
        self.chat().clear();
        self.push_view();
    }

    // ----------------------------------------------------------------- models

    /// Reads the model list of `provider` (if there is a key for it).
    pub fn refresh_models(self: &Arc<Self>, provider: Provider) {
        let shared = self.clone();
        tokio::spawn(async move { fetch_models(shared, provider).await });
    }
}

enum Outcome {
    Done(Option<String>),
    /// The API refused the thinking settings: ask again without them.
    Retry,
    Failed(String),
    /// Stopped, or overtaken by a newer request.
    Cancelled,
}

async fn run_chat(shared: Arc<Shared>, generation: u64) {
    let mut attempt = 0u8;
    let outcome = loop {
        match stream_once(&shared, generation, attempt).await {
            Outcome::Retry => {
                attempt += 1;
                let mut chat = shared.chat();
                if chat.generation != generation {
                    return;
                }
                if let Some(answer) = chat.messages.last_mut() {
                    answer.text.clear();
                    answer.thinking.clear();
                }
            }
            other => break other,
        }
    };

    {
        let mut chat = shared.chat();
        if chat.generation != generation {
            return;
        }
        chat.busy = false;
        match outcome {
            Outcome::Failed(message) => {
                chat.drop_empty_answer();
                chat.messages.push(Message::new(Kind::Error, message));
            }
            Outcome::Done(stop) => {
                let note = match stop.as_deref() {
                    Some("refusal" | "content_filter") => Some("_The model declined to answer._"),
                    Some("max_tokens" | "length") => {
                        Some("_The answer hit the output limit and was cut off._")
                    }
                    _ => None,
                };
                match chat.messages.last_mut() {
                    Some(answer) if answer.kind == Kind::Assistant => {
                        if let Some(note) = note {
                            if !answer.text.is_empty() {
                                answer.text.push_str("\n\n");
                            }
                            answer.text.push_str(note);
                        }
                    }
                    _ => {}
                }
                if chat
                    .messages
                    .last()
                    .is_some_and(|m| m.kind == Kind::Assistant && m.text.is_empty())
                {
                    chat.drop_empty_answer();
                    chat.messages.push(Message::new(
                        Kind::Error,
                        "The model answered with nothing.",
                    ));
                }
            }
            Outcome::Retry | Outcome::Cancelled => {}
        }
    }
    shared.set_task(None);
    shared.push_view();
}

async fn stream_once(shared: &Arc<Shared>, generation: u64, attempt: u8) -> Outcome {
    let (provider, url, key, body) = {
        let chat = shared.chat();
        if chat.generation != generation {
            return Outcome::Cancelled;
        }
        let history = chat.history();
        let system = chat.system();
        let req = ChatRequest {
            model: &chat.model,
            effort: chat.effort,
            system: &system,
            history: &history,
            caps: chat.caps.get(&chat.model).copied(),
        };
        let (url, body) = match chat.provider {
            Provider::Anthropic => (
                format!("{}/v1/messages", shared.anthropic_base),
                anthropic_body(&req, attempt),
            ),
            Provider::OpenAi => (
                format!("{}/v1/chat/completions", shared.openai_base),
                openai_body(&req, attempt),
            ),
        };
        (chat.provider, url, chat.key(chat.provider).to_owned(), body)
    };

    let request = shared
        .http
        .post(url)
        .header("content-type", "application/json")
        .header("accept", "text/event-stream");
    let request = match provider {
        Provider::Anthropic => request
            .header("x-api-key", key)
            .header("anthropic-version", ANTHROPIC_VERSION),
        Provider::OpenAi => request.bearer_auth(key),
    };
    let response = match request.body(body.to_string()).send().await {
        Ok(r) => r,
        Err(e) => return Outcome::Failed(format!("Couldn't reach {}: {e}", provider.label())),
    };

    let status = response.status();
    if !status.is_success() {
        let text = response.text().await.unwrap_or_default();
        let message = error_message(&text)
            .unwrap_or_else(|| format!("{} answered HTTP {status}", provider.label()));
        if status.as_u16() == 400 && attempt == 0 && is_thinking_error(&message) {
            return Outcome::Retry;
        }
        return Outcome::Failed(message);
    }

    let mut stream = response.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    let mut stop_reason = None;
    let mut last_push = Instant::now();

    // Applies one line; `Err` ends the request.
    let mut line_done = |line: &[u8]| -> Result<(), Outcome> {
        let line = String::from_utf8_lossy(line);
        let delta = parse_stream_line(provider, line.trim_end_matches('\r'));
        if let Some(e) = delta.error {
            return Err(Outcome::Failed(e));
        }
        if delta.stop_reason.is_some() {
            stop_reason = delta.stop_reason;
        }
        if delta.text.is_empty() && delta.thinking.is_empty() {
            return Ok(());
        }
        let mut chat = shared.chat();
        if chat.generation != generation {
            return Err(Outcome::Cancelled);
        }
        if let Some(answer) = chat.messages.last_mut() {
            answer.text.push_str(&delta.text);
            answer.thinking.push_str(&delta.thinking);
        }
        Ok(())
    };

    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(e) => {
                return Outcome::Failed(format!(
                    "The connection to {} broke: {e}",
                    provider.label()
                ))
            }
        };
        buf.extend_from_slice(&chunk);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let result = line_done(&buf[..pos]);
            buf.drain(..=pos);
            if let Err(outcome) = result {
                return outcome;
            }
        }
        if last_push.elapsed() >= PUSH_INTERVAL {
            last_push = Instant::now();
            shared.push_view();
        }
    }
    // A last line the provider didn't end with a newline
    if !buf.is_empty() {
        if let Err(outcome) = line_done(&buf) {
            return outcome;
        }
    }
    Outcome::Done(stop_reason)
}

async fn fetch_models(shared: Arc<Shared>, provider: Provider) {
    let key = {
        let mut chat = shared.chat();
        let key = chat.key(provider).to_owned();
        if key.is_empty() {
            return;
        }
        chat.loading_models = true;
        chat.models_error.clear();
        key
    };
    shared.push_view();

    let request = match provider {
        Provider::Anthropic => shared
            .http
            .get(format!("{}/v1/models?limit=1000", shared.anthropic_base))
            .header("x-api-key", &key)
            .header("anthropic-version", ANTHROPIC_VERSION),
        Provider::OpenAi => shared
            .http
            .get(format!("{}/v1/models", shared.openai_base))
            .bearer_auth(&key),
    };
    let result: Result<String, String> = async {
        let response = request
            .send()
            .await
            .map_err(|e| format!("Couldn't reach {}: {e}", provider.label()))?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        if status.is_success() {
            Ok(text)
        } else {
            Err(error_message(&text)
                .unwrap_or_else(|| format!("Couldn't load the models (HTTP {status})")))
        }
    }
    .await;

    {
        let mut chat = shared.chat();
        // The key changed meanwhile: this says nothing about the new one
        if chat.key(provider) != key {
            return;
        }
        chat.loading_models = false;
        match result {
            Err(message) => chat.models_error = message,
            Ok(text) => match provider {
                Provider::Anthropic => match parse_anthropic_models(&text) {
                    Some((models, caps)) if !models.is_empty() => {
                        chat.models.insert(provider, models);
                        chat.caps = caps;
                    }
                    Some(_) => {}
                    None => chat.models_error = "Couldn't read the model list".into(),
                },
                Provider::OpenAi => match parse_openai_models(&text) {
                    Some(models) if !models.is_empty() => {
                        chat.models.insert(provider, models);
                    }
                    Some(_) => {}
                    None => chat.models_error = "Couldn't read the model list".into(),
                },
            },
        }
    }
    shared.push_view();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::Persisted;
    use std::path::PathBuf;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    /// What the fake server answers with.
    #[derive(Clone)]
    struct Reply {
        status: u16,
        /// Sent one by one, with `gap` between them.
        chunks: Vec<String>,
        gap: Duration,
    }

    fn reply(status: u16, chunks: &[&str]) -> Reply {
        Reply {
            status,
            chunks: chunks.iter().map(|c| (*c).to_owned()).collect(),
            gap: Duration::ZERO,
        }
    }

    #[derive(Debug)]
    struct Seen {
        path: String,
        headers: String,
        body: String,
    }

    /// A one-purpose HTTP server: answers requests in order with `replies`
    /// (the last one repeats) and remembers what it was asked.
    async fn serve(replies: Vec<Reply>) -> (String, Arc<Mutex<Vec<Seen>>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            let mut n = 0;
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let reply = replies[n.min(replies.len() - 1)].clone();
                n += 1;
                let log = log.clone();
                tokio::spawn(async move {
                    let mut data = Vec::new();
                    let mut tmp = [0u8; 4096];
                    let (head_end, length) = loop {
                        let read = sock.read(&mut tmp).await.unwrap_or(0);
                        if read == 0 {
                            return;
                        }
                        data.extend_from_slice(&tmp[..read]);
                        if let Some(pos) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&data[..pos]).to_lowercase();
                            let length = head
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length:"))
                                .and_then(|v| v.trim().parse::<usize>().ok())
                                .unwrap_or(0);
                            break (pos + 4, length);
                        }
                    };
                    while data.len() < head_end + length {
                        let read = sock.read(&mut tmp).await.unwrap_or(0);
                        if read == 0 {
                            break;
                        }
                        data.extend_from_slice(&tmp[..read]);
                    }
                    let head = String::from_utf8_lossy(&data[..head_end]).into_owned();
                    log.lock().unwrap().push(Seen {
                        path: head
                            .split_whitespace()
                            .nth(1)
                            .unwrap_or_default()
                            .to_owned(),
                        headers: head.to_lowercase(),
                        body: String::from_utf8_lossy(&data[head_end..]).into_owned(),
                    });

                    let _ = sock
                        .write_all(
                            format!(
                                "HTTP/1.1 {} X\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
                                reply.status
                            )
                            .as_bytes(),
                        )
                        .await;
                    for chunk in &reply.chunks {
                        let _ = sock.write_all(chunk.as_bytes()).await;
                        let _ = sock.flush().await;
                        tokio::time::sleep(reply.gap).await;
                    }
                    let _ = sock.shutdown().await;
                });
            }
        });
        (base, seen)
    }

    fn shared(base: &str, provider: Provider) -> (Arc<Shared>, Arc<Mutex<Vec<View>>>) {
        let mut chat = Chat::new(Persisted::default(), PathBuf::new());
        chat.anthropic_key = "sk-ant-test".into();
        chat.openai_key = "sk-openai-test".into();
        chat.set_provider(provider);
        let shared = Shared::with_bases(chat, base, base);
        let pushed = Arc::new(Mutex::new(Vec::new()));
        let sink = pushed.clone();
        shared.set_pusher(move |v| sink.lock().unwrap().push(v));
        (shared, pushed)
    }

    async fn until_idle(shared: &Arc<Shared>) {
        for _ in 0..200 {
            if !shared.chat().busy {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the request never finished");
    }

    fn sse(events: &[&str]) -> Vec<String> {
        events.iter().map(|e| format!("data: {e}\n\n")).collect()
    }

    #[tokio::test]
    async fn an_anthropic_answer_streams_into_the_chat() {
        let events = sse(&[
            r#"{"type":"message_start","message":{"id":"m"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me see"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello "}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"wörld"}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]);
        let (base, seen) = serve(vec![Reply {
            status: 200,
            chunks: events,
            gap: Duration::from_millis(5),
        }])
        .await;
        let (shared, pushed) = shared(&base, Provider::Anthropic);

        shared.send("  hi there ");
        assert!(shared.chat().busy);
        until_idle(&shared).await;

        let chat = shared.chat();
        assert_eq!(chat.messages.len(), 2);
        assert_eq!(chat.messages[0].text, "hi there");
        assert_eq!(chat.messages[1].kind, Kind::Assistant);
        assert_eq!(chat.messages[1].text, "Hello wörld");
        assert_eq!(chat.messages[1].thinking, "let me see");
        assert!(pushed.lock().unwrap().len() >= 2);

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].path, "/v1/messages");
        assert!(seen[0].headers.contains("x-api-key: sk-ant-test"));
        assert!(seen[0]
            .headers
            .contains(&format!("anthropic-version: {ANTHROPIC_VERSION}")));
        let body: serde_json::Value = serde_json::from_str(&seen[0].body).unwrap();
        assert_eq!(body["model"], "claude-sonnet-5-5");
        assert_eq!(body["messages"][0]["content"], "hi there");
        assert_eq!(body["thinking"]["type"], "adaptive");
    }

    #[tokio::test]
    async fn an_openai_answer_streams_into_the_chat() {
        let events = sse(&[
            r#"{"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"content":"Hi"}}]}"#,
            r#"{"choices":[{"index":0,"delta":{"content":" there"}}]}"#,
            r#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ]);
        let (base, seen) = serve(vec![Reply {
            status: 200,
            chunks: events,
            gap: Duration::ZERO,
        }])
        .await;
        let (shared, _) = shared(&base, Provider::OpenAi);
        shared.chat().system_prompt = "be nice".into();

        shared.send("hello");
        until_idle(&shared).await;

        assert_eq!(shared.chat().messages[1].text, "Hi there");
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].path, "/v1/chat/completions");
        assert!(seen[0]
            .headers
            .contains("authorization: bearer sk-openai-test"));
        let body: serde_json::Value = serde_json::from_str(&seen[0].body).unwrap();
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][0]["content"], "be nice");
        assert_eq!(body["reasoning_effort"], "medium");
    }

    #[tokio::test]
    async fn an_error_becomes_an_error_message() {
        let (base, _) = serve(vec![reply(
            401,
            &[r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#],
        )])
        .await;
        let (shared, _) = shared(&base, Provider::Anthropic);

        shared.send("hi");
        until_idle(&shared).await;

        let chat = shared.chat();
        assert!(!chat.busy);
        // The empty answer is gone, the error is there
        assert_eq!(chat.messages.len(), 2);
        assert_eq!(chat.messages[1].kind, Kind::Error);
        assert_eq!(chat.messages[1].text, "invalid x-api-key");
    }

    #[tokio::test]
    async fn an_error_in_the_stream_keeps_what_was_written() {
        let events = sse(&[
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half an ans"}}"#,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]);
        let (base, _) = serve(vec![Reply {
            status: 200,
            chunks: events,
            gap: Duration::ZERO,
        }])
        .await;
        let (shared, _) = shared(&base, Provider::Anthropic);

        shared.send("hi");
        until_idle(&shared).await;

        let chat = shared.chat();
        assert_eq!(chat.messages[1].text, "Half an ans");
        assert_eq!(chat.messages[2].kind, Kind::Error);
        assert_eq!(chat.messages[2].text, "Overloaded");
    }

    #[tokio::test]
    async fn refused_thinking_settings_are_dropped_and_the_request_repeated() {
        let ok = sse(&[
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fine"}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
        ]);
        let (base, seen) = serve(vec![
            reply(400, &[r#"{"error":{"type":"invalid_request_error","message":"thinking.type: not supported for this model"}}"#]),
            Reply {
                status: 200,
                chunks: ok,
                gap: Duration::ZERO,
            },
        ])
        .await;
        let (shared, _) = shared(&base, Provider::Anthropic);

        shared.send("hi");
        until_idle(&shared).await;

        assert_eq!(shared.chat().messages[1].text, "fine");
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        let first: serde_json::Value = serde_json::from_str(&seen[0].body).unwrap();
        let second: serde_json::Value = serde_json::from_str(&seen[1].body).unwrap();
        assert!(first.get("thinking").is_some());
        assert!(second.get("thinking").is_none());
        assert!(second.get("output_config").is_none());
    }

    #[tokio::test]
    async fn a_cut_off_answer_says_so() {
        let events = sse(&[
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Long"}}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#,
        ]);
        let (base, _) = serve(vec![Reply {
            status: 200,
            chunks: events,
            gap: Duration::ZERO,
        }])
        .await;
        let (shared, _) = shared(&base, Provider::Anthropic);
        shared.send("hi");
        until_idle(&shared).await;
        assert!(shared.chat().messages[1]
            .text
            .starts_with("Long\n\n_The answer hit the output limit"));
    }

    #[tokio::test]
    async fn stopping_keeps_the_partial_answer() {
        let events = sse(&[
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"one "}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"two "}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"three"}}"#,
        ]);
        let (base, _) = serve(vec![Reply {
            status: 200,
            chunks: events,
            gap: Duration::from_millis(300),
        }])
        .await;
        let (shared, _) = shared(&base, Provider::Anthropic);

        shared.send("hi");
        tokio::time::sleep(Duration::from_millis(150)).await;
        shared.stop();

        {
            let chat = shared.chat();
            assert!(!chat.busy);
            assert_eq!(chat.messages[1].text, "one ");
        }
        // Nothing more arrives after it was stopped
        tokio::time::sleep(Duration::from_millis(700)).await;
        assert_eq!(shared.chat().messages[1].text, "one ");

        // And an answer that never started is dropped altogether
        let (base, _) = serve(vec![Reply {
            status: 200,
            chunks: vec![": ping\n\n".into()],
            gap: Duration::from_secs(5),
        }])
        .await;
        let (shared, _) = self::shared(&base, Provider::Anthropic);
        shared.send("hi");
        tokio::time::sleep(Duration::from_millis(100)).await;
        shared.stop();
        assert_eq!(shared.chat().messages.len(), 1);
    }

    #[tokio::test]
    async fn sending_needs_a_key() {
        let (base, seen) = serve(vec![reply(200, &[])]).await;
        let (shared, _) = shared(&base, Provider::Anthropic);
        shared.chat().anthropic_key = "  ".into();
        shared.send("hi");
        let chat = shared.chat();
        assert!(!chat.busy);
        assert_eq!(chat.messages.len(), 1);
        assert_eq!(chat.messages[0].kind, Kind::Error);
        assert!(seen.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_model_list_replaces_the_fallback() {
        let body = r#"{"data":[
            {"id":"claude-new","display_name":"Claude New","capabilities":{
                "thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true}}},
                "effort":{"supported":true}}}
        ]}"#;
        let (base, seen) = serve(vec![reply(200, &[body])]).await;
        let (shared, _) = shared(&base, Provider::Anthropic);

        shared.refresh_models(Provider::Anthropic);
        for _ in 0..100 {
            if !shared.chat().loading_models
                && shared.chat().models[&Provider::Anthropic].len() == 1
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let chat = shared.chat();
        assert_eq!(chat.models[&Provider::Anthropic][0].label, "Claude New");
        assert!(chat.caps["claude-new"].adaptive);
        // The OpenAI list is still the fallback
        assert!(chat.models[&Provider::OpenAi].len() > 1);
        let seen = seen.lock().unwrap();
        assert!(seen[0].path.starts_with("/v1/models"));
        assert!(seen[0].headers.contains("x-api-key: sk-ant-test"));
    }

    #[tokio::test]
    async fn a_failing_model_list_is_reported_not_fatal() {
        let (base, _) = serve(vec![reply(
            401,
            &[r#"{"error":{"message":"Incorrect API key"}}"#],
        )])
        .await;
        let (shared, _) = shared(&base, Provider::OpenAi);
        shared.refresh_models(Provider::OpenAi);
        for _ in 0..100 {
            if !shared.chat().models_error.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let chat = shared.chat();
        assert_eq!(chat.models_error, "Incorrect API key");
        assert!(!chat.loading_models);
        assert!(!chat.models[&Provider::OpenAi].is_empty());
    }
}
