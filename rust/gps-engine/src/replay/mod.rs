// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Deterministic replay of a recorded GPS trace.
//!
//! A [`ReplaySession`] owns replay time and the derived engine state while
//! Flutter owns presentation and user interaction (the clock/ticker, map,
//! controls). [`ReplaySession::advance`] takes an explicit real-time delta;
//! Rust never spawns timers.
//!
//! Raw fixes are fed through a [`LiveRecorder`] as replay time progresses, so
//! distance, pace, moving time and (when a route is supplied) continuity-aware
//! route progress/match state are produced by the same engine used for live
//! recording. Seeking resets and replays from the start, keeping behavior
//! deterministic.

use crate::geo::Coordinate;
use crate::gps::GpsFix;
use crate::live::{
    LiveConfig, LiveGhost, LiveGhostSnapshot, LiveMatchStatus, LiveRecorder, LiveSnapshot,
};
use crate::route::Route;
use crate::units::{Distance, Duration, Speed, Timestamp};

/// Playback state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplayState {
    /// Advancing with the clock.
    Playing,
    /// Frozen at the current elapsed time.
    Paused,
    /// Reached the end of the trace.
    Finished,
}

/// Point-in-time replay state consumed by the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplaySnapshot {
    /// Replay elapsed time from the first fix.
    pub elapsed: Duration,
    /// Total replayable duration of the trace.
    pub total: Duration,
    /// Playback state after this step.
    pub state: ReplayState,
    /// Playback speed multiplier.
    pub speed: f64,
    /// Number of fixes applied up to `elapsed`.
    pub applied_fixes: usize,
    /// Total fixes in the trace.
    pub total_fixes: usize,
    /// Latest applied position, if any.
    pub position: Option<Coordinate>,
    /// Last fix accuracy, if reported.
    pub accuracy: Option<Distance>,
    /// Engine distance (route coverage or filtered geodesic).
    pub distance: Distance,
    /// Engine moving time.
    pub moving: Duration,
    /// Current pace.
    pub pace: Speed,
    /// Route progress `0.0..=1.0` (0 when free-running).
    pub route_progress: f64,
    /// Lateral distance from the route, when off-route.
    pub off_route: Option<Distance>,
    /// Route-matching status.
    pub match_status: LiveMatchStatus,
    /// Route-matching confidence `0.0..=1.0`.
    pub match_confidence: f64,
    /// Ghost comparison at the current replay progress, if a ghost is set.
    pub ghost: Option<LiveGhostSnapshot>,
}

impl ReplaySnapshot {
    /// `true` when replay has reached the end of the trace.
    pub fn finished(&self) -> bool {
        self.state == ReplayState::Finished
    }
}

/// A deterministic replay session over recorded GPS fixes.
#[derive(Debug, Clone)]
pub struct ReplaySession {
    fixes: Vec<GpsFix>,
    route: Option<Route>,
    ghost: Option<LiveGhost>,
    config: LiveConfig,
    t0: Option<Timestamp>,
    total: Duration,
    elapsed: Duration,
    speed: f64,
    state: ReplayState,
    /// Index of the next fix not yet applied.
    cursor: usize,
    recorder: LiveRecorder,
}

impl ReplaySession {
    /// Creates a session over `fixes`. Fixes are sorted by timestamp and exact
    /// timestamp duplicates dropped so replay is stable regardless of input
    /// order.
    pub fn new(fixes: Vec<GpsFix>, route: Option<Route>) -> Self {
        Self::with_ghost(fixes, route, None)
    }

    /// Creates a session with an optional ghost (reference attempt samples).
    pub fn with_ghost(fixes: Vec<GpsFix>, route: Option<Route>, ghost: Option<LiveGhost>) -> Self {
        Self::with_config(fixes, route, ghost, LiveConfig::default())
    }

    /// Creates a session with an explicit live/engine configuration.
    pub fn with_config(
        mut fixes: Vec<GpsFix>,
        route: Option<Route>,
        ghost: Option<LiveGhost>,
        config: LiveConfig,
    ) -> Self {
        fixes.sort_by(|a, b| {
            a.timestamp
                .unix_secs()
                .partial_cmp(&b.timestamp.unix_secs())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        fixes.dedup_by(|a, b| (a.timestamp.unix_secs() - b.timestamp.unix_secs()).abs() < 1e-9);

        let t0 = fixes.first().map(|f| f.timestamp);
        let total = match (fixes.first(), fixes.last()) {
            (Some(a), Some(b)) => {
                let s = b.timestamp.elapsed_since(a.timestamp).as_secs();
                Duration::from_secs(if s.is_finite() && s > 0.0 { s } else { 0.0 })
            }
            _ => Duration::ZERO,
        };

        let mut recorder = LiveRecorder::new(config.clone(), route.clone());
        recorder.set_ghost(ghost.clone());
        ReplaySession {
            fixes,
            route,
            ghost,
            config,
            t0,
            total,
            elapsed: Duration::ZERO,
            speed: 1.0,
            state: ReplayState::Paused,
            cursor: 0,
            recorder,
        }
    }

    /// Total duration of the trace.
    pub fn duration(&self) -> Duration {
        self.total
    }

    /// Current replay state.
    pub fn state(&self) -> ReplayState {
        self.state
    }

    /// Current elapsed time.
    pub fn elapsed(&self) -> Duration {
        self.elapsed
    }

    /// Starts or resumes playback.
    pub fn play(&mut self) {
        if self.fixes.is_empty() {
            self.state = ReplayState::Finished;
            return;
        }
        if self.state == ReplayState::Finished {
            // Restart from the end means replay from beginning.
            self.seek(Duration::ZERO);
        }
        self.state = ReplayState::Playing;
    }

    /// Pauses playback.
    pub fn pause(&mut self) {
        if self.state == ReplayState::Playing {
            self.state = ReplayState::Paused;
        }
    }

    /// Sets the playback speed multiplier (clamped to a sane range).
    pub fn set_speed(&mut self, speed: f64) {
        if speed.is_finite() && speed > 0.0 {
            self.speed = speed.clamp(0.1, 32.0);
        }
    }

    /// Seeks to `elapsed` from the start of the trace, resetting engine state
    /// and replaying all fixes up to that point.
    pub fn seek(&mut self, elapsed: Duration) {
        let target = elapsed.as_secs();
        let clamped = if target.is_finite() {
            target.clamp(0.0, self.total.as_secs())
        } else {
            0.0
        };
        self.elapsed = Duration::from_secs(clamped);
        self.rebuild_to(self.elapsed);
        if self.elapsed.as_secs() >= self.total.as_secs() - 1e-9 && !self.fixes.is_empty() {
            self.state = ReplayState::Finished;
        } else if self.state == ReplayState::Finished {
            self.state = ReplayState::Paused;
        }
    }

    /// Advances playback by `delta` of real time (scaled by the current speed)
    /// and returns the resulting snapshot. When paused or finished, `delta` is
    /// ignored and the current snapshot is returned.
    pub fn advance(&mut self, delta: Duration) -> ReplaySnapshot {
        if self.state == ReplayState::Playing {
            let step = delta.as_secs() * self.speed;
            if step.is_finite() && step > 0.0 {
                let next = (self.elapsed.as_secs() + step).min(self.total.as_secs());
                self.elapsed = Duration::from_secs(next);
                self.apply_up_to(self.elapsed);
                if self.elapsed.as_secs() >= self.total.as_secs() - 1e-9 {
                    self.elapsed = self.total;
                    self.state = ReplayState::Finished;
                }
            }
        }
        self.snapshot()
    }

    /// Returns the current snapshot without advancing time.
    pub fn snapshot(&self) -> ReplaySnapshot {
        let live: LiveSnapshot = self.recorder.snapshot();
        let ghost = self.recorder.ghost_snapshot();
        let position = live.position.or_else(|| {
            self.fixes
                .get(self.cursor.saturating_sub(1))
                .map(|f| f.coordinate)
        });
        ReplaySnapshot {
            elapsed: self.elapsed,
            total: self.total,
            state: self.state,
            speed: self.speed,
            applied_fixes: self.cursor,
            total_fixes: self.fixes.len(),
            position,
            accuracy: live.accuracy,
            distance: live.distance,
            moving: live.moving,
            pace: live.pace,
            route_progress: live.route_progress,
            off_route: live.off_route,
            match_status: live.match_status,
            match_confidence: live.match_confidence,
            ghost,
        }
    }

    fn rebuild_to(&mut self, elapsed: Duration) {
        self.recorder = LiveRecorder::new(self.config.clone(), self.route.clone());
        self.recorder.set_ghost(self.ghost.clone());
        self.cursor = 0;
        self.apply_up_to(elapsed);
    }

    fn apply_up_to(&mut self, elapsed: Duration) {
        let Some(t0) = self.t0 else {
            return;
        };
        let target = elapsed.as_secs();
        while self.cursor < self.fixes.len() {
            let fix = self.fixes[self.cursor];
            let at = fix.timestamp.elapsed_since(t0).as_secs();
            if at > target + 1e-9 {
                break;
            }
            self.recorder.push(fix);
            self.cursor += 1;
        }
        if self.state == ReplayState::Finished
            || self.elapsed.as_secs() >= self.total.as_secs() - 1e-9
        {
            self.recorder.finish();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::Coordinate;

    fn coord(lat: f64, lon: f64) -> Coordinate {
        Coordinate::new(lat, lon).unwrap()
    }

    fn fix(lat: f64, lon: f64, second: i64) -> GpsFix {
        GpsFix::new(Timestamp::from_unix_secs(second as f64), coord(lat, lon))
    }

    fn straight_fixes() -> Vec<GpsFix> {
        vec![
            fix(52.50000, 13.40000, 0),
            fix(52.50050, 13.40000, 10),
            fix(52.50100, 13.40000, 20),
            fix(52.50150, 13.40000, 30),
            fix(52.50200, 13.40000, 40),
        ]
    }

    #[test]
    fn empty_trace_is_finished_and_stable() {
        let mut s = ReplaySession::new(vec![], None);
        s.play();
        let snap = s.advance(Duration::from_secs(1.0));
        assert_eq!(snap.state, ReplayState::Finished);
        assert_eq!(snap.total_fixes, 0);
        assert_eq!(snap.distance.meters(), 0.0);
    }

    #[test]
    fn advance_applies_fixes_in_time_order() {
        let mut s = ReplaySession::new(straight_fixes(), None);
        assert_eq!(s.state(), ReplayState::Paused);
        s.play();
        let snap = s.advance(Duration::from_secs(15.0));
        assert_eq!(snap.state, ReplayState::Playing);
        assert_eq!(snap.applied_fixes, 2); // t=0, t=10
        assert!(snap.distance.meters() > 40.0);
    }

    #[test]
    fn pause_freezes_progress() {
        let mut s = ReplaySession::new(straight_fixes(), None);
        s.play();
        let a = s.advance(Duration::from_secs(15.0));
        s.pause();
        let b = s.advance(Duration::from_secs(100.0));
        assert_eq!(b.state, ReplayState::Paused);
        assert_eq!(b.applied_fixes, a.applied_fixes);
        assert!((b.elapsed.as_secs() - a.elapsed.as_secs()).abs() < 1e-9);
    }

    #[test]
    fn seek_rebuilds_state_deterministically() {
        let mut s = ReplaySession::new(straight_fixes(), None);
        s.play();
        let end = s.advance(Duration::from_secs(40.0));
        assert!(end.finished());

        s.seek(Duration::from_secs(10.0));
        let mid = s.snapshot();
        assert_eq!(mid.state, ReplayState::Paused);
        assert_eq!(mid.applied_fixes, 2); // t=0, t=10

        // Seeking to the same point again yields the same snapshot.
        s.seek(Duration::from_secs(10.0));
        let mid2 = s.snapshot();
        assert_eq!(mid.applied_fixes, mid2.applied_fixes);
        assert!((mid.distance.meters() - mid2.distance.meters()).abs() < 1e-9);
    }

    #[test]
    fn speed_multiplier_scales_elapsed() {
        let mut s = ReplaySession::new(straight_fixes(), None);
        s.play();
        s.set_speed(2.0);
        let snap = s.advance(Duration::from_secs(5.0)); // 10s of replay time
        assert_eq!(snap.applied_fixes, 2); // t=0, t=10
        assert!((snap.elapsed.as_secs() - 10.0).abs() < 1e-9);
    }

    #[test]
    fn route_replay_reports_route_progress() {
        let route = Route::new(vec![coord(52.50000, 13.40000), coord(52.50300, 13.40000)]).unwrap();
        let mut s = ReplaySession::new(straight_fixes(), Some(route));
        s.play();
        let snap = s.advance(Duration::from_secs(40.0));
        assert!(snap.route_progress > 0.5);
        assert!(snap.distance.meters() > 150.0);
    }

    #[test]
    fn sorts_and_dedupes_input_fixes() {
        let fixes = vec![
            fix(52.50100, 13.40000, 20),
            fix(52.50000, 13.40000, 0),
            fix(52.50000, 13.40000, 0), // duplicate
            fix(52.50050, 13.40000, 10),
        ];
        let s = ReplaySession::new(fixes, None);
        assert_eq!(s.duration().as_secs(), 20.0);
        assert_eq!(s.snapshot().total_fixes, 3);
    }
}
