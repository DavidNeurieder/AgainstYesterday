// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Polyline simplification with Ramer–Douglas–Peucker.

use crate::geo::{Coordinate, project_to_segment};
use crate::units::Distance;

use super::model::Track;
use super::point::TrackPoint;

/// Configuration for [`super::simplify`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SimplifyConfig {
    /// Maximum distance a removed point may lie from the simplified polyline,
    /// in meters.
    pub tolerance: Distance,
}

impl Default for SimplifyConfig {
    fn default() -> Self {
        SimplifyConfig {
            tolerance: Distance::from_meters(2.0),
        }
    }
}

/// Reduces a track's dimensionality while keeping its shape within
/// `config.tolerance`. Timestamps and sensor fields of the surviving points
/// are preserved unchanged.
///
/// The first and last points are always kept.
pub fn simplify(track: &Track, config: &SimplifyConfig) -> Track {
    let coords = track.coordinates();
    let indices = rdp_indices(&coords, config.tolerance.meters());
    let points = indices
        .iter()
        .map(|&i| track.points()[i])
        .collect::<Vec<TrackPoint>>();
    Track::from_unchecked(points)
}

/// Ramer–Douglas–Peucker over coordinates, returning the indices to keep
/// (including both endpoints) in ascending order.
fn rdp_indices(coords: &[Coordinate], tolerance: f64) -> Vec<usize> {
    let n = coords.len();
    if n <= 2 {
        return (0..n).collect();
    }

    let mut keep = vec![false; n];
    keep[0] = true;
    keep[n - 1] = true;

    let mut stack = vec![(0usize, n - 1)];
    while let Some((start, end)) = stack.pop() {
        let a = coords[start];
        let b = coords[end];

        let mut max_distance = 0.0;
        let mut max_index = start;
        for (i, c) in coords
            .iter()
            .enumerate()
            .skip(start + 1)
            .take(end - start - 1)
        {
            let lateral = project_to_segment(*c, a, b, 0).lateral_error.meters();
            if lateral > max_distance {
                max_distance = lateral;
                max_index = i;
            }
        }

        if max_distance > tolerance {
            keep[max_index] = true;
            stack.push((start, max_index));
            stack.push((max_index, end));
        }
    }

    (0..n).filter(|&i| keep[i]).collect()
}
