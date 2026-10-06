// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use crate::error::TrackError;
use crate::geo::Coordinate;
use crate::units::{Distance, Duration, Speed, Timestamp};

use super::point::TrackPoint;
use super::statistics::MovingConfig;

/// A chronologically ordered GPS activity.
///
/// A `Track` is always valid after construction: it has at least two points,
/// timestamps are monotonically non-decreasing, and every numeric observation
/// is finite. Holding the internal vector private keeps those invariants.
///
/// A `Track` is a recording of where the device actually was. It is distinct
/// from a canonical route (a cleaned, repeatable geometry) which is introduced
/// in a later phase.
#[derive(Debug, Clone, PartialEq)]
pub struct Track {
    points: Vec<TrackPoint>,
}

impl Track {
    /// Constructs a track, validating the invariants described above.
    pub fn new(points: Vec<TrackPoint>) -> Result<Self, TrackError> {
        if points.is_empty() {
            return Err(TrackError::Empty);
        }
        if points.len() < 2 {
            return Err(TrackError::TooFewPoints(points.len()));
        }

        let mut previous: Option<Timestamp> = None;
        for (index, point) in points.iter().enumerate() {
            point.validate(index)?;
            if let Some(prev) = previous
                && point.timestamp() < prev
            {
                return Err(TrackError::NonMonotonicTimestamp(index));
            }
            previous = Some(point.timestamp());
        }

        Ok(Track { points })
    }

    /// Constructs a track from points that are already known to be valid;
    /// used internally by processing stages whose output preserves the
    /// invariants by construction.
    pub(crate) fn from_unchecked(points: Vec<TrackPoint>) -> Track {
        debug_assert!(
            Track::new(points.clone()).is_ok(),
            "processing stage produced an invalid track"
        );
        Track { points }
    }

    /// All points, in chronological order.
    pub fn points(&self) -> &[TrackPoint] {
        &self.points
    }

    /// The geographic coordinates of all points, in order.
    pub fn coordinates(&self) -> Vec<Coordinate> {
        self.points.iter().map(|p| p.coordinate()).collect()
    }

    /// The first point, if any.
    pub fn start(&self) -> Option<&TrackPoint> {
        self.points.first()
    }

    /// The last point, if any.
    pub fn end(&self) -> Option<&TrackPoint> {
        self.points.last()
    }

    /// Number of points in the track.
    pub fn len(&self) -> usize {
        self.points.len()
    }

    /// Whether the track has no points.
    pub fn is_empty(&self) -> bool {
        self.points.is_empty()
    }

    /// Elapsed wall-clock time from the first to the last point.
    pub fn duration(&self) -> Duration {
        match (self.points.first(), self.points.last()) {
            (Some(first), Some(last)) => last.timestamp().elapsed_since(first.timestamp()),
            _ => Duration::ZERO,
        }
    }

    /// Total geodesic length of the track.
    pub fn distance(&self) -> Distance {
        super::statistics::total_distance(self)
    }

    /// Elapsed time spent actually moving (see [`MovingConfig`]).
    pub fn moving_duration(&self, config: &MovingConfig) -> Duration {
        super::statistics::moving_duration(self, config)
    }

    /// Elapsed time spent stopped (duration minus moving time, never negative).
    pub fn paused_duration(&self, config: &MovingConfig) -> Duration {
        let moving = self.moving_duration(config).as_secs();
        let elapsed = self.duration().as_secs();
        Duration::from_secs((elapsed - moving).max(0.0))
    }

    /// Total positive elevation change in meters.
    pub fn elevation_gain(&self) -> f64 {
        super::statistics::elevation_gain(self)
    }

    /// Total negative elevation change in meters.
    pub fn elevation_loss(&self) -> f64 {
        super::statistics::elevation_loss(self)
    }

    /// Average speed over the total elapsed time.
    pub fn average_speed(&self) -> Speed {
        let elapsed = self.duration().as_secs();
        if elapsed > 0.0 {
            Speed::from_mps(self.distance().meters() / elapsed)
        } else {
            Speed::ZERO
        }
    }

    /// Average speed over the moving time only: total distance divided by
    /// [`Self::moving_duration`]. Stop-segment distances are tiny by
    /// construction, so counting them has a negligible effect.
    pub fn moving_speed(&self, config: &MovingConfig) -> Speed {
        let moving = self.moving_duration(config).as_secs();
        if moving > 0.0 {
            Speed::from_mps(self.distance().meters() / moving)
        } else {
            Speed::ZERO
        }
    }

    /// Removes bad GPS points according to [`super::filtering::FilterConfig`].
    pub fn filter(
        &self,
        config: &super::filtering::FilterConfig,
    ) -> (Track, super::filtering::ProcessingReport) {
        super::filtering::filter(self, config)
    }

    /// Reduces the number of points while preserving shape within tolerance,
    /// using [`super::simplification::SimplifyConfig`].
    pub fn simplify(&self, config: &super::simplification::SimplifyConfig) -> Track {
        super::simplification::simplify(self, config)
    }

    /// Re-samples the track to an evenly distance-spaced sequence.
    pub fn resample_by_distance(&self, interval: Distance) -> Result<Track, TrackError> {
        super::resampling::resample_by_distance(self, interval)
    }

    /// Plays the track finish → start while keeping the same total duration and
    /// monotonic ascending timestamps.
    pub fn reversed(&self) -> Track {
        super::reverse::reverse(self)
    }
}
