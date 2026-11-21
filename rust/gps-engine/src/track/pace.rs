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
use crate::track::TrackPoint;
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

/// Bounds for [`rolling_best_pace_ms_per_km`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RollingBestPaceConfig {
    /// Odd median window applied to coordinates before timing a window. A
    /// median removes isolated GPS outliers without smoothing away a real run.
    pub smoothing_window: usize,
    /// Skip a median position that has drifted farther than this from its raw
    /// fix. That means outliers dominate the local median, so the sample is not
    /// trustworthy enough to time.
    pub max_median_shift: Distance,
    /// Time window used to measure net displacement.
    pub pace: RollingPaceConfig,
    /// Minimum confidence required from a rolling-pace sample.
    pub min_confidence: Confidence,
    /// Quantile of the valid rolling samples used as the sustained best pace.
    /// Lower values are faster; the default ignores the fastest tail.
    pub best_quantile: f64,
}

impl Default for RollingBestPaceConfig {
    fn default() -> Self {
        Self {
            smoothing_window: 13,
            max_median_shift: Distance::from_meters(50.0),
            pace: RollingPaceConfig::default(),
            min_confidence: Confidence::new(0.5),
            best_quantile: 0.25,
        }
    }
}

impl RollingBestPaceConfig {
    /// Forces an odd, non-empty smoothing window.
    #[must_use]
    pub fn clamped(mut self) -> Self {
        self.smoothing_window = self.smoothing_window.max(1) | 1;
        self
    }
}

/// Valid rolling-window paces over a track, in milliseconds per kilometre.
///
/// A short coordinate median removes isolated outliers before each window is
/// timed. This is the evidence behind [`rolling_best_pace_ms_per_km`]; callers
/// that need a different summary can use the samples directly.
#[must_use]
pub fn rolling_pace_samples_ms_per_km(
    points: &[TrackPoint],
    config: &RollingBestPaceConfig,
) -> Vec<f64> {
    let config = config.clamped();
    let half = config.smoothing_window / 2;
    let mut pace = RollingPace::new(config.pace);
    let mut samples = Vec::new();

    for (index, point) in points.iter().enumerate() {
        let lo = index.saturating_sub(half);
        let hi = (index + half + 1).min(points.len());
        let smoothed = median_coordinate(&points[lo..hi]);
        if distance(smoothed, point.coordinate()).meters() > config.max_median_shift.meters() {
            continue;
        }
        pace.push(point.timestamp(), smoothed);
        let sample = pace.sample();
        if sample.confidence < config.min_confidence {
            continue;
        }
        let Some(speed) = sample.speed else {
            continue;
        };
        let mps = speed.mps();
        if !mps.is_finite() || mps <= 0.0 {
            continue;
        }
        let pace_ms = 1_000_000.0 / mps;
        if pace_ms.is_finite() {
            samples.push(pace_ms);
        }
    }
    samples
}

/// Fastest sustained pace over a track, in milliseconds per kilometre.
///
/// Unlike the legacy single-segment minimum, this takes a low quantile of
/// median-smoothed rolling windows. A single corrupt fix cannot masquerade as
/// a personal best, and the fastest noisy tail is ignored. Sparse tracks with
/// no usable rolling window report `None` instead of inventing a fastest split.
#[must_use]
pub fn rolling_best_pace_ms_per_km(
    points: &[TrackPoint],
    config: &RollingBestPaceConfig,
) -> Option<u64> {
    let config = config.clamped();
    let mut samples = rolling_pace_samples_ms_per_km(points, &config);
    if samples.is_empty() {
        return None;
    }
    samples.sort_by(f64::total_cmp);
    let quantile = config.best_quantile.clamp(0.0, 1.0);
    let index = (quantile * (samples.len() - 1) as f64).round() as usize;
    Some(samples[index] as u64)
}

fn median_coordinate(points: &[TrackPoint]) -> Coordinate {
    let mut latitudes: Vec<f64> = points.iter().map(|p| p.coordinate().latitude()).collect();
    let mut longitudes: Vec<f64> = points.iter().map(|p| p.coordinate().longitude()).collect();
    latitudes.sort_by(f64::total_cmp);
    longitudes.sort_by(f64::total_cmp);
    Coordinate::new(median(&latitudes), median(&longitudes))
        .expect("median of valid coordinates is valid")
}

fn median(sorted: &[f64]) -> f64 {
    debug_assert!(!sorted.is_empty());
    let middle = sorted.len() / 2;
    if sorted.len() % 2 == 1 {
        sorted[middle]
    } else {
        (sorted[middle - 1] + sorted[middle]) / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::track::{Track, TrackPoint};

    fn c(lat: f64, lon: f64) -> Coordinate {
        Coordinate::new(lat, lon).unwrap()
    }

    fn north(meters: f64) -> f64 {
        meters / 111_195.0
    }

    fn moving_track(outlier: Option<usize>) -> Track {
        let points = (0..80)
            .map(|index| {
                let offset = if outlier == Some(index) { 500.0 } else { 0.0 };
                let latitude = 52.5 + north(index as f64 * 2.0 + offset);
                TrackPoint::new(timestamp(index as f64), c(latitude, 13.4))
            })
            .collect();
        Track::new(points).expect("moving track")
    }

    fn timestamp(seconds: f64) -> Timestamp {
        Timestamp::from_unix_secs(seconds)
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

    #[test]
    fn rolling_best_ignores_an_isolated_outlier() {
        let track = moving_track(Some(10));
        let config = RollingBestPaceConfig::default();
        let samples = rolling_pace_samples_ms_per_km(track.points(), &config);
        assert!(!samples.is_empty());
        assert!(
            samples.iter().all(|pace| *pace > 400_000.0),
            "a single corrupt fix must not look like a sprint: {samples:?}"
        );
        let best =
            rolling_best_pace_ms_per_km(track.points(), &config).expect("usable rolling window");
        // The constant truth is 2 m/s, or 500_000 ms/km. Smoothed edge windows
        // are slightly slower, so the low quantile stays near that value.
        assert!(
            (best as f64 - 500_000.0).abs() < 10_000.0,
            "rolling best was {best}"
        );
    }

    #[test]
    fn sparse_tracks_have_no_rolling_best() {
        let points = vec![
            TrackPoint::new(timestamp(0.0), c(52.5, 13.4)),
            TrackPoint::new(timestamp(45.0), c(52.5 + north(100.0), 13.4)),
        ];
        assert_eq!(
            rolling_best_pace_ms_per_km(&points, &RollingBestPaceConfig::default()),
            None
        );
    }
}
