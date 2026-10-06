// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPX boundary robustness (§41): GPX is user-controlled external data, so
//! the engine must return errors — never panic — no matter how hostile the
//! input is. Also directed cases for the shapes listed in the plan.

use proptest::prelude::*;

use gps_engine::geo::Coordinate;
use gps_engine::units::Timestamp;
use gps_engine::{Track, TrackPoint, parse_gpx, read_gpx_file, write_gpx};

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    /// Arbitrary bytes must yield Ok or Err — never a panic (or hang).
    #[test]
    fn arbitrary_bytes_never_panic(bytes in any::<Vec<u8>>()) {
        let _ = parse_gpx(&bytes);
    }

    /// Arbitrary ASCII/UTF-8 text must also never panic.
    #[test]
    fn arbitrary_text_never_panic(text in any::<String>()) {
        let _ = parse_gpx(text.as_bytes());
    }

    /// Even arbitrary well-formed XML must not panic.
    #[test]
    fn arbitrary_xml_never_panic(xml in "[</>a-z0-9=\" ':.-]{0,4000}") {
        let _ = parse_gpx(xml.as_bytes());
    }
}

#[test]
fn empty_document_is_an_error() {
    let err = parse_gpx(b"").unwrap_err();
    // Missing or malformed, but a tracked error.
    let _ = format!("{err}");
    assert!(parse_gpx(b"   ").is_err());
}

#[test]
fn broken_xml_is_an_error() {
    assert!(parse_gpx(b"<gpx><trk><trkseg><trkpt").is_err());
    assert!(parse_gpx(b"not-xml-at-all").is_err());
}

#[test]
fn invalid_coordinates_are_errors() {
    let bad_lat = br#"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="91.0" lon="13.0"><time>2024-06-01T10:00:00Z</time></trkpt>
    </trkseg></trk></gpx>"#;
    let bad_lon = br#"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="52.0" lon="181.0"><time>2024-06-01T10:00:00Z</time></trkpt>
    </trkseg></trk></gpx>"#;
    let no_attrs = br#"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt><time>2024-06-01T10:00:00Z</time></trkpt>
    </trkseg></trk></gpx>"#;
    assert!(parse_gpx(bad_lat).is_err());
    assert!(parse_gpx(bad_lon).is_err());
    assert!(parse_gpx(no_attrs).is_err());
}

#[test]
fn duplicate_timestamps_are_accepted() {
    let ts = "2024-06-01T10:00:00Z";
    let xml = format!(
        r#"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="52.0" lon="13.0"><time>{ts}</time></trkpt>
        <trkpt lat="52.001" lon="13.001"><time>{ts}</time></trkpt>
        <trkpt lat="52.002" lon="13.002"><time>{ts}</time></trkpt>
    </trkseg></trk></gpx>"#
    );
    let track = parse_gpx(xml.as_bytes()).unwrap();
    assert_eq!(track.points().len(), 3);
}

#[test]
fn missing_time_falls_back_deterministically() {
    // No `<time>` anywhere: ordered points with a starting-epoch fallback.
    let xml = r#"<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>
        <trkpt lat="52.0" lon="13.0"/>
        <trkpt lat="52.001" lon="13.001"/>
    </trkseg></trk></gpx>"#;
    let track = parse_gpx(xml.as_bytes()).unwrap();
    assert_eq!(track.points().len(), 2);
    assert_eq!(track.points()[0].timestamp().unix_ms(), 0);
    assert_eq!(track.points()[1].timestamp().unix_ms(), 1_000);
}

#[test]
fn multiple_segments_and_tracks_flatten() {
    let xml = r#"<gpx xmlns="http://www.topografix.com/GPX/1/1">
        <trk><name>a</name><trkseg>
            <trkpt lat="52.0" lon="13.0"><time>2024-06-01T10:00:00Z</time></trkpt>
        </trkseg></trk>
        <trk><trkseg>
            <trkpt lat="52.001" lon="13.001"><time>2024-06-01T10:00:02Z</time></trkpt>
            <trkpt lat="52.002" lon="13.002"><time>2024-06-01T10:00:04Z</time></trkpt>
        </trkseg>
        <trkseg>
            <trkpt lat="52.003" lon="13.003"><time>2024-06-01T10:00:06Z</time></trkpt>
        </trkseg></trk>
    </gpx>"#;
    let track = parse_gpx(xml.as_bytes()).unwrap();
    assert_eq!(track.points().len(), 4, "points flatten across trk/trkseg");
    // Order is preserved.
    assert_eq!(track.points()[3].coordinate().latitude(), 52.003);
}

#[test]
fn huge_track_round_trips() {
    // A ~1 MB GPX (20 k points) must write and reparse without panic and
    // preserve every point.
    let mut points = Vec::with_capacity(20_000);
    for i in 0..20_000u32 {
        let lat = 52.0 + (i % 1000) as f64 * 1e-6;
        let lon = 13.0 + (i / 1000) as f64 * 1e-6;
        points.push(TrackPoint::new(
            Timestamp::from_unix_ms(i as i64 * 1_000),
            Coordinate::new(lat, lon).unwrap(),
        ));
    }
    let track = Track::new(points).unwrap();

    let mut bytes = Vec::new();
    write_gpx(&track, &mut bytes).unwrap();
    assert!(bytes.len() > 500_000, "should be a large document");

    let reparsed = parse_gpx(&bytes).unwrap();
    assert_eq!(reparsed.points().len(), 20_000);
    assert_eq!(
        reparsed.points()[19_999].coordinate().latitude(),
        52.0 + 999.0e-6
    );
    assert_eq!(reparsed.end().unwrap().timestamp().unix_ms(), 19_999_000);
}

#[test]
fn api_level_io_error_not_panic() {
    // Reading a nonexistent file is a typed error, not a panic.
    let err = read_gpx_file("/nonexistent/nope.gpx").unwrap_err();
    let _ = format!("{err}");
}
