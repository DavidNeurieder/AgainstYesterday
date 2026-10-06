// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Regenerates the deterministic synthetic corpus under `testdata/synthetic/`
//! (§33 of the crate plan).
//!
//! Every track is generated with a fixed seed and written as GPX, so the
//! corpus is reproducible:
//!
//! ```text
//! cargo run --example generate_corpus
//! ```
//!
//! Ten recordings of a single loop under many defect profiles (clean / noisy /
//! sparse / gapped / stopped / outliers / reversed / detour) plus one genuinely
//! different route (`other.gpx`). The sibling [`evaluate`](evaluate) example
//! and `tests/evaluate.rs` turn the `manifest.json` produced here into
//! precision/recall/F1 numbers (§38–§40).

use std::path::Path;

use gps_engine::geo::Coordinate;
use gps_engine::synthetic::{SyntheticConfig, add_detour, generate, reverse as reverse_track};
use gps_engine::units::Distance;
use gps_engine::{Route, Track, write_gpx_file};

const OUT_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/synthetic");

/// The shared loop every same-route recording follows (~4.9 km, §38).
fn loop_route() -> Route {
    let raw = [
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
        Coordinate::new(52.510_815, 13.400_000).unwrap(),
        Coordinate::new(52.515_315, 13.410_918).unwrap(),
        Coordinate::new(52.507_500, 13.418_836).unwrap(),
        Coordinate::new(52.500_000, 13.410_918).unwrap(),
        Coordinate::new(52.500_000, 13.400_000).unwrap(),
    ];
    Route::new(raw.to_vec()).expect("valid loop")
}

/// A plainly different route, well outside the loop corridor (~1 km away).
fn other_route() -> Route {
    let raw = [
        Coordinate::new(52.470_000, 13.430_000).unwrap(),
        Coordinate::new(52.475_500, 13.430_000).unwrap(),
        Coordinate::new(52.475_500, 13.438_000).unwrap(),
        Coordinate::new(52.470_000, 13.438_000).unwrap(),
        Coordinate::new(52.470_000, 13.430_000).unwrap(),
    ];
    Route::new(raw.to_vec()).expect("valid other route")
}

fn write(name: &str, track: &Track) {
    let path = Path::new(OUT_DIR).join(name);
    write_gpx_file(track, &path).expect("write corpus file");
    println!("wrote {}", path.display());
}

/// The loop-family recordings (all "same" against each other).
fn loop_family_names() -> Vec<&'static str> {
    vec![
        "clean.gpx",
        "detour.gpx",
        "gapped.gpx",
        "noisy_12m.gpx",
        "noisy_5m.gpx",
        "outliers.gpx",
        "reversed.gpx",
        "sparse.gpx",
        "stopped.gpx",
    ]
}

/// Writes `manifest.json` (§39): every unordered pair with its ground truth.
fn write_manifest() {
    let loop_family = loop_family_names();
    let mut lines = String::from("{\n  \"matches\": [\n");
    let mut entries = Vec::new();

    for (i, a) in loop_family.iter().enumerate() {
        for b in &loop_family[i + 1..] {
            entries.push((*a, *b, "same"));
        }
    }
    for a in &loop_family {
        entries.push((*a, "other.gpx", "different"));
    }

    for (i, (a, b, expected)) in entries.iter().enumerate() {
        let comma = if i + 1 < entries.len() { "," } else { "" };
        lines.push_str(&format!(
            "    {{\"a\": \"{a}\", \"b\": \"{b}\", \"expected\": \"{expected}\"}}{comma}\n"
        ));
    }
    lines.push_str("  ]\n}\n");

    let path = Path::new(OUT_DIR).join("manifest.json");
    std::fs::write(&path, lines).expect("write manifest");
    println!("wrote {}", path.display());
}

fn main() {
    let loop_route = loop_route();
    let other_route = other_route();
    let loop_geometry = loop_route.geometry();
    let other_geometry = other_route.geometry();
    std::fs::create_dir_all(OUT_DIR).expect("create corpus dir");

    write(
        "clean.gpx",
        &generate(loop_geometry, &SyntheticConfig::clean(1)),
    );
    write(
        "noisy_5m.gpx",
        &generate(loop_geometry, &SyntheticConfig::noisy(2, 5.0)),
    );
    write(
        "noisy_12m.gpx",
        &generate(loop_geometry, &SyntheticConfig::noisy(3, 12.0)),
    );
    write(
        "sparse.gpx",
        &generate(loop_geometry, &SyntheticConfig::sparse(4)),
    );
    write(
        "gapped.gpx",
        &generate(loop_geometry, &SyntheticConfig::gapped(5)),
    );
    write(
        "stopped.gpx",
        &generate(loop_geometry, &SyntheticConfig::stopped(6)),
    );
    write(
        "outliers.gpx",
        &generate(loop_geometry, &SyntheticConfig::outliers(7)),
    );
    write(
        "reversed.gpx",
        &reverse_track(&generate(loop_geometry, &SyntheticConfig::noisy(8, 5.0))),
    );
    write(
        "detour.gpx",
        &add_detour(
            &generate(loop_geometry, &SyntheticConfig::noisy(9, 5.0)),
            Distance::from_meters(60.0),
        ),
    );
    write(
        "other.gpx",
        &generate(other_geometry, &SyntheticConfig::clean(10)),
    );

    write_manifest();

    println!(
        "corpus: {} loop-family tracks + 1 different route ({:.2} km loop, {:.2} km other)",
        loop_family_names().len(),
        loop_route.length().kilometers(),
        other_route.length().kilometers()
    );
}
