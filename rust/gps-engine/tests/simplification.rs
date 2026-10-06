// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! RDP simplification.

use gps_engine::geo::Coordinate;
use gps_engine::units::{Distance, Timestamp};
use gps_engine::{SimplifyConfig, Track, TrackPoint};

fn point(ms: i64, lat: f64, lon: f64) -> TrackPoint {
    TrackPoint::new(
        Timestamp::from_unix_ms(ms),
        Coordinate::new(lat, lon).unwrap(),
    )
}

#[test]
fn straight_line_collapses_to_endpoints() {
    let mut pts = Vec::new();
    for i in 0..10 {
        pts.push(point(i * 1_000, i as f64 * 0.001, 0.0));
    }
    let track = Track::new(pts).unwrap();
    let simplified = track.simplify(&SimplifyConfig::default());
    assert_eq!(simplified.points().len(), 2);
    assert_eq!(simplified.start(), track.start());
    assert_eq!(simplified.end(), track.end());
}

#[test]
fn sharp_turn_is_preserved() {
    // L-shaped route: corner at (1, 0) is far from the straight chord.
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.001, 0.0),
        point(2_000, 0.001, 0.001),
    ])
    .unwrap();

    let tight = SimplifyConfig {
        tolerance: Distance::from_meters(0.5),
    };
    let simplified = track.simplify(&tight);
    assert_eq!(
        simplified.points().len(),
        3,
        "tight tolerance keeps the corner"
    );
    assert_eq!(
        simplified.points()[1].coordinate(),
        Coordinate::new(0.001, 0.0).unwrap()
    );

    let loose = SimplifyConfig {
        tolerance: Distance::from_meters(100.0),
    };
    let collapsed = track.simplify(&loose);
    assert_eq!(
        collapsed.points().len(),
        2,
        "loose tolerance drops the corner"
    );
}

#[test]
fn timestamps_are_preserved() {
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.001, 0.0),
        point(2_000, 0.002, 0.0),
    ])
    .unwrap();
    let simplified = track.simplify(&SimplifyConfig::default());
    let kept: Vec<i64> = simplified
        .points()
        .iter()
        .map(|p| p.timestamp().unix_ms())
        .collect();
    assert!(
        kept.iter().all(|&t| t % 1000 == 0),
        "kept points must be original points"
    );
}

#[test]
fn two_point_track_is_unchanged() {
    let track = Track::new(vec![point(0, 0.0, 0.0), point(1_000, 0.01, 0.0)]).unwrap();
    let simplified = track.simplify(&SimplifyConfig::default());
    assert_eq!(simplified.points().len(), 2);
    assert_eq!(simplified, track);
}
