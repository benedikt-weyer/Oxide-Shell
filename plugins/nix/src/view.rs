//! Renders [`State`] as the dashboard tab: header, actions, status, live
//! activity and the collapsible console.

use caelestia_plugin_sdk::ui::{
    self, Align, ButtonStyle, Container, Elide, Surface, TextStyle, Tone,
};

use crate::backend::pb;
use crate::state::{phase_label, State};
use crate::VIEW;

const CARD_PADDING: f64 = 12.0;
const MAX_ITEMS: usize = 8;
const CONSOLE_HEIGHT: f64 = 260.0;

pub fn format_bytes(bytes: f64) -> String {
    if bytes.is_nan() || bytes <= 0.0 {
        return "0 B".into();
    }
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let (mut v, mut i) = (bytes, 0);
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    let decimals = if v < 10.0 && i > 0 { 1 } else { 0 };
    format!("{v:.decimals$} {}", UNITS[i])
}

/// "2026-10-15T13:45:00+02:00" -> "2026-10-15 13:45" (the commit's own local time).
fn short_time(iso: &str) -> String {
    match iso.get(..16) {
        Some(head) if iso.as_bytes().get(10) == Some(&b'T') => head.replacen('T', " ", 1),
        _ => iso.to_string(),
    }
}

fn last_updated(s: &State) -> String {
    match &s.flake {
        None => "Checking flake…".into(),
        Some(f) if !f.has_git_history => "No git history found for this flake".into(),
        Some(f) if f.last_modified_iso8601.is_empty() => "Last updated: unknown".into(),
        Some(f) => format!("Last updated {}", short_time(&f.last_modified_iso8601)),
    }
}

fn header(s: &State) -> Container {
    ui::row()
        .fill()
        .spacing(12.0)
        .align(Align::Center)
        .child(
            ui::column()
                .spacing(4.0)
                .child(ui::text("System flake").style(TextStyle::Headline))
                .child(
                    ui::text(last_updated(s))
                        .style(TextStyle::Label)
                        .tone(Tone::Muted),
                ),
        )
        .child(ui::spacer(0.0))
        .child(
            ui::button("")
                .icon("refresh")
                .action("refresh")
                .style(ButtonStyle::Text),
        )
}

fn actions(s: &State) -> Container {
    let button = |label: &str, icon: &str, action: &str| {
        ui::button(label)
            .icon(icon)
            .action(action)
            .style(ButtonStyle::Tonal)
            .disabled(s.running)
            .fill()
    };
    ui::row()
        .fill()
        .spacing(12.0)
        .child(button("Update flake", "cloud_download", "update"))
        .child(button("Rebuild: switch", "sync", "rebuild_switch"))
        .child(button("Rebuild: boot", "restart_alt", "rebuild_boot"))
}

fn status(s: &State) -> Container {
    let failed = s.failed();
    let label = phase_label(s.phase);
    let text = if s.status.is_empty() {
        label.to_string()
    } else {
        format!("{label}: {}", s.status)
    };
    let tone = if failed { Tone::Error } else { Tone::Default };

    let mut line = ui::row().fill().spacing(8.0).align(Align::Center);
    line = if s.running {
        line.child(ui::spinner().size(20.0))
    } else {
        line.child(
            ui::icon(if failed { "error" } else { "check_circle" })
                .size(24.0)
                .tone(if failed { Tone::Error } else { Tone::Primary }),
        )
    };
    line = line.child(ui::text(text).tone(tone).fill(Elide::Right));
    if failed {
        line = line.child(
            ui::button("")
                .icon(if s.copied {
                    "inventory"
                } else {
                    "content_copy"
                })
                .action("copy_error")
                .style(ButtonStyle::Text),
        );
    }

    let bar = if s.running && s.fraction < 0.0 {
        ui::progress_linear(0.0).indeterminate(true)
    } else {
        ui::progress_linear(s.fraction.max(0.0))
    }
    .tone(if failed { Tone::Error } else { Tone::Primary })
    .fill();

    ui::column()
        .fill()
        .surface(Surface::Card)
        .padding(CARD_PADDING)
        .spacing(8.0)
        .child(line)
        .child(bar)
}

fn has_activity(s: &State) -> bool {
    s.running && (!s.items.is_empty() || s.stats.builds_expected > 0 || s.stats.copies_expected > 0)
}

fn item_row(item: &pb::BuildItem) -> Container {
    let download = item.kind == pb::BuildItemKind::BuildItemDownload as i32;
    let done = item.status == pb::BuildItemStatus::BuildItemDone as i32;
    let running = item.status == pb::BuildItemStatus::BuildItemRunning as i32;
    let name = if item.name.is_empty() {
        "(unknown)"
    } else {
        &item.name
    };

    let mut row = ui::row()
        .fill()
        .spacing(8.0)
        .align(Align::Center)
        .child(
            ui::icon(if download { "download" } else { "build" })
                .size(18.0)
                .tone(if done { Tone::Primary } else { Tone::Muted }),
        )
        .child(
            ui::text(name)
                .style(TextStyle::Mono)
                .tone(if done { Tone::Muted } else { Tone::Default })
                .fill(Elide::Middle),
        );
    if download && item.bytes_expected > 0.0 {
        row = row.child(
            ui::text(format!(
                "{} / {}",
                format_bytes(item.bytes_done),
                format_bytes(item.bytes_expected)
            ))
            .style(TextStyle::Mono)
            .tone(Tone::Muted),
        );
    }
    if done {
        row = row.child(ui::icon("check").size(18.0).tone(Tone::Primary));
    } else if running {
        row = row.child(ui::spinner().size(14.0));
    }
    row
}

fn activity(s: &State) -> Container {
    let st = &s.stats;
    let mut summary = ui::row().fill().spacing(12.0);

    if st.builds_expected > 0 {
        let text = if st.builds_running > 0 {
            format!(
                "Building {}/{} ({} running)",
                st.builds_done, st.builds_expected, st.builds_running
            )
        } else {
            format!("Built {}/{}", st.builds_done, st.builds_expected)
        };
        summary = summary.child(ui::text(text).style(TextStyle::Label).tone(Tone::Muted));
    }
    if st.copies_expected > 0 {
        let bytes = if st.download_bytes_expected > 0 {
            format!(
                " ({}/{})",
                format_bytes(st.download_bytes_done as f64),
                format_bytes(st.download_bytes_expected as f64)
            )
        } else {
            String::new()
        };
        summary = summary.child(
            ui::text(format!(
                "Downloading {}/{}{bytes}",
                st.copies_done, st.copies_expected
            ))
            .style(TextStyle::Label)
            .tone(Tone::Muted),
        );
    }

    let rate: f64 = s
        .items
        .iter()
        .filter(|i| {
            i.kind == pb::BuildItemKind::BuildItemDownload as i32
                && i.status == pb::BuildItemStatus::BuildItemRunning as i32
        })
        .map(|i| i.bytes_per_sec)
        .sum();
    summary = summary.child(ui::spacer(0.0));
    if rate > 0.0 {
        summary = summary.child(
            ui::text(format!("{}/s", format_bytes(rate)))
                .style(TextStyle::Label)
                .tone(Tone::Muted),
        );
    }

    ui::column()
        .fill()
        .surface(Surface::Card)
        .padding(CARD_PADDING)
        .spacing(4.0)
        .child(summary)
        .children(s.items.iter().take(MAX_ITEMS).map(item_row))
}

fn console(s: &State) -> Container {
    let header = ui::row()
        .fill()
        .align(Align::Center)
        .child(
            ui::button("Console output")
                .icon(if s.console_expanded {
                    "expand_less"
                } else {
                    "expand_more"
                })
                .action("toggle_console")
                .style(ButtonStyle::Text),
        )
        .child(ui::spacer(0.0));
    let header = if s.log.is_empty() {
        header
    } else {
        header.child(
            ui::text(s.log.len().to_string())
                .style(TextStyle::Label)
                .tone(Tone::Muted),
        )
    };

    let mut card = ui::column()
        .fill()
        .surface(Surface::CardLow)
        .padding(CARD_PADDING)
        .spacing(8.0)
        .child(header);
    if s.console_expanded {
        let log = s
            .log
            .iter()
            .fold(ui::log_view(), |log, (line, is_error)| {
                log.line(line.clone(), *is_error)
            })
            .height(CONSOLE_HEIGHT)
            .placeholder("Output from an update or rebuild appears here");
        card = card.child(log);
    }
    card
}

pub fn render(s: &State) -> ui::View {
    let mut root = ui::column()
        .fill()
        .spacing(12.0)
        .child(header(s))
        .child(actions(s))
        .child(status(s));
    if has_activity(s) {
        root = root.child(activity(s));
    }
    root = root.child(console(s));
    ui::View::new(VIEW, root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_are_humanised() {
        assert_eq!(format_bytes(0.0), "0 B");
        assert_eq!(format_bytes(512.0), "512 B");
        assert_eq!(format_bytes(1536.0), "1.5 KB");
        assert_eq!(format_bytes(15.0 * 1024.0 * 1024.0), "15 MB");
    }

    #[test]
    fn times_are_shortened() {
        assert_eq!(short_time("2026-10-15T13:45:00+02:00"), "2026-10-15 13:45");
        assert_eq!(short_time("yesterday"), "yesterday");
    }

    #[test]
    fn idle_and_running_states_render() {
        let mut s = State::default();
        let _ = render(&s);
        s.begin();
        s.items.push(pb::BuildItem::default());
        assert!(has_activity(&s));
        let _ = render(&s);
    }
}
