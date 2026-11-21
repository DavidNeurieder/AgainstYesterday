// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Quantitative GPS quality metrics with synthetic ground truth.
//!
//! The existing `evaluate` module answers one question — do two recordings
//! belong to the same route? — and pins a precision/recall/F1 baseline for it.
//! This module answers a different question: how far is the engine's output
//! from what actually happened? It scores raw distance, filtered distance,
//! route progress, position, pace, ghost gap, stationary drift and outage
//! recovery against the clean trajectory retained by the synthetic generator.
//!
//! Everything here is deterministic: no wall clock, no randomness outside the
//! seeded generator, and no floating-point ordering from hash iteration.

use std::collections::HashMap;

use crate::attempt::{Attempt, AttemptSample};
use crate::filtering::{AdaptiveResult, EstimatorConfig, estimate_fixes};
use crate::geo::{Coordinate, bearing, distance as geo_distance};
use crate::ghost::Ghost;
use crate::gps::GpsFix;
use crate::route::{ContinuityConfig, Route, RouteMatcher, RouteObservation};
use crate::synthetic::{GroundTruthSample, SyntheticConfig, generate_with_truth};
use crate::track::{Track, TrackPoint};
use crate::units::{Distance, Duration, Speed, Timestamp};
use crate::{FilterConfig, filter};

/// Maximum progress error that counts as recovered after an outage.
const RECOVERY_PROGRESS_TOLERANCE_M: f64 = 20.0;
/// Number of seconds used for rolling observed speed before scoring pace.
const PACE_WINDOW_SAMPLES: usize = 5;

/// A generated observation plus the route and truth needed to score it.
#[derive(Debug, Clone, PartialEq)]
pub struct QualityScenario {
    /// Stable scenario name used in reports and baselines.
    pub name: String,
    /// The oriented route the runner actually followed.
    pub route: Vec<Coordinate>,
    /// Noisy observed fixes.
    pub observed: Track,
    /// Clean ground-truth rows, including dropped samples.
    pub truth: Vec<GroundTruthSample>,
}

impl QualityScenario {
    /// Builds a scenario from a route and a deterministic generator preset.
    pub fn from_synthetic(
        name: impl Into<String>,
        geometry: &[Coordinate],
        config: &SyntheticConfig,
    ) -> Self {
        let mut oriented = geometry.to_vec();
        if config.reverse {
            oriented.reverse();
        }
        let result = generate_with_truth(geometry, config);
        QualityScenario {
            name: name.into(),
            route: oriented,
            observed: result.observed,
            truth: result.truth,
        }
    }
}

/// Metrics for the default-off adaptive estimator running in shadow mode.
///
/// These values never replace the legacy columns above. They let Gate B compare
/// the same ground truth through both pipelines before any promotion decision.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ShadowQualityMetrics {
    /// Ground distance on the adaptive axis, in meters.
    pub distance_m: f64,
    /// Absolute error of adaptive distance, as a percentage of truth.
    pub distance_error_pct: f64,
    /// Root-mean-square position error against truth, in meters.
    pub position_rmse_m: f64,
    /// Worst position error against truth, in meters.
    pub position_max_error_m: f64,
    /// Monotone route progress measured from adaptive positions, in meters.
    pub route_distance_m: f64,
    /// Absolute error of adaptive route progress, as a percentage of truth.
    pub route_distance_error_pct: f64,
    /// Mean absolute adaptive route-projection error, in meters.
    pub projection_mae_m: f64,
    /// Worst adaptive route-projection error, in meters.
    pub projection_max_error_m: f64,
    /// Mean absolute rolling-pace error, in seconds per kilometre.
    pub pace_mae_s_per_km: f64,
    /// Mean absolute ghost time-gap error, in seconds.
    pub ghost_gap_mae_s: f64,
    /// Distance accepted while truth was stationary, in meters.
    pub false_movement_m: f64,
    /// False movement per stationary minute, in meters.
    pub false_movement_m_per_min: f64,
    /// Mean outage recovery delay, in seconds.
    pub recovery_mean_s: f64,
    /// Worst outage recovery delay, in seconds.
    pub recovery_max_s: f64,
    /// Number of outage windows found in truth.
    pub outage_windows: usize,
    /// Number of outage windows that recovered within the tolerance.
    pub recoveries: usize,
    /// Observations fused into the adaptive estimate.
    pub accepted_fixes: usize,
    /// Observations rejected by the adaptive gate.
    pub rejected_fixes: usize,
    /// Fixes classified as stationary.
    pub stationary_fixes: usize,
    /// Fixes where smoothing was reduced to preserve a corner.
    pub corner_fixes: usize,
    /// Filter resets after a long GPS outage.
    pub gap_resets: usize,
    /// Filter re-anchors after sustained rejection of good-looking fixes.
    pub rejection_resets: usize,
}

/// All error metrics for one scenario.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct QualityMetrics {
    /// Reference route length from ground truth, in meters.
    pub truth_distance_m: f64,
    /// Distance of the untouched observed fixes, in meters.
    pub raw_distance_m: f64,
    /// Distance after the standard matching filter, in meters.
    pub filtered_distance_m: f64,
    /// Monotone route progress measured by projection, in meters.
    pub route_distance_m: f64,
    /// Absolute error of raw distance, as a percentage of truth.
    pub raw_distance_error_pct: f64,
    /// Absolute error of filtered distance, as a percentage of truth.
    pub filtered_distance_error_pct: f64,
    /// Absolute error of route progress, as a percentage of truth.
    pub route_distance_error_pct: f64,
    /// Root-mean-square position error against truth, in meters.
    pub position_rmse_m: f64,
    /// Worst position error against truth, in meters.
    pub position_max_error_m: f64,
    /// Mean absolute route-projection error, in meters.
    pub projection_mae_m: f64,
    /// Worst route-projection error, in meters.
    pub projection_max_error_m: f64,
    /// Mean absolute rolling-pace error, in seconds per kilometre.
    pub pace_mae_s_per_km: f64,
    /// Mean absolute ghost time-gap error, in seconds.
    pub ghost_gap_mae_s: f64,
    /// Distance accepted while truth was stationary, in meters.
    pub false_movement_m: f64,
    /// False movement per stationary minute, in meters.
    pub false_movement_m_per_min: f64,
    /// Mean outage recovery delay, in seconds.
    pub recovery_mean_s: f64,
    /// Worst outage recovery delay, in seconds.
    pub recovery_max_s: f64,
    /// Number of outage windows found in truth.
    pub outage_windows: usize,
    /// Number of outage windows that recovered within the tolerance.
    pub recoveries: usize,
    /// Number of observed fixes scored.
    pub observed_points: usize,
    /// Default-off adaptive estimator metrics for the same input.
    pub shadow: ShadowQualityMetrics,
}

/// Metrics for a named scenario.
#[derive(Debug, Clone, PartialEq)]
pub struct ScenarioQuality {
    /// Scenario name copied from the input.
    pub name: String,
    /// Computed metrics.
    pub metrics: QualityMetrics,
}

/// A deterministic, printable benchmark report.
#[derive(Debug, Clone, PartialEq)]
pub struct QualityReport {
    /// Per-scenario results in input order.
    pub scenarios: Vec<ScenarioQuality>,
}

impl QualityReport {
    /// Scores every scenario and keeps the report in input order.
    pub fn from_scenarios(scenarios: &[QualityScenario]) -> Self {
        QualityReport {
            scenarios: scenarios
                .iter()
                .map(|scenario| ScenarioQuality {
                    name: scenario.name.clone(),
                    metrics: score(scenario),
                })
                .collect(),
        }
    }

    /// Fixed-width text summary for CLI/example output.
    pub fn report(&self) -> String {
        let mut out = String::from(
            "scenario              points  dist%   filt%   route%   RMSEm  projm  pace/km  gap s  driftm  rec s  sh dist%  sh RMSE  sh drift\n\
             ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n",
        );
        for scenario in &self.scenarios {
            let m = scenario.metrics;
            out.push_str(&format!(
                "{:<20} {:>6}  {:>6.2}  {:>6.2}  {:>7.2}  {:>6.2}  {:>5.2}  {:>8.2}  {:>5.2}  {:>7.2}  {:>5.2}  {:>8.2}  {:>7.2}  {:>8.2}\n",
                scenario.name,
                m.observed_points,
                m.raw_distance_error_pct,
                m.filtered_distance_error_pct,
                m.route_distance_error_pct,
                m.position_rmse_m,
                m.projection_mae_m,
                m.pace_mae_s_per_km,
                m.ghost_gap_mae_s,
                m.false_movement_m,
                m.recovery_mean_s,
                m.shadow.distance_error_pct,
                m.shadow.position_rmse_m,
                m.shadow.false_movement_m,
            ));
        }
        out
    }

    /// Stable machine-readable JSON without external serialization crates.
    pub fn to_json(&self) -> String {
        let mut out = String::from(
            "{\n  \"schema_version\": 1,\n  \"source\": \"synthetic\",\n  \"generator\": \"gps_engine::quality_metrics::benchmark_scenarios\",\n  \"scenarios\": [\n",
        );
        for (i, scenario) in self.scenarios.iter().enumerate() {
            let m = scenario.metrics;
            out.push_str("    {\n");
            out.push_str(&format!(
                "      \"name\": \"{}\",\n\
                 \"truth_distance_m\": {},\n\
                 \"raw_distance_m\": {},\n\
                 \"filtered_distance_m\": {},\n\
                 \"route_distance_m\": {},\n\
                 \"raw_distance_error_pct\": {},\n\
                 \"filtered_distance_error_pct\": {},\n\
                 \"route_distance_error_pct\": {},\n\
                 \"position_rmse_m\": {},\n\
                 \"position_max_error_m\": {},\n\
                 \"projection_mae_m\": {},\n\
                 \"projection_max_error_m\": {},\n\
                 \"pace_mae_s_per_km\": {},\n\
                 \"ghost_gap_mae_s\": {},\n\
                 \"false_movement_m\": {},\n\
                 \"false_movement_m_per_min\": {},\n\
                 \"recovery_mean_s\": {},\n\
                 \"recovery_max_s\": {},\n\
                 \"outage_windows\": {},\n\
                 \"recoveries\": {},\n\
                 \"observed_points\": {},\n",
                json_escape(&scenario.name),
                json_f64(m.truth_distance_m),
                json_f64(m.raw_distance_m),
                json_f64(m.filtered_distance_m),
                json_f64(m.route_distance_m),
                json_f64(m.raw_distance_error_pct),
                json_f64(m.filtered_distance_error_pct),
                json_f64(m.route_distance_error_pct),
                json_f64(m.position_rmse_m),
                json_f64(m.position_max_error_m),
                json_f64(m.projection_mae_m),
                json_f64(m.projection_max_error_m),
                json_f64(m.pace_mae_s_per_km),
                json_f64(m.ghost_gap_mae_s),
                json_f64(m.false_movement_m),
                json_f64(m.false_movement_m_per_min),
                json_f64(m.recovery_mean_s),
                json_f64(m.recovery_max_s),
                m.outage_windows,
                m.recoveries,
                m.observed_points,
            ));
            out.push_str(&shadow_json(m.shadow));
            let comma = if i + 1 < self.scenarios.len() {
                ","
            } else {
                ""
            };
            out.push_str(&format!("    }}{comma}\n"));
        }
        out.push_str("  ]\n}\n");
        out
    }
}

/// Scores one scenario against its ground truth.
pub fn score(scenario: &QualityScenario) -> QualityMetrics {
    let truth = &scenario.truth;
    let observed = &scenario.observed;
    let truth_by_time: HashMap<i64, GroundTruthSample> = truth
        .iter()
        .map(|sample| (sample.timestamp.unix_ms(), *sample))
        .collect();

    let truth_distance = truth.last().map_or(0.0, |s| s.route_distance.max(0.0));
    let filtered = filter(observed, &FilterConfig::matching()).0;
    let raw_distance = observed.distance().meters();
    let filtered_distance = filtered.distance().meters();

    let projections = route_projections(observed.points(), &scenario.route);
    let route_distance = projections.last().map_or(0.0, |p| p.1);
    let (position_errors, projection_errors) =
        error_vectors(observed.points(), &projections, &truth_by_time);

    let pace_mae = pace_error(observed.points(), &truth_by_time);
    let ghost_gap_mae = ghost_gap_error(truth, truth_distance, &projections);
    let (false_movement, stationary_minutes) =
        false_movement_for_points(observed.points(), &truth_by_time, truth);
    let (recovery_mean, recovery_max, windows, recoveries) = recovery(truth, &projections);

    let adaptive = estimate_fixes(&gps_fixes(observed), &EstimatorConfig::shadow());
    let shadow = score_shadow(&adaptive, scenario, &truth_by_time, truth_distance);

    QualityMetrics {
        truth_distance_m: truth_distance,
        raw_distance_m: raw_distance,
        filtered_distance_m: filtered_distance,
        route_distance_m: route_distance,
        raw_distance_error_pct: pct_error(raw_distance, truth_distance),
        filtered_distance_error_pct: pct_error(filtered_distance, truth_distance),
        route_distance_error_pct: pct_error(route_distance, truth_distance),
        position_rmse_m: rmse(&position_errors),
        position_max_error_m: max_or_zero(&position_errors),
        projection_mae_m: mean(&projection_errors),
        projection_max_error_m: max_or_zero(&projection_errors),
        pace_mae_s_per_km: pace_mae,
        ghost_gap_mae_s: ghost_gap_mae,
        false_movement_m: false_movement,
        false_movement_m_per_min: if stationary_minutes > 0.0 {
            false_movement / stationary_minutes
        } else {
            0.0
        },
        recovery_mean_s: recovery_mean,
        recovery_max_s: recovery_max,
        outage_windows: windows,
        recoveries,
        observed_points: observed.points().len(),
        shadow,
    }
}

/// Scores the adaptive estimator without changing the legacy metrics.
fn score_shadow(
    adaptive: &AdaptiveResult,
    scenario: &QualityScenario,
    truth_by_time: &HashMap<i64, GroundTruthSample>,
    truth_distance: f64,
) -> ShadowQualityMetrics {
    let points = &adaptive.points;
    let projections = route_projections(points, &scenario.route);
    let route_distance = projections.last().map_or(0.0, |p| p.1);
    let (position_errors, projection_errors) = error_vectors(points, &projections, truth_by_time);
    let pace_mae = pace_error(points, truth_by_time);
    let ghost_gap_mae = ghost_gap_error(&scenario.truth, truth_distance, &projections);
    let (false_movement, stationary_minutes) =
        false_movement_for_points(points, truth_by_time, &scenario.truth);
    let (recovery_mean, recovery_max, windows, recoveries) =
        recovery(&scenario.truth, &projections);
    let distance = adaptive.distance.meters();
    let report = adaptive.report;

    ShadowQualityMetrics {
        distance_m: distance,
        distance_error_pct: pct_error(distance, truth_distance),
        position_rmse_m: rmse(&position_errors),
        position_max_error_m: max_or_zero(&position_errors),
        route_distance_m: route_distance,
        route_distance_error_pct: pct_error(route_distance, truth_distance),
        projection_mae_m: mean(&projection_errors),
        projection_max_error_m: max_or_zero(&projection_errors),
        pace_mae_s_per_km: pace_mae,
        ghost_gap_mae_s: ghost_gap_mae,
        false_movement_m: false_movement,
        false_movement_m_per_min: if stationary_minutes > 0.0 {
            false_movement / stationary_minutes
        } else {
            0.0
        },
        recovery_mean_s: recovery_mean,
        recovery_max_s: recovery_max,
        outage_windows: windows,
        recoveries,
        accepted_fixes: report.accepted,
        rejected_fixes: report.rejected(),
        stationary_fixes: report.stationary_fixes,
        corner_fixes: report.corner_fixes,
        gap_resets: report.gap_resets,
        rejection_resets: report.rejection_resets,
    }
}

/// Converts an observed track back to the raw fixes an estimator sees.
fn gps_fixes(observed: &Track) -> Vec<GpsFix> {
    observed
        .points()
        .iter()
        .map(|point| GpsFix {
            timestamp: point.timestamp(),
            coordinate: point.coordinate(),
            accuracy: point.accuracy().map(Distance::from_meters),
            altitude: point.altitude(),
            speed: point.speed().map(Speed::from_mps),
            bearing: point.bearing(),
        })
        .collect()
}

/// Continuity-aware progress for a sequence of points.
///
/// The engine's own matcher is used rather than a nearest-point projection: on
/// a closed loop a global projection keeps snapping back to earlier segments,
/// which is not the progress axis the app actually uses.
fn route_projections(points: &[TrackPoint], geometry: &[Coordinate]) -> Vec<(Timestamp, f64)> {
    let mut projections: Vec<(Timestamp, f64)> = Vec::with_capacity(points.len());
    let Ok(route) = Route::new(geometry.to_vec()) else {
        return projections;
    };
    let mut matcher = RouteMatcher::new(ContinuityConfig::default());
    // Closed loops share their start and finish coordinate; without an
    // explicit seed the first noisy fix can be re-anchored at the finish.
    matcher.seed(Distance::ZERO);
    for (index, point) in points.iter().enumerate() {
        let (derived_speed, derived_bearing) = if index == 0 {
            (None, None)
        } else {
            let previous = &points[index - 1];
            let dt = point
                .timestamp()
                .elapsed_since(previous.timestamp())
                .as_secs();
            let speed = if dt > 0.0 {
                Some(Speed::from_mps(
                    geo_distance(previous.coordinate(), point.coordinate()).meters() / dt,
                ))
            } else {
                None
            };
            (
                speed,
                bearing(previous.coordinate(), point.coordinate()).ok(),
            )
        };
        let observation = RouteObservation {
            coordinate: point.coordinate(),
            timestamp: point.timestamp(),
            accuracy: point.accuracy().map(Distance::from_meters),
            speed: point.speed().map(Speed::from_mps).or(derived_speed),
            bearing: point.bearing().or(derived_bearing),
        };
        let step = matcher.update_observation(&route, &observation);
        projections.push((point.timestamp(), step.projection.distance.meters()));
    }
    projections
}

/// Position and projection errors against truth at matching timestamps.
fn error_vectors(
    points: &[TrackPoint],
    projections: &[(Timestamp, f64)],
    truth_by_time: &HashMap<i64, GroundTruthSample>,
) -> (Vec<f64>, Vec<f64>) {
    let mut position_errors = Vec::new();
    let mut projection_errors = Vec::new();
    for (point, (_, along)) in points.iter().zip(projections.iter()) {
        if let Some(truth) = truth_by_time.get(&point.timestamp().unix_ms()) {
            position_errors.push(geo_distance(point.coordinate(), truth.coordinate).meters());
            projection_errors.push((along - truth.route_distance).abs());
        }
    }
    (position_errors, projection_errors)
}

/// A deterministic set of scenarios covering the documented degradations.
pub fn benchmark_scenarios() -> Vec<QualityScenario> {
    let route = benchmark_route();
    vec![
        QualityScenario::from_synthetic("clean", &route, &SyntheticConfig::clean(101)),
        QualityScenario::from_synthetic("jitter_5m", &route, &SyntheticConfig::noisy(102, 5.0)),
        QualityScenario::from_synthetic("jitter_12m", &route, &SyntheticConfig::noisy(103, 12.0)),
        QualityScenario::from_synthetic("sparse", &route, &SyntheticConfig::sparse(104)),
        QualityScenario::from_synthetic("outage_25pct", &route, &SyntheticConfig::gapped(105)),
        QualityScenario::from_synthetic(
            "stationary_drift",
            &route,
            &SyntheticConfig {
                position_noise: Distance::ZERO,
                stop_probability: 0.3,
                stationary_drift: Distance::from_meters(6.0),
                seed: 106,
                ..SyntheticConfig::default()
            },
        ),
        QualityScenario::from_synthetic("gps_jumps", &route, &SyntheticConfig::outliers(107)),
        QualityScenario::from_synthetic(
            "urban_canyon",
            &route,
            &SyntheticConfig {
                sampling_interval: Duration::from_secs(1.0),
                position_noise: Distance::from_meters(14.0),
                gap_probability: 0.08,
                outlier_probability: 0.02,
                stop_probability: 0.01,
                outlier_distance: Distance::from_meters(180.0),
                seed: 108,
                ..SyntheticConfig::default()
            },
        ),
        QualityScenario::from_synthetic(
            "forest_trail",
            &route,
            &SyntheticConfig {
                sampling_interval: Duration::from_secs(2.0),
                position_noise: Distance::from_meters(8.0),
                gap_probability: 0.12,
                outlier_probability: 0.01,
                stop_probability: 0.02,
                outlier_distance: Distance::from_meters(90.0),
                seed: 109,
                ..SyntheticConfig::default()
            },
        ),
        QualityScenario::from_synthetic(
            "reverse",
            &route,
            &SyntheticConfig {
                reverse: true,
                ..SyntheticConfig::noisy(110, 5.0)
            },
        ),
    ]
}

/// The same ~4.9 km loop used by the checked-in matching corpus.
fn benchmark_route() -> Vec<Coordinate> {
    vec![
        // Short distinct lead-in/tail keep the closed loop from anchoring the
        // matcher at its finish on the first noisy fix.
        Coordinate::new(52.499_000, 13.400_000).expect("valid coordinate"),
        Coordinate::new(52.500_000, 13.400_000).expect("valid coordinate"),
        Coordinate::new(52.510_815, 13.400_000).expect("valid coordinate"),
        Coordinate::new(52.515_315, 13.410_918).expect("valid coordinate"),
        Coordinate::new(52.507_500, 13.418_836).expect("valid coordinate"),
        Coordinate::new(52.500_000, 13.410_918).expect("valid coordinate"),
        Coordinate::new(52.500_000, 13.400_000).expect("valid coordinate"),
        Coordinate::new(52.499_000, 13.400_700).expect("valid coordinate"),
    ]
}

/// Rolling observed speed compared with the true ground speed.
fn pace_error(points: &[TrackPoint], truth_by_time: &HashMap<i64, GroundTruthSample>) -> f64 {
    let mut observed_speeds: Vec<f64> = Vec::new();
    let mut errors = Vec::new();
    for pair in points.windows(2) {
        let dt = pair[1]
            .timestamp()
            .elapsed_since(pair[0].timestamp())
            .as_secs();
        if dt <= 0.0 {
            continue;
        }
        let (Some(a), Some(b)) = (
            truth_by_time.get(&pair[0].timestamp().unix_ms()),
            truth_by_time.get(&pair[1].timestamp().unix_ms()),
        ) else {
            continue;
        };
        let truth_speed = (a.speed.mps() + b.speed.mps()) / 2.0;
        if truth_speed <= 0.0 {
            continue;
        }
        let measured_speed = geo_distance(pair[0].coordinate(), pair[1].coordinate()).meters() / dt;
        observed_speeds.push(measured_speed);
        let window = observed_speeds
            .iter()
            .rev()
            .take(PACE_WINDOW_SAMPLES)
            .copied()
            .collect::<Vec<_>>();
        let smoothed = mean(&window);
        if smoothed > 0.0 {
            errors.push((1000.0 / smoothed - 1000.0 / truth_speed).abs());
        }
    }
    mean(&errors)
}

/// Ghost gap error at fixed fractions of the reference course.
fn ghost_gap_error(
    truth: &[GroundTruthSample],
    truth_distance: f64,
    projections: &[(Timestamp, f64)],
) -> f64 {
    if let Some(first) = truth.first() {
        let start = first.timestamp;
        let truth_samples: Vec<AttemptSample> = truth
            .iter()
            .map(|sample| AttemptSample {
                distance: Distance::from_meters(sample.route_distance.max(0.0)),
                elapsed: sample.timestamp.elapsed_since(start),
            })
            .collect();
        let observed_samples: Vec<AttemptSample> = projections
            .iter()
            .map(|(timestamp, distance)| AttemptSample {
                distance: Distance::from_meters(*distance),
                elapsed: timestamp.elapsed_since(start),
            })
            .collect();
        if let (Ok(reference), Ok(current)) = (
            Attempt::from_samples(truth_samples),
            Attempt::from_samples(observed_samples),
        ) {
            let ghost = Ghost::new(reference, current);
            let errors: Vec<f64> = [0.1_f64, 0.25, 0.5, 0.75, 0.9]
                .iter()
                .filter_map(|fraction| {
                    ghost
                        .state_at_distance(Distance::from_meters(truth_distance * fraction))
                        .map(|state| state.time_difference.as_secs().abs())
                })
                .collect();
            return mean(&errors);
        }
    }
    0.0
}

/// Distance accumulated while ground truth was stationary.
fn false_movement_for_points(
    points: &[TrackPoint],
    truth_by_time: &HashMap<i64, GroundTruthSample>,
    truth: &[GroundTruthSample],
) -> (f64, f64) {
    let mut false_m = 0.0f64;
    for pair in points.windows(2) {
        let is_stationary = [pair[0].timestamp().unix_ms(), pair[1].timestamp().unix_ms()]
            .iter()
            .all(|ms| truth_by_time.get(ms).is_some_and(|t| t.stationary));
        if is_stationary {
            false_m += geo_distance(pair[0].coordinate(), pair[1].coordinate()).meters();
        }
    }
    (false_m, stationary_minutes(truth))
}

/// Stationary minutes in the ground truth, shared by both pipelines.
fn stationary_minutes(truth: &[GroundTruthSample]) -> f64 {
    let mut stationary_seconds = 0.0f64;
    for pair in truth.windows(2) {
        if pair[1].stationary {
            stationary_seconds += pair[1].timestamp.elapsed_since(pair[0].timestamp).as_secs();
        }
    }
    stationary_seconds / 60.0
}

/// Delay from the end of each truth outage window to reliable progress.
fn recovery(
    truth: &[GroundTruthSample],
    projections: &[(Timestamp, f64)],
) -> (f64, f64, usize, usize) {
    let mut delays = Vec::new();
    let mut windows = 0usize;
    let mut i = 0usize;
    while i < truth.len() {
        if !truth[i].outage {
            i += 1;
            continue;
        }
        windows += 1;
        while i + 1 < truth.len() && truth[i + 1].outage {
            i += 1;
        }
        let outage_end = truth[i].timestamp;
        let Some((next_time, measured)) = projections
            .iter()
            .find(|(timestamp, _)| *timestamp > outage_end)
        else {
            i += 1;
            continue;
        };
        let actual = truth
            .iter()
            .find(|sample| sample.timestamp == *next_time)
            .map_or(*measured, |sample| sample.route_distance);
        if (*measured - actual).abs() <= RECOVERY_PROGRESS_TOLERANCE_M {
            delays.push(next_time.elapsed_since(outage_end).as_secs());
        }
        i += 1;
    }
    (mean(&delays), max_or_zero(&delays), windows, delays.len())
}

fn pct_error(measured: f64, truth: f64) -> f64 {
    if truth <= 0.0 {
        0.0
    } else {
        (measured - truth).abs() / truth * 100.0
    }
}

fn mean(values: &[f64]) -> f64 {
    if values.is_empty() {
        0.0
    } else {
        values.iter().sum::<f64>() / values.len() as f64
    }
}

fn rmse(values: &[f64]) -> f64 {
    if values.is_empty() {
        return 0.0;
    }
    (values.iter().map(|v| v * v).sum::<f64>() / values.len() as f64).sqrt()
}

fn max_or_zero(values: &[f64]) -> f64 {
    values.iter().copied().fold(0.0f64, f64::max)
}

fn shadow_json(s: ShadowQualityMetrics) -> String {
    format!(
        "      \"shadow\": {{\n\
          \"distance_m\": {},\n\
          \"distance_error_pct\": {},\n\
          \"position_rmse_m\": {},\n\
          \"position_max_error_m\": {},\n\
          \"route_distance_m\": {},\n\
          \"route_distance_error_pct\": {},\n\
          \"projection_mae_m\": {},\n\
          \"projection_max_error_m\": {},\n\
          \"pace_mae_s_per_km\": {},\n\
          \"ghost_gap_mae_s\": {},\n\
          \"false_movement_m\": {},\n\
          \"false_movement_m_per_min\": {},\n\
          \"recovery_mean_s\": {},\n\
          \"recovery_max_s\": {},\n\
          \"outage_windows\": {},\n\
          \"recoveries\": {},\n\
          \"accepted_fixes\": {},\n\
          \"rejected_fixes\": {},\n\
          \"stationary_fixes\": {},\n\
          \"corner_fixes\": {},\n\
          \"gap_resets\": {},\n\
          \"rejection_resets\": {}\n\
        }}\n",
        json_f64(s.distance_m),
        json_f64(s.distance_error_pct),
        json_f64(s.position_rmse_m),
        json_f64(s.position_max_error_m),
        json_f64(s.route_distance_m),
        json_f64(s.route_distance_error_pct),
        json_f64(s.projection_mae_m),
        json_f64(s.projection_max_error_m),
        json_f64(s.pace_mae_s_per_km),
        json_f64(s.ghost_gap_mae_s),
        json_f64(s.false_movement_m),
        json_f64(s.false_movement_m_per_min),
        json_f64(s.recovery_mean_s),
        json_f64(s.recovery_max_s),
        s.outage_windows,
        s.recoveries,
        s.accepted_fixes,
        s.rejected_fixes,
        s.stationary_fixes,
        s.corner_fixes,
        s.gap_resets,
        s.rejection_resets,
    )
}

fn json_f64(value: f64) -> String {
    if value.is_finite() {
        format!("{value:.6}")
    } else {
        "0.000000".to_string()
    }
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c.is_control() => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_scenario_has_near_zero_errors() {
        let scenario = QualityScenario::from_synthetic(
            "clean",
            &benchmark_route(),
            &SyntheticConfig::clean(7),
        );
        let metrics = score(&scenario);
        assert!(metrics.raw_distance_error_pct < 2.0, "{metrics:?}");
        assert!(metrics.filtered_distance_error_pct < 2.0, "{metrics:?}");
        assert!(metrics.position_rmse_m < 1e-6, "{metrics:?}");
        assert!(metrics.projection_mae_m < 0.01, "{metrics:?}");
        assert_eq!(metrics.false_movement_m, 0.0);
        assert_eq!(metrics.outage_windows, 0);
    }

    #[test]
    fn stationary_scenario_exposes_false_movement() {
        let scenario = QualityScenario::from_synthetic(
            "stopped",
            &benchmark_route(),
            &SyntheticConfig {
                position_noise: Distance::ZERO,
                stop_probability: 0.3,
                stationary_drift: Distance::from_meters(6.0),
                seed: 8,
                ..SyntheticConfig::default()
            },
        );
        let metrics = score(&scenario);
        assert!(metrics.false_movement_m_per_min > 0.0, "{metrics:?}");
    }

    #[test]
    fn report_is_deterministic_json() {
        let report = QualityReport::from_scenarios(&benchmark_scenarios());
        let a = report.to_json();
        let b = QualityReport::from_scenarios(&benchmark_scenarios()).to_json();
        assert_eq!(a, b);
        assert!(a.contains("\"urban_canyon\""));
        assert!(a.contains("\"outage_windows\""));
    }
}
