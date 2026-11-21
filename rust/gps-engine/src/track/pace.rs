// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Time-windowed ground speed for live pace readouts.
//!
//! Two consecutive fixes are a terrible speed sensor: at 1 Hz with 5 m of
//! positional noise they imply hundreds of seconds per kilometre of error.
//! This module derives speed from net displacement over a short time window
//! instead, with a minimum movement threshold so stationary jitter cannot
//! produce a pace. It is pure and deterministic; callers decide whether to
//! publish the optional confidence alongside the speed.

use std::collections::VecDeque;

use crate::estimate::Confidence;
use crate::geo::{Coordinate, distance};
use crate::units::{Distance, Duration, Speed, Timestamp};

/// Bounds for [`RollingPace`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RollingPaceConfig {
    /// Preferred measurement window. Displacement is taken from the oldest
    /// sample inside this window to the newest one.
    pub window: Duration,
    /// Net movement below this is treated as stationary/unknown.
    pub min_distance: Distance,
    /// When sampling is sparser than `window`, fall back to the previous fix
    /// if the gap is no longer than this. Longer gaps have no pace.
    pub max_fallback_gap: Duration,
}

impl Default for RollingPaceConfig {
    fn default() -> Self {
        Self {
            window: Duration::from_secs(15.0),
            min_distance: Distance::from_meters(15.0),
            max_fallback_gap: Duration::from_secs(30.0),
        }
    }
}

/// One pace estimate and the evidence behind it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RollingPaceSample {
    /// Ground speed over the selected window, when movement was plausible.
    pub speed: Option<Speed>,
    /// Confidence from window occupancy and distance moved. `ZERO` when there
    /// is no speed estimate.
    pub confidence: Confidence,
}

/// Maintains a bounded window of recent positions and derives pace from it.
#[derive(Debug, Clone, PartialEq)]
pub struct RollingPace {
    config: RollingPaceConfig,
    samples: VecDeque<(Timestamp, Coordinate)>,
}

impl RollingPace {
    /// Creates an empty window.
    pub fn new(config: RollingPaceConfig) -> Self {
        Self {
            config,
            samples: VecDeque::new(),
        }
    }

    /// Adds one accepted fix in timestamp order.
    pub fn push(&mut self, timestamp: Timestamp, coordinate: Coordinate) {
        if let Some(last) = self.samples.back() {
            if timestamp.elapsed_since(last.0).as_secs() <= 0.0 {
                return;
            }
        }
        self.samples.push_back((timestamp, coordinate));
        let keep = self
            .config
            .window
            .as_secs()
            .max(self.config.max_fallback_gap.as_secs());
        let newest = timestamp;
        while self.samples.len() > 2 && newest.elapsed_since(self.samples[0].0).as_secs() > keep {
            self.samples.pop_front();
        }
    }

    /// Drops all history (pause, seek, or a new run).
    pub fn reset(&mut self) {
        self.samples.clear();
    }

    /// Speed over the configured window, or `None` when evidence is too weak.
    pub fn speed(&self) -> Option<Speed> {
        self.sample().speed
    }

    /// The full pace sample, including its confidence.
    pub fn sample(&self) -> RollingPaceSample {
        if self.samples.len() < 2 {
            return RollingPaceSample {
                speed: None,
                confidence: Confidence::ZERO,
            };
        }
        let newest = *self.samples.back().expect("at least two samples");
        let mut start = self.samples.len() - 1;
        while start > 0
            && newest.0.elapsed_since(self.samples[start - 1].0).as_secs()
                <= self.config.window.as_secs()
        {
            start -= 1;
        }
        if start == self.samples.len() - 1 {
            start = self.samples.len() - 2;
            if newest.0.elapsed_since(self.samples[start].0).as_secs()
                > self.config.max_fallback_gap.as_secs()
            {
                return RollingPaceSample {
                    speed: None,
                    confidence: Confidence::ZERO,
                };
            }
        }
        let oldest = self.samples[start];
        let dt = newest.0.elapsed_since(oldest.0).as_secs();
        if !dt.is_finite() || dt <= 0.0 {
            return RollingPaceSample {
                speed: None,
                confidence: Confidence::ZERO,
            };
        }
        let moved = distance(oldest.1, newest.1).meters();
        let min_moved = self.config.min_distance.meters().max(f64::EPSILON);
        if !moved.is_finite() || moved < min_moved {
            return RollingPaceSample {
                speed: None,
                confidence: Confidence::ZERO,
            };
        }
        let occupancy = ((self.samples.len() - start) as f64 / 4.0).min(1.0);
        let movement = (moved / min_moved).min(1.0);
        RollingPaceSample {
            speed: Some(Speed::from_mps(moved / dt)),
            confidence: Confidence::new(0.5 * occupancy + 0.5 * movement),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(lat: f64, lon: f64) -> Coordinate {
        Coordinate::new(lat, lon).unwrap()
    }

    fn north(meters: f64) -> f64 {
        meters / 111_195.0
    }

    #[test]
    fn single_fix_has_no_pace() {
        let mut pace = RollingPace::new(RollingPaceConfig::default());
        pace.push(Timestamp::from_unix_secs(0.0), c(52.5, 13.4));
        assert_eq!(pace.speed(), None);
        assert_eq!(pace.sample().confidence, Confidence::ZERO);
    }

    #[test]
    fn speed_uses_net_displacement_not_segment_jitter() {
        let mut pace = RollingPace::new(RollingPaceConfig::default());
        pace.push(Timestamp::from_unix_secs(0.0), c(52.5, 13.4));
        pace.push(Timestamp::from_unix_secs(2.0), c(52.5 + north(10.0), 13.4));
        pace.push(Timestamp::from_unix_secs(4.0), c(52.5, 13.4));
        pace.push(Timestamp::from_unix_secs(6.0), c(52.5 + north(30.0), 13.4));
        let sample = pace.sample();
        let speed = sample.speed.expect("moving window");
        assert!((speed.mps() - 5.0).abs() < 0.5, "got {}", speed.mps());
        assert!(sample.confidence.value() > 0.0);
    }

    #[test]
    fn stationary_jitter_has_no_pace() {
        let mut pace = RollingPace::new(RollingPaceConfig::default());
        pace.push(Timestamp::from_unix_secs(0.0), c(52.5, 13.4));
        for second in 1..=8 {
            let lat = 52.5 + north(if second % 2 == 0 { 2.0 } else { -2.0 });
            pace.push(Timestamp::from_unix_secs(second as f64), c(lat, 13.4));
        }
        assert_eq!(pace.speed(), None);
    }

    #[test]
    fn sparse_cadence_falls_back_to_the_previous_fix() {
        let mut pace = RollingPace::new(RollingPaceConfig::default());
        pace.push(Timestamp::from_unix_secs(0.0), c(52.5, 13.4));
        pace.push(Timestamp::from_unix_secs(25.0), c(52.5 + north(50.0), 13.4));
        let speed = pace.speed().expect("fallback speed");
        assert!((speed.mps() - 2.0).abs() < 0.05);
    }

    #[test]
    fn long_gap_has_no_pace_and_reset_clears_history() {
        let mut pace = RollingPace::new(RollingPaceConfig::default());
        pace.push(Timestamp::from_unix_secs(0.0), c(52.5, 13.4));
        // A 45 s cadence is beyond the fallback bound; publishing a speed from
        // one stale pair would be less honest than showing no pace.
        pace.push(
            Timestamp::from_unix_secs(45.0),
            c(52.5 + north(100.0), 13.4),
        );
        assert_eq!(pace.speed(), None);
        pace.push(
            Timestamp::from_unix_secs(90.0),
            c(52.5 + north(200.0), 13.4),
        );
        assert_eq!(pace.speed(), None);
        pace.reset();
        pace.push(Timestamp::from_unix_secs(100.0), c(52.5, 13.4));
        assert_eq!(pace.speed(), None);
    }
}
