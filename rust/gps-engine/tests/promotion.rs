// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Regression tests for the promoted adaptive pipeline.
//!
//! The batch audit path must keep one audit row per raw fix, map estimator
//! rejections onto the public reason enum, and still keep the final timestamp
//! in the cleaned track at its estimated coordinate. These contracts are what
//! let Flutter keep the v1 audit model while the production filter changes.

use gps_engine::filtering::{EstimatorConfig, estimate_fixes};
use gps_engine::geo::Coordinate;
use gps_engine::gps::{GpsFix, GpsTrace, RejectionReason};
use gps_engine::track::{FilterConfig, FilterReason};
use gps_engine::units::Timestamp;

const STEP: f64 = 0.000_05;

fn fix(lat: f64, lon: f64, second: i64) -> GpsFix {
    GpsFix::new(
        Timestamp::from_unix_secs(second as f64),
        Coordinate::new(lat, lon).expect("valid coordinate"),
    )
}

#[test]
fn promoted_batch_audits_rejections_and_forces_the_endpoint() {
    let mut fixes: Vec<GpsFix> = (0..12)
        .map(|i| fix(52.5 + i as f64 * STEP, 13.4, i))
        .collect();
    // 300 m in 7 s: below the speed ceiling but over the jump ceiling, so the
    // reason is unambiguously `Jump` rather than `ImpossibleSpeed`.
    let spike = fix(52.5 + 0.0027, 13.4, 18);
    fixes.push(spike);
    for i in 12..17 {
        fixes.push(fix(52.5 + i as f64 * STEP, 13.4, i + 8));
    }
    let endpoint = fix(52.5, 13.5, 25);
    fixes.push(endpoint);

    let processed = GpsTrace::new(fixes.clone())
        .expect("valid trace")
        .process(&FilterConfig::default())
        .expect("process");

    assert_eq!(processed.samples.len(), fixes.len());
    assert_eq!(processed.report.input_points, fixes.len());
    assert_eq!(processed.report.output_points, processed.track.len());
    assert_eq!(
        processed.samples.iter().filter(|s| s.accepted).count(),
        processed.track.len()
    );

    let spike_sample = &processed.samples[12];
    assert!(!spike_sample.accepted);
    assert_eq!(
        spike_sample.reason,
        Some(RejectionReason::Filter(FilterReason::Jump))
    );
    assert_eq!(spike_sample.sample.coordinate, spike.coordinate);
    assert!(spike_sample.position_estimate.is_some());
    assert!(
        processed
            .track
            .points()
            .iter()
            .all(|point| point.coordinate() != spike.coordinate),
        "the rejected spike entered the cleaned track"
    );

    let endpoint_sample = processed.samples.last().expect("one sample per fix");
    assert!(endpoint_sample.accepted);
    assert_eq!(endpoint_sample.reason, None);

    // A rejected closing fix still occupies the final timestamp, but at the
    // estimator's position: the raw wobble must not become a fake finish chord.
    let adaptive = estimate_fixes(
        &fixes,
        &EstimatorConfig::from_filter(&FilterConfig::default()),
    );
    let estimated_endpoint = adaptive.fixes.last().expect("one row per fix");
    assert_ne!(estimated_endpoint.coordinate, endpoint.coordinate);
    assert_eq!(
        processed.track.end().expect("non-empty track").coordinate(),
        estimated_endpoint.coordinate
    );
}
