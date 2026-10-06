// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests for `Attempt` invariants (§32).
//!
//! The coverage curve that `from_track` builds must always be monotonic, and
//! its query functions (`time_at`, `distance_at`) must be monotonic and stay
//! within the route's bounds.

use gps_engine::geo::Coordinate;
use gps_engine::units::{Distance, Duration, Timestamp};
use gps_engine::{Attempt, Route, Track, TrackPoint};
use proptest::prelude::*;

fn coord() -> impl Strategy<Value = Coordinate> {
    (-0.05f64..0.05, -0.05f64..0.05)
        .prop_map(|(lat, lon)| Coordinate::new(lat, lon).expect("in range"))
}

fn route() -> impl Strategy<Value = Route> {
    proptest::collection::vec(coord(), 2..=6)
        .prop_map(|coords| Route::new(coords).expect("valid route"))
}

fn track() -> impl Strategy<Value = Track> {
    proptest::collection::vec(coord(), 2..=12).prop_map(|coords| {
        let pts = coords
            .into_iter()
            .enumerate()
            .map(|(i, c)| TrackPoint::new(Timestamp::from_unix_ms((i * 2_000) as i64), c))
            .collect();
        Track::new(pts).expect("valid track")
    })
}

proptest! {
    #[test]
    fn coverage_curve_is_monotonic(t in track(), r in route()) {
        let attempt = Attempt::from_track(&t, &r);
        let mut prev_d = f64::NEG_INFINITY;
        let mut prev_e = f64::NEG_INFINITY;
        for s in &attempt.samples {
            prop_assert!(s.distance.meters() + 1e-9 >= prev_d, "distance went backwards");
            prop_assert!(s.elapsed.as_secs() + 1e-9 >= prev_e, "elapsed went backwards");
            prev_d = s.distance.meters();
            prev_e = s.elapsed.as_secs();
        }
    }

    #[test]
    fn attempt_stays_within_route(t in track(), r in route()) {
        let attempt = Attempt::from_track(&t, &r);
        let len = r.length().meters();
        prop_assert!(attempt.distance.meters() <= len + 1e-9, "coverage exceeds route");
        prop_assert!(attempt.distance.meters() >= 0.0);
        prop_assert_eq!(
            attempt.elapsed_time,
            attempt.samples.last().expect("non-empty").elapsed
        );
    }

    #[test]
    fn time_at_is_monotonic(t in track(), r in route(), a in 0.0f64..1.0, b in 0.0f64..1.0) {
        let attempt = Attempt::from_track(&t, &r);
        let max = attempt.distance.meters();
        let (d1, d2) = (a * max, b * max);
        let (t1, t2) = (attempt.time_at(Distance::from_meters(d1)), attempt.time_at(Distance::from_meters(d2)));
        if let (Some(x), Some(y)) = (t1, t2) {
            if d1 <= d2 {
                prop_assert!(x.as_secs() <= y.as_secs() + 1e-9, "time_at must be non-decreasing");
            } else {
                prop_assert!(x.as_secs() >= y.as_secs() - 1e-9, "time_at must be non-increasing in reverse");
            }
        }
    }

    #[test]
    fn distance_at_is_monotonic_and_bounded(t in track(), r in route()) {
        let attempt = Attempt::from_track(&t, &r);
        let end = attempt.elapsed_time.as_secs();
        let len = r.length().meters();
        let mut prev = f64::NEG_INFINITY;
        for i in 0..=10 {
            let e = Duration::from_secs(end * i as f64 / 10.0);
            let d = attempt.distance_at(e).expect("in-range time");
            prop_assert!(d.meters() + 1e-9 >= prev, "distance_at went backwards");
            prop_assert!(d.meters() <= len + 1e-9);
            prev = d.meters();
        }
        // Before the start there is nothing; past the finish it is terminal.
        prop_assert!(attempt.distance_at(Duration::from_secs(-1.0)).is_none());
        prop_assert_eq!(
            attempt.distance_at(Duration::from_secs(end + 100.0)),
            Some(attempt.distance)
        );
    }
}
