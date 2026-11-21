// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Noise-tolerant elevation gain and loss.
//!
//! Summing every positive altitude step turns receiver jitter into climbing:
//! a 2 Hz track with ±8 m of altitude noise can report thousands of metres of
//! gain on a flat route. This module keeps the raw totals for audit and adds a
//! robust median-filtered breakdown with a dead band. It is deterministic, has
//! no dependencies, and never changes the stored track.

use super::Track;

/// Bounds for the robust elevation estimate.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ElevationConfig {
    /// Odd number of neighbouring altitude samples in each median window.
    pub median_window: usize,
    /// Changes smaller than this are treated as noise, in meters.
    pub noise_threshold_m: f64,
}

impl Default for ElevationConfig {
    fn default() -> Self {
        Self {
            median_window: 13,
            noise_threshold_m: 1.0,
        }
    }
}

impl ElevationConfig {
    /// Returns a copy with finite, usable bounds.
    pub fn clamped(&self) -> Self {
        let mut config = *self;
        config.median_window = config.median_window.max(1) | 1;
        if !config.noise_threshold_m.is_finite() || config.noise_threshold_m < 0.0 {
            config.noise_threshold_m = 0.0;
        }
        config
    }
}

/// Raw and robust elevation totals for one track.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ElevationBreakdown {
    /// Legacy sum of all positive altitude steps.
    pub raw_gain_m: f64,
    /// Legacy sum of all negative altitude steps.
    pub raw_loss_m: f64,
    /// Median-filtered positive change above the noise threshold.
    pub gain_m: f64,
    /// Median-filtered negative change above the noise threshold.
    pub loss_m: f64,
}

/// Computes both the raw and robust elevation totals.
pub fn breakdown(track: &Track, config: &ElevationConfig) -> ElevationBreakdown {
    let config = config.clamped();
    let altitudes: Vec<Option<f64>> = track
        .points()
        .iter()
        .map(|point| point.altitude())
        .collect();
    let half = config.median_window / 2;
    let mut raw_gain = 0.0;
    let mut raw_loss = 0.0;
    let mut gain = 0.0;
    let mut loss = 0.0;

    for index in 1..altitudes.len() {
        let (Some(previous), Some(current)) = (altitudes[index - 1], altitudes[index]) else {
            continue;
        };
        raw_gain += (current - previous).max(0.0);
        raw_loss += (previous - current).max(0.0);

        let (Some(previous), Some(current)) = (
            window_median(&altitudes, index - 1, half),
            window_median(&altitudes, index, half),
        ) else {
            continue;
        };
        let delta = current - previous;
        if delta > config.noise_threshold_m {
            gain += delta;
        } else if delta < -config.noise_threshold_m {
            loss += -delta;
        }
    }

    ElevationBreakdown {
        raw_gain_m: raw_gain,
        raw_loss_m: raw_loss,
        gain_m: gain,
        loss_m: loss,
    }
}

/// Robust gain with the default noise bounds.
pub fn gain(track: &Track) -> f64 {
    breakdown(track, &ElevationConfig::default()).gain_m
}

/// Robust loss with the default noise bounds.
pub fn loss(track: &Track) -> f64 {
    breakdown(track, &ElevationConfig::default()).loss_m
}

fn window_median(altitudes: &[Option<f64>], center: usize, half: usize) -> Option<f64> {
    let lo = center.saturating_sub(half);
    let hi = (center + half + 1).min(altitudes.len());
    let mut values: Vec<f64> = altitudes[lo..hi].iter().flatten().copied().collect();
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.total_cmp(b));
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 1 {
        values[mid]
    } else {
        (values[mid - 1] + values[mid]) / 2.0
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::units::Timestamp;

    fn track(altitudes: &[Option<f64>]) -> Track {
        let points = altitudes
            .iter()
            .enumerate()
            .map(|(index, altitude)| {
                let latitude = 52.5 + index as f64 / 111_195.0;
                let mut point = TrackPoint::new(Timestamp::from_unix_secs(index as f64), {
                    Coordinate::new(latitude, 13.4).expect("valid coordinate")
                });
                if let Some(altitude) = altitude {
                    point = point.with_altitude(*altitude).expect("valid altitude");
                }
                point
            })
            .collect();
        Track::new(points).expect("valid track")
    }

    use crate::Coordinate;
    use crate::track::TrackPoint;

    #[test]
    fn raw_totals_count_every_jitter_step() {
        let track = track(&[Some(0.0), Some(4.0), Some(0.0), Some(4.0), Some(0.0)]);
        let result = breakdown(&track, &ElevationConfig::default());
        assert!((result.raw_gain_m - 8.0).abs() < 1e-9);
        assert!((result.raw_loss_m - 8.0).abs() < 1e-9);
    }

    #[test]
    fn robust_totals_reject_small_jitter() {
        let track = track(&[Some(0.0), Some(2.0), Some(0.0), Some(2.0), Some(0.0)]);
        let result = breakdown(&track, &ElevationConfig::default());
        assert_eq!(result.gain_m, 0.0);
        assert_eq!(result.loss_m, 0.0);
    }

    #[test]
    fn robust_totals_keep_real_climbing() {
        let track = track(&[
            Some(0.0),
            Some(10.0),
            Some(20.0),
            Some(30.0),
            Some(40.0),
            Some(30.0),
            Some(20.0),
            Some(10.0),
            Some(0.0),
        ]);
        let config = ElevationConfig {
            median_window: 1,
            noise_threshold_m: 3.0,
        };
        let result = breakdown(&track, &config);
        assert!((result.gain_m - 40.0).abs() < 1e-9);
        assert!((result.loss_m - 40.0).abs() < 1e-9);
    }

    #[test]
    fn missing_altitude_is_skipped_without_bridge() {
        let track = track(&[Some(0.0), None, Some(20.0), Some(20.0)]);
        let result = breakdown(&track, &ElevationConfig::default());
        assert_eq!(result.raw_gain_m, 0.0);
        assert_eq!(result.gain_m, 0.0);
    }
}
