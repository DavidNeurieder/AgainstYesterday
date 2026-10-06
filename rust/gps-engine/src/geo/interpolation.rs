// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use super::coordinate::Coordinate;

/// Linearly interpolates between two coordinates in lat/lon space.
///
/// `fraction` is clamped to `[0, 1]`; `0.0` returns `a` exactly, `1.0` returns
/// `b` exactly, and `0.5` returns the coordinate midpoint.
pub fn interpolate(a: Coordinate, b: Coordinate, fraction: f64) -> Coordinate {
    let t = fraction.clamp(0.0, 1.0);
    let latitude = a.latitude() + (b.latitude() - a.latitude()) * t;
    let longitude = a.longitude() + (b.longitude() - a.longitude()) * t;
    Coordinate::new(latitude, longitude).expect("interpolation stays within coordinate bounds")
}
