// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPS filtering: spikes, bad accuracy, fast movement, time gaps.

use gps_engine::geo::Coordinate;
use gps_engine::units::{Distance, Duration, Speed, Timestamp};
use gps_engine::{FilterConfig, Track, TrackPoint};

fn point(ms: i64, lat: f64, lon: f64) -> TrackPoint {
    TrackPoint::new(
        Timestamp::from_unix_ms(ms),
        Coordinate::new(lat, lon).unwrap(),
    )
}

#[test]
fn obvious_gps_jump_is_removed() {
    // p2 is a single ~111 km outlier; its ~11 m neighbours are legitimate.
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.0001, 0.0),
        point(2_000, 1.0, 0.0),
        point(3_000, 0.0002, 0.0),
    ])
    .unwrap();

    let (filtered, report) = track.filter(&FilterConfig::default());

    assert_eq!(report.input_points, 4);
    assert_eq!(report.output_points, 3);
    assert_eq!(report.removed_points, 1);
    assert_eq!(filtered.points().len(), 3);
    // The outlier (lat 1.0) is gone; its neighbours are untouched.
    let kept: Vec<f64> = filtered
        .points()
        .iter()
        .map(|p| p.coordinate().latitude())
        .collect();
    assert!(!kept.contains(&1.0));
    assert_eq!(kept[0], 0.0);
    assert_eq!(kept[2], 0.0002);
}

#[test]
fn bad_accuracy_point_is_removed() {
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        TrackPoint::new(
            Timestamp::from_unix_ms(1_000),
            Coordinate::new(0.001, 0.0).unwrap(),
        )
        .with_accuracy(300.0)
        .unwrap(),
        point(2_000, 0.002, 0.0),
    ])
    .unwrap();

    let (filtered, report) = track.filter(&FilterConfig::default());
    assert_eq!(report.removed_points, 1);
    assert_all_points_accuracy_none_or_ok(&filtered);
}

fn assert_all_points_accuracy_none_or_ok(track: &Track) {
    for p in track.points() {
        if let Some(a) = p.accuracy() {
            assert!(a <= 50.0, "accuracy {a} should have been filtered");
        }
    }
}

#[test]
fn reported_too_fast_point_is_removed() {
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        TrackPoint::new(
            Timestamp::from_unix_ms(1_000),
            Coordinate::new(0.001, 0.0).unwrap(),
        )
        .with_speed(100.0)
        .unwrap(),
        point(2_000, 0.002, 0.0),
    ])
    .unwrap();

    let (filtered, _) = track.filter(&FilterConfig::default());
    assert_eq!(filtered.points().len(), 2);
}

#[test]
fn legitimate_fast_cycling_is_kept() {
    // 15 m/s ≈ 54 km/h: well below the 90 km/h threshold.
    let mut pts = Vec::new();
    let mut ms = 0;
    let dt_s = 1.0;
    for i in 0..10 {
        let lat = 0.0 + 15.0 * dt_s * (i as f64) / 111_195.0;
        pts.push(point(ms, lat, 0.0));
        ms += (dt_s * 1000.0) as i64;
    }
    let track = Track::new(pts).unwrap();
    let (filtered, report) = track.filter(&FilterConfig::default());
    assert_eq!(report.removed_points, 0, "cycling must not be filtered");
    assert_eq!(filtered.points().len(), 10);
}

#[test]
fn large_time_gap_is_not_a_jump() {
    // The same GPS area before and after a 2-hour pause: no jump should be
    // flagged across the gap (max_time_gap is 60 s, so 7200 s is a pause).
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.0001, 0.0),
        point(7_201_000, 0.0002, 0.0),
        point(7_202_000, 0.0003, 0.0),
    ])
    .unwrap();

    let (filtered, report) = track.filter(&FilterConfig::default());
    assert_eq!(report.removed_points, 0);
    assert_eq!(filtered.points().len(), 4);
}

#[test]
fn endpoints_always_survive() {
    let track = Track::new(vec![
        TrackPoint::new(
            Timestamp::from_unix_ms(0),
            Coordinate::new(0.0, 0.0).unwrap(),
        )
        .with_accuracy(999.0)
        .unwrap(),
        point(1_000, 0.0001, 0.0),
        TrackPoint::new(
            Timestamp::from_unix_ms(2_000),
            Coordinate::new(0.0002, 0.0).unwrap(),
        )
        .with_accuracy(999.0)
        .unwrap(),
    ])
    .unwrap();

    let (filtered, report) = track.filter(&FilterConfig::default());
    assert_eq!(report.removed_points, 0, "endpoints are never removed");
    assert_eq!(filtered.points().len(), 3);
}

#[test]
fn disabled_options_filter_nothing() {
    let config = FilterConfig {
        max_accuracy: None,
        max_speed: None,
        max_jump: None,
        max_time_gap: None,
    };
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.01, 0.0),
        point(2_000, 0.02, 0.0),
    ])
    .unwrap();
    let (filtered, report) = track.filter(&config);
    assert_eq!(report.removed_points, 0);
    assert_eq!(filtered.points().len(), track.len());
}

#[test]
fn report_tracks_distance_change() {
    fn cfg() -> FilterConfig {
        FilterConfig {
            max_accuracy: None,
            max_speed: Some(Speed::from_kmh(20.0)),
            max_jump: Some(Distance::from_meters(100.0)),
            max_time_gap: Some(Duration::from_secs(60.0)),
        }
    }
    // A huge excursion point adds significant bogus distance. The gentle
    // ~3 m steps approach the outlier below the 20 km/h speed cap.
    let track = Track::new(vec![
        point(0, 0.0, 0.0),
        point(1_000, 0.00003, 0.0),
        point(2_000, 1.0, 0.0),
        point(3_000, 0.00006, 0.0),
    ])
    .unwrap();
    let (filtered, report) = track.filter(&cfg());
    assert_eq!(report.removed_points, 1);
    assert!(report.distance_before.meters() > report.distance_after.meters());
    assert!(filtered.distance().meters() < report.distance_before.meters());
    assert_eq!(report.input_points, 4);
    assert_eq!(report.output_points, 3);
}
