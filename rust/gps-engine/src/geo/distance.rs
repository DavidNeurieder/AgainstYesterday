// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use super::bearing::Bearing;
use super::coordinate::Coordinate;
use crate::units::Distance;

/// Mean earth radius in meters (IUGG).
pub const EARTH_RADIUS_METERS: f64 = 6_371_008.8;

/// Great-circle distance between two coordinates using the haversine formula.
///
/// Computed on a spherical earth model; sufficiently accurate for GPS-scale
/// activities where the error against an ellipsoidal model is well under a
/// meter.
pub fn distance(a: Coordinate, b: Coordinate) -> Distance {
    let lat1 = a.latitude().to_radians();
    let lat2 = b.latitude().to_radians();
    let d_lat = lat2 - lat1;
    let d_lon = (b.longitude() - a.longitude()).to_radians();

    let h = (d_lat / 2.0).sin().powi(2) + lat1.cos() * lat2.cos() * (d_lon / 2.0).sin().powi(2);
    let h = h.clamp(0.0, 1.0);
    let central_angle = 2.0 * h.sqrt().atan2((1.0 - h).sqrt());

    Distance::from_meters(EARTH_RADIUS_METERS * central_angle)
}

/// The coordinate reached by starting at `start` and travelling `dist` meters
/// along initial bearing `bearing` on the sphere.
pub fn destination(start: Coordinate, bearing: Bearing, dist: Distance) -> Coordinate {
    let angular = dist.meters() / EARTH_RADIUS_METERS;
    let theta = bearing.as_radians();
    let phi1 = start.latitude().to_radians();
    let lambda1 = start.longitude().to_radians();

    let sin_phi2 = phi1.sin() * angular.cos() + phi1.cos() * angular.sin() * theta.cos();
    let phi2 = sin_phi2.asin();
    let lambda2 = lambda1
        + (theta.sin() * angular.sin() * phi1.cos()).atan2(angular.cos() - phi1.sin() * phi2.sin());

    let latitude = phi2.to_degrees().clamp(-90.0, 90.0);
    let longitude = (lambda2.to_degrees() + 540.0).rem_euclid(360.0) - 180.0;
    Coordinate::new(latitude, longitude).expect("destination output is always in range")
}
