// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Constant-velocity Kalman filter in a local east/north tangent plane.
//!
//! State: `[east, north, east_velocity, north_velocity]` with a 4×4 covariance.
//! Prediction uses the real timestamp delta, never a fixed 1 Hz cadence. The
//! implementation is intentionally small and dependency-free; all arithmetic
//! is plain `f64` with defensive fallbacks when a matrix becomes singular.

use crate::estimate::Confidence;
use crate::geo::{Bearing, Coordinate, EARTH_RADIUS_METERS};

const STATE: usize = 4;
const OBS: usize = 2;

/// A measurement's innovation relative to the filter's prediction.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Innovation {
    /// Squared Mahalanobis distance of the measurement.
    pub mahalanobis: f64,
    /// East/north innovation components, in meters.
    pub east: f64,
    /// North component of the innovation, in meters.
    pub north: f64,
}

impl Innovation {
    /// Confidence that the measurement is consistent with the prediction.
    ///
    /// `1.0` for no innovation, tending to zero as the residual grows.
    pub fn confidence(&self, chi2: f64) -> Confidence {
        let limit = chi2.max(f64::EPSILON);
        Confidence::new(1.0 / (1.0 + self.mahalanobis.max(0.0) / limit))
    }
}

#[derive(Debug, Clone, PartialEq)]
struct Matrix([[f64; STATE]; STATE]);

impl Matrix {
    fn zero() -> Self {
        Self([[0.0; STATE]; STATE])
    }

    fn identity() -> Self {
        let mut m = Self::zero();
        for (index, row) in m.0.iter_mut().enumerate() {
            row[index] = 1.0;
        }
        m
    }

    fn diagonal(values: [f64; STATE]) -> Self {
        let mut m = Self::zero();
        for (index, row) in m.0.iter_mut().enumerate() {
            row[index] = values[index];
        }
        m
    }

    fn transpose(&self) -> Self {
        let mut out = Self::zero();
        for i in 0..STATE {
            for j in 0..STATE {
                out.0[i][j] = self.0[j][i];
            }
        }
        out
    }

    fn mul(&self, other: &Self) -> Self {
        let mut out = Self::zero();
        for i in 0..STATE {
            for j in 0..STATE {
                let mut sum = 0.0;
                for k in 0..STATE {
                    sum += self.0[i][k] * other.0[k][j];
                }
                out.0[i][j] = sum;
            }
        }
        out
    }

    fn add(&self, other: &Self) -> Self {
        let mut out = Self::zero();
        for i in 0..STATE {
            for j in 0..STATE {
                out.0[i][j] = self.0[i][j] + other.0[i][j];
            }
        }
        out
    }
}

/// A 2×2 observation-space matrix, used for the innovation covariance.
#[derive(Debug, Clone, Copy, PartialEq)]
struct ObservationMatrix([[f64; OBS]; OBS]);

impl ObservationMatrix {
    fn inverse(&self) -> Option<Self> {
        let a = self.0[0][0];
        let b = self.0[0][1];
        let c = self.0[1][0];
        let d = self.0[1][1];
        let determinant = a * d - b * c;
        if !determinant.is_finite() || determinant <= 1e-12 {
            return None;
        }
        Some(Self([
            [d / determinant, -b / determinant],
            [-c / determinant, a / determinant],
        ]))
    }
}

/// The 4×4 constant-velocity filter, with no dependency on the app or CLI.
#[derive(Debug, Clone, PartialEq)]
pub struct KalmanFilter {
    state: [f64; STATE],
    covariance: Matrix,
    initialized: bool,
}

impl Default for KalmanFilter {
    fn default() -> Self {
        Self::new()
    }
}

impl KalmanFilter {
    /// Creates an uninitialized filter. Call [`Self::reset`] with the first fix.
    pub fn new() -> Self {
        Self {
            state: [0.0; STATE],
            covariance: Matrix::zero(),
            initialized: false,
        }
    }

    /// Anchors the filter at a local east/north position with zero velocity.
    pub fn reset(&mut self, east: f64, north: f64) {
        self.state = [east, north, 0.0, 0.0];
        self.covariance = Matrix::diagonal([25.0, 25.0, 100.0, 100.0]);
        self.initialized = true;
    }

    /// Whether [`Self::reset`] has been called.
    pub fn is_initialized(&self) -> bool {
        self.initialized
    }

    /// Predicts state and covariance forward by `dt` seconds.
    ///
    /// `process_noise` is an acceleration spectral density; larger values keep
    /// the filter agile during gaps and sharp turns.
    pub fn predict(&mut self, dt: f64, process_noise: f64) {
        if !self.initialized {
            return;
        }
        let dt = dt.clamp(0.0, 300.0);
        let q = process_noise.clamp(0.0, 100.0);
        let dt2 = dt * dt;
        let dt3 = dt2 * dt;
        let dt4 = dt2 * dt2;

        let mut transition = Matrix::identity();
        transition.0[0][2] = dt;
        transition.0[1][3] = dt;

        // Continuous white-acceleration model integrated over `dt`.
        let mut noise = Matrix::zero();
        noise.0[0][0] = q * dt4 / 4.0;
        noise.0[0][2] = q * dt3 / 2.0;
        noise.0[1][1] = q * dt4 / 4.0;
        noise.0[1][3] = q * dt3 / 2.0;
        noise.0[2][0] = q * dt3 / 2.0;
        noise.0[2][2] = q * dt2;
        noise.0[3][1] = q * dt3 / 2.0;
        noise.0[3][3] = q * dt2;

        self.state[0] += self.state[2] * dt;
        self.state[1] += self.state[3] * dt;
        self.covariance = transition
            .mul(&self.covariance)
            .mul(&transition.transpose())
            .add(&noise);
    }

    /// Fuses one east/north measurement with reported variance `sigma_squared`.
    ///
    /// Returns the innovation even when the update is skipped because the
    /// covariance is singular, so callers can still gate the raw fix.
    pub fn update(&mut self, east: f64, north: f64, sigma_squared: f64) -> Innovation {
        let y = [east - self.state[0], north - self.state[1]];
        if !self.initialized {
            return Innovation {
                mahalanobis: f64::INFINITY,
                east: y[0],
                north: y[1],
            };
        }
        let variance = sigma_squared.clamp(1e-4, 10_000.0);
        let p = &self.covariance;
        let s = ObservationMatrix([
            [p.0[0][0] + variance, p.0[0][1]],
            [p.0[1][0], p.0[1][1] + variance],
        ]);
        let Some(inverse) = s.inverse() else {
            return Innovation {
                mahalanobis: f64::INFINITY,
                east: y[0],
                north: y[1],
            };
        };
        let mahalanobis = y[0] * (inverse.0[0][0] * y[0] + inverse.0[0][1] * y[1])
            + y[1] * (inverse.0[1][0] * y[0] + inverse.0[1][1] * y[1]);
        let mahalanobis = if mahalanobis.is_finite() {
            mahalanobis.max(0.0)
        } else {
            f64::INFINITY
        };

        let mut gain = [[0.0; OBS]; STATE];
        for i in 0..STATE {
            for j in 0..OBS {
                gain[i][j] = p.0[i][0] * inverse.0[0][j] + p.0[i][1] * inverse.0[1][j];
            }
        }
        for (index, value) in self.state.iter_mut().enumerate() {
            *value += gain[index][0] * y[0] + gain[index][1] * y[1];
        }

        // Joseph form keeps the covariance symmetric and positive definite.
        let mut correction = Matrix::identity();
        for i in 0..STATE {
            correction.0[i][0] -= gain[i][0];
            correction.0[i][1] -= gain[i][1];
        }
        let mut noise_term = Matrix::zero();
        for i in 0..STATE {
            for j in 0..STATE {
                noise_term.0[i][j] = variance * (gain[i][0] * gain[j][0] + gain[i][1] * gain[j][1]);
            }
        }
        self.covariance = correction
            .mul(&self.covariance)
            .mul(&correction.transpose())
            .add(&noise_term);

        Innovation {
            mahalanobis,
            east: y[0],
            north: y[1],
        }
    }

    /// Current position estimate in local east/north meters.
    pub fn position(&self) -> (f64, f64) {
        (self.state[0], self.state[1])
    }

    /// Current velocity estimate in local east/north meters per second.
    pub fn velocity(&self) -> (f64, f64) {
        (self.state[2], self.state[3])
    }

    /// Estimated ground speed, always finite and non-negative.
    pub fn speed_mps(&self) -> f64 {
        let speed = self.state[2].hypot(self.state[3]);
        if speed.is_finite() { speed } else { 0.0 }
    }

    /// Estimated direction of travel, when the filter has meaningful velocity.
    pub fn bearing(&self) -> Option<Bearing> {
        if self.speed_mps() < 0.2 {
            return None;
        }
        Bearing::from_radians(self.state[2].atan2(self.state[3])).ok()
    }
}

/// Projection between geographic coordinates and a local tangent plane.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct LocalPlane {
    origin_lat_rad: f64,
    origin_lon_rad: f64,
    meters_per_lon_degree: f64,
}

impl LocalPlane {
    /// Anchors the plane at `origin`. Longitude scale uses the origin's cosine.
    pub fn new(origin: Coordinate) -> Self {
        let origin_lat_rad = origin.latitude().to_radians();
        Self {
            origin_lat_rad,
            origin_lon_rad: origin.longitude().to_radians(),
            meters_per_lon_degree: EARTH_RADIUS_METERS * origin_lat_rad.cos(),
        }
    }

    /// Geographic coordinate → local east/north meters.
    pub fn to_local(&self, coordinate: Coordinate) -> (f64, f64) {
        let north =
            (coordinate.latitude().to_radians() - self.origin_lat_rad) * EARTH_RADIUS_METERS;
        let east = (coordinate.longitude().to_radians() - self.origin_lon_rad)
            * self.meters_per_lon_degree;
        (east, north)
    }

    /// Local east/north meters → geographic coordinate, clamped to valid ranges.
    pub fn to_coordinate(&self, east: f64, north: f64) -> Coordinate {
        let latitude = (self.origin_lat_rad + north / EARTH_RADIUS_METERS).to_degrees();
        let longitude = (self.origin_lon_rad + east / self.meters_per_lon_degree).to_degrees();
        Coordinate::new(
            latitude.clamp(-90.0, 90.0),
            (longitude + 540.0).rem_euclid(360.0) - 180.0,
        )
        .expect("clamped coordinate is valid")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prediction_moves_position_by_velocity_times_dt() {
        let mut filter = KalmanFilter::new();
        filter.reset(0.0, 0.0);
        filter.state[2] = 3.0;
        filter.state[3] = 4.0;
        filter.predict(2.0, 0.0);
        let (east, north) = filter.position();
        assert!((east - 6.0).abs() < 1e-9);
        assert!((north - 8.0).abs() < 1e-9);
    }

    #[test]
    fn a_consistent_measurement_reduces_uncertainty() {
        let mut filter = KalmanFilter::new();
        filter.reset(0.0, 0.0);
        let before = filter.covariance.0[0][0];
        let innovation = filter.update(1.0, 0.0, 25.0);
        assert!(innovation.mahalanobis < 1.0);
        assert!(filter.covariance.0[0][0] < before);
        assert!((filter.position().0 - 1.0).abs() < 2.0);
    }

    #[test]
    fn a_far_measurement_has_large_innovation() {
        let mut filter = KalmanFilter::new();
        filter.reset(0.0, 0.0);
        let near = filter.update(1.0, 0.0, 25.0);
        let far = filter.update(500.0, 0.0, 25.0);
        assert!(far.mahalanobis > near.mahalanobis);
        assert!(far.confidence(9.21).value() < 0.01);
    }

    #[test]
    fn local_plane_round_trips_coordinates() {
        let origin = Coordinate::new(52.5, 13.4).expect("valid coordinate");
        let plane = LocalPlane::new(origin);
        let point = Coordinate::new(52.501, 13.402).expect("valid coordinate");
        let (east, north) = plane.to_local(point);
        let back = plane.to_coordinate(east, north);
        assert!((back.latitude() - point.latitude()).abs() < 1e-10);
        assert!((back.longitude() - point.longitude()).abs() < 1e-10);
    }
}
