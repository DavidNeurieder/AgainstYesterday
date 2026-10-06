// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Distance resampling.

use gps_engine::geo::{Coordinate, distance};
use gps_engine::units::{Distance, Timestamp};
use gps_engine::{Track, TrackError, TrackPoint};

fn point(ms: i64, lat: f64, lon: f64) -> TrackPoint {
    TrackPoint::new(
        Timestamp::from_unix_ms(ms),
        Coordinate::new(lat, lon).unwrap(),
    )
}

#[test]
fn regular_spacing_along_a_straight_line() {
    // ~1112 m meridian, resampled every 100 m.
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(60_000, 0.005, 0.0),
        point(120_000, 0.01, 0.0),
    ])
    .unwrap();
    let total = track.distance().meters();

    let resampled = track
        .resample_by_distance(Distance::from_meters(100.0))
        .unwrap();

    // First point is the start, last point is the true end.
    assert_eq!(
        resampled.start().unwrap().coordinate(),
        track.start().unwrap().coordinate()
    );
    assert_eq!(
        resampled.end().unwrap().coordinate(),
        track.end().unwrap().coordinate()
    );

    // Interior points sit at multiples of the interval along the track; the
    // final point is the true endpoint at `total`.
    let start_coord = resampled.start().unwrap().coordinate();
    let mut last = start_coord;
    for (i, p) in resampled.points().iter().enumerate().skip(1) {
        let d = distance(last, p.coordinate()).meters();
        assert!(d > 0.0 && d <= 150.0, "unexpected step {d} m");
        let is_final = i == resampled.points().len() - 1;
        let expected = if is_final { total } else { i as f64 * 100.0 };
        let along = distance(start_coord, p.coordinate()).meters();
        assert!(
            (along - expected).abs() < 1.0,
            "point {i} at {along} m, expected {expected}"
        );
        last = p.coordinate();
    }

    // Resampled length ≈ original length.
    assert!((resampled.distance().meters() - total).abs() < 5.0);
    // Timestamps are non-decreasing.
    for pair in resampled.points().windows(2) {
        assert!(pair[1].timestamp() >= pair[0].timestamp());
    }
}

#[test]
fn irregular_input_is_interpolated() {
    // A very sparse but valid input still yields spacing.
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(300_000, 0.02, 0.0), // 2.2 km away
    ])
    .unwrap();

    let resampled = track
        .resample_by_distance(Distance::from_meters(500.0))
        .unwrap();
    let interior = resampled.points().len() - 2;
    assert!(
        interior >= 3,
        "expected several interior samples, got {interior}"
    );
    for p in resampled.points().iter().skip(1).take(interior) {
        assert!(
            p.altitude().is_none(),
            "interpolated points carry no sensor fields"
        );
    }
}

#[test]
fn duplicate_points_are_tolerated() {
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.0, 0.0), // duplicate coordinate
        point(2_000, 0.005, 0.0),
        point(60_000, 0.01, 0.0),
    ])
    .unwrap();
    let resampled = track
        .resample_by_distance(Distance::from_meters(50.0))
        .unwrap();
    assert!(resampled.points().len() >= 2);
    assert!(resampled.duration().as_secs() >= track.duration().as_secs() - 0.01);
}

#[test]
fn short_track_keeps_endpoints() {
    let track = Track::new(vec![point(0, 0.0, 0.0), point(60_000, 0.001, 0.0)]).unwrap();
    // Interval larger than the whole track.
    let resampled = track
        .resample_by_distance(Distance::from_meters(10_000.0))
        .unwrap();
    assert_eq!(resampled.points().len(), 2);
    assert_eq!(
        resampled.end().unwrap().coordinate(),
        track.end().unwrap().coordinate()
    );
}

#[test]
fn invalid_intervals_are_rejected() {
    let track = Track::new(vec![point(0, 0.0, 0.0), point(1_000, 0.01, 0.0)]).unwrap();
    assert!(matches!(
        track.resample_by_distance(Distance::from_meters(0.0)),
        Err(TrackError::InvalidInterval(_))
    ));
    assert!(matches!(
        track.resample_by_distance(Distance::from_meters(-5.0)),
        Err(TrackError::InvalidInterval(_))
    ));
    assert!(matches!(
        track.resample_by_distance(Distance::from_meters(f64::NAN)),
        Err(TrackError::InvalidInterval(_))
    ));
}
