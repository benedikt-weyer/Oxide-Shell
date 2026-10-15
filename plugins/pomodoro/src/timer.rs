//! The pomodoro state machine. Pure and clock-free: the caller feeds it one
//! `tick` per second while the timer runs.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Focus,
    ShortBreak,
    LongBreak,
}

impl Phase {
    pub fn label(self) -> &'static str {
        match self {
            Phase::Focus => "Focus",
            Phase::ShortBreak => "Short break",
            Phase::LongBreak => "Long break",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Config {
    pub focus_minutes: u32,
    pub short_break_minutes: u32,
    pub long_break_minutes: u32,
    pub sessions_until_long_break: u32,
    pub auto_start: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            focus_minutes: 25,
            short_break_minutes: 5,
            long_break_minutes: 15,
            sessions_until_long_break: 4,
            auto_start: false,
        }
    }
}

/// A phase ran out. Carries what to tell the user.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Finished {
    pub finished: Phase,
    pub next: Phase,
}

#[derive(Clone, Debug)]
pub struct Timer {
    pub config: Config,
    phase: Phase,
    // Elapsed rather than remaining, so changing a duration in the settings
    // mid-phase just moves the end instead of needing a fix-up.
    elapsed: u32,
    running: bool,
    // Focus sessions finished in the current long-break cycle.
    cycle: u32,
    total_focus: u32,
}

impl Timer {
    pub fn new(config: Config) -> Self {
        Self {
            config,
            phase: Phase::Focus,
            elapsed: 0,
            running: false,
            cycle: 0,
            total_focus: 0,
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn running(&self) -> bool {
        self.running
    }

    pub fn started(&self) -> bool {
        self.elapsed > 0
    }

    /// Focus sessions finished since the plugin started.
    pub fn total_focus(&self) -> u32 {
        self.total_focus
    }

    /// Focus sessions finished in this cycle, and how many make a cycle.
    pub fn cycle(&self) -> (u32, u32) {
        (self.cycle, self.config.sessions_until_long_break.max(1))
    }

    pub fn duration(&self) -> u32 {
        let minutes = match self.phase {
            Phase::Focus => self.config.focus_minutes,
            Phase::ShortBreak => self.config.short_break_minutes,
            Phase::LongBreak => self.config.long_break_minutes,
        };
        minutes.max(1).saturating_mul(60)
    }

    pub fn remaining(&self) -> u32 {
        self.duration().saturating_sub(self.elapsed)
    }

    pub fn fraction(&self) -> f64 {
        f64::from(self.elapsed.min(self.duration())) / f64::from(self.duration())
    }

    pub fn toggle(&mut self) {
        self.running = !self.running;
    }

    /// Back to the start of the current phase, paused.
    pub fn reset(&mut self) {
        self.elapsed = 0;
        self.running = false;
    }

    /// Jumps to the next phase without counting a skipped focus session.
    /// Keeps running if it was running.
    pub fn skip(&mut self) {
        self.phase = self.next_phase(false);
        self.elapsed = 0;
    }

    /// Advances one second. Returns `Some` when the phase just ended.
    pub fn tick(&mut self) -> Option<Finished> {
        if !self.running {
            return None;
        }
        self.elapsed += 1;
        if self.elapsed < self.duration() {
            return None;
        }

        let finished = self.phase;
        if finished == Phase::Focus {
            self.total_focus += 1;
            self.cycle += 1;
        }
        let next = self.next_phase(true);
        if next == Phase::LongBreak {
            self.cycle = 0;
        }
        self.phase = next;
        self.elapsed = 0;
        self.running = self.config.auto_start;
        Some(Finished { finished, next })
    }

    // `completed` says the focus phase that is ending was finished (and
    // already counted in `cycle`) rather than skipped.
    fn next_phase(&self, completed: bool) -> Phase {
        match self.phase {
            Phase::ShortBreak | Phase::LongBreak => Phase::Focus,
            Phase::Focus => {
                let done = self.cycle + u32::from(!completed);
                if done >= self.config.sessions_until_long_break.max(1) && completed {
                    Phase::LongBreak
                } else {
                    Phase::ShortBreak
                }
            }
        }
    }
}

pub fn format_mmss(secs: u32) -> String {
    format!("{:02}:{:02}", secs / 60, secs % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tiny() -> Timer {
        Timer::new(Config {
            focus_minutes: 1,
            short_break_minutes: 1,
            long_break_minutes: 2,
            sessions_until_long_break: 2,
            auto_start: false,
        })
    }

    fn run_out(t: &mut Timer) -> Finished {
        t.toggle();
        loop {
            if let Some(f) = t.tick() {
                return f;
            }
        }
    }

    #[test]
    fn idle_timer_does_not_tick() {
        let mut t = tiny();
        assert_eq!(t.tick(), None);
        assert_eq!(t.remaining(), 60);
        assert!(!t.started());
    }

    #[test]
    fn counts_down_and_formats() {
        let mut t = tiny();
        t.toggle();
        for _ in 0..5 {
            t.tick();
        }
        assert_eq!(format_mmss(t.remaining()), "00:55");
        assert!(t.started());
    }

    #[test]
    fn long_break_after_configured_sessions() {
        let mut t = tiny();
        assert_eq!(
            run_out(&mut t),
            Finished {
                finished: Phase::Focus,
                next: Phase::ShortBreak
            }
        );
        assert_eq!(
            run_out(&mut t),
            Finished {
                finished: Phase::ShortBreak,
                next: Phase::Focus
            }
        );
        assert_eq!(
            run_out(&mut t),
            Finished {
                finished: Phase::Focus,
                next: Phase::LongBreak
            }
        );
        assert_eq!(t.cycle().0, 0);
        assert_eq!(t.total_focus(), 2);
        assert_eq!(t.duration(), 120);
        assert_eq!(
            run_out(&mut t),
            Finished {
                finished: Phase::LongBreak,
                next: Phase::Focus
            }
        );
    }

    #[test]
    fn finished_phase_pauses_unless_auto_start() {
        let mut t = tiny();
        run_out(&mut t);
        assert!(!t.running());
        t.config.auto_start = true;
        t.toggle();
        for _ in 0..60 {
            t.tick();
        }
        assert!(t.running(), "auto_start keeps the next phase running");
        assert_eq!(t.phase(), Phase::Focus);
    }

    #[test]
    fn skip_does_not_count_a_session() {
        let mut t = tiny();
        t.skip();
        assert_eq!(t.phase(), Phase::ShortBreak);
        assert_eq!(t.total_focus(), 0);
        assert_eq!(t.cycle().0, 0);
    }

    #[test]
    fn skip_keeps_running_state() {
        let mut t = tiny();
        t.toggle();
        t.skip();
        assert!(t.running());
    }

    #[test]
    fn reset_rewinds_and_pauses() {
        let mut t = tiny();
        t.toggle();
        t.tick();
        t.reset();
        assert!(!t.running() && !t.started());
        assert_eq!(t.remaining(), 60);
    }

    #[test]
    fn shortening_the_phase_below_elapsed_ends_it_cleanly() {
        let mut t = Timer::new(Config {
            focus_minutes: 5,
            ..Config::default()
        });
        t.toggle();
        for _ in 0..90 {
            t.tick();
        }
        t.config.focus_minutes = 1;
        assert_eq!(t.remaining(), 0);
        assert!(t.tick().is_some());
    }
}
