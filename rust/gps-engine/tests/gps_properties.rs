// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests for the M15 raw-GPS module: the hand-rolled JSON schema
//! must round-trip, parse without panicking on arbitrary input, and keep its
//! audit invariant under `process`.

use gps_engine::Coordinate;
use gps_engine::geo::Bearing;
use gps_engine::gps::{GpsFix, GpsTrace};
use gps_engine::track::FilterConfig;
use gps_engine::units::{Distance, Speed, Timestamp};
use proptest::prelude::*;

fn coord() -> impl Strategy<Value = Coordinate> {
    (-89.9f64..89.9, -180.0f64..180.0)
        .prop_map(|(lat, lon)| Coordinate::new(lat, lon).expect("strategy stays in range"))
}

fn fix() -> impl Strategy<Value = GpsFix> {
    (
        0i64..4_000_000_000_000i64, // ms up to ~2096
        coord(),
        proptest::option::of((0.0f64..500.0).prop_map(Distance::from_meters)),
        proptest::option::of(-500.0f64..9_000.0),
        proptest::option::of((0.0f64..40.0).prop_map(Speed::from_mps)),
        proptest::option::of((0.0f64..360.0).prop_map(|d| Bearing::from_degrees(d).unwrap())),
    )
        .prop_map(
            |(timestamp, coordinate, accuracy, altitude, speed, bearing)| GpsFix {
                timestamp: Timestamp::from_unix_ms(timestamp),
                coordinate,
                accuracy,
                altitude,
                speed,
                bearing,
            },
        )
}

fn trace() -> impl Strategy<Value = GpsTrace> {
    proptest::collection::vec(fix(), 2..40)
        .prop_map(|fixes| GpsTrace::new(fixes).expect("two or more fixes"))
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(256))]

    #[test]
    fn trace_round_trips_through_json(trace in trace()) {
        let json = trace.to_json();
        let reparsed = GpsTrace::from_json(&json).expect("serializer is self-consistent");
        prop_assert_eq!(reparsed.to_json(), json, "serialization is idempotent");
        prop_assert_eq!(reparsed.len(), trace.len());
    }

    #[test]
    fn arbitrary_bytes_never_panic(bytes in proptest::collection::vec(any::<u8>(), 0..4096)) {
        let text = String::from_utf8_lossy(&bytes);
        // Must never panic; Ok or Err are both fine for garbage input.
        let _ = GpsTrace::from_json(&text);
    }

    #[test]
    fn processing_keeps_the_audit_invariant(trace in trace()) {
        if let Ok(processed) = trace.process(&FilterConfig::default()) {
            prop_assert_eq!(processed.samples.len(), trace.len());
            prop_assert_eq!(
                processed.accepted(),
                processed.track.points().len(),
                "accepted must equal cleaned length"
            );
            for sample in &processed.samples {
                if !sample.accepted {
                    prop_assert!(sample.reason.is_some(), "rejections carry a reason");
                }
            }
        }
        // A degenerate trace (everything filtered / too few unique points)
        // surfaces a typed error instead of a panic; nothing to assert then.
    }
}
