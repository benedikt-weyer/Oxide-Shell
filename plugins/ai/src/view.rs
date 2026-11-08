//! Turns the chat state into the widget tree of the panel.

use caelestia_plugin_sdk::ui::{
    button, column, icon, keyed, markdown, row, scroll, select, spacer, spinner, text, text_input,
    Align, ButtonStyle, Container, Elide, Node, Surface, TextStyle, Tone, View,
};

use crate::chat::{context_label, Chat, Kind, Message, CONTEXT_SIZES};
use crate::provider::{Effort, Provider};

pub const CHAT_VIEW: &str = "chat";

pub fn chat_view(chat: &Chat) -> View {
    let root = column()
        .fill()
        .spacing(10.0)
        .child(keyed("preset-row", preset_row(chat)))
        .child(keyed("select-row", select_row(chat)))
        .children((!chat.models_error.is_empty()).then(|| {
            keyed(
                "models-error",
                text(&chat.models_error)
                    .style(TextStyle::Label)
                    .tone(Tone::Error)
                    .fill(Elide::None),
            )
        }))
        .child(keyed(
            "messages",
            scroll(messages(chat)).expand().stick_to_end(),
        ))
        .child(keyed("input-row", input_row(chat)));
    View::new(CHAT_VIEW, keyed("root", root))
}

fn icon_button(icon: &str, action: &str) -> caelestia_plugin_sdk::ui::Button {
    button("")
        .icon(icon)
        .action(action)
        .style(ButtonStyle::Text)
}

fn preset_row(chat: &Chat) -> Container {
    if chat.naming_preset {
        return row()
            .fill()
            .align(Align::Center)
            .spacing(8.0)
            .child(keyed(
                "name-input",
                text_input("preset_save")
                    .placeholder("Name of the preset")
                    .submit_icon("check")
                    .autofocus(),
            ))
            .child(keyed("name-cancel", icon_button("close", "preset_cancel")));
    }

    let mut presets = select("preset", &chat.preset)
        .icon("bookmarks")
        .placeholder("Preset")
        .title("Presets");
    for p in &chat.presets {
        presets = presets.option_full(&p.name, &p.name, "", p.summary());
    }
    if chat.presets.is_empty() {
        presets = presets.disabled(true);
    }

    let mut r = row()
        .fill()
        .align(Align::Center)
        .spacing(4.0)
        .child(keyed("preset", presets))
        .child(spacer(0.0))
        .child(keyed(
            "preset-save",
            icon_button("bookmark_add", "preset_begin"),
        ));
    if !chat.preset.is_empty() {
        r = r.child(keyed(
            "preset-delete",
            icon_button("delete", "preset_delete"),
        ));
    }
    r.child(keyed("clear", icon_button("add_comment", "clear")))
}

fn select_row(chat: &Chat) -> Container {
    let mut providers = select("provider", chat.provider.id())
        .icon(chat.provider.icon())
        .title("Provider");
    for p in Provider::ALL {
        providers = providers.option_full(p.id(), p.label(), p.icon(), "");
    }

    let mut models = select("model", &chat.model)
        .icon("smart_toy")
        .placeholder("Model")
        .title(if chat.loading_models {
            "Model (loading the list…)"
        } else {
            "Model"
        });
    for m in chat.available_models() {
        let description = if m.label == m.id {
            String::new()
        } else {
            m.id.clone()
        };
        models = models.option_full(&m.id, &m.label, "", description);
    }

    let mut efforts = select("effort", chat.effort.id())
        .icon("lightbulb")
        .title("Thinking effort");
    for e in Effort::ALL {
        efforts = efforts.option(e.id(), e.label());
    }

    let mut contexts = select("context", chat.context.to_string())
        .icon("memory")
        .placeholder(context_label(chat.context))
        .title("Context size (tokens)");
    let mut sizes: Vec<u32> = CONTEXT_SIZES.to_vec();
    // A preset or an old selection may use a size that isn't in the list
    if !sizes.contains(&chat.context) {
        sizes.push(chat.context);
        sizes.sort_unstable();
    }
    for size in sizes {
        contexts = contexts.option(size.to_string(), context_label(size));
    }

    row()
        .align(Align::Center)
        .spacing(6.0)
        .child(keyed("provider", providers))
        .child(keyed("model", models))
        .child(keyed("effort", efforts))
        .child(keyed("context", contexts))
}

fn messages(chat: &Chat) -> Container {
    let mut list = column().fill().spacing(8.0);

    if chat.messages.is_empty() {
        let hint: Node = if chat.has_key() {
            text(format!(
                "Ask {} anything.",
                chat.available_models()
                    .iter()
                    .find(|m| m.id == chat.model)
                    .map_or(chat.model.as_str(), |m| m.label.as_str())
            ))
            .tone(Tone::Muted)
            .fill(Elide::None)
            .into()
        } else {
            column()
                .fill()
                .surface(Surface::CardLow)
                .padding(14.0)
                .spacing(6.0)
                .child(
                    row()
                        .align(Align::Center)
                        .spacing(8.0)
                        .child(icon("key").tone(Tone::Primary))
                        .child(text(format!("No {} API key yet", chat.provider.label())).style(TextStyle::Title)),
                )
                .child(
                    text("Add one in this plugin's settings (the gear in the header, or Nexus > Plugins > AI Chat), then come back.")
                        .tone(Tone::Muted)
                        .fill(Elide::None),
                )
                .into()
        };
        return list.child(keyed("hint", hint));
    }

    let last = chat.messages.len() - 1;
    for (i, m) in chat.messages.iter().enumerate() {
        let waiting = chat.busy && i == last;
        list = list.child(keyed(format!("m{i}"), message(i, m, waiting)));
    }
    list
}

fn message(index: usize, m: &Message, waiting: bool) -> Container {
    let header = |glyph: &str, who: &str, tone: Tone| {
        row()
            .align(Align::Center)
            .spacing(6.0)
            .child(icon(glyph).size(18.0).tone(tone))
            .child(text(who).style(TextStyle::Label).tone(Tone::Muted))
    };

    match m.kind {
        Kind::User => column()
            .fill()
            .surface(Surface::Card)
            .padding(12.0)
            .spacing(4.0)
            .child(header("person", "You", Tone::Primary))
            .child(text(&m.text).fill(Elide::None)),
        Kind::Error => column()
            .fill()
            .surface(Surface::Card)
            .padding(12.0)
            .spacing(4.0)
            .child(header("error", "Error", Tone::Error))
            .child(text(&m.text).tone(Tone::Error).fill(Elide::None)),
        Kind::Assistant => {
            let mut c = column()
                .fill()
                .surface(Surface::CardLow)
                .padding(12.0)
                .spacing(4.0)
                .child(header("auto_awesome", "Assistant", Tone::Secondary));
            if !m.thinking.is_empty() {
                c = c.child(
                    button(if m.show_thinking {
                        "Hide thinking"
                    } else {
                        "Show thinking"
                    })
                    .icon(if m.show_thinking {
                        "expand_less"
                    } else {
                        "expand_more"
                    })
                    .style(ButtonStyle::Text)
                    .action("toggle_thinking")
                    .payload(index.to_string()),
                );
                if m.show_thinking {
                    c = c.child(markdown(&m.thinking).tone(Tone::Muted));
                }
            }
            if m.text.is_empty() {
                if waiting {
                    c = c.child(
                        row()
                            .align(Align::Center)
                            .spacing(8.0)
                            .child(spinner().size(18.0))
                            .child(text("Thinking…").tone(Tone::Muted)),
                    );
                }
                c
            } else {
                c.child(markdown(&m.text))
            }
        }
    }
}

fn input_row(chat: &Chat) -> Container {
    let placeholder = if chat.has_key() {
        format!(
            "Message {} (Shift+Enter for a new line)",
            chat.provider.label()
        )
    } else {
        format!(
            "Add a {} API key in the settings first",
            chat.provider.label()
        )
    };
    let mut r = row().fill().align(Align::Center).spacing(8.0).child(keyed(
        "input",
        text_input("send")
            .placeholder(placeholder)
            .multiline()
            .max_lines(6)
            .submit_icon("send")
            .disabled(chat.busy || !chat.has_key())
            .reset_token(chat.input_token.to_string())
            .autofocus(),
    ));
    if chat.busy {
        r = r.child(keyed(
            "stop",
            button("")
                .icon("stop")
                .action("stop")
                .style(ButtonStyle::Tonal),
        ));
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::chat::Persisted;
    use caelestia_plugin_sdk::proto::{node::Kind as NodeKind, Node as Proto};
    use std::path::PathBuf;

    fn chat() -> Chat {
        let mut c = Chat::new(Persisted::default(), PathBuf::new());
        c.anthropic_key = "sk-test".into();
        c
    }

    fn walk<'a>(n: &'a Proto, out: &mut Vec<&'a Proto>) {
        out.push(n);
        match n.kind.as_ref() {
            Some(NodeKind::Column(b)) | Some(NodeKind::Row(b)) => {
                b.children.iter().for_each(|c| walk(c, out))
            }
            Some(NodeKind::Scroll(s)) => {
                if let Some(c) = &s.child {
                    walk(c, out);
                }
            }
            _ => {}
        }
    }

    fn all(view: &View) -> Vec<&Proto> {
        let mut out = Vec::new();
        walk(&view.root.0, &mut out);
        out
    }

    fn selects(nodes: &[&Proto]) -> Vec<(String, String)> {
        nodes
            .iter()
            .filter_map(|n| match n.kind.as_ref() {
                Some(NodeKind::Select(s)) => Some((s.action_id.clone(), s.selected.clone())),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn the_panel_has_every_selector_and_an_input() {
        let v = chat_view(&chat());
        let nodes = all(&v);
        assert_eq!(
            selects(&nodes),
            [
                ("preset".to_owned(), String::new()),
                ("provider".to_owned(), "anthropic".to_owned()),
                ("model".to_owned(), "claude-sonnet-5-5".to_owned()),
                ("effort".to_owned(), "medium".to_owned()),
                ("context".to_owned(), "32768".to_owned()),
            ]
        );
        let inputs: Vec<_> = nodes
            .iter()
            .filter_map(|n| match n.kind.as_ref() {
                Some(NodeKind::TextInput(t)) => Some(t),
                _ => None,
            })
            .collect();
        assert_eq!(inputs.len(), 1);
        assert_eq!(inputs[0].action_id, "send");
        assert!(!inputs[0].disabled);
        assert!(nodes.iter().any(
            |n| matches!(n.kind.as_ref(), Some(NodeKind::Scroll(s)) if s.expand && s.stick_to_end)
        ));
        assert_eq!(v.root.0.key, "root");
    }

    #[test]
    fn nothing_can_be_sent_without_a_key_or_while_answering() {
        let mut c = chat();
        c.anthropic_key.clear();
        let nodes_v = chat_view(&c);
        let input = |v: &View| {
            all(v)
                .into_iter()
                .find_map(|n| match n.kind.as_ref() {
                    Some(NodeKind::TextInput(t)) => Some(t.clone()),
                    _ => None,
                })
                .unwrap()
        };
        assert!(input(&nodes_v).disabled);

        let mut c = chat();
        c.busy = true;
        c.messages.push(Message::new(Kind::User, "hi"));
        c.messages.push(Message::new(Kind::Assistant, ""));
        let v = chat_view(&c);
        assert!(input(&v).disabled);
        // The stop button appears, and the answer in progress shows a spinner
        let nodes = all(&v);
        assert!(nodes.iter().any(
            |n| matches!(n.kind.as_ref(), Some(NodeKind::Button(b)) if b.action_id == "stop")
        ));
        assert!(nodes
            .iter()
            .any(|n| matches!(n.kind.as_ref(), Some(NodeKind::Spinner(_)))));
    }

    #[test]
    fn messages_keep_their_key_while_the_last_one_grows() {
        let mut c = chat();
        c.messages.push(Message::new(Kind::User, "hi"));
        c.messages.push(Message::new(Kind::Assistant, "He"));
        let keys = |v: &View| -> Vec<String> {
            all(v)
                .iter()
                .map(|n| n.key.clone())
                .filter(|k| {
                    k.strip_prefix('m')
                        .is_some_and(|n| !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()))
                })
                .collect()
        };
        let before = keys(&chat_view(&c));
        c.messages[1].text.push_str("llo");
        assert_eq!(before, keys(&chat_view(&c)));
        assert_eq!(before, ["m0", "m1"]);
    }

    #[test]
    fn thinking_can_be_shown() {
        let mut c = chat();
        c.messages.push(Message::new(Kind::User, "hi"));
        let mut a = Message::new(Kind::Assistant, "answer");
        a.thinking = "hmm".into();
        c.messages.push(a);

        let markdowns = |c: &Chat| {
            all(&chat_view(c))
                .iter()
                .filter(|n| matches!(n.kind.as_ref(), Some(NodeKind::Markdown(_))))
                .count()
        };
        assert_eq!(markdowns(&c), 1);
        c.messages[1].show_thinking = true;
        assert_eq!(markdowns(&c), 2);
    }

    #[test]
    fn naming_a_preset_swaps_the_row() {
        let mut c = chat();
        c.naming_preset = true;
        let v = chat_view(&c);
        let nodes = all(&v);
        assert!(nodes.iter().any(|n| matches!(n.kind.as_ref(), Some(NodeKind::TextInput(t)) if t.action_id == "preset_save")));
        assert!(!selects(&nodes).iter().any(|(a, _)| a == "preset"));
    }
}
