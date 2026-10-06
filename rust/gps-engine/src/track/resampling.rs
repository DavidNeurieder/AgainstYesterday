// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Distance-based resampling.

use crate::error::TrackError;
use crate::geo::{distance, interpolate, polyline_length};
use crate::units::{Distance, Timestamp};

use super::model::Track;
use super::point::TrackPoint;

/// Re-samples a track to points spaced `interval` meters apart along the
/// track, producing the common one-dimensional coordinate system used for
/// route comparison.
///
/// The first point is always the track's start. Interior points are emitted at
/// every multiple of `interval` along the geodesic path, with coordinates and
/// timestamps linearly interpolated between neighbouring original points. The
/// track's final point is always appended so the true endpoint and its
/// timestamp survive.
///
/// Returns [`TrackError::InvalidInterval`] unless `interval` is finite and
/// positive.
pub fn resample_by_distance(track: &Track, interval: Distance) -> Result<Track, TrackError> {
    let interval_m = interval.meters();
    if !interval_m.is_finite() || interval_m <= 0.0 {
        return Err(TrackError::InvalidInterval(interval_m));
    }

    let points = track.points();
    let n = points.len();
    let total = polyline_length(&track.coordinates()).meters();

    let mut out: Vec<TrackPoint> = Vec::new();
    out.push(points[0]);

    if total > 1e-9 {
        // Cumulative geodesic distance at each vertex.
        let coords = track.coordinates();
        let mut cumulative = Vec::with_capacity(n);
        cumulative.push(0.0);
        for pair in coords.windows(2) {
            cumulative.push(
                cumulative.last().expect("cumulative is never empty")
                    + distance(pair[0], pair[1]).meters(),
            );
        }

        let mut segment = 0usize;
        let mut k = 1usize;
        loop {
            let target = k as f64 * interval_m;
            if target >= total - 1e-9 {
                break;
            }
            while segment + 1 < n && cumulative[segment + 1] < target {
                segment += 1;
            }
            let segment_len = cumulative[segment + 1] - cumulative[segment];
            let t = if segment_len > 1e-12 {
                (target - cumulative[segment]) / segment_len
            } else {
                0.0
            };

            let a = points[segment];
            let b = points[segment + 1];
            let coordinate = interpolate(a.coordinate(), b.coordinate(), t);

            let t_a = a.timestamp().unix_ms() as f64;
            let t_b = b.timestamp().unix_ms() as f64;
            let timestamp = Timestamp::from_unix_ms((t_a + (t_b - t_a) * t).round() as i64);

            out.push(TrackPoint::new(timestamp, coordinate));
            k += 1;
        }
    }

    let last = points[n - 1];
    let tail = out[out.len() - 1];
    if out.len() < 2 || distance(last.coordinate(), tail.coordinate()).meters() > 1e-6 {
        out.push(last);
    }

    Ok(Track::from_unchecked(out))
}
