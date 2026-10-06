// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Track statistics: distance, durations, elevation, speeds.

use gps_engine::geo::Coordinate;
use gps_engine::units::Timestamp;
use gps_engine::{MovingConfig, Speed, Track, TrackPoint};

const DEG_M: f64 = std::f64::consts::PI / 180.0 * 6_371_008.8;

fn point(ms: i64, lat: f64, alt: Option<f64>) -> TrackPoint {
    let p = TrackPoint::new(
        Timestamp::from_unix_ms(ms),
        Coordinate::new(lat, 0.0).unwrap(),
    );
    match alt {
        Some(a) => p.with_altitude(a).unwrap(),
        None => p,
    }
}

#[test]
fn distance_is_known() {
    // Two 1° meridian steps.
    let track = Track::new(vec![
        point(0, 0.0, None),
        point(60_000, 1.0, None),
        point(120_000, 2.0, None),
    ])
    .unwrap();
    assert!((track.distance().meters() - 2.0 * DEG_M).abs() < 1e-6);
}

#[test]
fn durations_elapsed_vs_moving() {
    let track = Track::new(vec![
        point(0, 0.0, None),
        point(60_000, 1.0, None),        // 60 s of genuine movement
        point(600_000, 1.000_001, None), // 540 s of nearly-zero movement
    ])
    .unwrap();
    let cfg = MovingConfig::default();
    assert!((track.duration().as_secs() - 600.0).abs() < 1e-9);
    // The long, slow gap (≈0.0002 m/s) is a stop.
    assert!((track.moving_duration(&cfg).as_secs() - 60.0).abs() < 1e-9);
    assert!((track.paused_duration(&cfg).as_secs() - 540.0).abs() < 1e-9);
}

#[test]
fn short_gaps_always_count_as_moving() {
    // A 2 s standstill is below min_stop_duration and still counts as moving.
    let track = Track::new(vec![
        point(0, 0.0, None),
        point(60_000, 1.0, None),
        point(62_000, 1.0, None),
    ])
    .unwrap();
    let cfg = MovingConfig::default();
    assert!((track.moving_duration(&cfg).as_secs() - 62.0).abs() < 1e-9);
}

#[test]
fn elevation_gain_and_loss() {
    let track = Track::new(vec![
        point(0, 0.0, Some(100.0)),
        point(60_000, 1.0, Some(120.0)),
        point(120_000, 2.0, Some(90.0)),
        point(180_000, 3.0, Some(105.0)),
    ])
    .unwrap();
    assert!((track.elevation_gain() - 35.0).abs() < 1e-9); // +20, +15
    assert!((track.elevation_loss() - 30.0).abs() < 1e-9); // -30
}

#[test]
fn elevation_ignores_missing_altitude() {
    let track = Track::new(vec![
        point(0, 0.0, None),
        point(60_000, 1.0, Some(50.0)),
        point(120_000, 2.0, None),
    ])
    .unwrap();
    assert!((track.elevation_gain() - 0.0).abs() < 1e-12);
    assert!((track.elevation_loss() - 0.0).abs() < 1e-12);
}

#[test]
fn average_and_moving_speed() {
    let track = Track::new(vec![
        point(0, 0.0, None),
        point(60_000, 1.0, None),
        point(480_000, 1.000_001, None), // long stop
    ])
    .unwrap();
    // Average speed = full distance over elapsed time.
    let expected = track.distance().meters() / 480.0;
    assert!((track.average_speed().mps() - expected).abs() < 1e-9);

    let cfg = MovingConfig::default();
    let expected_moving = track.distance().meters() / 60.0;
    assert!((track.moving_speed(&cfg).mps() - expected_moving).abs() < 1e-9);
}

#[test]
fn zero_length_track_has_zero_speed() {
    let track = Track::new(vec![point(0, 5.0, None), point(60_000, 5.0, None)]).unwrap();
    assert!(track.distance().meters() < 1e-9);
    assert!(track.average_speed() == Speed::ZERO);
    assert!(track.moving_duration(&MovingConfig::default()).as_secs() < 1e-9);
}
