// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Pairwise route similarity.
//!
//! Given two GPS tracks, answers the MVP question *"do these recordings
//! represent the same route?"* with structured diagnostics rather than a bare
//! boolean:
//!
//! ```text
//! start:       8m
//! end:         13m
//! length:      1.02
//! overlap:     94%
//! direction:   0.98
//! ```
//!
//! See [`MatchConfig`] for the thresholds and [`MatchScore`] for the metrics.
//! The [`overall_score`](MatchScore::overall_score) is a provisional single
//! number; debugging should use the individual components.

use crate::geo::{BoundingBox, PolylineBounds, bearing, bounding_box, destination, distance};
use crate::units::Distance;
use crate::{Coordinate, Track};

/// Thresholds for pairwise track comparison.
///
/// `min_*`/`max_*` fields bound the reported metrics; `lateral_tolerance` is
/// the distance within which a point counts as "on" the other track's
/// geometry when computing spatial overlap.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatchConfig {
    /// A point is "on" another track when it projects within this many meters.
    pub lateral_tolerance: Distance,
    /// Minimum spatial overlap for a route match (0..1).
    pub min_spatial_overlap: f64,
    /// Minimum ratio `length_a / length_b` for a route match.
    pub min_distance_ratio: f64,
    /// Maximum ratio `length_a / length_b` for a route match.
    pub max_distance_ratio: f64,
    /// Maximum allowed start-to-start distance, in meters.
    pub max_start_distance: Distance,
    /// Maximum allowed finish-to-finish distance, in meters.
    pub max_end_distance: Distance,
}

impl Default for MatchConfig {
    fn default() -> Self {
        Self {
            lateral_tolerance: Distance::from_meters(25.0),
            min_spatial_overlap: 0.6,
            min_distance_ratio: 0.70,
            max_distance_ratio: 1.45,
            max_start_distance: Distance::from_meters(150.0),
            max_end_distance: Distance::from_meters(150.0),
        }
    }
}

/// Structured similarity report between two tracks.
///
/// All metrics are 0..1 fractions (or distances/ratios) that can be inspected
/// individually. `overall_score` aggregates them and is provisional — tune it
/// against a labeled corpus before trusting it as a threshold.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatchScore {
    /// Geodesic distance between the two start points, in meters.
    pub start_distance: Distance,
    /// Geodesic distance between the two finish points, in meters.
    pub end_distance: Distance,
    /// `length_a / length_b`.
    pub distance_ratio: f64,
    /// Fraction of each track's points near the other's geometry (the smaller
    /// of the two directions), 0..1.
    pub spatial_overlap: f64,
    /// Mean directional agreement of matched segments, 0..1 (~0 if one track
    /// runs the route reversed relative to the other).
    pub direction_similarity: f64,
    /// Fraction of consecutive `b`-projections onto `a` that advance along the
    /// route (allowing 25 m of backward jitter), 0..1. High when
    /// the two recordings progress in the same direction along the same shape;
    /// low when the subject repeatedly snaps back (e.g. crossing the other
    /// route repeatedly). Reported, but deliberately *not* folded into
    /// `overall_score`: it measures dynamic progression, not geometric
    /// agreement, and folding it in would silently re-weight the existing
    /// matching decision.
    pub continuity: f64,
    /// Provisional weighted aggregate of the metrics above, 0..1.
    pub overall_score: f64,
}

impl MatchScore {
    /// Conservative "same route?" decision from geometry-only metrics.
    ///
    /// Direction is *not* part of the boolean: a route run in reverse is still
    /// the same route, so reversed recordings keep matching while
    /// [`direction_similarity`](MatchScore::direction_similarity) is reported
    /// separately. All thresholds come from `config`.
    pub fn is_match(&self, config: &MatchConfig) -> bool {
        self.proximity_ok(config)
            && self.distance_ratio >= config.min_distance_ratio
            && self.distance_ratio <= config.max_distance_ratio
            && self.spatial_overlap >= config.min_spatial_overlap
    }

    /// Whether the start and finish pairs are within their proximity caps.
    fn proximity_ok(&self, config: &MatchConfig) -> bool {
        self.start_distance.meters() <= config.max_start_distance.meters()
            && self.end_distance.meters() <= config.max_end_distance.meters()
    }
}

/// A track's geometry indexed once for repeated comparison.
///
/// Building the index costs one pass over the track; matching a recording
/// against a whole catalog (discovery, benchmarks, evaluation) reuses it
/// instead of re-deriving the polyline, its segment boxes, the cumulative
/// distances, and the 50 m length basis on every pair.
#[derive(Debug, Clone, PartialEq)]
pub struct PreparedTrack {
    bounds: PolylineBounds,
    /// Meters along the raw polyline at each vertex (`cumulative[0] == 0`).
    cumulative: Vec<f64>,
    bbox: BoundingBox,
    /// Recorded length on the 50 m chord basis (see the private
    /// `robust_length` helper).
    robust_length: Distance,
    start: Coordinate,
    end: Coordinate,
}

impl PreparedTrack {
    /// Indexes a track's geometry for matching.
    pub fn new(track: &Track) -> Self {
        let points = track.points();
        let polyline: Vec<Coordinate> = points.iter().map(|p| p.coordinate()).collect();
        let mut cumulative = Vec::with_capacity(polyline.len());
        cumulative.push(0.0);
        for pair in polyline.windows(2) {
            cumulative.push(
                cumulative.last().expect("the start is always pushed")
                    + distance(pair[0], pair[1]).meters(),
            );
        }
        Self {
            bbox: bounding_box(&polyline).expect("a track has at least two points"),
            bounds: PolylineBounds::new(&polyline),
            cumulative,
            robust_length: robust_length(track),
            start: points[0].coordinate(),
            end: points
                .last()
                .expect("a track has at least two points")
                .coordinate(),
        }
    }

    /// The track's geometry, one coordinate per fix.
    pub fn polyline(&self) -> &[Coordinate] {
        self.bounds.coordinates()
    }

    /// Recorded length on the 50 m chord basis used for the distance ratio.
    pub fn robust_length(&self) -> Distance {
        self.robust_length
    }
}

/// Orientation-specific cheap necessary conditions for a route match.
struct MatchGate {
    forward: bool,
    reversed: bool,
}

impl MatchGate {
    fn new(a: &PreparedTrack, b: &PreparedTrack, config: &MatchConfig) -> Self {
        if !boxes_within(a.bbox, b.bbox, config.lateral_tolerance) {
            return Self {
                forward: false,
                reversed: false,
            };
        }
        let max_start = config.max_start_distance.meters();
        let max_end = config.max_end_distance.meters();
        Self {
            forward: distance(a.start, b.start).meters() <= max_start
                && distance(a.end, b.end).meters() <= max_end,
            reversed: distance(a.start, b.end).meters() <= max_start
                && distance(a.end, b.start).meters() <= max_end,
        }
    }
}

/// Whether the two bounding boxes come within `tol` meters of each other.
///
/// Conservative: it may say "yes" for tracks that still never touch, but a
/// "no" proves that no point of one lies within `tol` of the other's polyline.
fn boxes_within(a: BoundingBox, b: BoundingBox, tol: Distance) -> bool {
    let tol_m = tol.meters();
    if !tol_m.is_finite() || tol_m < 0.0 {
        return true; // nothing to prune on; the exact metrics decide
    }
    let d_lat = tol_m / 111_320.0;
    // Longitude degrees shrink toward the poles. Widening by the pole-ward
    // latitude of both boxes can only over-approximate, so it never rejects a
    // point that is genuinely within `tol`.
    let pole_ward = [
        a.min.latitude(),
        a.max.latitude(),
        b.min.latitude(),
        b.max.latitude(),
    ]
    .into_iter()
    .fold(0.0f64, |acc, lat| acc.max(lat.abs()));
    let cos_lat = (pole_ward + d_lat).min(90.0).to_radians().cos().max(1e-12);
    let d_lon = tol_m / (cos_lat * 111_320.0);

    a.min.latitude() - d_lat <= b.max.latitude()
        && b.min.latitude() - d_lat <= a.max.latitude()
        && a.min.longitude() - d_lon <= b.max.longitude()
        && b.min.longitude() - d_lon <= a.max.longitude()
}

fn length_ratio_ok(a: &PreparedTrack, b: &PreparedTrack, config: &MatchConfig) -> bool {
    let ratio = a.robust_length.meters() / b.robust_length.meters();
    ratio >= config.min_distance_ratio && ratio <= config.max_distance_ratio
}

/// Compares `a` against `b` in either travel orientation, returning the better
/// matching score when either the forward or the reversed comparison satisfies
/// `config`; `None` when neither does.
///
/// This lets route discovery cluster recordings that run the same route in the
/// opposite direction. The returned score reports the orientation that
/// matched.
pub fn compare_either_direction(a: &Track, b: &Track, config: &MatchConfig) -> Option<MatchScore> {
    let prepared_a = PreparedTrack::new(a);
    let prepared_b = PreparedTrack::new(b);
    compare_either_direction_prepared(&prepared_a, &prepared_b, b, config)
}

/// [`compare_either_direction`] for tracks whose geometry is already indexed.
///
/// `b_track` must be the recording `prepared_b` was built from: the reversed
/// orientation is resampled from its other end, so its length basis is not
/// recoverable from the forward index.
pub fn compare_either_direction_prepared(
    prepared_a: &PreparedTrack,
    prepared_b: &PreparedTrack,
    b_track: &Track,
    config: &MatchConfig,
) -> Option<MatchScore> {
    let gate = MatchGate::new(prepared_a, prepared_b, config);
    if !gate.forward && !gate.reversed {
        return None;
    }

    // `is_match` needs proximity, the length ratio, and spatial overlap. The
    // gate already settled proximity and the boxes, so the O(points²) metrics
    // only run for orientations that can still answer "same route".
    if gate.forward && length_ratio_ok(prepared_a, prepared_b, config) {
        let score = compare_prepared(prepared_a, prepared_b, config);
        if score.is_match(config) {
            return Some(score);
        }
    }

    if gate.reversed {
        let reversed_b = b_track.reversed();
        let prepared_reversed = PreparedTrack::new(&reversed_b);
        if length_ratio_ok(prepared_a, &prepared_reversed, config) {
            let score = compare_prepared(prepared_a, &prepared_reversed, config);
            if score.is_match(config) {
                return Some(score);
            }
        }
    }

    None
}

/// Compares two tracks with [`MatchConfig::default`].
pub fn compare(a: &Track, b: &Track) -> MatchScore {
    compare_with(a, b, &MatchConfig::default())
}

/// Compares two tracks under custom thresholds.
pub fn compare_with(a: &Track, b: &Track, config: &MatchConfig) -> MatchScore {
    compare_prepared(&PreparedTrack::new(a), &PreparedTrack::new(b), config)
}

/// Compares two prepared tracks in the given orientation, mirroring
/// [`compare_with`] exactly.
pub fn compare_prepared(a: &PreparedTrack, b: &PreparedTrack, config: &MatchConfig) -> MatchScore {
    let start_distance = distance(a.start, b.start);
    let end_distance = distance(a.end, b.end);
    let distance_ratio = a.robust_length.meters() / b.robust_length.meters();

    // A point can only lie within the lateral tolerance of the other track when
    // the two bounding boxes come that close. If they don't, every geometric
    // metric is exactly zero and the O(points²) passes can be skipped.
    let (spatial_overlap, direction_similarity, continuity) =
        if boxes_within(a.bbox, b.bbox, config.lateral_tolerance) {
            geometric_metrics(a, b, config)
        } else {
            (0.0, 0.0, 0.0)
        };

    let closure = |d: Distance, max: Distance| -> f64 {
        if max.meters() <= 0.0 {
            return 0.0;
        }
        (1.0 - (d.meters() / max.meters())).clamp(0.0, 1.0)
    };

    let overall_score = 0.40 * spatial_overlap
        + 0.25 * direction_similarity
        + 0.20 * closure(start_distance, config.max_start_distance)
        + 0.15 * closure(end_distance, config.max_end_distance);

    MatchScore {
        start_distance,
        end_distance,
        distance_ratio,
        spatial_overlap,
        direction_similarity,
        continuity,
        overall_score,
    }
}

/// The O(points²) metrics for one orientation, sharing the reference index and
/// the point-to-route projections between them.
fn geometric_metrics(
    a: &PreparedTrack,
    b: &PreparedTrack,
    config: &MatchConfig,
) -> (f64, f64, f64) {
    let tol = config.lateral_tolerance;

    // b's points against a's geometry feed both `overlap` (the b→a half) and
    // the continuity metric, which walks the same projections along a.
    let on_a = route_positions(a, b.polyline(), tol);
    let on_b = route_positions(b, a.polyline(), tol);

    // Direction-agnostic overlap: the smaller of the two point fractions, so a
    // recording that only covers part of the other route does not score 1.
    let overlap = (on_a.on as f64 / b.polyline().len() as f64)
        .min(on_b.on as f64 / a.polyline().len() as f64);
    let continuity = if on_a.on == 0 {
        0.0
    } else {
        on_a.advancing as f64 / on_a.on as f64
    };
    let direction = direction_similarity(a, b.polyline(), tol);
    (overlap, direction, continuity)
}

/// Point-to-route projections summarised in one pass.
struct RoutePositions {
    /// Points that landed within the lateral tolerance of the polyline.
    on: usize,
    /// Consecutive on-track points that advanced along the reference.
    advancing: usize,
}

/// Projects `points` onto `reference`'s polyline in a single pass.
///
/// The reference's cumulative polyline is the axis: each point that projects
/// within the lateral tolerance is counted as on-track, and counts as advancing
/// when its cumulative position does not fall more than `BACKTRACK_TOLERANCE_M`
/// behind the previous on-track position. The caller derives the spatial
/// overlap and the continuity metric from these counts, so one projection run
/// serves both. A subject that keeps crossing the reference back and forth (a
/// self-intersection, or an out-and-back run against the wrong half) ends up
/// with a low `advancing / on`.
fn route_positions(
    reference: &PreparedTrack,
    points: &[Coordinate],
    tol: Distance,
) -> RoutePositions {
    let mut previous: Option<f64> = None;
    let mut on = 0usize;
    let mut advancing = 0usize;
    for point in points {
        let Some(projection) = reference.bounds.project_within(*point, tol) else {
            continue;
        };
        let along =
            reference.cumulative[projection.segment_index] + projection.distance_along.meters();
        if let Some(prev) = previous
            && along >= prev - BACKTRACK_TOLERANCE_M
        {
            advancing += 1;
        }
        previous = Some(along);
        on += 1;
    }
    RoutePositions { on, advancing }
}

/// Along-track length robust to lateral GPS noise: the length of the track
/// re-sampled onto 50 m chords. Lateral jitter barely inflates a 50 m chord,
/// so recording-length ratios stay meaningful for the matcher (a raw point
/// length would be the noisy GPS path, not the route distance).
fn robust_length(track: &Track) -> Distance {
    const CHORD_M: f64 = 50.0;
    match track.resample_by_distance(Distance::from_meters(CHORD_M)) {
        Ok(resampled) => {
            let length = resampled.distance().meters();
            if length > 0.0 {
                Distance::from_meters(length)
            } else {
                track.distance() // too short to span a 50 m chord
            }
        }
        Err(_) => track.distance(),
    }
}

/// Backward jitter (m) between consecutive projections that still counts as
/// "advancing" for [`MatchScore::continuity`] (see [`route_positions`]).
const BACKTRACK_TOLERANCE_M: f64 = 25.0;

/// Mean directional agreement between matched segments: for each chord of `b`
/// spanning at least [`MIN_DIRECTION_STEP_M`] meters whose midpoint is near
/// `a`, compare the chord bearing with the bearing of the `a`-segment the
/// midpoint projects onto. Same direction scores +1, reversed scores 0.
///
/// A chord basis is used (rather than consecutive fixes) so that GPS noise
/// does not dominate the direction signal on short, slow steps.
const MIN_DIRECTION_STEP_M: f64 = 20.0;

fn direction_similarity(reference: &PreparedTrack, subject: &[Coordinate], tol: Distance) -> f64 {
    let geometry = reference.polyline();
    if subject.len() < 2 {
        return 0.0;
    }

    let mut sum = 0.0f64;
    let mut count = 0usize;

    let mut chord_start = subject[0];
    for &point in &subject[1..] {
        let step = distance(chord_start, point).meters();
        if step < MIN_DIRECTION_STEP_M {
            continue; // keep building the chord
        }

        let Ok(chord_bearing) = bearing(chord_start, point) else {
            chord_start = point;
            continue;
        };
        let mid = destination(
            chord_start,
            chord_bearing,
            Distance::from_meters(step / 2.0),
        );
        let Some(projection) = reference.bounds.project_within(mid, tol) else {
            chord_start = point;
            continue;
        };

        let seg_from = geometry[projection.segment_index];
        let seg_to = geometry[projection.segment_index + 1];
        let Ok(reference_bearing) = bearing(seg_from, seg_to) else {
            chord_start = point;
            continue;
        };

        let delta = (chord_bearing.as_radians() - reference_bearing.as_radians())
            .rem_euclid(std::f64::consts::TAU);
        sum += delta.cos().max(0.0);
        count += 1;

        chord_start = point;
    }

    if count == 0 {
        return 0.0;
    }
    sum / count as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::synthetic::{SyntheticConfig, add_detour, generate, reverse};
    use crate::{FilterConfig, SimplifyConfig, TrackPoint};

    fn route() -> Vec<Coordinate> {
        vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.506, 13.403).unwrap(),
            Coordinate::new(52.512, 13.401).unwrap(),
            Coordinate::new(52.518, 13.408).unwrap(),
        ]
    }

    fn clean(seed: u64) -> Track {
        generate(&route(), &SyntheticConfig::clean(seed))
    }

    fn noisy(seed: u64) -> Track {
        generate(&route(), &SyntheticConfig::noisy(seed, 6.0))
    }

    /// The real pipeline: messy recording → filter + simplify + resample (25 m),
    /// then compare. Resampling by distance gives a jitter-robust length basis.
    fn cleaned(track: &Track) -> Track {
        let (filtered, _report) = track.filter(&FilterConfig::default());
        let simplified = filtered.simplify(&SimplifyConfig::default());
        simplified
            .resample_by_distance(Distance::from_meters(25.0))
            .unwrap()
    }

    #[test]
    fn identical_track_scores_perfectly() {
        let a = clean(1);
        let score = compare(&a, &a);
        assert!(score.start_distance.meters() < 1e-9);
        assert!(score.end_distance.meters() < 1e-9);
        assert!((score.distance_ratio - 1.0).abs() < 1e-9);
        assert!(score.spatial_overlap > 0.99);
        assert!(score.direction_similarity > 0.99);
        assert!(
            score.continuity > 0.99,
            "a self-identical track never backtracks"
        );
        assert!(score.overall_score > 0.95);
    }

    #[test]
    fn gradual_out_and_back_keeps_continuity() {
        // A runner doubles back along the same corridor *gradually* (5 m per
        // sample vs the 25 m backward-jitter tolerance). Rewinding a few meters
        // per fix is still "continuous" — the metric must not call a normal
        // out-and-back a backtracking mess.
        let geometry = vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.522, 13.400).unwrap(),
        ];
        let reference = generate(&geometry, &SyntheticConfig::clean(1));
        let subject = generate(
            &[geometry[0], geometry[1], geometry[0]],
            &SyntheticConfig::clean(2),
        );

        let score = compare(&reference, &subject);
        assert!(
            score.spatial_overlap > 0.9,
            "out-and-back overlaps its corridor"
        );
        assert!(
            score.continuity > 0.8,
            "a gradual doubling-back is continuous, got {}",
            score.continuity
        );
    }

    #[test]
    fn snapping_back_subject_low_continuity_high_overlap() {
        // A subject that marches up 100 m and snaps back 50 m on every cell
        // stays inside the reference corridor (so overlap stays near 1), but
        // each 50 m snap-back exceeds the 25 m backward-jitter tolerance, so
        // `continuity` collapses to ~½.
        let geometry = vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.522, 13.400).unwrap(),
        ];
        let reference = generate(&geometry, &SyntheticConfig::clean(1));

        let step_deg = 1.0 / 111_132.0; // 1 m of latitude
        let mut positions = Vec::new();
        let mut center = 0.0f64;
        // Each cell advances 50 m then snaps straight back 50 m, so exactly
        // half the steps are hard snap-backs (> 25 m backward jitter).
        while center < 2200.0 {
            positions.extend([center, center + 50.0, center]);
            center += 50.0;
        }
        let points: Vec<TrackPoint> = positions
            .iter()
            .enumerate()
            .map(|(i, &offset)| {
                TrackPoint::new(
                    crate::units::Timestamp::from_unix_ms(i as i64 * 5_000),
                    Coordinate::new(52.500 + step_deg * offset, 13.400).unwrap(),
                )
            })
            .collect();
        let subject = Track::new(points).unwrap();

        let score = compare(&reference, &subject);
        assert!(
            score.spatial_overlap > 0.8,
            "the corridor is covered, got {}",
            score.spatial_overlap
        );
        // Half the steps are hard 50 m snap-backs (> the 25 m jitter window),
        // pushing continuity far below the ~1.0 of a forward-only run, even
        // though every other step still advances 50 m past the snap point.
        assert!(
            score.continuity < 0.7,
            "half the march is a hard snap-back, continuity got {}",
            score.continuity
        );
    }

    #[test]
    fn two_recordings_of_same_route_match() {
        let a = cleaned(&clean(1));
        let b = cleaned(&noisy(2));
        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap > 0.8,
            "overlap {}",
            score.spatial_overlap
        );
        assert!(
            score.direction_similarity > 0.8,
            "direction {}",
            score.direction_similarity
        );
        assert!(
            (score.distance_ratio - 1.0).abs() < 0.4,
            "ratio {}",
            score.distance_ratio
        );
    }

    #[test]
    fn reversed_track_keeps_overlap_but_panics_direction() {
        let a = clean(1);
        let b = reverse(&clean(1));
        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap > 0.8,
            "geometry overlap is direction-neutral"
        );
        assert!(
            score.direction_similarity < 0.2,
            "reversed recording should disagree in direction, got {}",
            score.direction_similarity
        );
    }

    #[test]
    fn crossing_routes_do_not_match() {
        // Two routes of similar length crossing near-perpendicularly at their
        // midpoint: they share only a tiny region, so they must not match.
        let route_a = vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.520, 13.400).unwrap(),
        ];
        let route_b = vec![
            Coordinate::new(52.510, 13.390).unwrap(),
            Coordinate::new(52.510, 13.410).unwrap(),
        ];
        let a = cleaned(&generate(&route_a, &SyntheticConfig::clean(1)));
        let b = cleaned(&generate(&route_b, &SyntheticConfig::clean(2)));

        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap < 0.3,
            "perpendicular crossing routes barely overlap, got {}",
            score.spatial_overlap
        );
        assert!(!score.is_match(&MatchConfig::default()));
    }

    #[test]
    fn parallel_routes_do_not_match() {
        // Two ~1 km parallel lanes 200 m apart: lateral error alone must
        // separate them (default tolerance is 25 m).
        let route_a = vec![
            Coordinate::new(52.500, 13.400).unwrap(),
            Coordinate::new(52.510, 13.400).unwrap(),
        ];
        let offset_west = Coordinate::new(52.500, 13.3980).unwrap();
        let offset_east = Coordinate::new(52.510, 13.3980).unwrap();
        let route_b = vec![offset_west, offset_east];
        let a = generate(&route_a, &SyntheticConfig::clean(1));
        let b = generate(&route_b, &SyntheticConfig::clean(2));

        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap < 0.3,
            "200 m apart lanes must not count as on-route (25 m tolerance)",
        );
        assert!(!score.is_match(&MatchConfig::default()));
    }

    #[test]
    fn different_route_scores_low() {
        let a = clean(1);
        let other_route = vec![
            Coordinate::new(52.510, 13.410).unwrap(),
            Coordinate::new(52.505, 13.430).unwrap(),
            Coordinate::new(52.498, 13.455).unwrap(),
        ];
        let b = generate(&other_route, &SyntheticConfig::clean(2));
        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap < 0.3,
            "different routes barely overlap"
        );
    }

    #[test]
    fn partial_route_reports_intermediate_overlap() {
        // b is a ~half-length prefix of a.
        let full = clean(1);
        let half: Vec<TrackPoint> = full.points()[..full.points().len() / 2].to_vec();
        let prefix = Track::new(half).unwrap();
        let score = compare(&full, &prefix);
        assert!(
            score.spatial_overlap < 0.8,
            "half route should not fully overlap"
        );
        assert!(score.spatial_overlap > 0.3);
        assert!(
            score.distance_ratio > 1.2 && score.distance_ratio < 3.0,
            "full/prefix length ratio was {}",
            score.distance_ratio
        );
    }

    #[test]
    fn detour_degrades_similarity_gracefully() {
        let a = clean(1);
        let b = add_detour(&a, Distance::from_meters(40.0));
        let score = compare(&a, &b);
        assert!(
            score.spatial_overlap > 0.5,
            "small detour keeps most points near"
        );
        assert!(score.spatial_overlap < 0.99, "but not all");
    }

    #[test]
    fn reversed_plus_noise_is_recovered_by_comparing_in_forward_order() {
        // The engine compares in the given order; a user recording the loop
        // in reverse should still show high overlap, which the caller can
        // combine with the low direction to decide it's the same route.
        let a = clean(1);
        let b = noisy(7);
        let b = reverse(&b);
        let score = compare(&a, &b);
        assert!(score.spatial_overlap > 0.6);
        assert!(score.direction_similarity < 0.3);
    }

    #[test]
    fn looser_lateral_tolerance_raises_overlap() {
        let a = clean(1);
        let b = add_detour(&a, Distance::from_meters(40.0));

        let tight = compare_with(
            &a,
            &b,
            &MatchConfig {
                lateral_tolerance: Distance::from_meters(10.0),
                ..MatchConfig::default()
            },
        );
        let loose = compare_with(
            &a,
            &b,
            &MatchConfig {
                lateral_tolerance: Distance::from_meters(100.0),
                ..MatchConfig::default()
            },
        );

        assert!(loose.spatial_overlap >= tight.spatial_overlap);
        assert!(
            loose.spatial_overlap > 0.9,
            "wide tolerance covers the detour"
        );
    }

    /// Straightforward reference implementation of the geometric metrics,
    /// kept here so the indexed fast path can be checked against it. The fast
    /// path only changes *where* the projections come from, never the answer.
    fn reference_metrics(a: &Track, b: &Track, tol: Distance) -> (f64, f64, f64) {
        use crate::geo::{PolylineBounds, bearing, destination};

        let pa: Vec<Coordinate> = a.points().iter().map(|p| p.coordinate()).collect();
        let pb: Vec<Coordinate> = b.points().iter().map(|p| p.coordinate()).collect();

        let fraction_near = |points: &[Coordinate], geometry: &[Coordinate]| -> f64 {
            let bounds = PolylineBounds::new(geometry);
            let mut near = 0usize;
            for point in points {
                if let Some(projection) = bounds.project_within(*point, tol)
                    && projection.lateral_error.meters() <= tol.meters()
                {
                    near += 1;
                }
            }
            near as f64 / points.len() as f64
        };
        let overlap = fraction_near(&pb, &pa).min(fraction_near(&pa, &pb));

        let mut cumulative = Vec::with_capacity(pa.len());
        cumulative.push(0.0);
        for pair in pa.windows(2) {
            cumulative.push(cumulative.last().unwrap() + distance(pair[0], pair[1]).meters());
        }
        let bounds = PolylineBounds::new(&pa);
        let mut previous: Option<f64> = None;
        let mut advancing = 0usize;
        let mut counted = 0usize;
        for point in &pb {
            let Some(projection) = bounds.project_within(*point, tol) else {
                continue;
            };
            let along = cumulative[projection.segment_index] + projection.distance_along.meters();
            if let Some(prev) = previous
                && along >= prev - BACKTRACK_TOLERANCE_M
            {
                advancing += 1;
            }
            previous = Some(along);
            counted += 1;
        }
        let continuity = if counted == 0 {
            0.0
        } else {
            advancing as f64 / counted as f64
        };

        let bounds = PolylineBounds::new(&pa);
        let mut sum = 0.0f64;
        let mut count = 0usize;
        let mut chord_start = pb[0];
        for &point in &pb[1..] {
            let step = distance(chord_start, point).meters();
            if step < MIN_DIRECTION_STEP_M {
                continue;
            }
            let Ok(chord_bearing) = bearing(chord_start, point) else {
                chord_start = point;
                continue;
            };
            let mid = destination(
                chord_start,
                chord_bearing,
                Distance::from_meters(step / 2.0),
            );
            let Some(projection) = bounds.project_within(mid, tol) else {
                chord_start = point;
                continue;
            };
            let Ok(reference_bearing) = bearing(
                pa[projection.segment_index],
                pa[projection.segment_index + 1],
            ) else {
                chord_start = point;
                continue;
            };
            let delta = (chord_bearing.as_radians() - reference_bearing.as_radians())
                .rem_euclid(std::f64::consts::TAU);
            sum += delta.cos().max(0.0);
            count += 1;
            chord_start = point;
        }
        let direction = if count == 0 { 0.0 } else { sum / count as f64 };

        (overlap, direction, continuity)
    }

    #[test]
    fn indexed_metrics_match_a_direct_recomputation() {
        let config = MatchConfig::default();
        let a = noisy(1);
        let cases = vec![
            clean(2),
            noisy(3),
            add_detour(&a, Distance::from_meters(40.0)),
            reverse(&noisy(4)),
        ];
        for b in &cases {
            let score = compare_with(&a, b, &config);
            let expected = reference_metrics(&a, b, config.lateral_tolerance);
            assert_eq!(score.spatial_overlap, expected.0);
            assert_eq!(score.direction_similarity, expected.1);
            assert_eq!(score.continuity, expected.2);
        }
    }

    #[test]
    fn distant_tracks_score_zero_without_geometry_work() {
        let a = clean(1);
        // Another city: no point can fall within the lateral tolerance.
        let far_route = vec![
            Coordinate::new(48.137, 11.575).unwrap(),
            Coordinate::new(48.145, 11.582).unwrap(),
        ];
        let far = generate(&far_route, &SyntheticConfig::clean(2));
        let config = MatchConfig::default();

        let score = compare_with(&a, &far, &config);
        assert_eq!(score.spatial_overlap, 0.0);
        assert_eq!(score.direction_similarity, 0.0);
        assert_eq!(score.continuity, 0.0);
        assert!(!score.is_match(&config));
        assert!(compare_either_direction(&a, &far, &config).is_none());
    }

    #[test]
    fn prepared_either_direction_matches_the_track_api() {
        let config = MatchConfig::default();
        let a = clean(1);
        let cases = vec![
            clean(2),
            noisy(3),
            reverse(&noisy(4)),
            add_detour(&a, Distance::from_meters(40.0)),
        ];
        for b in &cases {
            let direct = compare_either_direction(&a, b, &config);
            let prepared = compare_either_direction_prepared(
                &PreparedTrack::new(&a),
                &PreparedTrack::new(b),
                b,
                &config,
            );
            assert_eq!(direct, prepared);
        }
    }
}
