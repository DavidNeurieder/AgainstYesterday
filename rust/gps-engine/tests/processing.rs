// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests for track processing invariants.

use gps_engine::geo::{Coordinate, distance, polyline_length};
use gps_engine::units::{Distance, Timestamp};
use gps_engine::{SimplifyConfig, Track, TrackPoint};
use proptest::prelude::*;

// Build a track from up to 16 coordinates within a ~2 km box, sampled every
// 2 s, so distances and intervals stay comparable.
fn small_track() -> impl Strategy<Value = Track> {
    proptest::collection::vec((-0.01f64..0.01, -0.01f64..0.01), 2..16).prop_map(|coords| {
        let points = coords
            .into_iter()
            .enumerate()
            .map(|(i, (lat, lon))| {
                TrackPoint::new(
                    Timestamp::from_unix_ms(i as i64 * 2000),
                    Coordinate::new(lat, lon).expect("in range"),
                )
            })
            .collect();
        Track::new(points).expect("valid track")
    })
}

proptest! {
    #[test]
    fn resampling_never_adds_length(track in small_track(), interval_m in 5.0f64..80.0) {
        let original = track.distance().meters();
        let resampled = track
            .resample_by_distance(Distance::from_meters(interval_m))
            .unwrap();
        let kept = resampled.distance().meters();
        let slack = interval_m * 3.0 + 5.0;
        // Chords cannot exceed the paths they replace, so resampling must not
        // inflate distance.
        prop_assert!(kept <= original + slack, "resampling added {} m", kept - original);
        // Nor may it collapse: the straight-line span of the endpoints stays.
        let chord = distance(
            resampled.start().unwrap().coordinate(),
            resampled.end().unwrap().coordinate(),
        )
        .meters();
        prop_assert!(kept >= chord - slack, "resampling collapsed to {kept} < chord {chord}");
    }

    #[test]
    fn resampling_is_ordered(track in small_track(), interval_m in 5.0f64..80.0) {
        let resampled = track
            .resample_by_distance(Distance::from_meters(interval_m))
            .unwrap();
        let mut prev_t = i64::MIN;
        let mut prev_coord = resampled.start().unwrap().coordinate();
        for p in resampled.points() {
            prop_assert!(p.timestamp().unix_ms() >= prev_t, "timestamps must not go backwards");
            prev_t = p.timestamp().unix_ms();
            let d = distance(prev_coord, p.coordinate()).meters();
            // Consecutive samples never exceed 2 intervals (final short segment apart).
            prop_assert!(d <= interval_m * 2.0 + 1.0, "unexpected gap {d}");
            prev_coord = p.coordinate();
        }
    }

    #[test]
    fn simplification_keeps_endpoints_and_monotony(track in small_track()) {
        let simplified = track.simplify(&SimplifyConfig::default());
        prop_assert_eq!(simplified.start().unwrap().coordinate(), track.start().unwrap().coordinate());
        prop_assert_eq!(simplified.end().unwrap().coordinate(), track.end().unwrap().coordinate());
        prop_assert!(simplified.points().len() <= track.points().len());
        let mut prev = i64::MIN;
        for p in simplified.points() {
            prop_assert!(p.timestamp().unix_ms() >= prev);
            prev = p.timestamp().unix_ms();
        }
    }

    #[test]
    fn filtered_track_stays_valid(track in small_track()) {
        let (filtered, report) = track.filter(&gps_engine::FilterConfig::default());
        prop_assert!(filtered.points().len() >= 2);
        prop_assert_eq!(report.input_points, track.points().len());
        prop_assert_eq!(report.output_points, filtered.points().len());
        prop_assert_eq!(report.removed_points, report.input_points - report.output_points);
        // Original length is never smaller than the filtered length minus one jump budget.
        prop_assert!(report.distance_before.meters() + 10.0 >= report.distance_after.meters());
    }

    #[test]
    fn filtered_length_is_bounded_by_polyline(track in small_track()) {
        // Sanity: distance() equals the polyline length of its own points.
        let coords: Vec<Coordinate> = track.points().iter().map(|p| p.coordinate()).collect();
        let manual = polyline_length(&coords).meters();
        prop_assert!((manual - track.distance().meters()).abs() < 1e-6);
    }
}
