// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Canonical one-dimensional route representation.
//!
//! A [`Route`] is a polyline through space with a stable axis of progress:
//!
//! ```text
//! distance_along_route: 0m ─────────────────────── 7,800m
//! ```
//!
//! Guardrails and geometry are validated at construction; every method is
//! pure. Identity, metadata, and user naming live outside the engine.

pub mod canonical;
pub mod discovery;
pub mod matching;

pub use canonical::{CanonicalError, CanonicalizeConfig, canonicalize};
pub use discovery::{DiscoveredRoute, RouteCatalog, TrackAddition};
pub use matching::{MatchConfig, MatchScore, compare, compare_either_direction, compare_with};

use crate::Track;
use crate::error::RouteError;
use crate::geo::{
    Coordinate, Projection, distance, interpolate, project_to_polyline, project_to_segment,
};
use crate::units::{Distance, Speed};

/// A point sampled from a route: its coordinate paired with its position along
/// the route's one-dimensional axis.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RoutePoint {
    /// Distance along the route from its start, in meters.
    pub distance: Distance,
    /// The point on the route's geometry at that distance.
    pub coordinate: Coordinate,
}

/// A canonical polyline route with a stable 0 → `length()` axis.
///
/// Geometry is validated once at construction (at least two finite points);
/// all methods are pure. A route is the canonical coordinate system that
/// turns noisy GPS points into "distance along route" + "lateral error".
#[derive(Debug, Clone, PartialEq)]
pub struct Route {
    geometry: Vec<Coordinate>,
    /// Meters along the route at each geometry vertex: `cumulative[0] == 0`.
    cumulative: Vec<f64>,
    /// Total length in meters, equal to the last entry of `cumulative`.
    total: f64,
}

impl Route {
    /// Builds a route from a polyline of at least two coordinates.
    ///
    /// Duplicate vertices are allowed and contribute zero length.
    pub fn new(geometry: Vec<Coordinate>) -> Result<Self, RouteError> {
        if geometry.is_empty() {
            return Err(RouteError::Empty);
        }
        if geometry.len() < 2 {
            return Err(RouteError::TooFewPoints(geometry.len()));
        }

        let mut cumulative = Vec::with_capacity(geometry.len());
        cumulative.push(0.0);
        for pair in geometry.windows(2) {
            cumulative
                .push(cumulative.last().expect("non-empty") + distance(pair[0], pair[1]).meters());
        }
        let total = *cumulative.last().expect("non-empty");

        Ok(Self {
            geometry,
            cumulative,
            total,
        })
    }

    /// The route's raw polyline geometry.
    pub fn geometry(&self) -> &[Coordinate] {
        &self.geometry
    }

    /// The route's total length, from start to finish.
    pub fn length(&self) -> Distance {
        Distance::from_meters(self.total)
    }

    /// The route's start coordinate.
    pub fn start(&self) -> Coordinate {
        self.geometry[0]
    }

    /// The route's finish coordinate.
    pub fn end(&self) -> Coordinate {
        *self.geometry.last().expect("route has at least two points")
    }

    /// The coordinate at `distance` meters along the route.
    ///
    /// Returns `None` when `distance` is non-finite, negative, or beyond the
    /// route's total length. `distance == length()` yields the finish point.
    #[allow(clippy::manual_find)]
    pub fn coordinate_at(&self, distance: Distance) -> Option<Coordinate> {
        let target = distance.meters();
        if !target.is_finite() || target < 0.0 || target > self.total {
            return None;
        }
        if target == self.total {
            return Some(self.end());
        }

        // Locate the segment with cumulative[i] <= target < cumulative[i+1].
        let mut i = 0;
        for idx in 0..self.cumulative.len() - 1 {
            if target >= self.cumulative[idx] && target < self.cumulative[idx + 1] {
                i = idx;
                break;
            }
        }

        let seg_len = self.cumulative[i + 1] - self.cumulative[i];
        if seg_len == 0.0 {
            // Duplicate vertices in a row: land on the shared vertex.
            return Some(self.geometry[i]);
        }

        let fraction = ((target - self.cumulative[i]) / seg_len).clamp(0.0, 1.0);
        Some(interpolate(
            self.geometry[i],
            self.geometry[i + 1],
            fraction,
        ))
    }

    /// Projects a coordinate onto the nearest route segment.
    ///
    /// Unlike `geo::project_to_polyline`, the returned `distance_along`
    /// accumulates the distance from the route's start through the matched
    /// segment, giving the one-dimensional position used by attempts and
    /// ghost racing.
    pub fn project(&self, point: Coordinate) -> Projection {
        let mut projection =
            project_to_polyline(point, &self.geometry).expect("route has at least two points");
        projection.distance_along = Distance::from_meters(
            self.cumulative[projection.segment_index] + projection.distance_along.meters(),
        );
        projection
    }

    /// Projects a coordinate and pairs its route distance with the projected
    /// coordinate on the geometry.
    pub fn nearest(&self, point: Coordinate) -> RoutePoint {
        let projection = self.project(point);
        RoutePoint {
            distance: projection.distance_along,
            coordinate: projection.projected,
        }
    }

    /// Projects `point` onto the segments whose cumulative span intersects
    /// `[center - backward, center + forward]`.
    ///
    /// Restricting the search to a window around a previous along-route
    /// position is what disambiguates duplicate geometry (loops, figure
    /// eights, out-and-back routes): "being nearest to X" is not enough when X
    /// occurs twice, but "nearest to X within a window around where I was" is.
    /// `None` when no segment intersects the window or when the window is
    /// invalid (`backward`/`forward` negative or non-finite).
    ///
    /// The match with the smallest lateral error wins; matches return
    /// *cumulative* `distance_along` (from the route start), like
    /// [`Route::project`].
    pub fn projection_in_window(
        &self,
        point: Coordinate,
        center: Distance,
        backward: Distance,
        forward: Distance,
    ) -> Option<Projection> {
        let (lo, hi) = self.window_bounds(center, backward, forward)?;
        self.projections_in_window(point, lo, hi)
            .into_iter()
            .min_by(|a, b| {
                a.lateral_error
                    .meters()
                    .partial_cmp(&b.lateral_error.meters())
                    .expect("distances are finite")
            })
    }

    /// Validates a window and clamps it to the route's length.
    fn window_bounds(
        &self,
        center: Distance,
        backward: Distance,
        forward: Distance,
    ) -> Option<(f64, f64)> {
        let center = center.meters();
        let backward = backward.meters();
        let forward = forward.meters();
        if !center.is_finite() || !backward.is_finite() || !forward.is_finite() {
            return None;
        }
        if backward < 0.0 || forward < 0.0 {
            return None;
        }
        Some((
            (center - backward).clamp(0.0, self.total),
            (center + forward).clamp(0.0, self.total),
        ))
    }

    /// Projects `point` onto every segment overlapping `[lo, hi]`.
    fn projections_in_window(&self, point: Coordinate, lo: f64, hi: f64) -> Vec<Projection> {
        let mut out = Vec::new();
        for index in 0..self.cumulative.len() - 1 {
            let seg_lo = self.cumulative[index];
            let seg_hi = self.cumulative[index + 1];
            if seg_hi < lo || seg_lo > hi {
                continue;
            }
            let mut projection =
                project_to_segment(point, self.geometry[index], self.geometry[index + 1], index);
            if seg_lo > 0.0 {
                projection.distance_along =
                    Distance::from_meters(seg_lo + projection.distance_along.meters());
            }
            out.push(projection);
        }
        out
    }

    /// Projects a whole track with a continuity constraint (M15 Phase 5).
    ///
    /// This is what makes coverage monotone AND correct on difficult geometry:
    /// each point is matched inside a window anchored on the last covered
    /// position, and forward progress is additionally bounded by
    /// `max_speed × Δt`, so a runner at the *second* occurrence of a
    /// coordinate (a loop, or the return leg of an out-and-back) cannot
    /// teleport coverage across a mirror segment that shares its geometry.
    /// Coverage never decreases; when a raw match genuinely falls behind, it
    /// is clamped and flagged. A `reanchored` point means no segment matched
    /// the window (GPS dropout / jump) and the global nearest match was used.
    pub fn project_track_with_continuity(
        &self,
        track: &Track,
        config: &ContinuityConfig,
    ) -> Vec<ContinuousProjection> {
        let mut covered = 0.0f64;
        let mut last_timestamp = None;
        let mut out = Vec::with_capacity(track.len());
        for point in track.points() {
            let dt = match last_timestamp {
                Some(prev) => point.timestamp().elapsed_since(prev).as_secs().max(0.0),
                None => f64::INFINITY, // first point gets the full forward window
            };
            last_timestamp = Some(point.timestamp());
            // Coverage may advance at most `max_speed × Δt` (capped by the
            // config's forward window so a long dropout cannot teleport the
            // position); it may fall behind by at most `max_backtrack`.
            let forward = (config.max_speed.mps() * dt)
                .min(config.forward_window.meters())
                .max(0.0);
            let (lo, hi) = self
                .window_bounds(
                    Distance::from_meters(covered),
                    config.max_backtrack,
                    Distance::from_meters(forward),
                )
                .unwrap_or((covered, covered));

            let candidates = self.projections_in_window(point.coordinate(), lo, hi);
            let best = best_forward_candidate(&candidates, covered);

            let (raw, lateral, reanchored) = match best {
                Some((raw, lateral)) => (raw, lateral, false),
                None => {
                    let global = self.project(point.coordinate());
                    (
                        global.distance_along.meters(),
                        global.lateral_error.meters(),
                        true,
                    )
                }
            };
            let backtracker = raw + config.max_backtrack.meters() < covered;
            covered = covered.max(raw);
            out.push(ContinuousProjection {
                distance: Distance::from_meters(covered),
                raw: Distance::from_meters(raw),
                lateral_error: Distance::from_meters(lateral),
                backtracker,
                reanchored,
            });
        }
        out
    }
}

/// Chooses the continuity match from the candidates around `covered`.
///
/// Prefers the forward candidate nearest `covered` (a raw position at or
/// beyond the covered distance: continuing movement); only when no candidate
/// lies ahead does it fall back to the nearest candidate behind. This
/// deliberately breaks the geometric symmetry of mirrored route halves (an
/// out-and-back turnaround) in favor of forward progress.
fn best_forward_candidate(candidates: &[Projection], covered: f64) -> Option<(f64, f64)> {
    let forward = candidates
        .iter()
        .filter(|p| p.distance_along.meters() >= covered)
        .min_by(|a, b| {
            (a.distance_along.meters() - covered)
                .partial_cmp(&(b.distance_along.meters() - covered))
                .expect("distances are finite")
        });
    forward
        .or_else(|| {
            candidates.iter().min_by(|a, b| {
                (a.distance_along.meters() - covered)
                    .partial_cmp(&(b.distance_along.meters() - covered))
                    .expect("distances are finite")
            })
        })
        .map(|p| (p.distance_along.meters(), p.lateral_error.meters()))
}

/// Options for [`Route::project_track_with_continuity`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ContinuityConfig {
    /// Window searched *behind* the last covered position, in meters. A raw
    /// match falling further behind than this is counted as a `backtracker`
    /// (and its coverage is clamped).
    pub max_backtrack: Distance,
    /// Upper bound on how far a single point may advance coverage, in meters.
    /// Guards against a single jumpy fix teleporting the position forward
    /// (e.g. after a GPS dropout).
    pub forward_window: Distance,
    /// The fastest plausible forward progress of the subject, used to bound a
    /// single step's coverage advance to `max_speed × Δt` between fixes. This
    /// is the bound that keeps mirrored geometry apart: a candidate 200 m
    /// ahead can only be reached in the time a runner would actually take to
    /// get there.
    pub max_speed: Speed,
}

impl Default for ContinuityConfig {
    fn default() -> Self {
        Self {
            max_backtrack: Distance::from_meters(25.0),
            forward_window: Distance::from_meters(200.0),
            max_speed: Speed::from_mps(10.0),
        }
    }
}

/// One point of a [`Route::project_track_with_continuity`] series.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ContinuousProjection {
    /// Covered distance along the route (monotone: never decreases).
    pub distance: Distance,
    /// The raw windowed match before the monotone clamp, in meters.
    pub raw: Distance,
    /// Lateral error of the matched segment, in meters.
    pub lateral_error: Distance,
    /// `true` when `raw` fell behind the previous coverage by more than
    /// [`ContinuityConfig::max_backtrack`] and was clamped.
    pub backtracker: bool,
    /// `true` when the window contained no segment and a global re-anchor was
    /// used (dropout recovery).
    pub reanchored: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrackPoint;
    use crate::geo::{Bearing, bearing, project_to_polyline};

    /// A 3-vertex polyline: north along a meridian, then east along a parallel.
    /// The vertical leg is ~0.88 km and the horizontal leg ~0.68 km.
    fn corner_route() -> (Route, Vec<Coordinate>) {
        let a = Coordinate::new(52.50, 13.40).unwrap();
        let b = Coordinate::new(52.508, 13.40).unwrap();
        let c = Coordinate::new(52.508, 13.41).unwrap();
        let coords = vec![a, b, c];
        let route = Route::new(coords.clone()).unwrap();
        (route, coords)
    }

    #[test]
    fn construction_validates_point_count() {
        assert_eq!(Route::new(vec![]).unwrap_err(), RouteError::Empty);
        let single = Coordinate::new(52.5, 13.4).unwrap();
        assert_eq!(
            Route::new(vec![single]).unwrap_err(),
            RouteError::TooFewPoints(1)
        );
    }

    #[test]
    fn length_matches_sum_of_segments() {
        let (route, coords) = corner_route();
        let total =
            distance(coords[0], coords[1]).meters() + distance(coords[1], coords[2]).meters();
        assert!((route.length().meters() - total).abs() < 1e-9);
    }

    #[test]
    fn coordinate_at_endpoints_and_midpoints() {
        let (route, _coords) = corner_route();

        assert_eq!(route.coordinate_at(Distance::ZERO), Some(route.start()));
        assert_eq!(
            route.coordinate_at(route.length()),
            Some(route.end()),
            "at total length should land on the finish"
        );
        assert_eq!(route.coordinate_at(Distance::from_meters(-1.0)), None);
        assert_eq!(
            route.coordinate_at(Distance::from_meters(route.length().meters() + 1.0)),
            None
        );
        assert_eq!(route.coordinate_at(Distance::from_meters(f64::NAN)), None);

        // Halfway along the first (vertical) segment:
        let mid = route.coordinate_at(Distance::from_meters(
            distance(route.start(), route.geometry()[1]).meters() / 2.0,
        ));
        let vertical_mid = interpolate(route.start(), route.geometry()[1], 0.5);
        assert!((mid.unwrap().latitude() - vertical_mid.latitude()).abs() < 1e-12);
    }

    #[test]
    fn coordinate_at_trailing_zero_length_segment_is_valid() {
        let a = Coordinate::new(52.50, 13.40).unwrap();
        let b = Coordinate::new(52.505, 13.40).unwrap();
        let b2 = b; // duplicate vertex at the end
        let route = Route::new(vec![a, b, b2]).unwrap();
        assert_eq!(
            route.coordinate_at(route.length()),
            Some(b),
            "duplicate finish vertex should not panic"
        );
        let halfway = route.coordinate_at(Distance::from_meters(route.length().meters() / 2.0));
        assert!(halfway.is_some());
    }

    #[test]
    fn project_at_vertices_and_midpoint() {
        let (route, coords) = corner_route();

        let start_projection = route.project(coords[0]);
        assert!(start_projection.distance_along.meters().abs() < 1e-9);
        assert!(start_projection.lateral_error.meters().abs() < 1e-9);

        let end_projection = route.project(coords[2]);
        assert!(
            (end_projection.distance_along.meters() - route.length().meters()).abs() < 1e-9,
            "finish projects to the full route length"
        );

        // Midpoint of the first segment projects to half its length.
        let mid = interpolate(coords[0], coords[1], 0.5);
        let mid_projection = route.project(mid);
        let expected = distance(coords[0], mid).meters();
        assert!(
            (mid_projection.distance_along.meters() - expected).abs() < 1e-6,
            "segment midpoint should project to half its length"
        );
    }

    #[test]
    fn projection_accumulates_across_segments() {
        // A point near the middle of the second segment should report its
        // track along the whole route, not just the segment.
        let (route, coords) = corner_route();
        let vertical = distance(coords[0], coords[1]).meters();

        let probe = interpolate(coords[1], coords[2], 0.25); // second segment, quarter in
        let projection = route.project(probe);
        let expected = vertical + distance(coords[1], probe).meters();
        assert!((projection.distance_along.meters() - expected).abs() < 1e-6);

        // The nearest's coordinate should reproduce the probe's along-track
        // coordinate up to projection tolerance.
        let nearest = route.nearest(probe);
        assert!((nearest.distance.meters() - expected).abs() < 1e-6);
    }

    #[test]
    fn lateral_offset_projects_with_correct_error() {
        // A probe 30 m west of the vertical leg's midpoint: lateral error
        // should be ~30 m while the along-route distance stays at the
        // vertical leg's midpoint.
        let (route, _coords) = corner_route();

        let bearing_north = bearing(route.start(), route.geometry()[1]).unwrap();
        let mid = crate::geo::destination(
            route.start(),
            bearing_north,
            Distance::from_meters(route.length().meters() / 2.0),
        );
        let probe = crate::geo::destination(
            mid,
            Bearing::from_degrees(270.0).unwrap(),
            Distance::from_meters(30.0),
        );

        let projection = route.project(probe);
        let expected_along = route.length().meters() / 2.0;
        assert!(
            (projection.distance_along.meters() - expected_along).abs() < 1e-3,
            "offset point should keep its along-route distance"
        );
        assert!(
            (projection.lateral_error.meters() - 30.0).abs() < 1e-3,
            "lateral error should match the 30 m offset"
        );
    }

    #[test]
    fn project_agrees_with_raw_polyline_projection() {
        let (route, coords) = corner_route();

        // Probe off the bend (the second vertex), where either segment could
        // win; both projections must agree on the shape.
        let probe = crate::geo::destination(
            route.geometry()[1],
            Bearing::from_degrees(315.0).unwrap(),
            Distance::from_meters(25.0),
        );

        let raw = project_to_polyline(probe, &coords).unwrap();
        let wrapped = route.project(probe);
        assert_eq!(raw.segment_index, wrapped.segment_index);
        assert!(
            (raw.lateral_error.meters() - wrapped.lateral_error.meters()).abs() < 1e-9,
            "lateral error must not change when wrapping"
        );
        // Wrapped distance_along = accumulated prefix + per-segment distance.
        let prefix = if raw.segment_index == 0 {
            0.0
        } else {
            distance(coords[0], coords[1]).meters()
        };
        assert!(
            (wrapped.distance_along.meters() - (prefix + raw.distance_along.meters())).abs() < 1e-6,
            "wrapped distance must accumulate across segments"
        );
    }

    /// A contiguous out-and-back route: `A → B → A` on the same polyline.
    /// Walking out and back covers `2 × |AB|`.
    fn out_and_back_route() -> Route {
        let a = Coordinate::new(52.500, 13.400).unwrap();
        let b = Coordinate::new(52.505, 13.400).unwrap();
        Route::new(vec![a, b, a]).unwrap()
    }

    /// A clean forward run of the full out-and-back, sampled every `step_m`
    /// along the route axis (finish always included).
    fn full_track(route: &Route, step_m: f64) -> Track {
        let total = route.length().meters();
        let mut positions = Vec::new();
        let mut position = 0.0;
        while position <= total + 1e-6 {
            positions.push(position.min(total));
            position += step_m;
        }
        if *positions.last().unwrap() < total - 1e-6 {
            positions.push(total);
        }
        let points: Vec<TrackPoint> = positions
            .iter()
            .enumerate()
            .map(|(i, &position)| {
                TrackPoint::new(
                    crate::units::Timestamp::from_unix_ms(i as i64 * 5_000),
                    route
                        .coordinate_at(Distance::from_meters(position))
                        .unwrap(),
                )
            })
            .collect();
        Track::new(points).unwrap()
    }

    #[test]
    fn continuity_projection_reaches_back_turnaround() {
        // The global nearest projection of the return leg snaps back to the
        // start half, so naive max-coverage stagnates at the turn-around.
        // Windowed (continuity) projection must keep advancing to the finish.
        let route = out_and_back_route();
        let total = route.length().meters();
        let track = full_track(&route, 25.0);

        let global_max = track
            .points()
            .iter()
            .map(|p| route.project(p.coordinate()).distance_along.meters())
            .fold(0.0, f64::max);
        assert!(
            global_max <= total / 2.0 + 30.0,
            "naive coverage stagnates near the turn, got {global_max:.1} of {total:.1}"
        );

        let series = route.project_track_with_continuity(&track, &ContinuityConfig::default());
        let last = series.last().unwrap();
        assert!(
            (last.distance.meters() - total).abs() < 1e-3,
            "continuity coverage should reach the finish, got {:.1}",
            last.distance.meters()
        );
        // Coverage is monotone and continuity was never broken on a clean run.
        for pair in series.windows(2) {
            assert!(pair[1].distance.meters() >= pair[0].distance.meters() - 1e-9);
        }
        assert_eq!(series.iter().filter(|p| p.backtracker).count(), 0);
        assert_eq!(series.iter().filter(|p| p.reanchored).count(), 0);
    }

    #[test]
    fn continuity_projection_survives_a_backtracking_loop() {
        // A runner that briefly walks 100 m backward mid-run: backtrackers are
        // reported and clamped, but coverage keeps advancing when movement
        // resumes, rather than snapping to the pre-loop position.
        let route = out_and_back_route();
        let c = ContinuityConfig {
            max_backtrack: Distance::from_meters(25.0),
            ..ContinuityConfig::default()
        };

        // Out to 300 m, then a 100 m walk-back (300 → 275 → 250 → 225 → 200),
        // then forward to the finish.
        let total = route.length().meters();
        let mut positions: Vec<f64> = Vec::new();
        let mut p = 0.0;
        while p <= 275.0 {
            positions.push(p);
            p += 25.0;
        }
        positions.extend([300.0, 275.0, 250.0, 225.0, 200.0]);
        p = 325.0;
        while p <= total {
            positions.push(p.min(total));
            p += 25.0;
        }
        if *positions.last().unwrap() < total - 1e-6 {
            positions.push(total);
        }

        let points: Vec<TrackPoint> = positions
            .iter()
            .enumerate()
            .map(|(i, &position)| {
                TrackPoint::new(
                    crate::units::Timestamp::from_unix_ms(i as i64 * 5_000),
                    route
                        .coordinate_at(Distance::from_meters(position))
                        .unwrap(),
                )
            })
            .collect();
        let track = Track::new(points).unwrap();

        let series = route.project_track_with_continuity(&track, &c);
        let last = series.last().unwrap();
        assert!(
            last.distance.meters() > 0.9 * total,
            "coverage must recover past the backtrack, got {:.1}",
            last.distance.meters()
        );
        assert!(
            series.iter().filter(|p| p.backtracker).count() >= 3,
            "the 100 m backward walk should be flagged (3+ backtrackers)"
        );
        // Coverage still never decreases, even through the walk-back.
        for pair in series.windows(2) {
            assert!(pair[1].distance.meters() >= pair[0].distance.meters() - 1e-9);
        }
    }
}
