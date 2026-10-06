// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Fixture JSON schema contract (M15.10).
//!
//! The raw-GPS fixture is the seam between the Flutter developer exporter and
//! the Rust engine, so its shape is nailed down here:
//!
//! - `schema_version` is serialized, accepted, and *rejected* when newer;
//! - legacy documents without a version still parse;
//! - missing and explicit-`null` sensor fields are equivalent;
//! - the exact document the Flutter exporter emits round-trips losslessly.

use gps_engine::gps::{FIXTURE_SCHEMA_VERSION, Fixture, GpsTrace};

fn rejection(doc: &str) -> String {
    Fixture::from_json(doc)
        .expect_err("fixture should be rejected")
        .to_string()
}

/// The shape emitted by `buildFixtureJson` on the Flutter side: every sensor
/// field is always present, `null` where the receiver reported nothing.
const DART_EXPORTED: &str = r#"{"schema_version":1,
 "route":[{"lat":52.5,"lon":13.4},{"lat":52.5,"lon":13.4005}],
 "fixes":[
  {"timestamp_ms":0,"latitude":52.5,"longitude":13.4,
   "accuracy_m":47.5,"altitude_m":null,"speed_mps":null,"bearing_deg":null},
  {"timestamp_ms":2000,"latitude":52.5001,"longitude":13.4005,
   "accuracy_m":null,"altitude_m":60.0,"speed_mps":3.25,"bearing_deg":90.0}
 ]}"#;

#[test]
fn current_schema_version_is_serialized_and_accepted() {
    let fixture = Fixture::from_json(DART_EXPORTED).expect("v1 fixture parses");
    assert_eq!(fixture.trace.len(), 2);
    assert!(fixture.route.is_some(), "embedded route is retained");
    assert_eq!(
        fixture.to_json(),
        fixture.to_json(),
        "serialization is deterministic"
    );
    assert!(
        fixture
            .to_json()
            .starts_with(&format!("{{\"schema_version\":{FIXTURE_SCHEMA_VERSION},"))
    );
}

#[test]
fn legacy_fixture_without_version_still_parses() {
    let doc = r#"{"fixes":[
        {"timestamp_ms":0,"latitude":52.5,"longitude":13.4},
        {"timestamp_ms":1000,"latitude":52.5,"longitude":13.4001}]}"#;
    let trace = GpsTrace::from_json(doc).expect("legacy fixture parses");
    assert_eq!(trace.len(), 2);
}

#[test]
fn future_schema_version_is_rejected_with_actionable_message() {
    let message = rejection(r#"{"schema_version":2,"fixes":[]}"#);
    assert!(
        message.contains("unsupported fixture schema_version 2"),
        "{message}"
    );
    assert!(message.contains("supported: 1"), "{message}");
    assert!(message.contains("regenerate"), "{message}");
}

#[test]
fn malformed_schema_version_is_rejected() {
    let message = rejection(r#"{"schema_version":"1","fixes":[]}"#);
    assert!(message.contains("schema_version"), "{message}");
    let message = rejection(r#"{"schema_version":1.5,"fixes":[]}"#);
    assert!(message.contains("must be an integer"), "{message}");
}

#[test]
fn dart_exporter_shape_round_trips_every_sensor_field() {
    let fixture = Fixture::from_json(DART_EXPORTED).expect("dart-shaped fixture parses");
    let fixes = fixture.trace.fixes();

    assert_eq!(fixes[0].accuracy.map(|a| a.meters()), Some(47.5));
    assert_eq!(fixes[0].altitude, None);
    assert_eq!(fixes[0].speed, None);
    assert_eq!(fixes[0].bearing, None);

    assert_eq!(
        fixes[1].accuracy, None,
        "null accuracy stays missing, not 0 m"
    );
    assert_eq!(fixes[1].altitude, Some(60.0));
    assert_eq!(fixes[1].speed.map(|s| s.mps()), Some(3.25));
    assert_eq!(fixes[1].bearing.map(|b| b.as_degrees()), Some(90.0));

    // Re-parsing our own output yields exactly the same document again.
    let re = Fixture::from_json(&fixture.to_json()).expect("reparse");
    assert_eq!(re.to_json(), fixture.to_json());
}

#[test]
fn trace_only_json_also_carries_the_schema_version() {
    let doc = r#"{"fixes":[
        {"timestamp_ms":0,"latitude":52.5,"longitude":13.4},
        {"timestamp_ms":1000,"latitude":52.5,"longitude":13.4001}]}"#;
    let trace = GpsTrace::from_json(doc).expect("trace parses");
    assert!(trace.to_json().contains("\"schema_version\":1"));
    assert!(trace.to_json().contains("\"fixes\":["));
}
