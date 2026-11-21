// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Outlier gating: statistical residual plus the existing hard ceilings.
//!
//! The Mahalanobis innovation is the primary signal: it accounts for both the
//! filter's uncertainty and the receiver's reported accuracy. The hard
//! accuracy/speed/jump limits stay as a safety net, so a GPS artifact can
//! never be accepted just because an inflated covariance made it look plausible.

use crate::geo::{Coordinate, distance as geo_distance};
use crate::gps::GpsFix;
use crate::units::{Distance, Speed, Timestamp};

use super::EstimatorConfig;
use super::kalman::Innovation;

/// Why an observation was not fused into the adaptive estimate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShadowRejection {
    /// Reported accuracy exceeded the configured ceiling.
    TooInaccurate,
    /// Reported or implied speed exceeded the configured ceiling.
    ImpossibleSpeed,
    /// The step from the last fix exceeded the configured jump ceiling.
    Jump,
    /// The innovation residual was implausible under the filter covariance.
    Innovation,
    /// Timestamp did not advance, so no prediction could be made.
    NonMonotonicTime,
}

impl std::fmt::Display for ShadowRejection {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooInaccurate => write!(f, "accuracy exceeded limit"),
            Self::ImpossibleSpeed => write!(f, "speed exceeded limit"),
            Self::Jump => write!(f, "impossible jump"),
            Self::Innovation => write!(f, "innovation residual too large"),
            Self::NonMonotonicTime => write!(f, "timestamp did not advance"),
        }
    }
}

/// Whether the innovation is too large for the configured chi-square gate.
pub fn is_statistical_outlier(innovation: &Innovation, config: &EstimatorConfig) -> bool {
    !innovation.mahalanobis.is_finite() || innovation.mahalanobis > config.outlier_chi2
}

/// Applies the hard safety ceilings to one observation.
///
/// `previous` is the last raw fix; `derived_speed` comes from the measured
/// displacement and timestamp delta when the receiver reported no speed.
pub fn hard_rejection(
    previous: Option<GpsFix>,
    fix: &GpsFix,
    derived_speed_mps: Option<f64>,
    config: &EstimatorConfig,
) -> Option<ShadowRejection> {
    if let Some(accuracy) = fix.accuracy
        && accuracy.meters() > config.max_accuracy.meters()
    {
        return Some(ShadowRejection::TooInaccurate);
    }
    let reported = fix.speed.map(|speed| speed.mps()).or(derived_speed_mps);
    if reported.is_some_and(|speed| speed > config.max_speed.mps()) {
        return Some(ShadowRejection::ImpossibleSpeed);
    }
    if let Some(previous) = previous
        && geo_distance(previous.coordinate, fix.coordinate).meters() > config.max_jump.meters()
    {
        return Some(ShadowRejection::Jump);
    }
    None
}

/// Speed implied by two observations, or `None` for a non-positive time delta.
pub fn derived_speed(
    a_time: Timestamp,
    a: Coordinate,
    b_time: Timestamp,
    b: Coordinate,
) -> Option<f64> {
    let dt = b_time.elapsed_since(a_time).as_secs();
    if dt <= 0.0 {
        return None;
    }
    let meters = geo_distance(a, b).meters();
    Some(meters / dt)
}

/// Whether a reported accuracy exceeds the ceiling.
pub fn exceeds_accuracy(accuracy: Option<Distance>, max: Distance) -> bool {
    accuracy.is_some_and(|value| value.meters() > max.meters())
}

/// Whether a reported speed exceeds the ceiling.
pub fn exceeds_speed(speed: Option<Speed>, max: Speed) -> bool {
    speed.is_some_and(|value| value.mps() > max.mps())
}
