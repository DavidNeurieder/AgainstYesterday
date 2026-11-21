// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Optional adaptive GPS estimation, running in shadow mode by default.
//!
//! The engine's existing filter stays the production path. This module adds a
//! deterministic constant-velocity estimator that can be scored against ground
//! truth before any promotion decision. Nothing here mutates raw fixes: each
//! observation keeps its raw coordinate, quality input, and rejection reason.

pub mod cadence;
pub mod kalman;
pub mod outlier;
pub mod stationary;

pub use cadence::CadenceTracker;
pub use kalman::{Innovation, KalmanFilter, LocalPlane};
pub use outlier::{
    ShadowRejection, derived_speed, exceeds_accuracy, exceeds_speed, is_statistical_outlier,
};
pub use stationary::StationaryDetector;

use crate::estimate::{Confidence, MotionState, PositionEstimate, VelocityEstimate};
use crate::geo::{Coordinate, distance as geo_distance};
use crate::gps::GpsFix;
use crate::track::TrackPoint;
use crate::units::{Distance, Duration, Speed, Timestamp};

/// Configuration for the adaptive estimator.
///
/// `enabled` is `false` by default: enabling it never changes the legacy
/// filter, only calls to [`estimate_fixes`] use these settings.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EstimatorConfig {
    /// Whether [`estimate_fixes`] smooths positions instead of passing them
    /// through unchanged.
    pub enabled: bool,
    /// Accuracy above this is rejected outright (hard safety ceiling).
    pub max_accuracy: Distance,
    /// Reported or implied speed above this is rejected outright.
    pub max_speed: Speed,
    /// Step length above this is rejected outright.
    pub max_jump: Distance,
    /// Accuracy used when the receiver reports none.
    pub default_accuracy: Distance,
    /// Ground slower than this earns no distance or moving time.
    pub motion_floor: Speed,
    /// Acceleration spectral density of the constant-velocity model.
    pub process_noise: f64,
    /// Chi-square gate (2 degrees of freedom) for the innovation residual.
    pub outlier_chi2: f64,
    /// Speed hint below which stationary evidence is considered.
    pub stationary_speed: Speed,
    /// Consecutive tight fixes required to confirm a stop.
    pub stationary_enter_count: u32,
    /// Radius used to enter and leave the stationary state, in meters.
    pub stationary_exit_m: f64,
    /// Bearing change that disables smoothing to preserve a corner, in degrees.
    pub corner_bearing_deg: f64,
    /// Consecutive rejected fixes after which the filter re-anchors on the raw
    /// position, so one accepted artifact cannot poison every later fix.
    pub recovery_reset_after: u32,
}

impl Default for EstimatorConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            max_accuracy: Distance::from_meters(50.0),
            max_speed: Speed::from_kmh(500.0),
            max_jump: Distance::from_meters(200.0),
            default_accuracy: Distance::from_meters(12.0),
            motion_floor: Speed::from_mps(0.5),
            process_noise: 0.6,
            outlier_chi2: 9.21,
            stationary_speed: Speed::from_mps(0.8),
            stationary_enter_count: 3,
            stationary_exit_m: 8.0,
            corner_bearing_deg: 90.0,
            recovery_reset_after: 3,
        }
    }
}

impl EstimatorConfig {
    /// The shadow configuration used by the quality benchmark.
    pub fn shadow() -> Self {
        Self {
            enabled: true,
            ..Self::default()
        }
    }

    /// Returns a copy with every numeric field finite and non-negative.
    pub fn clamped(&self) -> Self {
        let mut config = *self;
        config.max_accuracy = positive_distance(config.max_accuracy, 50.0);
        config.max_speed = positive_speed(config.max_speed, 500.0 / 3.6);
        config.max_jump = positive_distance(config.max_jump, 200.0);
        config.default_accuracy = positive_distance(config.default_accuracy, 12.0);
        config.motion_floor = Speed::from_mps(config.motion_floor.mps().clamp(0.0, 100.0));
        config.process_noise = config.process_noise.clamp(0.0, 100.0);
        config.outlier_chi2 = config.outlier_chi2.clamp(0.01, 10_000.0);
        config.stationary_speed = Speed::from_mps(config.stationary_speed.mps().clamp(0.0, 20.0));
        config.stationary_enter_count = config.stationary_enter_count.max(1);
        config.stationary_exit_m = config.stationary_exit_m.clamp(0.5, 1_000.0);
        config.corner_bearing_deg = config.corner_bearing_deg.clamp(1.0, 180.0);
        config.recovery_reset_after = config.recovery_reset_after.max(1);
        config
    }
}

fn positive_distance(value: Distance, fallback_m: f64) -> Distance {
    let meters = value.meters();
    if meters.is_finite() && meters > 0.0 {
        value
    } else {
        Distance::from_meters(fallback_m)
    }
}

fn positive_speed(value: Speed, fallback_mps: f64) -> Speed {
    let mps = value.mps();
    if mps.is_finite() && mps > 0.0 {
        value
    } else {
        Speed::from_mps(fallback_mps)
    }
}

/// One observation after adaptive processing.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EstimatedFix {
    /// Timestamp of the observation.
    pub timestamp: Timestamp,
    /// Estimated position that enters the shadow track.
    pub coordinate: Coordinate,
    /// The unaltered receiver position.
    pub raw_coordinate: Coordinate,
    /// Whether the measurement was fused into the filter.
    pub accepted: bool,
    /// Why it was not fused, when applicable.
    pub reason: Option<ShadowRejection>,
    /// Motion classification for this fix.
    pub motion_state: MotionState,
    /// Estimated position with a bounded confidence.
    pub position_estimate: PositionEstimate,
    /// Estimated velocity, when the filter had enough evidence.
    pub velocity_estimate: Option<VelocityEstimate>,
    /// Distance this fix added to the shadow axis.
    pub distance_earned: Distance,
}

/// Aggregate counts from one adaptive pass.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AdaptiveReport {
    /// Number of raw observations offered to the estimator.
    pub input_fixes: usize,
    /// Observations fused into the filter.
    pub accepted: usize,
    /// Rejections by accuracy ceiling.
    pub rejected_accuracy: usize,
    /// Rejections by speed ceiling.
    pub rejected_speed: usize,
    /// Rejections by jump ceiling.
    pub rejected_jump: usize,
    /// Rejections by innovation residual.
    pub rejected_innovation: usize,
    /// Rejections because time did not advance.
    pub rejected_non_monotonic: usize,
    /// Observations that could not be converted to a valid track point.
    pub invalid_fixes: usize,
    /// Fixes classified as stationary.
    pub stationary_fixes: usize,
    /// Fixes where smoothing was reduced to preserve a corner.
    pub corner_fixes: usize,
    /// Filter resets after a long GPS outage.
    pub gap_resets: usize,
    /// Filter re-anchors after sustained rejection of good-looking fixes.
    pub rejection_resets: usize,
}

impl AdaptiveReport {
    /// Total number of rejected observations.
    pub fn rejected(&self) -> usize {
        self.rejected_accuracy
            + self.rejected_speed
            + self.rejected_jump
            + self.rejected_innovation
            + self.rejected_non_monotonic
            + self.invalid_fixes
    }
}

/// The complete output of [`estimate_fixes`].
#[derive(Debug, Clone, PartialEq)]
pub struct AdaptiveResult {
    /// One row per observation, including rejections that still carry an
    /// estimated position.
    pub fixes: Vec<EstimatedFix>,
    /// Estimated positions formatted as ordinary track points.
    pub points: Vec<TrackPoint>,
    /// Ground distance on the adaptive axis.
    pub distance: Distance,
    /// Moving time on the adaptive axis.
    pub moving: Duration,
    /// Decision counts.
    pub report: AdaptiveReport,
}

/// Runs the adaptive estimator over raw fixes in timestamp order.
///
/// With [`EstimatorConfig::enabled`] set to `false` the result is a documented
/// passthrough: positions are the raw coordinates, no innovation gating runs,
/// and the distance axis is the plain geodesic sum. This keeps the shadow API
/// safe to call from any consumer while leaving production behavior untouched.
pub fn estimate_fixes(fixes: &[GpsFix], config: &EstimatorConfig) -> AdaptiveResult {
    if fixes.is_empty() {
        return AdaptiveResult {
            fixes: Vec::new(),
            points: Vec::new(),
            distance: Distance::ZERO,
            moving: Duration::ZERO,
            report: AdaptiveReport::default(),
        };
    }
    if !config.enabled {
        return passthrough(fixes);
    }
    let config = config.clamped();
    let mut estimator = AdaptiveEstimator::new(fixes[0], &config);
    for fix in &fixes[1..] {
        estimator.add(*fix);
    }
    estimator.finish()
}

/// Stateful adaptive estimator; one instance per recording.
#[derive(Debug, Clone)]
pub struct AdaptiveEstimator {
    config: EstimatorConfig,
    plane: LocalPlane,
    filter: KalmanFilter,
    cadence: CadenceTracker,
    stationary: StationaryDetector,
    previous_fix: GpsFix,
    previous_time: Timestamp,
    last_coordinate: Option<Coordinate>,
    pending_distance_m: f64,
    pending_seconds: f64,
    consecutive_rejections: u32,
    accumulated_m: f64,
    moving_seconds: f64,
    fixes: Vec<EstimatedFix>,
    points: Vec<TrackPoint>,
    report: AdaptiveReport,
}

impl AdaptiveEstimator {
    /// Starts an estimator anchored at the first fix.
    pub fn new(first: GpsFix, config: &EstimatorConfig) -> Self {
        let config = config.clamped();
        let plane = LocalPlane::new(first.coordinate);
        let mut filter = KalmanFilter::new();
        filter.reset(0.0, 0.0);
        let mut result = Self {
            config,
            plane,
            filter,
            cadence: CadenceTracker::new(),
            stationary: StationaryDetector::new(
                config.stationary_enter_count,
                config.stationary_exit_m,
                config.stationary_speed.mps(),
            ),
            previous_fix: first,
            previous_time: first.timestamp,
            last_coordinate: None,
            pending_distance_m: 0.0,
            pending_seconds: 0.0,
            consecutive_rejections: 0,
            accumulated_m: 0.0,
            moving_seconds: 0.0,
            fixes: Vec::new(),
            points: Vec::new(),
            report: AdaptiveReport {
                input_fixes: 1,
                accepted: 1,
                ..AdaptiveReport::default()
            },
        };
        result.emit(
            first,
            first.coordinate,
            true,
            None,
            MotionState::Unknown(Confidence::new(0.5)),
            Confidence::ONE,
            0.0,
        );
        result
    }

    /// Feeds one raw fix in timestamp order.
    pub fn add(&mut self, fix: GpsFix) {
        self.report.input_fixes += 1;
        let dt = fix.timestamp.elapsed_since(self.previous_time).as_secs();
        if !dt.is_finite() || dt <= 0.0 {
            self.report.rejected_non_monotonic += 1;
            return;
        }
        let gap = self.cadence.is_gap(dt);
        // A long gap is not a new sampling cadence; learning it would hide the
        // next outage and leave the filter predicting across stale velocity.
        if !gap || self.cadence.observations() == 0 {
            self.cadence.observe(dt);
        }
        let local = self.plane.to_local(fix.coordinate);
        let derived = derived_speed(
            self.previous_time,
            self.previous_fix.coordinate,
            fix.timestamp,
            fix.coordinate,
        );
        let hard = outlier::hard_rejection(Some(self.previous_fix), &fix, derived, &self.config);
        let corner = self.is_corner(fix.coordinate);
        if corner {
            self.report.corner_fixes += 1;
        }
        if gap {
            self.filter.reset(local.0, local.1);
            self.stationary.reset();
            self.pending_distance_m = 0.0;
            self.pending_seconds = 0.0;
            // The outage bridge is not a movement segment; re-anchor here so
            // the first post-gap fix cannot earn the missing distance.
            self.last_coordinate = Some(fix.coordinate);
            self.report.gap_resets += 1;
        }

        let effective_dt = dt.min(self.cadence.nominal_seconds() * 2.0).max(0.05);
        let noise = self.config.process_noise
            * self.cadence.noise_factor(effective_dt)
            * if corner { 3.0 } else { 1.0 };

        // Probe on a clone so a rejected measurement cannot change the filter.
        let mut probe = self.filter.clone();
        probe.predict(effective_dt, noise);
        let sigma_squared = fix
            .accuracy
            .unwrap_or(self.config.default_accuracy)
            .meters()
            .max(1.0)
            .powi(2);
        let innovation = probe.update(local.0, local.1, sigma_squared);

        // A corner reduces smoothing through `noise`; it is never a licence to
        // accept a measurement that fails the hard ceilings or the innovation
        // gate. Bypassing those checks here inflated noisy distance badly.
        let reason = if gap {
            None
        } else if let Some(hard) = hard {
            Some(hard)
        } else if outlier::is_statistical_outlier(&innovation, &self.config) {
            Some(ShadowRejection::Innovation)
        } else {
            None
        };
        let accepted = reason.is_none();
        if accepted {
            self.filter = probe;
            self.consecutive_rejections = 0;
            self.report.accepted += 1;
        } else {
            let rejection = reason.expect("a rejection always has a reason");
            match rejection {
                ShadowRejection::TooInaccurate => self.report.rejected_accuracy += 1,
                ShadowRejection::ImpossibleSpeed => self.report.rejected_speed += 1,
                ShadowRejection::Jump => self.report.rejected_jump += 1,
                ShadowRejection::Innovation => self.report.rejected_innovation += 1,
                ShadowRejection::NonMonotonicTime => self.report.rejected_non_monotonic += 1,
            }
            self.consecutive_rejections += 1;
            // A stale filter that rejects every later fix must not become a
            // permanent outage. Re-anchor on the raw position after a short
            // run of position-based rejections.
            if self.consecutive_rejections >= self.config.recovery_reset_after
                && rejection == ShadowRejection::Innovation
            {
                self.filter.reset(local.0, local.1);
                self.stationary.reset();
                self.pending_distance_m = 0.0;
                self.pending_seconds = 0.0;
                self.last_coordinate = Some(fix.coordinate);
                self.consecutive_rejections = 0;
                self.report.rejection_resets += 1;
            }
        }

        let speed_hint = fix.speed.map(|speed| speed.mps()).or(derived);
        let motion = self.stationary.update(local.0, local.1, speed_hint);
        if motion.is_stationary() {
            self.report.stationary_fixes += 1;
        }

        let position = self.filter.position();
        let frozen = if motion.is_stationary() {
            self.stationary.anchor().unwrap_or(position)
        } else {
            position
        };
        let coordinate = self.plane.to_coordinate(frozen.0, frozen.1);
        let confidence = if accepted {
            innovation.confidence(self.config.outlier_chi2)
        } else {
            Confidence::ZERO
        };
        let earned = self.settle_distance(coordinate, dt, motion, accepted);
        self.emit(
            fix, coordinate, accepted, reason, motion, confidence, earned,
        );
        self.previous_fix = fix;
        self.previous_time = fix.timestamp;
    }

    /// Consumes the estimator and returns all auditable output.
    ///
    /// Any final `Unknown` window is credited on the last fix so the sum of
    /// per-fix distances always matches the aggregate axis.
    pub fn finish(mut self) -> AdaptiveResult {
        if self.pending_distance_m > 0.0 && self.pending_seconds > 0.0 {
            self.accumulated_m += self.pending_distance_m;
            self.moving_seconds += self.pending_seconds;
            if let Some(last) = self.fixes.last_mut() {
                last.distance_earned =
                    Distance::from_meters(last.distance_earned.meters() + self.pending_distance_m);
            }
            self.pending_distance_m = 0.0;
            self.pending_seconds = 0.0;
        }
        AdaptiveResult {
            fixes: self.fixes,
            points: self.points,
            distance: Distance::from_meters(self.accumulated_m),
            moving: Duration::from_secs(self.moving_seconds),
            report: self.report,
        }
    }

    fn is_corner(&self, coordinate: Coordinate) -> bool {
        let measured = match crate::geo::bearing(self.previous_fix.coordinate, coordinate).ok() {
            Some(bearing) => bearing,
            None => return false,
        };
        let prior = match self.filter.bearing() {
            Some(bearing) => bearing,
            None => return false,
        };
        let delta = (measured.as_radians() - prior.as_radians()).abs() % std::f64::consts::TAU;
        let delta = delta.min(std::f64::consts::TAU - delta);
        delta > self.config.corner_bearing_deg.to_radians()
    }

    /// Stages each segment until the motion classifier can judge it.
    ///
    /// A single jittery fix can look like movement before a stop is confirmed,
    /// so `Unknown` keeps the segment pending. Confirmed stationary motion
    /// discards the whole pending window; confirmed movement commits it in one
    /// auditable row.
    fn settle_distance(
        &mut self,
        coordinate: Coordinate,
        dt: f64,
        motion: MotionState,
        accepted: bool,
    ) -> f64 {
        if motion.is_stationary() {
            self.pending_distance_m = 0.0;
            self.pending_seconds = 0.0;
            return 0.0;
        }
        // A rejected fix is never a distance anchor: it may be a jump or a
        // stale filter position. Only accepted estimates advance the axis.
        if !accepted {
            return 0.0;
        }
        if let Some(last) = self.last_coordinate {
            let meters = geo_distance(last, coordinate).meters();
            if meters.is_finite()
                && meters > 0.0
                && meters / dt >= self.config.motion_floor.mps()
                && meters <= self.config.max_jump.meters()
            {
                self.pending_distance_m += meters;
                self.pending_seconds += dt;
            }
        }

        if !motion.is_moving() || self.pending_distance_m <= 0.0 || self.pending_seconds <= 0.0 {
            return 0.0;
        }

        let earned = self.pending_distance_m;
        self.accumulated_m += earned;
        self.moving_seconds += self.pending_seconds;
        self.pending_distance_m = 0.0;
        self.pending_seconds = 0.0;
        earned
    }

    #[allow(clippy::too_many_arguments)]
    fn emit(
        &mut self,
        fix: GpsFix,
        coordinate: Coordinate,
        accepted: bool,
        reason: Option<ShadowRejection>,
        motion: MotionState,
        confidence: Confidence,
        earned: f64,
    ) {
        let accuracy = fix.accuracy.unwrap_or(self.config.default_accuracy);
        let position_estimate =
            PositionEstimate::new(fix.timestamp, coordinate, accuracy, confidence);
        let (east, north) = self.filter.velocity();
        let velocity = VelocityEstimate::new(
            Speed::from_mps(east.hypot(north)),
            self.filter.bearing(),
            confidence,
        );
        let estimated = EstimatedFix {
            timestamp: fix.timestamp,
            coordinate,
            raw_coordinate: fix.coordinate,
            accepted,
            reason,
            motion_state: motion,
            position_estimate,
            velocity_estimate: Some(velocity),
            distance_earned: Distance::from_meters(earned),
        };
        if let Some(point) = track_point(fix, coordinate) {
            let point = point
                .with_position_estimate(position_estimate)
                .with_velocity_estimate(velocity)
                .with_motion_state(motion);
            self.points.push(point);
            if accepted {
                self.last_coordinate = Some(coordinate);
            }
        } else {
            self.report.invalid_fixes += 1;
        }
        self.fixes.push(estimated);
    }
}

/// Converts a raw fix to a track point at an estimated coordinate.
fn track_point(fix: GpsFix, coordinate: Coordinate) -> Option<TrackPoint> {
    let mut point = TrackPoint::new(fix.timestamp, coordinate);
    if let Some(altitude) = fix.altitude {
        point = point.with_altitude(altitude).ok()?;
    }
    if let Some(speed) = fix.speed {
        point = point.with_speed(speed.mps()).ok()?;
    }
    if let Some(accuracy) = fix.accuracy {
        point = point.with_accuracy(accuracy.meters()).ok()?;
    }
    if let Some(bearing) = fix.bearing {
        point = point.with_bearing(bearing);
    }
    Some(point)
}

fn passthrough(fixes: &[GpsFix]) -> AdaptiveResult {
    let mut fixes_out = Vec::with_capacity(fixes.len());
    let mut points = Vec::with_capacity(fixes.len());
    let mut distance_m = 0.0;
    let mut last_coordinate: Option<Coordinate> = None;
    for fix in fixes {
        let Some(point) = track_point(*fix, fix.coordinate) else {
            continue;
        };
        let earned = last_coordinate.map_or(0.0, |previous| {
            geo_distance(previous, fix.coordinate).meters()
        });
        distance_m += earned;
        last_coordinate = Some(fix.coordinate);
        let motion = MotionState::Unknown(Confidence::ZERO);
        let confidence = Confidence::ONE;
        let position = PositionEstimate::new(
            fix.timestamp,
            fix.coordinate,
            fix.accuracy.unwrap_or(Distance::ZERO),
            confidence,
        );
        points.push(
            point
                .with_position_estimate(position)
                .with_motion_state(motion),
        );
        fixes_out.push(EstimatedFix {
            timestamp: fix.timestamp,
            coordinate: fix.coordinate,
            raw_coordinate: fix.coordinate,
            accepted: true,
            reason: None,
            motion_state: motion,
            position_estimate: position,
            velocity_estimate: None,
            distance_earned: Distance::from_meters(earned),
        });
    }
    AdaptiveResult {
        fixes: fixes_out,
        points,
        distance: Distance::from_meters(distance_m),
        moving: Duration::ZERO,
        report: AdaptiveReport {
            input_fixes: fixes.len(),
            accepted: fixes.len(),
            ..AdaptiveReport::default()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::Coordinate;
    use crate::units::Timestamp;

    fn fix(lat: f64, lon: f64, second: i64) -> GpsFix {
        GpsFix::new(
            Timestamp::from_unix_secs(second as f64),
            Coordinate::new(lat, lon).expect("valid coordinate"),
        )
    }

    fn run(fixes: &[GpsFix], config: EstimatorConfig) -> AdaptiveResult {
        estimate_fixes(fixes, &config)
    }

    #[test]
    fn default_config_is_a_documentary_passthrough() {
        assert!(!EstimatorConfig::default().enabled);
        assert!(EstimatorConfig::shadow().enabled);
        let fixes = [fix(52.5, 13.4, 0), fix(52.501, 13.4, 2)];
        let result = run(&fixes, EstimatorConfig::default());
        assert_eq!(result.fixes[0].coordinate, fixes[0].coordinate);
        assert_eq!(result.fixes[1].coordinate, fixes[1].coordinate);
        assert!(result.fixes.iter().all(|row| row.accepted));
    }

    #[test]
    fn a_clean_run_survives_shadow_estimation() {
        let fixes: Vec<GpsFix> = (0..20)
            .map(|i| fix(52.5 + i as f64 * 0.000_05, 13.4, i))
            .collect();
        let result = run(&fixes, EstimatorConfig::shadow());
        assert_eq!(result.fixes.len(), fixes.len());
        assert!(result.distance.meters() > 50.0);
        assert!(result.report.rejected() <= 2);
    }

    #[test]
    fn an_isolated_spike_is_gated_out() {
        let mut fixes: Vec<GpsFix> = (0..20)
            .map(|i| fix(52.5 + i as f64 * 0.000_05, 13.4, i))
            .collect();
        fixes[10] = fix(52.5, 13.42, 10);
        let result = run(&fixes, EstimatorConfig::shadow());
        assert!(result.report.rejected() > 0, "{:?}", result.report);
    }

    #[test]
    fn stationary_drift_earns_no_distance() {
        let mut fixes = Vec::new();
        for second in 0..12 {
            let jitter = (second % 3) as f64 - 1.0;
            fixes.push(fix(52.5 + jitter * 0.000_02, 13.4, second));
        }
        let result = run(&fixes, EstimatorConfig::shadow());
        assert_eq!(result.distance.meters(), 0.0, "{:?}", result.report);
        assert!(result.report.stationary_fixes > 0);
    }

    #[test]
    fn per_fix_distance_sums_to_the_shadow_axis() {
        let fixes: Vec<GpsFix> = (0..20)
            .map(|i| fix(52.5 + i as f64 * 0.000_05, 13.4, i))
            .collect();
        for config in [EstimatorConfig::default(), EstimatorConfig::shadow()] {
            let result = run(&fixes, config);
            let summed: f64 = result
                .fixes
                .iter()
                .map(|row| row.distance_earned.meters())
                .sum();
            assert!(
                (summed - result.distance.meters()).abs() < 1e-9,
                "{config:?}: {summed} != {}",
                result.distance.meters()
            );
        }
    }

    #[test]
    fn a_gap_resets_the_filter_without_losing_later_fixes() {
        let mut fixes: Vec<GpsFix> = (0..10)
            .map(|i| fix(52.5 + i as f64 * 0.000_05, 13.4, i))
            .collect();
        fixes.push(fix(52.5 + 10.0 * 0.000_05, 13.4, 120));
        fixes.push(fix(52.5 + 11.0 * 0.000_05, 13.4, 121));
        let result = run(&fixes, EstimatorConfig::shadow());
        assert!(result.report.gap_resets > 0);
        assert!(result.distance.meters() > 50.0);
    }
}
