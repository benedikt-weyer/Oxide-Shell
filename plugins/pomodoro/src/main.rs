//! First-party pomodoro plugin for caelestia-shell: a focus/break timer on
//! the dashboard, configurable from Nexus.

mod timer;

use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::Duration;

use caelestia_plugin_sdk::settings::{Field, Section, SettingsSchema};
use caelestia_plugin_sdk::ui::{self, Align, ButtonStyle, Notification, TextStyle, Tone, Urgency};
use caelestia_plugin_sdk::{async_trait, Context, DashboardTab, Plugin, PluginInfo, Settings};
use timer::{format_mmss, Config, Phase, Timer};

const VIEW: &str = "timer";

struct Shared {
    timer: Timer,
    notify: bool,
}

struct Pomodoro {
    shared: Arc<Mutex<Shared>>,
    ctx: OnceLock<Context>,
}

impl Pomodoro {
    fn push(&self) {
        if let Some(ctx) = self.ctx.get() {
            ctx.push_view(render(&lock(&self.shared)));
        }
    }
}

fn lock(shared: &Mutex<Shared>) -> MutexGuard<'_, Shared> {
    // A poisoned lock only means a panic elsewhere; the timer state is still usable.
    shared.lock().unwrap_or_else(|e| e.into_inner())
}

fn config_from(settings: &Settings) -> Config {
    let d = Config::default();
    Config {
        focus_minutes: settings.u32("focus_minutes", d.focus_minutes),
        short_break_minutes: settings.u32("short_break_minutes", d.short_break_minutes),
        long_break_minutes: settings.u32("long_break_minutes", d.long_break_minutes),
        sessions_until_long_break: settings
            .u32("sessions_until_long_break", d.sessions_until_long_break),
        auto_start: settings.bool("auto_start", d.auto_start),
    }
}

fn tone(phase: Phase) -> Tone {
    match phase {
        Phase::Focus => Tone::Primary,
        Phase::ShortBreak => Tone::Secondary,
        Phase::LongBreak => Tone::Tertiary,
    }
}

fn render(s: &Shared) -> ui::View {
    let t = &s.timer;
    let (done, per_cycle) = t.cycle();

    let mut dots = ui::row().spacing(6.0);
    for i in 0..per_cycle {
        let filled = i < done;
        dots = dots.child(
            ui::icon(if filled {
                "circle"
            } else {
                "radio_button_unchecked"
            })
            .size(14.0)
            .tone(if filled { Tone::Primary } else { Tone::Muted }),
        );
    }

    let (toggle_label, toggle_icon) = if t.running() {
        ("Pause", "pause")
    } else if t.started() {
        ("Resume", "play_arrow")
    } else {
        ("Start", "play_arrow")
    };

    let controls = ui::row()
        .spacing(10.0)
        .child(
            ui::button("Reset")
                .icon("replay")
                .action("reset")
                .style(ButtonStyle::Tonal)
                .disabled(!t.started()),
        )
        .child(ui::button(toggle_label).icon(toggle_icon).action("toggle"))
        .child(
            ui::button("Skip")
                .icon("skip_next")
                .action("skip")
                .style(ButtonStyle::Tonal),
        );

    let root = ui::column()
        .spacing(16.0)
        .align(Align::Center)
        .child(
            ui::text(t.phase().label())
                .style(TextStyle::Title)
                .tone(tone(t.phase())),
        )
        .child(
            ui::progress_circular(t.fraction())
                .label(format_mmss(t.remaining()))
                .sublabel(if t.running() { "running" } else { "paused" })
                .tone(tone(t.phase()))
                .size(200.0),
        )
        .child(dots)
        .child(controls)
        .child(
            ui::text(format!(
                "{} focus session{} completed",
                t.total_focus(),
                if t.total_focus() == 1 { "" } else { "s" }
            ))
            .style(TextStyle::Label)
            .tone(Tone::Muted),
        );

    ui::View::new(VIEW, root)
}

#[async_trait]
impl Plugin for Pomodoro {
    fn info(&self) -> PluginInfo {
        PluginInfo::new(env!("CARGO_PKG_VERSION"))
            .dashboard_tab(DashboardTab::new(VIEW, "Pomodoro", "timer"))
            .settings(
                SettingsSchema::new()
                    .section(
                        Section::new("Durations")
                            .field(Field::number("focus_minutes", "Focus", 25.0, 1.0, 180.0).integer().unit("min"))
                            .field(
                                Field::number("short_break_minutes", "Short break", 5.0, 1.0, 60.0)
                                    .integer()
                                    .unit("min"),
                            )
                            .field(
                                Field::number("long_break_minutes", "Long break", 15.0, 1.0, 120.0)
                                    .integer()
                                    .unit("min"),
                            )
                            .field(
                                Field::number("sessions_until_long_break", "Sessions before long break", 4.0, 2.0, 12.0)
                                    .integer(),
                            ),
                    )
                    .section(
                        Section::new("Behaviour")
                            .field(
                                Field::toggle("auto_start", "Start next phase automatically", false)
                                    .description("Otherwise the timer waits for you after every focus session and break"),
                            )
                            .field(Field::toggle("notifications", "Notify when a phase ends", true)),
                    ),
            )
    }

    async fn start(&self, ctx: Context) {
        let _ = self.ctx.set(ctx.clone());
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let (finished, view, notify) = {
                    let mut s = lock(&shared);
                    if !s.timer.running() {
                        continue;
                    }
                    let finished = s.timer.tick();
                    (finished, render(&s), s.notify)
                };
                ctx.push_view(view);
                if let (Some(f), true) = (finished, notify) {
                    let (title, body, icon) = match f.finished {
                        Phase::Focus => (
                            "Focus session done",
                            format!("Time for a {}.", f.next.label().to_lowercase()),
                            "task_alt",
                        ),
                        _ => ("Break is over", "Back to focus.".to_string(), "timer"),
                    };
                    ctx.notify(
                        Notification::new(title, body)
                            .icon(icon)
                            .urgency(Urgency::Normal),
                    );
                }
            }
        });
    }

    async fn view(&self, view_id: &str) -> Option<ui::View> {
        (view_id == VIEW).then(|| render(&lock(&self.shared)))
    }

    async fn action(&self, _view_id: &str, action_id: &str, _payload: &str) -> Result<(), String> {
        {
            let mut s = lock(&self.shared);
            match action_id {
                "toggle" => s.timer.toggle(),
                "reset" => s.timer.reset(),
                "skip" => s.timer.skip(),
                other => return Err(format!("unknown action '{other}'")),
            }
        }
        self.push();
        Ok(())
    }

    async fn settings_changed(&self, settings: &Settings) {
        {
            let mut s = lock(&self.shared);
            s.timer.config = config_from(settings);
            s.notify = settings.bool("notifications", true);
        }
        self.push();
    }
}

fn main() {
    caelestia_plugin_sdk::main(Pomodoro {
        shared: Arc::new(Mutex::new(Shared {
            timer: Timer::new(Config::default()),
            notify: true,
        })),
        ctx: OnceLock::new(),
    });
}
