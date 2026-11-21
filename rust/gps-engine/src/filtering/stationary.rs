// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Stationary detection with hysteresis.
//!
//! A phone sitting on a table still reports metres of correction jitter. The
//! detector therefore looks at net displacement from a candidate anchor over
//! several fixes, not at a single instantaneous speed. Once stationary is
//! confirmed, two consecutive fixes outside the exit radius are required to
//! resume, so a lone spike does not restart the distance axis.

use crate::estimate::{Confidence, MotionState};

/// Stateful stationary classifier in local tangent-plane coordinates.
#[derive(Debug, Clone, PartialEq)]
pub struct StationaryDetector {
    enter_count: u32,
    exit_meters: f64,
    motion_speed_mps: f64,
    candidate_start: Option<(f64, f64)>,
    candidate_count: u32,
    confirmed: bool,
    anchor: Option<(f64, f64)>,
    outside_count: u32,
}

impl StationaryDetector {
    /// Builds a detector from clamped configuration values.
    pub fn new(enter_count: u32, exit_meters: f64, motion_speed_mps: f64) -> Self {
        Self {
            enter_count: enter_count.max(1),
            exit_meters: if exit_meters.is_finite() {
                exit_meters.max(0.5)
            } else {
                6.0
            },
            motion_speed_mps: if motion_speed_mps.is_finite() {
                motion_speed_mps.max(0.0)
            } else {
                0.8
            },
            candidate_start: None,
            candidate_count: 0,
            confirmed: false,
            anchor: None,
            outside_count: 0,
        }
    }

    /// Clears all state; the next fix starts a new candidate window.
    pub fn reset(&mut self) {
        self.candidate_start = None;
        self.candidate_count = 0;
        self.confirmed = false;
        self.anchor = None;
        self.outside_count = 0;
    }

    /// Whether stationary motion is currently confirmed.
    pub fn is_confirmed(&self) -> bool {
        self.confirmed
    }

    /// The anchor of the current stationary window, in local meters.
    pub fn anchor(&self) -> Option<(f64, f64)> {
        self.anchor
    }

    /// Classifies one local position.
    ///
    /// `speed_mps` is only a hint: missing or implausible speeds do not prevent
    /// a stationary decision when the position window is tight enough.
    pub fn update(&mut self, east: f64, north: f64, speed_mps: Option<f64>) -> MotionState {
        if !east.is_finite() || !north.is_finite() {
            return MotionState::Unknown(Confidence::ZERO);
        }
        let moving_confidence = Confidence::new(
            speed_mps
                .map(|speed| speed / (self.motion_speed_mps * 2.0).max(f64::EPSILON))
                .unwrap_or(0.5),
        );

        if self.confirmed {
            let anchor = self.anchor.expect("confirmed state has an anchor");
            let outside = (east - anchor.0).hypot(north - anchor.1) > self.exit_meters;
            self.outside_count = if outside { self.outside_count + 1 } else { 0 };
            if self.outside_count >= 2 {
                self.confirmed = false;
                self.anchor = None;
                self.candidate_start = None;
                self.candidate_count = 0;
                self.outside_count = 0;
                let floor = Confidence::new(0.5);
                return MotionState::Moving(if moving_confidence < floor {
                    floor
                } else {
                    moving_confidence
                });
            }
            return MotionState::Stationary(Confidence::new(0.95));
        }

        let start = *self.candidate_start.get_or_insert((east, north));
        if (east - start.0).hypot(north - start.1) > self.exit_meters {
            self.candidate_start = Some((east, north));
            self.candidate_count = 1;
            return MotionState::Moving(moving_confidence);
        }
        self.candidate_count += 1;
        if self.candidate_count >= self.enter_count {
            self.confirmed = true;
            self.anchor = self.candidate_start;
            self.outside_count = 0;
            return MotionState::Stationary(Confidence::new(0.9));
        }
        // A single tight fix is not evidence of movement. Reporting `Unknown`
        // until the candidate window contains at least two fixes lets the
        // caller stage distance without crediting stationary jitter.
        MotionState::Unknown(Confidence::new(0.3))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stationary_jitter_does_not_become_movement() {
        let mut detector = StationaryDetector::new(3, 6.0, 0.8);
        let mut states = Vec::new();
        for (east, north) in [(0.0, 0.0), (2.0, 1.0), (-1.0, 2.0), (1.0, -2.0)] {
            states.push(detector.update(east, north, Some(3.0)));
        }
        assert!(states.last().is_some_and(|state| state.is_stationary()));
        assert!(detector.is_confirmed());
    }

    #[test]
    fn two_fixes_outside_the_exit_radius_resume_movement() {
        let mut detector = StationaryDetector::new(2, 6.0, 0.8);
        assert!(detector.update(0.0, 0.0, None).is_unknown());
        assert!(detector.update(0.5, 0.0, None).is_stationary());
        assert!(detector.update(20.0, 0.0, Some(4.0)).is_stationary());
        assert!(detector.update(30.0, 0.0, Some(4.0)).is_moving());
    }

    #[test]
    fn reset_returns_to_the_gathering_state() {
        let mut detector = StationaryDetector::new(2, 6.0, 0.8);
        detector.update(0.0, 0.0, None);
        detector.update(0.5, 0.0, None);
        assert!(detector.is_confirmed());
        detector.reset();
        assert!(!detector.is_confirmed());
        assert!(detector.anchor().is_none());
    }
}
