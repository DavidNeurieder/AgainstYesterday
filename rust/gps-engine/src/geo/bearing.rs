// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use std::fmt;

use super::coordinate::Coordinate;
use crate::error::GeoError;

/// A compass direction measured clockwise from north, stored as radians in
/// `[0, 2π)`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bearing(f64);

impl Bearing {
    /// North.
    pub const NORTH: Bearing = Bearing(0.0);

    /// Constructs a bearing from radians, normalizing into `[0, 2π)`.
    ///
    /// Returns [`GeoError::NonFinite`] for NaN/∞ input.
    pub fn from_radians(radians: f64) -> Result<Self, GeoError> {
        if !radians.is_finite() {
            return Err(GeoError::NonFinite("bearing"));
        }
        Ok(Bearing(radians.rem_euclid(std::f64::consts::TAU)))
    }

    /// Constructs a bearing from compass degrees.
    pub fn from_degrees(degrees: f64) -> Result<Self, GeoError> {
        Self::from_radians(degrees.to_radians())
    }

    /// The bearing in radians, in `[0, 2π)`.
    pub fn as_radians(self) -> f64 {
        self.0
    }

    /// The bearing in compass degrees, in `[0, 360)`.
    pub fn as_degrees(self) -> f64 {
        self.0.to_degrees().rem_euclid(360.0)
    }
}

impl fmt::Display for Bearing {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.1}°", self.as_degrees())
    }
}

/// The initial bearing (great-circle direction) from `a` towards `b`,
/// measured clockwise from north.
pub fn bearing(a: Coordinate, b: Coordinate) -> Result<Bearing, GeoError> {
    let d_lon = (b.longitude() - a.longitude()).to_radians();
    let lat1 = a.latitude().to_radians();
    let lat2 = b.latitude().to_radians();

    let y = d_lon.sin() * lat2.cos();
    let x = lat1.cos() * lat2.sin() - lat1.sin() * lat2.cos() * d_lon.cos();
    Bearing::from_radians(y.atan2(x))
}
