// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Deterministic GPS quality baseline regression.

use std::path::Path;

use gps_engine::quality_metrics::{QualityReport, ShadowQualityMetrics, benchmark_scenarios};

const BASELINE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/testdata/baselines/gps_quality_v1.json"
);

fn assert_finite_shadow_metrics(s: ShadowQualityMetrics, name: &str) {
    for (field, value) in [
        ("distance_m", s.distance_m),
        ("distance_error_pct", s.distance_error_pct),
        ("position_rmse_m", s.position_rmse_m),
        ("position_max_error_m", s.position_max_error_m),
        ("route_distance_m", s.route_distance_m),
        ("route_distance_error_pct", s.route_distance_error_pct),
        ("projection_mae_m", s.projection_mae_m),
        ("projection_max_error_m", s.projection_max_error_m),
        ("pace_mae_s_per_km", s.pace_mae_s_per_km),
        ("truth_elevation_gain_m", s.truth_elevation_gain_m),
        ("truth_elevation_loss_m", s.truth_elevation_loss_m),
        ("raw_elevation_gain_error_m", s.raw_elevation_gain_error_m),
        ("raw_elevation_loss_error_m", s.raw_elevation_loss_error_m),
        ("elevation_gain_error_m", s.elevation_gain_error_m),
        ("elevation_loss_error_m", s.elevation_loss_error_m),
        ("ghost_gap_mae_s", s.ghost_gap_mae_s),
        ("false_movement_m", s.false_movement_m),
        ("false_movement_m_per_min", s.false_movement_m_per_min),
        ("recovery_mean_s", s.recovery_mean_s),
        ("recovery_max_s", s.recovery_max_s),
    ] {
        assert!(value.is_finite(), "{name}: shadow.{field} was {value}");
    }
}

#[test]
fn committed_baseline_matches_generated_report() {
    let expected = std::fs::read_to_string(Path::new(BASELINE))
        .expect("baseline exists; run `cargo run --example quality_benchmark -- --json ...`");
    let actual = QualityReport::from_scenarios(&benchmark_scenarios()).to_json();
    assert_eq!(
        actual, expected,
        "regenerate the baseline only after reviewing the metric change"
    );
}

#[test]
fn phase_two_ghost_gate() {
    let report = QualityReport::from_scenarios(&benchmark_scenarios());
    let urban = report
        .scenarios
        .iter()
        .find(|s| s.name == "urban_canyon")
        .expect("urban scenario");
    // The frozen-anchor failure produced >200 s of ghost-gap error and >360 m
    // of projection error on the adaptive axis. Recovery must keep both near
    // the clean-scenario noise floor.
    assert!(urban.metrics.shadow.ghost_gap_mae_s < 5.0);
    assert!(urban.metrics.shadow.projection_mae_m < 20.0);
    assert!(urban.metrics.ghost_gap_mae_s < 100.0);
    for scenario in &report.scenarios {
        assert!(
            scenario.metrics.shadow.ghost_gap_mae_s < 5.0,
            "{}: shadow gap {}",
            scenario.name,
            scenario.metrics.shadow.ghost_gap_mae_s
        );
    }
}

#[test]
fn rolling_pace_gate() {
    let report = QualityReport::from_scenarios(&benchmark_scenarios());
    let by_name = |name: &str| {
        report
            .scenarios
            .iter()
            .find(|s| s.name == name)
            .unwrap_or_else(|| panic!("{name} scenario"))
            .metrics
    };

    // The old two-fix pace scored 150–350 s/km on these degradations while
    // stationary drift alone contributed 277 s/km. A 15 s displacement window
    // keeps the same errors in the tens, without losing clean-scene accuracy.
    for name in [
        "jitter_5m",
        "jitter_12m",
        "gps_jumps",
        "urban_canyon",
        "forest_trail",
        "reverse",
    ] {
        let m = by_name(name);
        assert!(
            m.pace_mae_s_per_km < 130.0,
            "{name}: raw {}",
            m.pace_mae_s_per_km
        );
        assert!(
            m.shadow.pace_mae_s_per_km < 95.0,
            "{name}: shadow {}",
            m.shadow.pace_mae_s_per_km
        );
    }
    let clean = by_name("clean");
    assert!(clean.shadow.pace_mae_s_per_km < 5.0);
    let stationary = by_name("stationary_drift");
    assert!(stationary.shadow.pace_mae_s_per_km < 60.0);
}

#[test]
fn elevation_noise_gate() {
    let report = QualityReport::from_scenarios(&benchmark_scenarios());
    let scenario = report
        .scenarios
        .iter()
        .find(|s| s.name == "elevation_noise")
        .expect("elevation scenario");
    let m = scenario.metrics;
    assert!(
        m.truth_elevation_gain_m > 100.0,
        "ground truth must contain real climbing"
    );
    assert!(
        m.raw_elevation_gain_error_m > 1_000.0,
        "raw gain must expose the noise problem: {}",
        m.raw_elevation_gain_error_m
    );
    assert!(
        m.elevation_gain_error_m < 100.0,
        "robust gain: {}",
        m.elevation_gain_error_m
    );
    assert!(
        m.elevation_loss_error_m < 100.0,
        "robust loss: {}",
        m.elevation_loss_error_m
    );
    assert!(m.shadow.elevation_gain_error_m < 100.0);
    assert!(m.shadow.elevation_loss_error_m < 100.0);
}

#[test]
fn baseline_exposes_all_documented_metrics() {
    let report = QualityReport::from_scenarios(&benchmark_scenarios());
    assert_eq!(report.scenarios.len(), 11);
    let json = report.to_json();
    assert_eq!(
        json.matches("\"shadow\": {").count(),
        report.scenarios.len(),
        "every scenario exposes a nested shadow object"
    );
    assert!(json.contains("\"rejection_resets\":"));
    for scenario in &report.scenarios {
        let m = scenario.metrics;
        assert!(m.truth_distance_m > 0.0, "{}", scenario.name);
        assert!(m.raw_distance_m.is_finite(), "{}", scenario.name);
        assert!(m.filtered_distance_m.is_finite(), "{}", scenario.name);
        assert!(m.route_distance_m.is_finite(), "{}", scenario.name);
        assert!(m.position_rmse_m.is_finite(), "{}", scenario.name);
        assert!(m.pace_mae_s_per_km.is_finite(), "{}", scenario.name);
        assert!(m.ghost_gap_mae_s.is_finite(), "{}", scenario.name);
        assert!(m.false_movement_m.is_finite(), "{}", scenario.name);
        assert_finite_shadow_metrics(m.shadow, &scenario.name);
        assert_eq!(
            m.shadow.accepted_fixes + m.shadow.rejected_fixes,
            m.observed_points,
            "{}: every observation has one adaptive decision",
            scenario.name
        );
        let point_fraction = m.observed_points as f64 / 2000.0;
        assert!((0.0..=1.0).contains(&point_fraction));
    }

    let clean = report
        .scenarios
        .iter()
        .find(|s| s.name == "clean")
        .expect("clean scenario");
    assert!(clean.metrics.raw_distance_error_pct < 1.0);
    assert!(clean.metrics.position_rmse_m < 1e-6);
    assert_eq!(clean.metrics.false_movement_m, 0.0);

    let drift = report
        .scenarios
        .iter()
        .find(|s| s.name == "stationary_drift")
        .expect("stationary scenario");
    assert!(drift.metrics.false_movement_m > 0.0);

    let outage = report
        .scenarios
        .iter()
        .find(|s| s.name == "outage_25pct")
        .expect("outage scenario");
    assert!(outage.metrics.outage_windows > 0);
    assert!(outage.metrics.recoveries > 0);
}
