// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPX parsing from embedded fixtures and malformed documents.

use gps_engine::{GpxError, Track, parse_gpx, read_gpx, read_gpx_file};

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");

fn load(name: &str) -> Track {
    read_gpx_file(format!("{MANIFEST_DIR}/testdata/unit/{name}")).unwrap()
}

#[test]
fn straight_fixture_round_trips() {
    let track = load("straight.gpx");
    assert_eq!(track.points().len(), 3);

    let first = track.start().unwrap();
    assert!((first.coordinate().latitude() - 52.50).abs() < 1e-12);
    assert!((first.coordinate().longitude() - 13.40).abs() < 1e-12);

    let ts: Vec<i64> = track
        .points()
        .iter()
        .map(|p| p.timestamp().unix_ms())
        .collect();
    assert_eq!(
        ts,
        vec![1_717_236_000_000, 1_717_236_010_000, 1_717_236_020_000]
    );
}

#[test]
fn elevation_is_read() {
    let track = load("straight.gpx");
    let eles: Vec<Option<f64>> = track.points().iter().map(|p| p.altitude()).collect();
    assert_eq!(eles, vec![Some(35.0), Some(36.1), Some(37.5)]);
}

#[test]
fn loop_fixture_closes() {
    let track = load("loop.gpx");
    assert_eq!(track.points().len(), 5);
    assert_eq!(
        track.start().unwrap().coordinate(),
        track.end().unwrap().coordinate(),
        "loop returns to its start"
    );
    assert!(track.distance().meters() > 0.0);
}

#[test]
fn garmin_speed_extension_is_read() {
    let track = load("extension_speed.gpx");
    let speeds: Vec<Option<f64>> = track.points().iter().map(|p| p.speed()).collect();
    assert_eq!(speeds, vec![Some(3.25), Some(3.1)]);
}

#[test]
fn missing_times_are_synthesized() {
    let track = load("no_time.gpx");
    let ts: Vec<i64> = track
        .points()
        .iter()
        .map(|p| p.timestamp().unix_ms())
        .collect();
    assert_eq!(ts, vec![0, 1000, 2000]);
}

#[test]
fn sparse_fixture_preserves_duration() {
    let track = load("sparse.gpx");
    assert_eq!(track.points().len(), 4);
    assert!((track.duration().as_secs() - 10_830.0).abs() < 1e-9); // 3h 0m 30s
}

#[test]
fn parse_gpx_accepts_reader() {
    let data = std::fs::read(format!("{MANIFEST_DIR}/testdata/unit/loop.gpx")).unwrap();
    let track = parse_gpx(&data).unwrap();
    assert_eq!(track.points().len(), 5);
    let via_reader = read_gpx(std::io::Cursor::new(&data)).unwrap();
    assert_eq!(via_reader.points().len(), 5);
}

#[test]
fn malformed_xml_is_rejected() {
    // An end tag that does not match its opening start tag.
    let err = parse_gpx(b"<gpx><trk></gpx>".as_slice()).unwrap_err();
    assert!(matches!(err, GpxError::Parse(_)));
}

#[test]
fn trkpt_without_lat_is_rejected() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lon="13.4"><time>2024-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#;
    let err = parse_gpx(doc).unwrap_err();
    assert!(matches!(err, GpxError::Parse(_)));
}

#[test]
fn non_numeric_lat_is_rejected() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lat="abc" lon="13.4"><time>2024-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#;
    let err = parse_gpx(doc).unwrap_err();
    assert!(matches!(err, GpxError::Coordinate(_)));
}

#[test]
fn out_of_range_lat_is_rejected() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lat="99.0" lon="13.4"><time>2024-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#;
    let err = parse_gpx(doc).unwrap_err();
    assert!(matches!(err, GpxError::Coordinate(_)));
}

#[test]
fn bad_time_is_rejected() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lat="52.0" lon="13.4"><time>not a time</time></trkpt></trkseg></trk></gpx>"#;
    let err = parse_gpx(doc).unwrap_err();
    assert!(matches!(err, GpxError::InvalidTime { .. }));
}

#[test]
fn non_finite_elevation_is_rejected() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lat="52.0" lon="13.4"><ele>NaN</ele><time>2024-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#;
    let err = parse_gpx(doc).unwrap_err();
    assert!(matches!(err, GpxError::InvalidValue { .. }));
}

#[test]
fn zero_or_one_points_are_rejected() {
    let one = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg><trkpt lat="52.0" lon="13.4"><time>2024-01-01T00:00:00Z</time></trkpt></trkseg></trk></gpx>"#;
    assert!(matches!(parse_gpx(one), Err(GpxError::Track(_))));

    let none = br#"<?xml version="1.0"?><gpx><trk><trkseg></trkseg></trk></gpx>"#;
    assert!(matches!(parse_gpx(none), Err(GpxError::Track(_))));
}

#[test]
fn missing_file_is_an_io_error() {
    let err =
        read_gpx_file(format!("{MANIFEST_DIR}/testdata/unit/does_not_exist.gpx")).unwrap_err();
    assert!(matches!(err, GpxError::Io(_)));
}

#[test]
fn timestamps_with_timezone_offsets_are_absolutized() {
    let doc = br#"<?xml version="1.0"?>
        <gpx><trk><trkseg>
        <trkpt lat="52.5" lon="13.4"><time>2024-06-01T12:00:00+02:00</time></trkpt>
        <trkpt lat="52.5" lon="13.4"><time>2024-06-01T11:00:00Z</time></trkpt>
        </trkseg></trk></gpx>"#;
    let track = parse_gpx(doc).unwrap();
    // 12:00+02:00 == 10:00Z; the second point is 11:00Z, one hour later.
    let ts: Vec<i64> = track
        .points()
        .iter()
        .map(|p| p.timestamp().unix_ms())
        .collect();
    assert_eq!(ts[1] - ts[0], 3_600_000);
    // And it is ordered, so the track is valid.
    assert!(ts[1] > ts[0]);
}
