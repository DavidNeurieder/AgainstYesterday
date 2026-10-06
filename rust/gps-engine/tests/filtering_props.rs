// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests for processing invariants (§32).
//!
//! Filtering never *creates* movement: it only removes points. So every
//! surviving point must be an exact sample of the input, in order — the
//! filtered track is a subsequence of the original.

use gps_engine::geo::Coordinate;
use gps_engine::units::{Distance, Timestamp};
use gps_engine::{FilterConfig, Track, TrackPoint};
use proptest::prelude::*;

fn small_track() -> impl Strategy<Value = Track> {
    proptest::collection::vec((-0.01f64..0.01, -0.01f64..0.01), 2..=12).prop_map(|coords| {
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

/// Hash-order is preserved: build the input's index table and verify every
/// filtered point maps back to it in ascending order.
fn index_of(track: &Track) -> std::collections::HashMap<(i64, i64, i64), usize> {
    track
        .points()
        .iter()
        .enumerate()
        .map(|(i, p)| {
            let key = (
                p.timestamp().unix_ms(),
                (p.coordinate().latitude() * 1e9) as i64,
                (p.coordinate().longitude() * 1e9) as i64,
            );
            (key, i)
        })
        .collect()
}

proptest! {
    #[test]
    fn filtering_only_removes_points(track in small_track()) {
        let (filtered, report) = track.filter(&FilterConfig::default());
        let index = index_of(&track);
        let mut last: Option<usize> = None;
        for p in filtered.points() {
            let key = (
                p.timestamp().unix_ms(),
                (p.coordinate().latitude() * 1e9) as i64,
                (p.coordinate().longitude() * 1e9) as i64,
            );
            let i = match index.get(&key) {
                Some(&i) => i,
                None => {
                    return Err(proptest::test_runner::TestCaseError::fail(
                        "every filtered point is an original sample",
                    ))
                }
            };
            prop_assert!(
                last.is_none() || i > last.expect("set"),
                "filtered track must preserve input order"
            );
            last = Some(i);
        }
        prop_assert_eq!(filtered.points().len(), report.output_points);
    }

    #[test]
    fn filtered_movement_respects_original(track in small_track()) {
        // The filtered polyline is bounded by the original one: it can never
        // be longer (chords replace paths) and never shorter than the
        // straight-line span of its endpoints.
        let (filtered, _) = track.filter(&FilterConfig::default());
        let span = {
            let a = filtered.start().unwrap().coordinate();
            let b = filtered.end().unwrap().coordinate();
            gps_engine::geo::distance(a, b).meters()
        };
        let kept = filtered.distance().meters();
        let max_jump_budget = 10.0;
        prop_assert!(kept <= track.distance().meters() + max_jump_budget);
        prop_assert!(kept >= span - max_jump_budget);
    }

    #[test]
    fn resampling_keeps_first_and_last(track in small_track(), interval_m in 5.0f64..80.0) {
        let resampled = track
            .resample_by_distance(Distance::from_meters(interval_m))
            .unwrap();
        prop_assert!(
            gps_engine::geo::distance(
                resampled.start().unwrap().coordinate(),
                track.start().unwrap().coordinate()
            )
            .meters()
                < 1e-9
        );
        prop_assert!(
            gps_engine::geo::distance(
                resampled.end().unwrap().coordinate(),
                track.end().unwrap().coordinate()
            )
            .meters()
                < 1e-9
        );
    }
}
