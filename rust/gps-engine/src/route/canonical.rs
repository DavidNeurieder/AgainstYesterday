// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Canonical route generation from a cluster of recordings.
//!
//! Given several recordings that represent the same route, produce one robust
//! representative geometry:
//!
//! 1. Choose the best-quality (longest) recording as the reference.
//! 2. Project every other recording onto it.
//! 3. At fixed distances along the reference, average the nearby recorded
//!    coordinates.
//! 4. Reject points further than `max_lateral` from the reference.
//! 5. Build the canonical [`Route`].
//!
//! Deterministic and pure: same cluster in, same route out.

use crate::Track;
use crate::geo::{Coordinate, distance};
use crate::route::Route;
use crate::units::Distance;
use thiserror::Error;

/// Sampling parameters for [`canonicalize`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CanonicalizeConfig {
    /// Distance between canonical waypoints along the reference, in meters.
    pub step: Distance,
    /// Recorded points projecting further than this from the reference are
    /// rejected as outliers.
    pub max_lateral: Distance,
}

impl Default for CanonicalizeConfig {
    fn default() -> Self {
        Self {
            step: Distance::from_meters(20.0),
            max_lateral: Distance::from_meters(40.0),
        }
    }
}

/// Errors produced when generating a canonical route.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CanonicalError {
    /// No recordings were supplied.
    #[error("canonicalization requires at least one track, got {0}")]
    TooFewTracks(usize),
    /// The recordings collapsed into fewer than two distinct waypoints.
    #[error("recordings collapsed into a degenerate geometry")]
    DegenerateGeometry,
}

/// Builds a representative route from the given recordings of one route.
pub fn canonicalize(
    tracks: &[Track],
    config: &CanonicalizeConfig,
) -> Result<Route, CanonicalError> {
    if tracks.is_empty() {
        return Err(CanonicalError::TooFewTracks(tracks.len()));
    }

    // 1. Reference: the longest recording.
    let ref_idx = tracks
        .iter()
        .enumerate()
        .max_by(|a, b| {
            a.1.distance()
                .meters()
                .partial_cmp(&b.1.distance().meters())
                .expect("track distances are finite")
        })
        .expect("at least one track")
        .0;

    let reference_coords: Vec<Coordinate> = tracks[ref_idx]
        .points()
        .iter()
        .map(|p| p.coordinate())
        .collect();
    let reference = Route::new(reference_coords).map_err(|_| CanonicalError::DegenerateGeometry)?;
    let total = reference.length().meters();

    // 2. Project every other recording onto the reference once.
    let others: Vec<Vec<(f64, Coordinate)>> = tracks
        .iter()
        .enumerate()
        .filter(|(i, _)| *i != ref_idx)
        .map(|(_, t)| project_near(t, &reference, config))
        .collect();

    // 3. Average nearby recorded coordinates at fixed stations.
    let step_m = config.step.meters().max(1e-3);
    let n_steps = (total / step_m).ceil() as usize;
    let mut waypoints: Vec<Coordinate> = Vec::with_capacity(n_steps + 1);

    for k in 0..=n_steps {
        let station = (k as f64 * step_m).min(total);
        let lo = (station - step_m / 2.0).max(0.0);
        let hi = (station + step_m / 2.0).min(total);

        let mut neighbours = vec![
            reference
                .coordinate_at(Distance::from_meters(station))
                .ok_or(CanonicalError::DegenerateGeometry)?,
        ];

        for projected in &others {
            if let Some(coord) = nearest_in_window(projected, station, lo, hi) {
                neighbours.push(*coord);
            }
        }

        let n = neighbours.len() as f64;
        let lat = neighbours.iter().map(|c| c.latitude()).sum::<f64>() / n;
        let lon = neighbours.iter().map(|c| c.longitude()).sum::<f64>() / n;
        let coord = Coordinate::new(lat, lon).map_err(|_| CanonicalError::DegenerateGeometry)?;

        // 5. Drop consecutive near-duplicates so the route stays non-degenerate.
        if let Some(last) = waypoints.last() {
            if distance(*last, coord).meters() < 1e-6 {
                continue;
            }
        }
        waypoints.push(coord);
    }

    if waypoints.len() < 2 {
        return Err(CanonicalError::DegenerateGeometry);
    }
    Route::new(waypoints).map_err(|_| CanonicalError::DegenerateGeometry)
}

/// Projects one recording onto the reference, keeping only points within
/// `max_lateral` and pairing each with its along-route distance.
fn project_near(
    track: &Track,
    reference: &Route,
    config: &CanonicalizeConfig,
) -> Vec<(f64, Coordinate)> {
    track
        .points()
        .iter()
        .filter_map(|p| {
            let projection = reference.project(p.coordinate());
            if projection.lateral_error.meters() > config.max_lateral.meters() {
                return None;
            }
            Some((projection.distance_along.meters(), p.coordinate()))
        })
        .collect()
}

/// The recorded coordinate in `[lo, hi]` closest to `station`, if any.
fn nearest_in_window(
    projected: &[(f64, Coordinate)],
    station: f64,
    lo: f64,
    hi: f64,
) -> Option<&Coordinate> {
    projected
        .iter()
        .filter(|(along, _)| *along >= lo && *along <= hi)
        .min_by(|a, b| {
            (a.0 - station)
                .abs()
                .partial_cmp(&(b.0 - station).abs())
                .expect("along distances are finite")
        })
        .map(|(_, coord)| coord)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::Coordinate;
    use crate::synthetic::{SyntheticConfig, generate, reverse};
    use crate::{FilterConfig, SimplifyConfig};

    fn route() -> Vec<Coordinate> {
        vec![
            Coordinate::new(52.5000, 13.4000).unwrap(),
            Coordinate::new(52.5060, 13.4030).unwrap(),
            Coordinate::new(52.5120, 13.4010).unwrap(),
            Coordinate::new(52.5180, 13.4080).unwrap(),
        ]
    }

    fn cleaned(track: &Track) -> Track {
        let (filtered, _report) = track.filter(&FilterConfig::default());
        let simplified = filtered.simplify(&SimplifyConfig::default());
        simplified
            .resample_by_distance(Distance::from_meters(25.0))
            .unwrap()
    }

    fn record(seed: u64, noise: f64) -> Track {
        cleaned(&generate(&route(), &SyntheticConfig::noisy(seed, noise)))
    }

    fn cluster() -> Vec<Track> {
        vec![record(1, 0.0), record(99, 6.0), record(7, 6.0)]
    }

    #[test]
    fn empty_input_is_an_error() {
        assert_eq!(
            canonicalize(&[], &CanonicalizeConfig::default()).unwrap_err(),
            CanonicalError::TooFewTracks(0)
        );
    }

    #[test]
    fn single_track_regulates_its_own_geometry() {
        let tracks = vec![record(1, 0.0)];
        let config = CanonicalizeConfig {
            step: Distance::from_meters(20.0),
            ..CanonicalizeConfig::default()
        };
        let canonical = canonicalize(&tracks, &config).unwrap();

        let reference_len = tracks[0].distance().meters();
        assert!((canonical.length().meters() - reference_len).abs() < reference_len * 0.1);
        assert!(canonical.end() == tracks[0].end().unwrap().coordinate());
    }

    #[test]
    fn canonical_waypoints_stay_near_the_route() {
        let config = CanonicalizeConfig {
            step: Distance::from_meters(15.0),
            max_lateral: Distance::from_meters(30.0),
        };
        let tracks = cluster();
        let canonical = canonicalize(&tracks, &config).unwrap();

        let reference = Route::new(
            tracks[0]
                .points()
                .iter()
                .map(|p| p.coordinate())
                .collect::<Vec<_>>(),
        )
        .unwrap();

        // Every canonical waypoint projects within tolerance of the reference.
        for waypoint in canonical.geometry() {
            let projection = reference.project(*waypoint);
            assert!(
                projection.lateral_error.meters() <= config.max_lateral.meters() + 1e-6,
                "waypoint {:?} drifts {} m off the reference",
                waypoint,
                projection.lateral_error,
            );
        }

        // Endpoints stay put.
        assert!(
            crate::geo::distance(*canonical.geometry().first().unwrap(), reference.start(),)
                .meters()
                <= config.max_lateral.meters()
        );
        assert!(
            crate::geo::distance(*canonical.geometry().last().unwrap(), reference.end()).meters()
                <= config.max_lateral.meters()
        );
    }

    #[test]
    fn length_is_preserved_across_average() {
        let canonical = canonicalize(&cluster(), &CanonicalizeConfig::default()).unwrap();
        let reference_len = cluster()[0].distance().meters();

        assert!(
            (canonical.length().meters() - reference_len).abs() / reference_len < 0.1,
            "canonical length {} far from reference {}",
            canonical.length().meters(),
            reference_len,
        );
    }

    #[test]
    fn reversed_recording_must_not_throw_off_the_geometry() {
        let mut tracks = cluster();
        let rev = reverse(&record(42, 5.0));
        tracks.push(rev);

        let config = CanonicalizeConfig {
            step: Distance::from_meters(20.0),
            max_lateral: Distance::from_meters(40.0),
        };
        let canonical = canonicalize(&tracks, &config).unwrap();
        let reference_len = cluster()[0].distance().meters();

        assert!(
            (canonical.length().meters() - reference_len).abs() / reference_len < 0.15,
            "reversed recording distorted the length"
        );
    }
}
