// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Sampling-cadence tracking for the adaptive estimator.
//!
//! Real receivers alternate between 1 Hz fixes and several-second gaps. The
//! filter's process noise follows the observed cadence so a long gap increases
//! uncertainty instead of making the last velocity look certain forever.

/// An exponential moving estimate of the nominal interval between fixes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CadenceTracker {
    nominal_seconds: f64,
    observations: u32,
}

impl Default for CadenceTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl CadenceTracker {
    /// Starts with a conservative 1 Hz assumption.
    pub fn new() -> Self {
        Self {
            nominal_seconds: 1.0,
            observations: 0,
        }
    }

    /// Feeds one positive timestamp delta.
    pub fn observe(&mut self, dt_seconds: f64) {
        if !dt_seconds.is_finite() || dt_seconds <= 0.0 {
            return;
        }
        let dt = dt_seconds.clamp(0.05, 300.0);
        self.nominal_seconds = if self.observations == 0 {
            dt
        } else {
            0.8 * self.nominal_seconds + 0.2 * dt
        };
        self.observations += 1;
    }

    /// The smoothed nominal interval in seconds.
    pub fn nominal_seconds(&self) -> f64 {
        self.nominal_seconds
    }

    /// Number of intervals observed so far.
    pub fn observations(&self) -> u32 {
        self.observations
    }

    /// Whether a delta is a meaningful outage rather than normal jitter.
    pub fn is_gap(&self, dt_seconds: f64) -> bool {
        dt_seconds.is_finite() && dt_seconds > (1.9 * self.nominal_seconds).max(8.0)
    }

    /// Process-noise multiplier for a delta relative to the learned cadence.
    ///
    /// Bounded to `0.25..=16` so a single outlier cannot destabilise the
    /// covariance, while a genuine outage increases uncertainty materially.
    pub fn noise_factor(&self, dt_seconds: f64) -> f64 {
        if !dt_seconds.is_finite() || dt_seconds <= 0.0 {
            return 1.0;
        }
        let ratio = dt_seconds / self.nominal_seconds.max(0.05);
        ratio.clamp(0.25, 16.0).sqrt()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn learns_a_steady_cadence() {
        let mut cadence = CadenceTracker::new();
        for _ in 0..10 {
            cadence.observe(2.0);
        }
        assert!((cadence.nominal_seconds() - 2.0).abs() < 0.2);
        assert_eq!(cadence.observations(), 10);
    }

    #[test]
    fn gaps_and_noise_factors_are_bounded() {
        let mut cadence = CadenceTracker::new();
        cadence.observe(1.0);
        assert!(cadence.is_gap(10.0));
        assert!(!cadence.is_gap(2.0));
        assert!(!cadence.is_gap(f64::NAN));
        assert_eq!(cadence.noise_factor(0.0), 1.0);
        assert!(cadence.noise_factor(1000.0) <= 16.0);
        assert!(cadence.noise_factor(0.001) >= 0.25);
    }
}
