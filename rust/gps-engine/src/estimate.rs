// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Uncertainty-aware estimation contracts.
//!
//! These types describe *what we believe* about a fix, separately from the raw
//! observation and from the distances derived from it. They are additive:
//! nothing in the current pipeline populates them yet, so installing this
//! module changes no numerical output. Later phases attach estimates to
//! processed samples, match steps and snapshots without replacing the raw
//! fields that make every decision auditable.
//!
//! Every numeric input is clamped on construction. A `NaN` confidence becomes
//! zero, a negative accuracy or speed becomes zero, and a covariance matrix is
//! forced to stay symmetric and positive semi-definite.

use crate::geo::{Bearing, Coordinate};
use crate::units::{Distance, Speed, Timestamp};

/// Statistical confidence in `0.0..=1.0`.
///
/// Kept separate from a receiver's reported accuracy: accuracy is a length in
/// meters, confidence is a bounded belief about an estimate. Constructing a
/// `Confidence` is the only way to obtain one, so downstream code cannot hold
/// an out-of-range value.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Confidence(f64);

impl Confidence {
    /// No confidence at all.
    pub const ZERO: Self = Self(0.0);
    /// Complete confidence.
    pub const ONE: Self = Self(1.0);

    /// Clamps `value` into `0.0..=1.0`; non-finite input becomes [`Self::ZERO`].
    pub fn new(value: f64) -> Self {
        Self(if value.is_finite() {
            value.clamp(0.0, 1.0)
        } else {
            0.0
        })
    }

    /// The clamped `0.0..=1.0` value.
    pub fn value(self) -> f64 {
        self.0
    }
}

/// A position with its reported accuracy and our confidence in it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PositionEstimate {
    timestamp: Timestamp,
    coordinate: Coordinate,
    accuracy: Distance,
    confidence: Confidence,
}

impl PositionEstimate {
    /// Builds an estimate, clamping non-finite or negative accuracy to zero.
    pub fn new(
        timestamp: Timestamp,
        coordinate: Coordinate,
        reported_accuracy: Distance,
        confidence: Confidence,
    ) -> Self {
        let meters = reported_accuracy.meters();
        let accuracy = if meters.is_finite() && meters > 0.0 {
            reported_accuracy
        } else {
            Distance::ZERO
        };
        Self {
            timestamp,
            coordinate,
            accuracy,
            confidence,
        }
    }

    /// Observation time this estimate refers to.
    pub fn timestamp(self) -> Timestamp {
        self.timestamp
    }

    /// Estimated position.
    pub fn coordinate(self) -> Coordinate {
        self.coordinate
    }

    /// The receiver-reported horizontal accuracy in meters (never negative).
    pub fn accuracy(self) -> Distance {
        self.accuracy
    }

    /// Our statistical confidence in this position.
    pub fn confidence(self) -> Confidence {
        self.confidence
    }
}

/// A 2×2 covariance in a local east/north tangent plane, in meters squared.
///
/// Used only when an estimator needs to express directional uncertainty. The
/// diagonals are clamped non-negative and the off-diagonal term is bounded by
/// Cauchy–Schwarz, so the matrix is always symmetric positive semi-definite.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TangentCovariance {
    east_east_m2: f64,
    east_north_m2: f64,
    north_north_m2: f64,
}

impl TangentCovariance {
    /// Builds a clamped covariance from the three unique matrix entries.
    pub fn new(east_east_m2: f64, east_north_m2: f64, north_north_m2: f64) -> Self {
        let east_east = finite_non_negative(east_east_m2);
        let north_north = finite_non_negative(north_north_m2);
        let limit = (east_east * north_north).sqrt();
        let east_north = if east_north_m2.is_finite() {
            east_north_m2.clamp(-limit, limit)
        } else {
            0.0
        };
        Self {
            east_east_m2: east_east,
            east_north_m2: east_north,
            north_north_m2: north_north,
        }
    }

    /// Variance along east, in meters squared.
    pub fn east_east(self) -> f64 {
        self.east_east_m2
    }

    /// Covariance between east and north, in meters squared.
    pub fn east_north(self) -> f64 {
        self.east_north_m2
    }

    /// Variance along north, in meters squared.
    pub fn north_north(self) -> f64 {
        self.north_north_m2
    }
}

/// A velocity with its confidence and optional local-plane covariance.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VelocityEstimate {
    speed: Speed,
    bearing: Option<Bearing>,
    confidence: Confidence,
    covariance: Option<TangentCovariance>,
}

impl VelocityEstimate {
    /// Builds a velocity estimate without a covariance.
    ///
    /// Non-finite or negative speed is clamped to [`Speed::ZERO`].
    pub fn new(speed: Speed, bearing: Option<Bearing>, confidence: Confidence) -> Self {
        let mps = speed.mps();
        let speed = if mps.is_finite() && mps > 0.0 {
            speed
        } else {
            Speed::ZERO
        };
        Self {
            speed,
            bearing,
            confidence,
            covariance: None,
        }
    }

    /// Attaches a local tangent-plane covariance.
    pub fn with_covariance(mut self, covariance: TangentCovariance) -> Self {
        self.covariance = Some(covariance);
        self
    }

    /// Estimated ground speed (never negative).
    pub fn speed(self) -> Speed {
        self.speed
    }

    /// Estimated travel bearing, when known.
    pub fn bearing(self) -> Option<Bearing> {
        self.bearing
    }

    /// Our statistical confidence in this velocity.
    pub fn confidence(self) -> Confidence {
        self.confidence
    }

    /// Directional uncertainty, when an estimator supplied one.
    pub fn covariance(self) -> Option<TangentCovariance> {
        self.covariance
    }
}

/// Whether the runner is believed to be moving, with a confidence.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MotionState {
    /// Moving; the payload rates the evidence.
    Moving(Confidence),
    /// Stationary; drift must not earn distance.
    Stationary(Confidence),
    /// Not enough evidence to choose.
    Unknown(Confidence),
}

impl MotionState {
    /// The confidence attached to the current classification.
    pub fn confidence(self) -> Confidence {
        match self {
            Self::Moving(c) | Self::Stationary(c) | Self::Unknown(c) => c,
        }
    }

    /// Whether this is a moving classification.
    pub fn is_moving(self) -> bool {
        matches!(self, Self::Moving(_))
    }

    /// Whether this is a stationary classification.
    pub fn is_stationary(self) -> bool {
        matches!(self, Self::Stationary(_))
    }

    /// Whether this state is explicitly unknown.
    pub fn is_unknown(self) -> bool {
        matches!(self, Self::Unknown(_))
    }
}

/// The three distance meanings the engine keeps distinct.
///
/// Each axis is optional: a free run has no route coverage, a route-only
/// consumer may have no filtered geodesic distance, and a diagnostic view may
/// expose only raw path length. Nothing is inferred here; callers supply the
/// axes that exist in their context.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct DistanceBreakdown {
    raw: Option<Distance>,
    filtered: Option<Distance>,
    route: Option<Distance>,
}

impl DistanceBreakdown {
    /// An empty breakdown with no known axes.
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the raw geodesic distance (non-finite or negative becomes zero).
    pub fn with_raw(mut self, raw: Distance) -> Self {
        self.raw = Some(finite_distance(raw));
        self
    }

    /// Sets the filtered ground distance (non-finite or negative becomes zero).
    pub fn with_filtered(mut self, filtered: Distance) -> Self {
        self.filtered = Some(finite_distance(filtered));
        self
    }

    /// Sets the monotone route coverage (non-finite or negative becomes zero).
    pub fn with_route(mut self, route: Distance) -> Self {
        self.route = Some(finite_distance(route));
        self
    }

    /// Raw geodesic distance, when this context has one.
    pub fn raw(self) -> Option<Distance> {
        self.raw
    }

    /// Filtered ground distance, when this context has one.
    pub fn filtered(self) -> Option<Distance> {
        self.filtered
    }

    /// Monotone route coverage, when this context has one.
    pub fn route(self) -> Option<Distance> {
        self.route
    }
}

fn finite_distance(value: Distance) -> Distance {
    let meters = value.meters();
    if meters.is_finite() && meters > 0.0 {
        value
    } else {
        Distance::ZERO
    }
}

fn finite_non_negative(value: f64) -> f64 {
    if value.is_finite() && value > 0.0 {
        value
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn coordinate() -> Coordinate {
        Coordinate::new(52.5, 13.4).expect("valid coordinate")
    }

    #[test]
    fn confidence_clamps_and_rejects_non_finite() {
        assert_eq!(Confidence::new(-0.5), Confidence::ZERO);
        assert_eq!(Confidence::new(1.5), Confidence::ONE);
        assert_eq!(Confidence::new(f64::NAN), Confidence::ZERO);
        assert_eq!(Confidence::new(f64::INFINITY), Confidence::ZERO);
        assert_eq!(Confidence::new(0.25).value(), 0.25);
    }

    #[test]
    fn position_estimate_is_always_finite() {
        let estimate = PositionEstimate::new(
            Timestamp::from_unix_ms(0),
            coordinate(),
            Distance::from_meters(f64::NAN),
            Confidence::new(f64::NAN),
        );
        assert_eq!(estimate.accuracy(), Distance::ZERO);
        assert_eq!(estimate.confidence(), Confidence::ZERO);
        let clipped = PositionEstimate::new(
            Timestamp::from_unix_ms(0),
            coordinate(),
            Distance::from_meters(-4.0),
            Confidence::new(2.0),
        );
        assert_eq!(clipped.accuracy(), Distance::ZERO);
        assert_eq!(clipped.confidence(), Confidence::ONE);
    }

    #[test]
    fn covariance_stays_symmetric_positive_semidefinite() {
        let covariance = TangentCovariance::new(16.0, 100.0, 9.0);
        assert_eq!(covariance.east_east(), 16.0);
        assert_eq!(covariance.north_north(), 9.0);
        assert!(covariance.east_north().abs() <= 12.0 + 1e-12);
        let broken = TangentCovariance::new(-1.0, f64::NAN, f64::INFINITY);
        assert_eq!(broken.east_east(), 0.0);
        assert_eq!(broken.east_north(), 0.0);
        assert_eq!(broken.north_north(), 0.0);
    }

    #[test]
    fn velocity_and_motion_state_clamp_and_report() {
        let velocity = VelocityEstimate::new(
            Speed::from_mps(f64::NEG_INFINITY),
            None,
            Confidence::new(0.5),
        );
        assert_eq!(velocity.speed(), Speed::ZERO);
        assert_eq!(velocity.confidence().value(), 0.5);
        assert!(velocity.covariance().is_none());

        let moving = MotionState::Moving(Confidence::new(1.2));
        assert!(moving.is_moving());
        assert!(!moving.is_stationary());
        assert_eq!(moving.confidence(), Confidence::ONE);
        assert!(MotionState::Unknown(Confidence::ZERO).is_unknown());
        assert!(MotionState::Stationary(Confidence::ONE).is_stationary());
    }

    #[test]
    fn distance_breakdown_keeps_only_supplied_axes() {
        let empty = DistanceBreakdown::new();
        assert_eq!(
            (empty.raw(), empty.filtered(), empty.route()),
            (None, None, None)
        );
        let full = DistanceBreakdown::new()
            .with_raw(Distance::from_meters(10.0))
            .with_filtered(Distance::from_meters(-1.0))
            .with_route(Distance::from_meters(f64::NAN));
        assert_eq!(full.raw(), Some(Distance::from_meters(10.0)));
        assert_eq!(full.filtered(), Some(Distance::ZERO));
        assert_eq!(full.route(), Some(Distance::ZERO));
    }
}
