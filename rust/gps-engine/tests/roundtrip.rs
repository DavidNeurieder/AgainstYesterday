// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPX writer round-trips and determinism.

use std::io::Cursor;

use gps_engine::geo::Coordinate;
use gps_engine::synthetic::SyntheticConfig;
use gps_engine::units::Timestamp;
use gps_engine::{Track, TrackPoint, parse_gpx, read_gpx_file, write_gpx};

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");

#[test]
fn writer_is_deterministic() {
    let track = gps_engine::synthetic::generate(&crate_route(), &SyntheticConfig::noisy(1, 8.0));
    let a = render(&track);
    let b = render(&track);
    assert_eq!(a, b, "same track must serialize byte-identically");
}

#[test]
fn round_trip_preserves_geometry_and_time() {
    let disk = format!("{MANIFEST_DIR}/testdata/unit/straight.gpx");
    let track = read_gpx_file(&disk).unwrap();

    let bytes = render(&track);
    let parsed = parse_gpx(&bytes).unwrap();

    assert_eq!(track.points().len(), parsed.points().len());
    for (a, b) in track.points().iter().zip(parsed.points().iter()) {
        assert_eq!(a.timestamp().unix_ms(), b.timestamp().unix_ms());
        assert!(
            (a.coordinate().latitude() - b.coordinate().latitude()).abs() < 1e-6,
            "latitude drifted"
        );
        assert!(
            (a.coordinate().longitude() - b.coordinate().longitude()).abs() < 1e-6,
            "longitude drifted"
        );
    }
}

#[test]
fn millisecond_timestamps_survive() {
    // 2024-06-01T10:00:00.500Z in milliseconds.
    let ts = Timestamp::from_unix_ms(1_717_236_000_500);
    let track = Track::new(vec![
        TrackPoint::new(ts, Coordinate::new(52.0, 13.0).unwrap()),
        TrackPoint::new(
            Timestamp::from_unix_ms(1_717_236_001_250),
            Coordinate::new(52.001, 13.001).unwrap(),
        ),
    ])
    .unwrap();

    let bytes = render(&track);
    assert!(String::from_utf8_lossy(&bytes).contains("2024-06-01T10:00:00.500Z"));

    let parsed = parse_gpx(&bytes).unwrap();
    assert_eq!(parsed.points()[0].timestamp().unix_ms(), 1_717_236_000_500);
    assert_eq!(parsed.points()[1].timestamp().unix_ms(), 1_717_236_001_250);
    assert_eq!(parsed.points()[0].coordinate().latitude(), 52.0);
    assert!(parsed.points()[0].altitude().is_none());
}

#[test]
fn pre_epoch_timestamps_format_to_utc() {
    // 1969-12-31T23:59:59.900Z.
    let track = Track::new(vec![
        TrackPoint::new(
            Timestamp::from_unix_ms(-100),
            Coordinate::new(52.0, 13.0).unwrap(),
        ),
        TrackPoint::new(
            Timestamp::from_unix_ms(99),
            Coordinate::new(52.001, 13.001).unwrap(),
        ),
    ])
    .unwrap();
    let bytes = render(&track);
    let text = String::from_utf8_lossy(&bytes);
    assert!(text.contains("1969-12-31T23:59:59.900Z"), "{text}");
    assert!(text.contains("1970-01-01T00:00:00.099Z"), "{text}");
    let parsed = parse_gpx(&bytes).unwrap();
    assert_eq!(parsed.points()[0].timestamp().unix_ms(), -100);
    assert_eq!(parsed.points()[1].timestamp().unix_ms(), 99);
}

#[test]
fn synthetic_corpus_files_parse() {
    let dir = std::path::Path::new(MANIFEST_DIR).join("testdata/synthetic");
    let mut entries: Vec<_> = std::fs::read_dir(&dir)
        .expect("synthetic corpus exists; run `cargo run --example generate_corpus`")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            p.extension()
                .map(|ext| ext.eq_ignore_ascii_case("gpx"))
                .unwrap_or(false)
        })
        .collect();
    entries.sort();
    assert!(!entries.is_empty(), "corpus directory must not be empty");

    for path in entries {
        let track = read_gpx_file(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        assert!(track.points().len() >= 2, "{} too short", path.display());
        // And the corpus round-trips through the writer.
        let bytes = render(&track);
        let reparsed = parse_gpx(&bytes).unwrap();
        assert_eq!(
            reparsed.points().len(),
            track.points().len(),
            "{}",
            path.display()
        );
    }
}

fn crate_route() -> Vec<Coordinate> {
    vec![
        Coordinate::new(52.500, 13.400).unwrap(),
        Coordinate::new(52.510, 13.400).unwrap(),
        Coordinate::new(52.510, 13.411).unwrap(),
        Coordinate::new(52.500, 13.411).unwrap(),
    ]
}

/// Serializes a track to a byte vector.
fn render(track: &Track) -> Vec<u8> {
    let mut out = Cursor::new(Vec::new());
    write_gpx(track, &mut out).unwrap();
    out.into_inner()
}
