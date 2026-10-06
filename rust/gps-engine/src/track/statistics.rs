// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Aggregate statistics over a [`Track`].

use crate::geo::{distance as geo_distance, polyline_length};
use crate::units::{Distance, Duration, Speed};

use super::model::Track;

/// Controls how "moving time" is separated from stopped time.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MovingConfig {
    /// Gaps whose average speed is below this are treated as stops.
    pub min_speed: Speed,
    /// A gap must last at least this long before it can count as a stop.
    pub min_stop_duration: Duration,
}

impl Default for MovingConfig {
    fn default() -> Self {
        MovingConfig {
            // ~1.8 km/h: slower than any realistic jog.
            min_speed: Speed::from_mps(0.5),
            min_stop_duration: Duration::from_secs(5.0),
        }
    }
}

/// Elapsed time spent actually moving.
///
/// Each gap between consecutive points counts towards moving time unless it
/// is longer than `config.min_stop_duration` *and* its average speed is below
/// `config.min_speed`, in which case the whole gap counts as a stop.
pub fn moving_duration(track: &Track, config: &MovingConfig) -> Duration {
    let mut total = 0.0;
    for pair in track.points().windows(2) {
        let dt = pair[1]
            .timestamp()
            .elapsed_since(pair[0].timestamp())
            .as_secs();
        if dt <= 0.0 {
            continue;
        }
        if dt < config.min_stop_duration.as_secs() {
            total += dt;
            continue;
        }
        let speed = geo_distance(pair[0].coordinate(), pair[1].coordinate()).meters() / dt;
        if speed > config.min_speed.mps() {
            total += dt;
        }
    }
    Duration::from_secs(total)
}

/// Total positive elevation change in meters (sum of ascending steps where
/// both endpoints report altitude).
pub fn elevation_gain(track: &Track) -> f64 {
    let mut gain = 0.0;
    for pair in track.points().windows(2) {
        if let (Some(a), Some(b)) = (pair[0].altitude(), pair[1].altitude()) {
            gain += (b - a).max(0.0);
        }
    }
    gain
}

/// Total negative elevation change in meters (sum of descending steps where
/// both endpoints report altitude).
pub fn elevation_loss(track: &Track) -> f64 {
    let mut loss = 0.0;
    for pair in track.points().windows(2) {
        if let (Some(a), Some(b)) = (pair[0].altitude(), pair[1].altitude()) {
            loss += (a - b).max(0.0);
        }
    }
    loss
}

/// Total geodesic length of the track.
pub fn total_distance(track: &Track) -> Distance {
    polyline_length(&track.coordinates())
}
