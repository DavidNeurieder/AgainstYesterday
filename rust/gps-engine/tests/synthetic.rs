// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Synthetic GPS generator: determinism, validity, and presets.

use gps_engine::Track;
use gps_engine::geo::{Coordinate, project_to_polyline};
use gps_engine::synthetic::{self, SyntheticConfig, generate};
use gps_engine::units::{Distance, Timestamp};

/// A ~200 m meridian route with a slight west/east wiggle in the middle so
/// lateral deviation is measurable.
fn route() -> Vec<Coordinate> {
    vec![
        Coordinate::new(52.5000, 13.4000).unwrap(),
        Coordinate::new(52.5006, 13.4002).unwrap(),
        Coordinate::new(52.5012, 13.4001).unwrap(),
        Coordinate::new(52.5018, 13.4000).unwrap(),
    ]
}

fn assert_valid_noise(track: &Track, route: &[Coordinate], max_error_m: f64) {
    for p in track.points() {
        let projection = project_to_polyline(p.coordinate(), route).expect("route has segments");
        assert!(
            projection.lateral_error.meters() <= max_error_m,
            "point {:?} deviates {:?} which exceeds {max_error_m} m",
            p.coordinate(),
            projection.lateral_error,
        );
    }
}

#[test]
fn clean_track_follows_route_exactly() {
    let config = SyntheticConfig::clean(1);
    let track = generate(&route(), &config);
    assert!(track.points().len() >= 30);
    assert_valid_noise(&track, &route(), 1e-6);
}

#[test]
fn same_seed_is_deterministic() {
    let config = SyntheticConfig::noisy(7, 6.0);
    let a = generate(&route(), &config);
    let b = generate(&route(), &config);
    assert_eq!(a, b);
}

#[test]
fn noisy_track_stays_near_route() {
    let config = SyntheticConfig::noisy(3, 25.0);
    let track = generate(&route(), &config);
    assert_valid_noise(&track, &route(), 25.0 + 2.0);
}

#[test]
fn all_variants_produce_valid_monotonic_tracks() {
    let seeds = [1u64, 99, 123_456_789];
    let presets: Vec<SyntheticConfig> = vec![
        SyntheticConfig::clean(0),
        SyntheticConfig::noisy(0, 10.0),
        SyntheticConfig::sparse(0),
        SyntheticConfig::dense(0),
        SyntheticConfig::gapped(0),
        SyntheticConfig::stopped(0),
        SyntheticConfig::outliers(0),
    ];

    for config in &presets {
        for &seed in &seeds {
            let config = SyntheticConfig { seed, ..*config };
            let track = generate(&route(), &config);
            assert!(track.points().len() >= 2, "preset {:?}", config);
            let mut prev = Timestamp::from_unix_ms(i64::MIN);
            for p in track.points() {
                assert!(
                    p.timestamp() >= prev,
                    "timestamps must be non-decreasing, got {prev:?} then {:?}",
                    p.timestamp(),
                );
                prev = p.timestamp();
            }
            let _ = Track::new(track.points().to_vec()).expect("already valid");
        }
    }
}

#[test]
fn sparse_preset_has_fewer_points_than_dense() {
    let sparse = generate(
        &route(),
        &SyntheticConfig {
            seed: 5,
            ..SyntheticConfig::sparse(5)
        },
    );
    let dense = generate(
        &route(),
        &SyntheticConfig {
            seed: 5,
            ..SyntheticConfig::dense(5)
        },
    );
    assert!(sparse.points().len() < dense.points().len());
}

#[test]
fn stopped_preset_has_stationary_interior_points() {
    let track = generate(
        &route(),
        &SyntheticConfig {
            seed: 11,
            ..SyntheticConfig::stopped(11)
        },
    );
    let mut stationary = 0;
    for pair in track.points().windows(2) {
        if pair[0].coordinate() == pair[1].coordinate() {
            stationary += 1;
        }
    }
    assert!(stationary > 0, "expected at least one stationary pair");
}

#[test]
fn reverse_runs_finish_to_start() {
    let config = SyntheticConfig {
        reverse: true,
        ..SyntheticConfig::clean(2)
    };
    let track = generate(&route(), &config);
    let pts = track.points();
    // First point is the route finish; last point is the route start.
    assert!(
        (pts[0].coordinate().latitude() - route()[3].latitude()).abs() < 1e-9,
        "reversed track should start at the finish"
    );
    assert!(
        (pts.last().unwrap().coordinate().latitude() - route()[0].latitude()).abs() < 1e-9,
        "reversed track should end at the start"
    );
}

#[test]
fn detour_deviates_in_the_middle() {
    let base = generate(&route(), &SyntheticConfig::clean(0));
    let detoured = synthetic::add_detour(&base, Distance::from_meters(20.0));

    assert_eq!(
        detoured.points().len(),
        base.points().len(),
        "detour keeps all points"
    );

    let mut max_gap = 0.0f64;
    for (a, b) in base.points().iter().zip(detoured.points()) {
        max_gap = max_gap.max(gps_engine::geo::distance(a.coordinate(), b.coordinate()).meters());
    }
    // Mid-track should deviate by ~20 m; nothing should jump wildly.
    assert!(
        max_gap > 10.0,
        "expected a sizable mid-track excursion, got {max_gap}"
    );
    assert!(
        max_gap <= 22.0,
        "excursion {max_gap} exceeds the configured detour"
    );

    // Endpoints are left on the route.
    assert_eq!(
        detoured.start().unwrap().coordinate(),
        base.start().unwrap().coordinate()
    );
    assert_eq!(
        detoured.end().unwrap().coordinate(),
        base.end().unwrap().coordinate()
    );
}

#[test]
fn reverse_preserves_duration() {
    let track = generate(&route(), &SyntheticConfig::clean(0));
    let reversed = synthetic::reverse(&track);
    assert!((reversed.duration().as_secs() - track.duration().as_secs()).abs() < 1e-6);
    assert_eq!(
        reversed.start().unwrap().coordinate(),
        track.end().unwrap().coordinate()
    );
    let mut prev = Timestamp::from_unix_ms(i64::MIN);
    for p in reversed.points() {
        assert!(p.timestamp() >= prev);
        prev = p.timestamp();
    }
}

#[test]
fn rng_unit_is_in_range() {
    let mut rng = synthetic::Rng::new(0);
    for _ in 0..1000 {
        let u = rng.unit();
        assert!((0.0..1.0).contains(&u), "unit() = {u}");
    }
}
