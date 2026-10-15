//! The plugin's model: what the daemon last reported, plus the little UI
//! state (console expanded, error copied) that only lives here.

use std::collections::VecDeque;

use crate::backend::pb;

/// Lines kept for the console, so long builds can't grow without bound.
const MAX_LOG_LINES: usize = 500;

/// `EventPhase` ordinals the UI cares about, see `nix_backend.proto`.
pub const PHASE_FAILED: i32 = pb::EventPhase::Failed as i32;

pub fn phase_label(phase: i32) -> &'static str {
    match pb::EventPhase::try_from(phase) {
        Ok(pb::EventPhase::Started) => "Starting",
        Ok(pb::EventPhase::FlakeUpdate) => "Updating flake",
        Ok(pb::EventPhase::Build) => "Building",
        Ok(pb::EventPhase::Diff) => "Diffing closures",
        Ok(pb::EventPhase::Register) => "Registering generation",
        Ok(pb::EventPhase::Activate) => "Activating",
        Ok(pb::EventPhase::Finished) => "Finished",
        Ok(pb::EventPhase::Failed) => "Failed",
        _ => "Idle",
    }
}

#[derive(Debug)]
pub struct State {
    pub running: bool,
    pub phase: i32,
    /// 0..1, or negative while unknown.
    pub fraction: f64,
    pub status: String,
    pub last_error: String,
    pub items: Vec<pb::BuildItem>,
    pub stats: pb::BuildStats,
    pub flake: Option<pb::FlakeStatusReply>,
    pub log: VecDeque<(String, bool)>,
    pub console_expanded: bool,
    pub copied: bool,
}

impl Default for State {
    fn default() -> Self {
        Self {
            running: false,
            phase: 0,
            fraction: -1.0,
            status: String::new(),
            last_error: String::new(),
            items: Vec::new(),
            stats: pb::BuildStats::default(),
            flake: None,
            log: VecDeque::new(),
            console_expanded: false,
            copied: false,
        }
    }
}

impl State {
    pub fn failed(&self) -> bool {
        !self.running && self.phase == PHASE_FAILED
    }

    /// Resets everything an operation reports, for a fresh run.
    pub fn begin(&mut self) {
        self.running = true;
        self.phase = 0;
        self.fraction = -1.0;
        self.status.clear();
        self.last_error.clear();
        self.items.clear();
        self.stats = pb::BuildStats::default();
        self.log.clear();
        self.copied = false;
    }

    pub fn push_log(&mut self, line: String, is_error: bool) {
        self.log.push_back((line, is_error));
        while self.log.len() > MAX_LOG_LINES {
            self.log.pop_front();
        }
    }

    pub fn apply(&mut self, event: pb::ProgressEvent) {
        self.phase = event.phase;
        if event.fraction_done >= 0.0 {
            self.fraction = event.fraction_done;
        }
        if !event.message.is_empty() {
            self.status = event.message.clone();
            self.push_log(event.message.clone(), event.is_error);
        }
        if event.is_error {
            self.last_error = event.message;
        }
        self.items = event.active_items;
        self.stats = event.stats.unwrap_or_default();
    }

    /// The stream ended; `error` is the RPC-level failure, if any.
    pub fn finish(&mut self, error: Option<String>) {
        if let Some(error) = error.filter(|e| !e.is_empty()) {
            self.last_error = error.clone();
            self.push_log(error, true);
        }
        self.running = false;
        self.items.clear();
        self.stats = pb::BuildStats::default();
    }

    /// Plain-text report for pasting into an issue or chat: the status
    /// message, the RPC error (if distinct), then every error line of the log.
    pub fn error_text(&self) -> String {
        let mut parts: Vec<&str> = Vec::new();
        if !self.status.is_empty() {
            parts.push(&self.status);
        }
        if !self.last_error.is_empty() && self.last_error != self.status {
            parts.push(&self.last_error);
        }
        for (line, _) in self.log.iter().filter(|l| l.1) {
            if !parts.contains(&line.as_str()) {
                parts.push(line);
            }
        }
        parts.join("\n")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(
        phase: pb::EventPhase,
        message: &str,
        is_error: bool,
        fraction: f64,
    ) -> pb::ProgressEvent {
        pb::ProgressEvent {
            phase: phase as i32,
            message: message.into(),
            is_error,
            fraction_done: fraction,
            ..Default::default()
        }
    }

    #[test]
    fn events_update_status_and_log() {
        let mut s = State::default();
        s.begin();
        s.apply(event(pb::EventPhase::Build, "building foo", false, 0.5));
        assert_eq!(s.phase, pb::EventPhase::Build as i32);
        assert_eq!(s.status, "building foo");
        assert_eq!(s.fraction, 0.5);
        assert_eq!(s.log.len(), 1);
        // Unknown progress keeps the last known fraction.
        s.apply(event(pb::EventPhase::Build, "", false, -1.0));
        assert_eq!(s.fraction, 0.5);
        assert_eq!(s.log.len(), 1);
    }

    #[test]
    fn failure_is_reported_once_finished() {
        let mut s = State::default();
        s.begin();
        s.apply(event(pb::EventPhase::Failed, "boom", true, -1.0));
        assert!(!s.failed(), "still running until the stream ends");
        s.finish(None);
        assert!(s.failed());
        assert_eq!(s.error_text(), "boom");
    }

    #[test]
    fn rpc_error_is_logged_and_distinct_in_report() {
        let mut s = State::default();
        s.begin();
        s.apply(event(pb::EventPhase::Build, "building", false, -1.0));
        s.finish(Some("unavailable".into()));
        assert_eq!(s.error_text(), "building\nunavailable");
    }

    #[test]
    fn log_is_bounded() {
        let mut s = State::default();
        for i in 0..MAX_LOG_LINES + 10 {
            s.push_log(i.to_string(), false);
        }
        assert_eq!(s.log.len(), MAX_LOG_LINES);
        assert_eq!(s.log.front().unwrap().0, "10");
    }
}
