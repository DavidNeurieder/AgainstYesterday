// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Regenerates the deterministic M15 raw-GPS fixtures under `tests/fixtures/`.
//!
//! ```text
//! cargo run --example generate_fixtures
//! ```
//!
//! Five fixture documents, each a schema-versioned
//! `{"schema_version": 1, "route": [...], "fixes": [...]}` object the gps
//! module can parse back via [`Fixture::from_json`] / `GpsTrace`:
//!
//! - `clean_loop.json`: a perfect loop with good reported accuracy.
//! - `gps_jitter.json`: noisy per-fix positions (degraded accuracy).
//! - `gps_jump.json`: rare far-off fixes that snap back onto the route.
//! - `gps_dropout.json`: frequent dropped fixes (time advances without a fix).
//! - `out_and_back.json`: a clean out-and-back along the same meridian — the
//!   classic continuity stressor (the return leg mirrors the out leg).
//!
//! The routes are embedded so torture tests can assert every *accepted* fix
//! stays within a few meters of the route even when the raw trace is ridden
//! with defects (M15).

use std::fs;
use std::path::Path;

use gps_engine::geo::{Bearing, Coordinate, bearing, distance};
use gps_engine::gps::{Fixture, GpsFix, GpsTrace};
use gps_engine::synthetic::{SyntheticConfig, generate};
use gps_engine::units::Distance;
use gps_engine::{Route, Track};

const OUT_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures");

/// A ~1.1 km closed loop used by the defect fixtures.
fn loop_route() -> Route {
    let raw = [
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
        Coordinate::new(52.503_000, 13.400_000).unwrap(),
        Coordinate::new(52.503_000, 13.400_500).unwrap(),
        Coordinate::new(52.503_000, 13.401_000).unwrap(),
        Coordinate::new(52.500_000, 13.401_000).unwrap(),
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
    ];
    Route::new(raw.to_vec()).expect("valid loop")
}

/// The out-and-back route: south on the 13.4000 meridian, then north back
/// over the exact same ground — the mirror-image geometry that trips naive
/// continuity matching.
fn out_and_back_route() -> Route {
    let raw = [
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
        Coordinate::new(52.505_000, 13.400_000).unwrap(),
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
    ];
    Route::new(raw.to_vec()).expect("valid out-and-back")
}

/// Converts a synthesized track into raw GPS fixes carrying the sensor fields
/// the pipeline consumes: reported accuracy, altitude, travelling speed and
/// bearing, each derived (deterministically) from the geometry.
fn to_fixes(track: &Track, accuracy_m: f64) -> Vec<GpsFix> {
    let points = track.points();
    points
        .iter()
        .enumerate()
        .map(|(i, point)| {
            let coordinate = point.coordinate();
            let prev = points[..i]
                .last()
                .map(|p| p.coordinate())
                .unwrap_or(coordinate);
            let next = points[i + 1..]
                .first()
                .map(|p| p.coordinate())
                .unwrap_or(coordinate);
            let heading = bearing(prev, coordinate)
                .ok()
                .or_else(|| bearing(coordinate, next).ok())
                .unwrap_or(Bearing::NORTH);
            let speed = if i == 0 {
                None
            } else {
                let dt = point
                    .timestamp()
                    .elapsed_since(points[i - 1].timestamp())
                    .as_secs();
                let dist = distance(prev, coordinate).meters();
                (dt > 0.0).then_some(gps_engine::units::Speed::from_mps(dist / dt))
            };
            GpsFix {
                timestamp: point.timestamp(),
                coordinate,
                accuracy: Some(Distance::from_meters(accuracy_m)),
                altitude: Some(60.0),
                speed,
                bearing: Some(heading),
            }
        })
        .collect()
}

fn write_fixture(name: &str, route: &Route, trace: &GpsTrace) {
    let fixture = Fixture {
        route: Some(route.clone()),
        trace: trace.clone(),
    };
    let path = Path::new(OUT_DIR).join(name);
    fs::write(&path, fixture.to_json()).expect("write fixture");
    println!(
        "wrote {} ({:>4} fixes, {:.3} km route)",
        path.display(),
        trace.len(),
        route.length().kilometers()
    );
}

fn main() {
    fs::create_dir_all(OUT_DIR).expect("create fixtures dir");

    let loop_route = loop_route();
    let ob_route = out_and_back_route();
    let loop_geometry = loop_route.geometry();

    let clean = generate(loop_geometry, &SyntheticConfig::clean(1));
    write_fixture(
        "clean_loop.json",
        &loop_route,
        &GpsTrace::new(to_fixes(&clean, 6.0)).unwrap(),
    );

    let jitter = generate(loop_geometry, &SyntheticConfig::noisy(2, 12.0));
    write_fixture(
        "gps_jitter.json",
        &loop_route,
        &GpsTrace::new(to_fixes(&jitter, 14.0)).unwrap(),
    );

    let jump = generate(
        loop_geometry,
        &SyntheticConfig {
            position_noise: Distance::from_meters(2.0),
            outlier_probability: 0.05,
            outlier_distance: Distance::from_meters(150.0),
            gap_probability: 0.0,
            stop_probability: 0.0,
            seed: 3,
            ..SyntheticConfig::default()
        },
    );
    write_fixture(
        "gps_jump.json",
        &loop_route,
        &GpsTrace::new(to_fixes(&jump, 28.0)).unwrap(),
    );

    let dropout = generate(loop_geometry, &SyntheticConfig::gapped(4));
    write_fixture(
        "gps_dropout.json",
        &loop_route,
        &GpsTrace::new(to_fixes(&dropout, 7.0)).unwrap(),
    );

    let ob = generate(ob_route.geometry(), &SyntheticConfig::clean(5));
    write_fixture(
        "out_and_back.json",
        &ob_route,
        &GpsTrace::new(to_fixes(&ob, 6.0)).unwrap(),
    );

    println!(
        "fixtures: 4 defect/clean recordings on a {:.3} km loop + 1 out-and-back ({:.3} km)",
        loop_route.length().kilometers(),
        ob_route.length().kilometers()
    );
}
