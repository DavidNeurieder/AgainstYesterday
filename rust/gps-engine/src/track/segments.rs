// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Splitting a track into equal-distance sections and comparing them.

use crate::Track;
use crate::geo::distance;
use crate::units::{Distance, Duration, Speed, Timestamp};

/// One equal-distance slice of a track.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackSegment {
    /// Zero-based section index.
    pub index: usize,
    /// Distance from the track start to the section start.
    pub start_distance: Distance,
    /// Distance from the track start to the section end.
    pub end_distance: Distance,
    /// Geodesic length of the section.
    pub distance: Distance,
    /// Elapsed wall-clock time across the section.
    pub duration: Duration,
    /// Average speed over the section (distance / duration, 0 if no time).
    pub average_speed: Speed,
    /// Total positive elevation change in the section.
    pub elevation_gain: f64,
    /// Number of original fixes that fall inside the section.
    pub point_count: usize,
}

/// Per-section comparison of a group of tracks that share a route.
#[derive(Debug, Clone, PartialEq)]
pub struct SegmentComparison {
    /// Zero-based section index.
    pub index: usize,
    /// Distance from the route start to the section start.
    pub start_distance: Distance,
    /// Distance from the route start to the section end.
    pub end_distance: Distance,
    /// One entry per input track, in input order.
    pub segments: Vec<TrackSegment>,
    /// Slowest section speed among the tracks.
    pub min_speed: Speed,
    /// Fastest section speed among the tracks.
    pub max_speed: Speed,
    /// Arithmetic mean of the section speeds.
    pub mean_speed: Speed,
    /// Spread between fastest and slowest (max - min).
    pub speed_spread: Speed,
}

/// Errors produced by sectioning.
#[derive(Debug, Clone, PartialEq)]
pub enum SegmentError {
    /// `segments` must be greater than zero.
    ZeroSegments,
    /// The track has zero (or non-finite) total length.
    ZeroLength,
    /// No tracks were given to compare.
    NoTracks,
}

impl std::fmt::Display for SegmentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SegmentError::ZeroSegments => write!(f, "segments must be greater than zero"),
            SegmentError::ZeroLength => write!(f, "track has zero length"),
            SegmentError::NoTracks => write!(f, "no tracks to compare"),
        }
    }
}

impl std::error::Error for SegmentError {}

/// Split `track` into `segments` equal-distance sections.
pub fn segments(track: &Track, segments: usize) -> Result<Vec<TrackSegment>, SegmentError> {
    if segments == 0 {
        return Err(SegmentError::ZeroSegments);
    }
    let points = track.points();
    let n = points.len();
    let mut cumulative = vec![0.0f64; n];
    for i in 1..n {
        cumulative[i] = cumulative[i - 1]
            + distance(points[i - 1].coordinate(), points[i].coordinate()).meters();
    }
    let total = cumulative[n - 1];
    if !total.is_finite() || total <= 0.0 {
        return Err(SegmentError::ZeroLength);
    }

    // Timestamp at an arbitrary distance along the track, linearly
    // interpolated between the two neighbouring fixes.
    let time_at = |target: f64| -> Timestamp {
        let target = target.clamp(0.0, total);
        // find segment
        let mut i = 0usize;
        while i + 1 < n && cumulative[i + 1] < target {
            i += 1;
        }
        if i + 1 >= n {
            return points[n - 1].timestamp();
        }
        let seg_len = cumulative[i + 1] - cumulative[i];
        let frac = if seg_len > 0.0 {
            (target - cumulative[i]) / seg_len
        } else {
            0.0
        };
        let t0 = points[i].timestamp().unix_secs();
        let t1 = points[i + 1].timestamp().unix_secs();
        Timestamp::from_unix_secs(t0 + (t1 - t0) * frac)
    };

    let mut out = Vec::with_capacity(segments);
    for si in 0..segments {
        let lo = total * si as f64 / segments as f64;
        let hi = total * (si + 1) as f64 / segments as f64;
        let t_lo = time_at(lo);
        let t_hi = time_at(hi);

        // Count fixes and elevation gain inside (lo, hi].
        let mut point_count = 0usize;
        let mut elev_gain = 0.0f64;
        for i in 0..n {
            if cumulative[i] > lo && cumulative[i] <= hi {
                point_count += 1;
            }
            if i > 0 && cumulative[i] > lo && cumulative[i] <= hi {
                let prev_alt = points[i - 1].altitude();
                let curr_alt = points[i].altitude();
                if let (Some(a0), Some(a1)) = (prev_alt, curr_alt) {
                    let diff = a1 - a0;
                    if diff > 0.0 {
                        elev_gain += diff;
                    }
                }
            }
        }
        // Make sure the final section owns the last fix.
        if si == segments - 1 {
            point_count = point_count.max(1);
        }

        let distance = Distance::from_meters((hi - lo).max(0.0));
        let duration_secs = (t_hi.unix_secs() - t_lo.unix_secs()).max(0.0);
        let duration = Duration::from_secs(duration_secs);
        let average_speed = if duration_secs > 0.0 {
            Speed::from_mps(distance.meters() / duration_secs)
        } else {
            Speed::ZERO
        };

        out.push(TrackSegment {
            index: si,
            start_distance: Distance::from_meters(lo),
            end_distance: Distance::from_meters(hi),
            distance,
            duration,
            average_speed,
            elevation_gain: elev_gain,
            point_count,
        });
    }
    Ok(out)
}

/// Section-by-section comparison of a group of tracks.
pub fn compare_segments(
    tracks: &[Track],
    segment_count: usize,
) -> Result<Vec<SegmentComparison>, SegmentError> {
    if tracks.is_empty() {
        return Err(SegmentError::NoTracks);
    }
    let per_track: Vec<Vec<TrackSegment>> = tracks
        .iter()
        .map(|t| segments(t, segment_count))
        .collect::<Result<_, _>>()?;

    let mut out = Vec::with_capacity(segment_count);
    for i in 0..segment_count {
        let segs: Vec<TrackSegment> = per_track.iter().map(|v| v[i].clone()).collect();
        let mut min_speed = segs[0].average_speed;
        let mut max_speed = segs[0].average_speed;
        let mut sum = 0.0f64;
        for s in &segs {
            if s.average_speed.mps() < min_speed.mps() {
                min_speed = s.average_speed;
            }
            if s.average_speed.mps() > max_speed.mps() {
                max_speed = s.average_speed;
            }
            sum += s.average_speed.mps();
        }
        let mean_speed = Speed::from_mps(sum / segs.len() as f64);
        let speed_spread = Speed::from_mps(max_speed.mps() - min_speed.mps());
        out.push(SegmentComparison {
            index: i,
            start_distance: segs[0].start_distance,
            end_distance: segs[0].end_distance,
            segments: segs,
            min_speed,
            max_speed,
            mean_speed,
            speed_spread,
        });
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Route-axis segmentation (fixed distance boundaries along a canonical route)
// ---------------------------------------------------------------------------

use crate::attempt::Attempt;

/// One fixed-distance slice of an attempt along the canonical route.
#[derive(Debug, Clone, PartialEq)]
pub struct RouteSegment {
    /// Zero-based section index.
    pub index: usize,
    /// Distance from the route start to the section start.
    pub start_distance: Distance,
    /// Distance from the route start to the section end (route boundary).
    pub end_distance: Distance,
    /// Elapsed time across the part of the section the attempt actually covered.
    pub duration: Duration,
    /// Average speed over the covered part (0 if no time).
    pub average_speed: Speed,
    /// Whether the attempt covered the whole section.
    pub complete: bool,
}

/// Per-section comparison of a group of attempts on the same route.
#[derive(Debug, Clone, PartialEq)]
pub struct RouteSegmentComparison {
    /// Zero-based section index.
    pub index: usize,
    /// Distance from the route start to the section start.
    pub start_distance: Distance,
    /// Distance from the route start to the section end (route boundary).
    pub end_distance: Distance,
    /// One entry per input attempt, in input order.
    pub segments: Vec<RouteSegment>,
    /// Slowest section speed among the attempts that covered it.
    pub min_speed: Speed,
    /// Fastest section speed among the attempts that covered it.
    pub max_speed: Speed,
    /// Arithmetic mean of the covering attempts' section speeds.
    pub mean_speed: Speed,
    /// Spread between fastest and slowest (max - min).
    pub speed_spread: Speed,
}

/// Splits a single attempt into fixed-distance sections along the route.
pub fn route_segments(
    attempt: &Attempt,
    segment_distance: Distance,
    route_distance: Distance,
) -> Result<Vec<RouteSegment>, SegmentError> {
    if segment_distance.meters() <= 0.0 {
        return Err(SegmentError::ZeroSegments);
    }
    if route_distance.meters() <= 0.0 {
        return Err(SegmentError::ZeroLength);
    }

    let seg = segment_distance.meters();
    let total = route_distance.meters();
    let n = (total / seg).ceil() as usize;
    let n = n.max(1);

    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let start = (i as f64) * seg;
        let end = ((i as f64 + 1.0) * seg).min(total);
        if start >= total {
            break;
        }
        let covered_end = end.min(attempt.distance.meters());
        let complete = attempt.distance.meters() >= end - 1e-9;

        let duration_secs = if start < attempt.distance.meters() {
            let t_start = attempt
                .time_at(Distance::from_meters(start))
                .map(|d| d.as_secs())
                .unwrap_or(0.0);
            let t_end = attempt
                .time_at(Distance::from_meters(covered_end))
                .map(|d| d.as_secs())
                .unwrap_or(t_start);
            (t_end - t_start).max(0.0)
        } else {
            0.0
        };
        let duration = Duration::from_secs(duration_secs);
        let covered = (covered_end - start).max(0.0);
        let average_speed = if duration_secs > 0.0 {
            Speed::from_mps(covered / duration_secs)
        } else {
            Speed::ZERO
        };

        out.push(RouteSegment {
            index: i,
            start_distance: Distance::from_meters(start),
            end_distance: Distance::from_meters(end),
            duration,
            average_speed,
            complete,
        });
    }
    Ok(out)
}

/// Section-by-section comparison of a group of attempts on the same route.
pub fn compare_route_segments(
    attempts: &[Attempt],
    segment_distance: Distance,
    route_distance: Distance,
) -> Result<Vec<RouteSegmentComparison>, SegmentError> {
    if attempts.is_empty() {
        return Err(SegmentError::NoTracks);
    }
    if segment_distance.meters() <= 0.0 {
        return Err(SegmentError::ZeroSegments);
    }
    if route_distance.meters() <= 0.0 {
        return Err(SegmentError::ZeroLength);
    }

    let per_attempt: Vec<Vec<RouteSegment>> = attempts
        .iter()
        .map(|a| route_segments(a, segment_distance, route_distance).unwrap_or_default())
        .collect();

    let section_count = per_attempt.first().map(|v| v.len()).unwrap_or(0);
    let mut out = Vec::with_capacity(section_count);
    for i in 0..section_count {
        let segs: Vec<RouteSegment> = per_attempt.iter().map(|v| v[i].clone()).collect();
        let mut min_speed = Speed::ZERO;
        let mut max_speed = Speed::ZERO;
        let mut sum = 0.0f64;
        let mut count = 0usize;
        let mut first = true;
        for s in &segs {
            if s.duration.as_secs() <= 0.0 {
                continue;
            }
            if first {
                min_speed = s.average_speed;
                max_speed = s.average_speed;
                first = false;
            } else {
                if s.average_speed.mps() < min_speed.mps() {
                    min_speed = s.average_speed;
                }
                if s.average_speed.mps() > max_speed.mps() {
                    max_speed = s.average_speed;
                }
            }
            sum += s.average_speed.mps();
            count += 1;
        }
        if count == 0 {
            min_speed = Speed::ZERO;
            max_speed = Speed::ZERO;
        }
        let mean_speed = if count > 0 {
            Speed::from_mps(sum / count as f64)
        } else {
            Speed::ZERO
        };
        let speed_spread = Speed::from_mps((max_speed.mps() - min_speed.mps()).max(0.0));
        let (start_distance, end_distance) = if let Some(s) = segs.first() {
            (s.start_distance, s.end_distance)
        } else {
            (Distance::ZERO, Distance::ZERO)
        };
        out.push(RouteSegmentComparison {
            index: i,
            start_distance,
            end_distance,
            segments: segs,
            min_speed,
            max_speed,
            mean_speed,
            speed_spread,
        });
    }
    Ok(out)
}
