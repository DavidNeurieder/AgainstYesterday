// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Track model validation and accessors.

use gps_engine::geo::Coordinate;
use gps_engine::units::Timestamp;
use gps_engine::{Track, TrackError, TrackField, TrackPoint};

fn point(ms: i64, lat: f64, lon: f64) -> TrackPoint {
    TrackPoint::new(
        Timestamp::from_unix_ms(ms),
        Coordinate::new(lat, lon).unwrap(),
    )
}

#[test]
fn empty_track_is_rejected() {
    assert_eq!(Track::new(vec![]), Err(TrackError::Empty));
}

#[test]
fn single_point_track_is_rejected() {
    assert_eq!(
        Track::new(vec![point(0, 1.0, 1.0)]),
        Err(TrackError::TooFewPoints(1))
    );
}

#[test]
fn valid_track_is_accepted() {
    let track = Track::new(vec![point(0, 1.0, 1.0), point(1000, 2.0, 2.0)]).unwrap();
    assert_eq!(track.len(), 2);
    assert!(!track.is_empty());
    assert_eq!(
        track.start().unwrap().timestamp(),
        Timestamp::from_unix_ms(0)
    );
    assert_eq!(
        track.end().unwrap().timestamp(),
        Timestamp::from_unix_ms(1000)
    );
}

#[test]
fn decreasing_timestamps_are_rejected() {
    let err = Track::new(vec![point(1000, 1.0, 1.0), point(500, 2.0, 2.0)]).unwrap_err();
    assert!(matches!(err, TrackError::NonMonotonicTimestamp(1)));
}

#[test]
fn equal_timestamps_are_allowed() {
    // Duplicate timestamps pass construction and are left for the filtering
    // phase to resolve.
    Track::new(vec![point(1000, 1.0, 1.0), point(1000, 2.0, 2.0)]).unwrap();
}

#[test]
fn non_finite_altitude_is_rejected() {
    let err = point(0, 1.0, 1.0)
        .with_altitude(f64::NAN)
        .expect_err("NaN altitude must fail");
    assert!(matches!(
        err,
        TrackError::InvalidValue {
            field: TrackField::Altitude,
            ..
        }
    ));
}

#[test]
fn non_finite_speed_is_rejected() {
    let err = point(0, 1.0, 1.0)
        .with_speed(f64::NEG_INFINITY)
        .expect_err("infinite speed must fail");
    assert!(matches!(
        err,
        TrackError::InvalidValue {
            field: TrackField::Speed,
            ..
        }
    ));
}

#[test]
fn optional_fields_round_trip() {
    let p = point(0, 1.0, 1.0)
        .with_altitude(42.0)
        .unwrap()
        .with_speed(3.1)
        .unwrap()
        .with_accuracy(4.2)
        .unwrap();
    assert_eq!(p.altitude(), Some(42.0));
    assert_eq!(p.speed(), Some(3.1));
    assert_eq!(p.accuracy(), Some(4.2));
}

#[test]
fn duration_is_last_minus_first() {
    let track = Track::new(vec![point(0, 1.0, 1.0), point(90_000, 2.0, 2.0)]).unwrap();
    assert!((track.duration().as_secs() - 90.0).abs() < 1e-9);
}

#[test]
fn points_are_not_mutably_exposed() {
    let track = Track::new(vec![point(0, 1.0, 1.0), point(1000, 2.0, 2.0)]).unwrap();
    let got: Vec<_> = track.points().iter().map(|p| p.coordinate()).collect();
    assert_eq!(got.len(), 2);
}
