// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests guarding geometric invariants.

use gps_engine::geo::{bearing, destination, distance, interpolate};
use gps_engine::units::Distance;
use gps_engine::{Bearing, Coordinate};
use proptest::prelude::*;

fn coord() -> impl Strategy<Value = Coordinate> {
    (-89.9f64..89.9, -180.0f64..180.0)
        .prop_map(|(lat, lon)| Coordinate::new(lat, lon).expect("strategy stays in range"))
}

proptest! {
    #[test]
    fn distance_is_symmetric(a in coord(), b in coord()) {
        let d1 = distance(a, b).meters();
        let d2 = distance(b, a).meters();
        prop_assert!((d1 - d2).abs() < 1e-9);
    }

    #[test]
    fn distance_to_self_is_zero(p in coord()) {
        prop_assert!((distance(p, p).meters()).abs() < 1e-9);
    }

    #[test]
    fn triangle_inequality(a in coord(), b in coord(), c in coord()) {
        let ab = distance(a, b).meters();
        let bc = distance(b, c).meters();
        let ac = distance(a, c).meters();
        prop_assert!(ac <= ab + bc + 1.0);
    }

    #[test]
    fn destination_distance_is_preserved(
        start in coord(),
        degrees in 0.0f64..360.0,
        meters in 0.0f64..200_000.0,
    ) {
        let brg = Bearing::from_degrees(degrees).unwrap();
        let expected = Distance::from_meters(meters);
        let arrived = destination(start, brg, expected);
        let actual = distance(start, arrived).meters();
        prop_assert!((actual - meters).abs() < meters * 1e-6 + 1e-6);
    }

    #[test]
    fn destination_round_trip_via_bearing(a in coord(), b in coord()) {
        let brg = bearing(a, b).unwrap();
        let d = distance(a, b);
        let arrived = destination(a, brg, d);
        let err = distance(arrived, b).meters();
        prop_assert!(err < 1e-6);
    }

    #[test]
    fn interpolate_stays_between_coordinates(a in coord(), b in coord(), t in -2.0f64..3.0) {
        let p = interpolate(a, b, t);
        let min_lat = a.latitude().min(b.latitude()) - 1e-9;
        let max_lat = a.latitude().max(b.latitude()) + 1e-9;
        let min_lon = a.longitude().min(b.longitude()) - 1e-9;
        let max_lon = a.longitude().max(b.longitude()) + 1e-9;
        prop_assert!(p.latitude() >= min_lat && p.latitude() <= max_lat);
        prop_assert!(p.longitude() >= min_lon && p.longitude() <= max_lon);
    }

    #[test]
    fn bearing_normalized_to_full_circle(a in coord(), b in coord()) {
        let deg = bearing(a, b).unwrap().as_degrees();
        prop_assert!((0.0..360.0).contains(&deg));
    }
}
