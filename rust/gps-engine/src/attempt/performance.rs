// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Performance comparison: two attempts over the same route.
//!
//! The reference is normally the personal best; the comparison answers "how
//! far behind/ahead are we, in time, at each distance along the route?".
//!
//! ```text
//! at distance   time difference
//! 0m        →     0.0s
//! 500m      →   -6.4s   (ahead)
//! 1000m     →   -6.4s   (ahead)
//! ```

use crate::attempt::Attempt;
use crate::units::{Distance, Duration};

/// How to sample the pointwise comparison.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ComparisonConfig {
    /// Distance between comparison points.
    pub step: Distance,
}

impl Default for ComparisonConfig {
    fn default() -> Self {
        Self {
            step: Distance::from_meters(100.0),
        }
    }
}

/// One point of the pointwise comparison.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ComparisonPoint {
    /// Route distance at which both attempts were evaluated.
    pub distance: Distance,
    /// `current - reference`: positive means the current attempt is slower
    /// (behind) at this distance.
    pub time_difference: Duration,
}

/// Result of comparing two attempts over the same route.
#[derive(Debug, Clone, PartialEq)]
pub struct PerformanceComparison {
    /// `current.elapsed_time - reference.elapsed_time`.
    pub total_time_difference: Duration,
    /// `current.distance - reference.distance` (final coverage).
    pub distance_difference: Distance,
    /// Pointwise comparison at every multiple of `ComparisonConfig::step`
    /// up to the distance covered by both attempts.
    pub points: Vec<ComparisonPoint>,
}

/// Compares `current` against the `reference` attempt at fixed distance
/// intervals.
pub fn compare(
    reference: &Attempt,
    current: &Attempt,
    config: &ComparisonConfig,
) -> PerformanceComparison {
    let step = config.step.meters().max(1.0);
    let shared = reference.distance.meters().min(current.distance.meters());

    let total_time_difference = current.elapsed_time - reference.elapsed_time;
    let distance_difference = current.distance - reference.distance;

    let mut points = Vec::new();
    let mut d = 0.0;
    loop {
        if d > shared {
            break;
        }
        let distance = Distance::from_meters(d);
        if let (Some(r), Some(c)) = (reference.time_at(distance), current.time_at(distance)) {
            points.push(ComparisonPoint {
                distance,
                time_difference: c - r,
            });
        }
        d += step;
    }

    PerformanceComparison {
        total_time_difference,
        distance_difference,
        points,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attempt::AttemptSample;

    /// PB: 10 km in 50 min with a 5 km split of 25 min.
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

    /// Current: 10 km in 52 min with a 5 km split of 25:30.
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
    fn deterministic_pb_race_comparison() {
        // PB 10km/50min vs current 10km/52min → exactly 120 s behind.
        let comparison = compare(&pb(), &current(), &ComparisonConfig::default());
        assert!((comparison.total_time_difference.as_secs() - 120.0).abs() < 1e-9);
        assert!(comparison.distance_difference.meters().abs() < 1e-9);

        let at_5k = comparison
            .points
            .iter()
            .find(|p| (p.distance.meters() - 5_000.0).abs() < 0.5)
            .expect("5000m point sampled");
        assert!(
            (at_5k.time_difference.as_secs() - 30.0).abs() < 1e-9,
            "at 5 km the current attempt is behind by exactly 30 s"
        );
    }

    #[test]
    fn identical_attempts_compare_even() {
        let comparison = compare(&pb(), &pb(), &ComparisonConfig::default());
        assert!(comparison.total_time_difference.as_secs().abs() < 1e-9);
        assert!(
            comparison
                .points
                .iter()
                .all(|p| p.time_difference.as_secs().abs() < 1e-9)
        );
    }

    #[test]
    fn faster_attempt_is_ahead() {
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
        let comparison = compare(&pb(), &faster, &ComparisonConfig::default());
        assert!((comparison.total_time_difference.as_secs() + 60.0).abs() < 1e-9);
        let at_5k = comparison
            .points
            .iter()
            .find(|p| (p.distance.meters() - 5_000.0).abs() < 0.5)
            .unwrap();
        assert!((at_5k.time_difference.as_secs() + 30.0).abs() < 1e-9);
    }
}
