// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! End-to-end engine pipeline (M15.10): raw GPS fixture in, ghost snapshot out.
//!
//! The unit suites each cover one stage; this test wires the *whole* M15
//! pipeline together on real fixture data so integrators have one place to see
//! (and run) the raw → processed → route-axis → ghost flow:
//!
//! ```text
//! Fixture::from_json → normalized → process(FilterConfig) → project with
//! continuity → Attempt::from_track → Ghost::snapshot
//! ```

use std::fs;

use gps_engine::geo::project_to_polyline;
use gps_engine::gps::Fixture;
use gps_engine::route::ContinuityConfig;
use gps_engine::track::FilterConfig;
use gps_engine::units::Distance;
use gps_engine::{Attempt, Ghost};

fn fixture(name: &str) -> Fixture {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    Fixture::from_json(&fs::read_to_string(&path).expect("fixture exists")).expect("fixture parses")
}

fn pipeline(name: &str, corridor_m: f64) {
    let fixture = fixture(name);
    let route = fixture.route.clone().expect("fixture embeds its route");

    // 1. raw fixes → validated, chronologically ordered trace.
    let normalized = fixture.trace.normalized();
    assert!(
        !normalized.is_empty(),
        "{name}: fixes survive normalization"
    );
    assert!(
        normalized
            .fixes()
            .windows(2)
            .all(|w| w[1].timestamp.unix_ms() >= w[0].timestamp.unix_ms()),
        "{name}: normalization orders the trace"
    );

    // 2. filter + quality audit.
    let processed = normalized
        .process(&FilterConfig::default())
        .expect("process");
    assert_eq!(
        processed.samples.len(),
        normalized.len(),
        "{name}: one audit per fix"
    );
    assert_eq!(
        processed.accepted(),
        processed.track.points().len(),
        "{name}: accepted count == cleaned length"
    );
    assert!(processed.accepted() >= 2, "{name}: usable track survives");

    // 3. every accepted point lies inside the route corridor.
    for point in processed.track.points() {
        let projection =
            project_to_polyline(point.coordinate(), route.geometry()).expect("route non-empty");
        assert!(
            projection.lateral_error.meters() <= corridor_m,
            "{name}: accepted point is {} m off route",
            projection.lateral_error.meters()
        );
    }

    // 4. project the cleaned track onto the route axis with continuity.
    let series =
        route.project_track_with_continuity(&processed.track, &ContinuityConfig::default());
    assert!(
        !series.is_empty(),
        "{name}: continuity projection is non-empty"
    );

    // 5. reduce to an attempt and race it against itself: a self-race is level.
    let attempt = Attempt::from_track(&processed.track, &route);
    let ghost = Ghost::new(attempt.clone(), attempt);
    let half = Distance::from_meters(route.length().meters() * 0.5);
    if let Some(snapshot) = ghost.snapshot_at_distance(half) {
        assert!(
            snapshot.state.time_difference.as_secs().abs() < 1e-9,
            "{name}: a self-race is level"
        );
        assert!(!snapshot.state.ahead, "{name}: level is not ahead");
        assert!(
            (0.0..=1.0).contains(&snapshot.confidence),
            "{name}: confidence is a probability"
        );
    }
}

#[test]
fn raw_fixture_flows_to_a_ghost_snapshot() {
    pipeline("clean_loop.json", 20.0);
    pipeline("gps_jitter.json", 40.0);
    pipeline("gps_dropout.json", 20.0);
    pipeline("out_and_back.json", 20.0);
}
