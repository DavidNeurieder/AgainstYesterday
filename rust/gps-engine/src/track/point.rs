// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use crate::error::{TrackError, TrackField};
use crate::geo::{Bearing, Coordinate};
use crate::units::Timestamp;

/// A single GPS observation.
///
/// The timestamp and coordinate are mandatory; altitude, speed, accuracy, and
/// bearing are optional sensor fields. Numeric fields are validated to be
/// finite when set.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TrackPoint {
    timestamp: Timestamp,
    coordinate: Coordinate,
    altitude: Option<f64>,
    speed: Option<f64>,
    accuracy: Option<f64>,
    bearing: Option<Bearing>,
}

impl TrackPoint {
    /// Creates a point with no optional sensor fields. The coordinate is
    /// already validated by [`Coordinate::new`].
    pub fn new(timestamp: Timestamp, coordinate: Coordinate) -> Self {
        TrackPoint {
            timestamp,
            coordinate,
            altitude: None,
            speed: None,
            accuracy: None,
            bearing: None,
        }
    }

    /// Sets the altitude in meters, returning an error if not finite.
    pub fn with_altitude(mut self, altitude: f64) -> Result<Self, TrackError> {
        if !altitude.is_finite() {
            return Err(TrackError::InvalidValue {
                index: 0,
                field: TrackField::Altitude,
                value: altitude,
            });
        }
        self.altitude = Some(altitude);
        Ok(self)
    }

    /// Sets the GPS-reported speed in meters per second.
    pub fn with_speed(mut self, speed: f64) -> Result<Self, TrackError> {
        if !speed.is_finite() {
            return Err(TrackError::InvalidValue {
                index: 0,
                field: TrackField::Speed,
                value: speed,
            });
        }
        self.speed = Some(speed);
        Ok(self)
    }

    /// Sets the horizontal accuracy in meters.
    pub fn with_accuracy(mut self, accuracy: f64) -> Result<Self, TrackError> {
        if !accuracy.is_finite() {
            return Err(TrackError::InvalidValue {
                index: 0,
                field: TrackField::Accuracy,
                value: accuracy,
            });
        }
        self.accuracy = Some(accuracy);
        Ok(self)
    }

    /// Sets the reported travel bearing, measured clockwise from north.
    pub fn with_bearing(mut self, bearing: Bearing) -> Self {
        self.bearing = Some(bearing);
        self
    }

    /// The observation timestamp.
    pub fn timestamp(self) -> Timestamp {
        self.timestamp
    }

    /// The observed coordinate.
    pub fn coordinate(self) -> Coordinate {
        self.coordinate
    }

    /// Altitude in meters, if reported.
    pub fn altitude(self) -> Option<f64> {
        self.altitude
    }

    /// Speed in meters per second, if reported.
    pub fn speed(self) -> Option<f64> {
        self.speed
    }

    /// Horizontal accuracy in meters, if reported.
    pub fn accuracy(self) -> Option<f64> {
        self.accuracy
    }

    /// Travel bearing (clockwise from north), if reported.
    pub fn bearing(self) -> Option<Bearing> {
        self.bearing
    }

    /// Validates all numeric fields for finiteness; used by [`Track::new`].
    pub(crate) fn validate(&self, index: usize) -> Result<(), TrackError> {
        if let Some(value) = self.altitude
            && !value.is_finite()
        {
            return Err(TrackError::InvalidValue {
                index,
                field: TrackField::Altitude,
                value,
            });
        }
        if let Some(value) = self.speed
            && !value.is_finite()
        {
            return Err(TrackError::InvalidValue {
                index,
                field: TrackField::Speed,
                value,
            });
        }
        if let Some(value) = self.accuracy
            && !value.is_finite()
        {
            return Err(TrackError::InvalidValue {
                index,
                field: TrackField::Accuracy,
                value,
            });
        }
        Ok(())
    }
}
