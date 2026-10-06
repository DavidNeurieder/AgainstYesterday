// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Typed errors for the engine.
//!
//! Constructors validate their input and return explicit errors; the engine
//! never panics on malformed data.

use std::fmt;

use thiserror::Error;

/// The optional fields of a [`crate::TrackPoint`] that refer to a numeric
/// observation, used to report which value failed validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackField {
    /// Altitude in meters.
    Altitude,
    /// GPS-reported speed in meters per second.
    Speed,
    /// Horizontal accuracy in meters.
    Accuracy,
}

impl fmt::Display for TrackField {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TrackField::Altitude => write!(f, "altitude"),
            TrackField::Speed => write!(f, "speed"),
            TrackField::Accuracy => write!(f, "accuracy"),
        }
    }
}

/// Errors produced by geographic primitives.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum GeoError {
    /// Latitude outside `[-90, 90]`.
    #[error("latitude {0} is out of range [-90, 90]")]
    LatitudeOutOfRange(f64),
    /// Longitude outside `[-180, 180]`.
    #[error("longitude {0} is out of range [-180, 180]")]
    LongitudeOutOfRange(f64),
    /// A value that must be finite is NaN or infinite.
    #[error("non-finite {0}")]
    NonFinite(&'static str),
}

/// Errors produced when constructing or validating a [`crate::Track`].
#[derive(Debug, Clone, PartialEq, Error)]
pub enum TrackError {
    /// The track has no points at all.
    #[error("track contains no points")]
    Empty,
    /// The track has fewer than two points, so distance cannot be computed.
    #[error("track requires at least two points, got {0}")]
    TooFewPoints(usize),
    /// Timestamps are not monotonically (non-decreasing) ordered.
    #[error("timestamp at index {0} violates monotonic ordering")]
    NonMonotonicTimestamp(usize),
    /// A point carries a non-finite numeric observation.
    #[error("point at index {index} has {field} value {value} which is not finite")]
    InvalidValue {
        /// 0-based index of the offending point.
        index: usize,
        /// Which field was invalid.
        field: TrackField,
        /// The offending value.
        value: f64,
    },
    /// A resampling interval that is not finite and positive.
    #[error("resampling interval {0} m must be finite and positive")]
    InvalidInterval(f64),
}

/// Errors produced when reading a GPX file into a [`crate::Track`].
#[derive(Debug, Clone, PartialEq, Error)]
pub enum GpxError {
    /// The reader failed; the message is the underlying I/O error text.
    #[error("I/O error while reading GPX: {0}")]
    Io(String),
    /// The document is not well-formed XML or violates the GPX structure.
    #[error("invalid GPX: {0}")]
    Parse(String),
    /// A `<trkpt>` element is missing or has a non-numeric `lat`/`lon` attribute.
    #[error("invalid coordinate in GPX: {0}")]
    Coordinate(String),
    /// An `ele`/`speed`/`accuracy` value is not a finite number.
    #[error("point {index} has {field} value \"{value}\" which is not a finite number")]
    InvalidValue {
        /// 0-based index of the offending point.
        index: usize,
        /// Which extension or standard field was invalid.
        field: TrackField,
        /// The offending text.
        value: String,
    },
    /// A `<time>` value is not a parseable UTC or timezone-qualified
    /// RFC 3339 timestamp.
    #[error("point {index} has invalid time \"{value}\": {reason}")]
    InvalidTime {
        /// 0-based index of the offending point.
        index: usize,
        /// The offending text.
        value: String,
        /// Why the timestamp could not be parsed.
        reason: String,
    },
    /// The resulting point set violates [`crate::Track::new`] invariants.
    #[error("invalid track produced from GPX: {0}")]
    Track(#[from] TrackError),
}

/// Errors produced when constructing a [`crate::Route`].
#[derive(Debug, Clone, PartialEq, Error)]
pub enum RouteError {
    /// The route has no geometry at all.
    #[error("route contains no points")]
    Empty,
    /// The route has fewer than two points, so length cannot be computed.
    #[error("route requires at least two points, got {0}")]
    TooFewPoints(usize),
}

/// Errors produced when ingesting raw GPS samples (M15 [`crate::gps`]).
#[derive(Debug, Clone, PartialEq, Error)]
pub enum GpsError {
    /// A trace needs at least two fixes to define movement.
    #[error("gps trace requires at least two fixes, got {0}")]
    TooFewFixes(usize),
    /// The trace has no usable fixes left after normalizing/filtering.
    #[error("gps trace has no usable fixes after processing")]
    NoUsableTrack,
    /// The trace produced a [`crate::Track`] that violated its invariants.
    #[error("invalid track produced from gps trace: {0}")]
    Track(#[from] TrackError),
    /// A fixture document was not well-formed JSON or violated the schema.
    #[error("invalid gps fixture: {0}")]
    Fixture(String),
}
