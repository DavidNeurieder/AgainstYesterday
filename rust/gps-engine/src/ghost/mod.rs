// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Ghost: race your own best effort.
//!
//! A ghost is the reference (PB) attempt replayed against the live runner:
//! at any elapsed time we know how far the runner is, how far the ghost is,
//! and whether we are ahead.
//!
//! ```text
//! at 20:00    you are at 4,812m, ghost at 4,812m was at 19:43
//!             → 17s behind
//! distance: 4812m  difference: +17s  ahead: false
//! ```

use crate::attempt::{Attempt, AttemptSample};
use crate::units::{Distance, Duration};

/// Reference-sample spacing (m) at or below which a ghost comparison is rated
/// `confidence == 1.0`.
pub const MIN_HIGH_CONFIDENCE_SPACING_M: f64 = 10.0;

/// Reference-sample spacing (m) at which a ghost comparison is rated
/// `confidence == 0.0` (and below which it stays 0).
pub const LOW_CONFIDENCE_SPACING_M: f64 = 60.0;

/// The duel state between the runner and the ghost at one instant or at one
/// distance.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GhostState {
    /// Route distance at which the comparison is made.
    pub distance: Distance,
    /// `current - reference` at this distance:
    /// positive means the live runner is behind the ghost.
    pub time_difference: Duration,
    /// `true` when the live runner is ahead of the ghost
    /// (`time_difference < 0`).
    pub ahead: bool,
}

/// A ghost comparison with its mathematical confidence (M15 Phase 4).
///
/// [`GhostState`] alone answers "how far ahead/behind and by how long"; a
/// snapshot additionally exposes the spatial gap and a `0.0..=1.0`
/// `confidence` so callers can tell a trustworthy comparison from a guess
/// based on sparse reference samples.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GhostSnapshot {
    /// The duel state at the comparison point ([`GhostState`], unchanged).
    pub state: GhostState,
    /// Spatial separation of the two runners at the same elapsed time:
    /// `reference.distance_at(elapsed) - current.distance_at(elapsed)`.
    /// Positive when the live runner is behind the ghost.
    pub spatial_gap: Distance,
    /// How much to trust this snapshot, derived from the density of the
    /// reference attempt's samples near the comparison distance. `1.0` when
    /// the reference is sampled at least every [`MIN_HIGH_CONFIDENCE_SPACING_M`];
    /// `0.0` when gaps reach [`LOW_CONFIDENCE_SPACING_M`], linearly in between.
    pub confidence: f64,
}

/// A ghost built from a reference (PB) attempt, competing against a live
/// (`current`) attempt.
#[derive(Debug, Clone, PartialEq)]
pub struct Ghost {
    reference: Attempt,
    current: Attempt,
}

impl Ghost {
    /// Creates a ghost duel. `reference` is the personal best; `current` is
    /// the live attempt.
    pub fn new(reference: Attempt, current: Attempt) -> Self {
        Self { reference, current }
    }

    /// Evaluates the duel at an elapsed time of the *live* runner.
    ///
    /// The state reports how far the runner has come by `elapsed`, what the
    /// reference's time at that distance was, and whether the runner is
    /// ahead. `None` for negative or non-finite elapsed times.
    pub fn state_at(&self, elapsed: Duration) -> Option<GhostState> {
        let current_distance = self.current.distance_at(elapsed)?;
        let reference_time = match self.reference.time_at(current_distance) {
            Some(t) => t,
            // The runner is past every distance the reference ever covered:
            // fall back to the reference's finishing time.
            None => self.reference.elapsed_time,
        };
        let time_difference = Duration::from_secs(elapsed.as_secs() - reference_time.as_secs());
        Some(GhostState {
            distance: current_distance,
            time_difference,
            ahead: time_difference.as_secs() < 0.0,
        })
    }

    /// Evaluates the duel at a fixed route distance (a split-point query).
    ///
    /// `None` if either attempt never covered that distance. At the start
    /// (`0m`) both are even.
    pub fn state_at_distance(&self, distance: Distance) -> Option<GhostState> {
        let current_time = self.current.time_at(distance)?;
        let reference_time = match self.reference.time_at(distance) {
            Some(t) => t,
            None => self.reference.elapsed_time,
        };
        let time_difference = current_time - reference_time;
        Some(GhostState {
            distance,
            time_difference,
            ahead: time_difference.as_secs() < 0.0,
        })
    }

    /// A full ghost snapshot at an elapsed time of the *live* runner.
    ///
    /// Composes [`Ghost::state_at`] with the spatial gap and the comparison
    /// confidence (see [`GhostSnapshot`]). `None` when
    /// [`Ghost::state_at`] is `None`.
    pub fn snapshot_at(&self, elapsed: Duration) -> Option<GhostSnapshot> {
        let state = self.state_at(elapsed)?;
        let reference_distance = self.reference.distance_at(elapsed)?;
        Some(GhostSnapshot {
            spatial_gap: Distance::from_meters(
                reference_distance.meters() - state.distance.meters(),
            ),
            confidence: self.confidence_at(state.distance.meters()),
            state,
        })
    }

    /// A full ghost snapshot at a fixed route distance.
    ///
    /// Composes [`Ghost::state_at_distance`] with the spatial gap and the
    /// comparison confidence. `None` when [`Ghost::state_at_distance`] is
    /// `None`.
    pub fn snapshot_at_distance(&self, distance: Distance) -> Option<GhostSnapshot> {
        let state = self.state_at_distance(distance)?;
        // The live runner reaches `distance` at this elapsed time; compare the
        // ghost's spatial position at that same moment.
        let elapsed = self.current.time_at(distance)?;
        let reference_distance = self.reference.distance_at(elapsed)?;
        Some(GhostSnapshot {
            spatial_gap: Distance::from_meters(reference_distance.meters() - distance.meters()),
            confidence: self.confidence_at(distance.meters()),
            state,
        })
    }

    /// Confidence in an interpolation at `distance_m`, from the reference
    /// attempt's closest sample spacing.
    fn confidence_at(&self, distance_m: f64) -> f64 {
        let samples = &self.reference.samples;
        let spacing = sample_spacing_at(samples, distance_m);
        (1.0 - (spacing - MIN_HIGH_CONFIDENCE_SPACING_M)
            / (LOW_CONFIDENCE_SPACING_M - MIN_HIGH_CONFIDENCE_SPACING_M))
            .clamp(0.0, 1.0)
    }
}

/// The reference-sample interval (meters) that brackets (or precedes)
/// `distance_m` — the interval over which a [`crate::attempt::Attempt::time_at`]
/// interpolation takes place, and therefore how much the sampling cadence
/// influences the ghost gap.
fn sample_spacing_at(samples: &[AttemptSample], distance_m: f64) -> f64 {
    let last = samples.last().expect("attempt is never empty");
    if samples.len() == 1 || last.distance.meters() <= 0.0 {
        return last.distance.meters().abs();
    }
    if distance_m <= 0.0 {
        // Before the first sample: the interval reaching the start line.
        return samples[0].distance.meters();
    }
    if distance_m >= last.distance.meters() {
        // At or past the finish: the final interval.
        return samples[samples.len() - 1].distance.meters()
            - samples[samples.len() - 2].distance.meters();
    }
    if let Some(j) = samples
        .iter()
        .position(|s| s.distance.meters() >= distance_m)
    {
        let near = samples[j].distance.meters();
        if j == 0 {
            near // interval from the start line to the first sample
        } else {
            near - samples[j - 1].distance.meters()
        }
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attempt::AttemptSample;

    /// PB: 10 km in 50 min, 5 km split at 25 min.
    fn pb() -> Attempt {
        Attempt::from_samples(vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(5_000.0),
                elapsed: Duration::from_secs(1_500.0),
            },
            AttemptSample {
                distance: Distance::from_meters(10_000.0),
                elapsed: Duration::from_secs(3_000.0),
            },
        ])
        .unwrap()
    }

    /// Current: 10 km in 52 min, 5 km split at 25:30.
    fn current() -> Attempt {
        Attempt::from_samples(vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(5_000.0),
                elapsed: Duration::from_secs(1_530.0),
            },
            AttemptSample {
                distance: Distance::from_meters(10_000.0),
                elapsed: Duration::from_secs(3_120.0),
            },
        ])
        .unwrap()
    }

    #[test]
    fn behind_by_exactly_30_seconds_at_5km() {
        // Spec: PB 5km = 25:00, current 5km = 25:30 → behind 30s.
        let ghost = Ghost::new(pb(), current());
        let state = ghost
            .state_at_distance(Distance::from_meters(5_000.0))
            .unwrap();
        assert!((state.time_difference.as_secs() - 30.0).abs() < 1e-9);
        assert!(!state.ahead);
        assert!((state.distance.meters() - 5_000.0).abs() < 1e-9);
    }

    #[test]
    fn ahead_when_current_is_faster() {
        let faster = Attempt::from_samples(vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(5_000.0),
                elapsed: Duration::from_secs(1_470.0),
            },
            AttemptSample {
                distance: Distance::from_meters(10_000.0),
                elapsed: Duration::from_secs(2_940.0),
            },
        ])
        .unwrap();
        let ghost = Ghost::new(pb(), faster);
        let state = ghost
            .state_at_distance(Distance::from_meters(5_000.0))
            .unwrap();
        assert!((state.time_difference.as_secs() + 30.0).abs() < 1e-9);
        assert!(state.ahead);
    }

    #[test]
    fn tied_attempts_are_never_ahead() {
        let ghost = Ghost::new(pb(), pb());
        for d in [0.0, 5_000.0, 10_000.0] {
            let state = ghost.state_at_distance(Distance::from_meters(d)).unwrap();
            assert!(state.time_difference.as_secs().abs() < 1e-9);
            assert!(!state.ahead);
        }
    }

    #[test]
    fn before_start_and_after_finish() {
        let ghost = Ghost::new(pb(), current());

        // Before the start: even at the start line.
        let state = ghost.state_at(Duration::ZERO).unwrap();
        assert!(state.distance.meters().abs() < 1e-9);
        assert!(state.time_difference.as_secs().abs() < 1e-9);
        assert!(!state.ahead);

        // Past the finish: runner finished 10000 m, ghost benchmark 3000 s:
        // by t = 3120 s the runner has just finished ⇒ +120 s behind.
        let state = ghost.state_at(Duration::from_secs(3_120.0)).unwrap();
        assert!((state.distance.meters() - 10_000.0).abs() < 1e-9);
        assert!((state.time_difference.as_secs() - 120.0).abs() < 1e-9);
        assert!(!state.ahead);
    }

    #[test]
    fn mid_race_state_uses_live_distance() {
        let ghost = Ghost::new(pb(), current());
        // At t = 1500 s: the current attempt has been running 25 min.
        // distance_at(1500) on a linear 0..1530s→0..5000m ramp gives 4901.96m.
        let state = ghost.state_at(Duration::from_secs(1_500.0)).unwrap();
        let expected = 5_000.0 * (1_500.0 / 1_530.0);
        assert!((state.distance.meters() - expected).abs() < 1e-6);
        // Ghost's time at that distance lies on the 0..1500s→0..5000m ramp,
        // so the deficit is purely the 5k split gap at this early stage.
        assert!(state.time_difference.as_secs() > 0.0);
        assert!(!state.ahead);
    }

    #[test]
    fn state_at_rejects_negative_elapsed() {
        let ghost = Ghost::new(pb(), current());
        assert!(ghost.state_at(Duration::from_secs(-1.0)).is_none());
        assert!(ghost.state_at(Duration::from_secs(f64::NAN)).is_none());
        assert!(ghost.snapshot_at(Duration::from_secs(-1.0)).is_none());
    }

    /// A constant 5 m/s attempt over `finish_m` sampled every `cadence_s`.
    fn constant_pace(cadence_s: f64, finish_m: f64) -> Attempt {
        let mut samples = Vec::new();
        let mut d = 0.0;
        while d <= finish_m {
            samples.push(AttemptSample {
                distance: Distance::from_meters(d),
                elapsed: Duration::from_secs(d / 5.0),
            });
            d += 5.0 * cadence_s;
        }
        Attempt::from_samples(samples).unwrap()
    }

    #[test]
    fn snapshot_gap_is_sampling_rate_invariant() {
        // M15 critical invariant: two runs of the *same* movement must have
        // the same ghost gap regardless of GPS sampling cadence.
        let reference_1hz = constant_pace(1.0, 5_000.0);
        let reference_5s = constant_pace(5.0, 5_000.0);
        let current = constant_pace(1.0, 5_000.0);

        let dense = Ghost::new(reference_1hz.clone(), current.clone());
        let sparse = Ghost::new(reference_5s, current);

        for elapsed in [30.0, 300.0, 900.0, 999.0] {
            let t = Duration::from_secs(elapsed);
            let a = dense.snapshot_at(t).unwrap();
            let b = sparse.snapshot_at(t).unwrap();
            assert!(
                (a.state.time_difference.as_secs() - b.state.time_difference.as_secs()).abs()
                    < 1e-6,
                "time gap must not depend on sampling cadence (t={elapsed}s)"
            );
            assert!(
                (a.spatial_gap.meters() - b.spatial_gap.meters()).abs() < 1e-6,
                "spatial gap must not depend on sampling cadence (t={elapsed}s)"
            );
        }
    }

    #[test]
    fn snapshot_confidence_reflects_reference_density() {
        // Dense (1 m/s cadence ⇒ 5 m spacing) reference: confidence 1.0.
        let dense = Ghost::new(constant_pace(1.0, 2_000.0), current());
        let dense_snap = dense
            .snapshot_at_distance(Distance::from_meters(500.0))
            .unwrap();
        assert_eq!(dense_snap.confidence, 1.0);

        // Sparse (30 s cadence ⇒ 150 m spacing) reference: confidence 0.0.
        let sparse = Ghost::new(constant_pace(30.0, 2_000.0), current());
        let sparse_snap = sparse
            .snapshot_at_distance(Distance::from_meters(500.0))
            .unwrap();
        assert_eq!(sparse_snap.confidence, 0.0);

        // Medium (6 s cadence ⇒ 30 m spacing): fractional confidence.
        let medium = Ghost::new(constant_pace(6.0, 2_000.0), current());
        let medium_snap = medium
            .snapshot_at_distance(Distance::from_meters(500.0))
            .unwrap();
        assert!(medium_snap.confidence > 0.0 && medium_snap.confidence < 1.0);
    }

    #[test]
    fn snapshot_spatial_gap_sign_follows_ahead_behind() {
        // The "pb" is 25:00 at 5 km; the current attempt is 10 s slower.
        let slow = Attempt::from_samples(vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(5_000.0),
                elapsed: Duration::from_secs(1_510.0),
            },
            AttemptSample {
                distance: Distance::from_meters(10_000.0),
                elapsed: Duration::from_secs(3_020.0),
            },
        ])
        .unwrap();
        let ghost = Ghost::new(pb(), slow);
        let snap = ghost.snapshot_at(Duration::from_secs(1_500.0)).unwrap();
        // At t = 1500 s the slow runner hasn't reached 5 km, so the ghost (PB)
        // is further along the route: positive spatial gap, behind.
        assert!(snap.spatial_gap.meters() > 0.0);
        assert!(!snap.state.ahead);

        // A faster runner is spatially ahead: negative spatial gap.
        let fast = Attempt::from_samples(vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(5_000.0),
                elapsed: Duration::from_secs(1_490.0),
            },
            AttemptSample {
                distance: Distance::from_meters(10_000.0),
                elapsed: Duration::from_secs(2_980.0),
            },
        ])
        .unwrap();
        let ghost = Ghost::new(pb(), fast);
        let snap = ghost.snapshot_at(Duration::from_secs(1_500.0)).unwrap();
        assert!(snap.spatial_gap.meters() < 0.0);
        assert!(snap.state.ahead);
    }

    #[test]
    fn sample_spacing_bracketing_is_sane() {
        let attempt = constant_pace(2.0, 1_000.0); // 10 m spacing
        let samples = &attempt.samples;
        // Between samples 0 and 10 → spacing of the (2nd, 3rd) interval = 10m.
        assert!((sample_spacing_at(samples, 25.0) - 10.0).abs() < 1e-9);
        // Before the start: interval to the first sample.
        assert!((sample_spacing_at(samples, -5.0) - 0.0).abs() < 1e-9);
        // At the finish: final interval.
        assert!((sample_spacing_at(samples, 1_000.0) - 10.0).abs() < 1e-9);
    }
}
