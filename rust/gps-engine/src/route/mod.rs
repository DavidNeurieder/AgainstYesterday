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
pub use matching::{
    MatchConfig, MatchScore, PreparedTrack, compare, compare_either_direction,
    compare_either_direction_prepared, compare_prepared, compare_with,
};

use crate::Track;
use crate::error::RouteError;
use crate::geo::{
    self, Bearing, Coordinate, Projection, distance, interpolate, project_to_polyline,
    project_to_segment,
};
use crate::units::{Distance, Speed, Timestamp};

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
    pub(crate) fn window_bounds(
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
    pub(crate) fn projections_in_window(
        &self,
        point: Coordinate,
        lo: f64,
        hi: f64,
    ) -> Vec<Projection> {
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
/// Among forward candidates (at or beyond `covered`) prefers the one with the
/// smallest lateral error, breaking ties by the smallest forward advance so
/// progress stays continuous. This keeps a fix that has rounded a vertex on
/// the new segment (lateral ~0) instead of sticking to the previous segment's
/// endpoint (small advance, larger lateral). Mirrored geometry (an
/// out-and-back return) is already separated by the forward filter: the
/// outbound mirror sits behind `covered` and is never a forward candidate.
///
/// Only when no candidate lies ahead does it fall back to the nearest
/// candidate behind `covered`.
pub(crate) fn best_forward_candidate(
    candidates: &[Projection],
    covered: f64,
) -> Option<(f64, f64)> {
    let forward = candidates
        .iter()
        .filter(|p| p.distance_along.meters() >= covered)
        .min_by(|a, b| {
            a.lateral_error
                .meters()
                .partial_cmp(&b.lateral_error.meters())
                .expect("distances are finite")
                .then_with(|| {
                    (a.distance_along.meters() - covered)
                        .partial_cmp(&(b.distance_along.meters() - covered))
                        .expect("distances are finite")
                })
        });
    forward
        .or_else(|| {
            candidates.iter().min_by(|a, b| {
                (covered - a.distance_along.meters())
                    .abs()
                    .partial_cmp(&(covered - b.distance_along.meters()).abs())
                    .expect("distances are finite")
                    .then_with(|| {
                        a.lateral_error
                            .meters()
                            .partial_cmp(&b.lateral_error.meters())
                            .expect("distances are finite")
                    })
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

/// One GPS observation fed to [`RouteMatcher`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RouteObservation {
    /// Reported position.
    pub coordinate: Coordinate,
    /// Observation time.
    pub timestamp: Timestamp,
    /// Reported horizontal accuracy (1σ-ish), when known.
    pub accuracy: Option<Distance>,
    /// Reported or derived ground speed, when known.
    pub speed: Option<Speed>,
    /// Reported or derived travel bearing (clockwise from true north), when known.
    pub bearing: Option<Bearing>,
}

const MIN_HEADING_SPEED_MPS: f64 = 0.6;
const SIGMA_H_RAD: f64 = 35.0_f64 * std::f64::consts::PI / 180.0;
const SIGMA_P_BASE_M: f64 = 40.0;
const SIGMA_V_MPS: f64 = 3.0;
const SIGMA_D_DEFAULT_M: f64 = 15.0;
const SIGMA_D_MIN_M: f64 = 5.0;
const SIGMA_D_MAX_M: f64 = 50.0;

fn wrap_angle_rad(a: f64) -> f64 {
    let mut x = (a + std::f64::consts::PI).rem_euclid(std::f64::consts::TAU) - std::f64::consts::PI;
    // rem_euclid can yield -PI in edge cases; normalize to (-PI, PI].
    if x <= -std::f64::consts::PI {
        x += std::f64::consts::TAU;
    }
    x
}

fn segment_bearing(route: &Route, segment_index: usize) -> Option<Bearing> {
    let geom = route.geometry();
    if segment_index + 1 >= geom.len() {
        return None;
    }
    geo::bearing(geom[segment_index], geom[segment_index + 1]).ok()
}

/// Confidence in a match decision, `0.0` (untrusted) .. `1.0` (certain).
/// Kept separate from per-candidate cost and from the receiver's reported
/// GPS accuracy.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatchConfidence(pub f64);

impl MatchConfidence {
    /// No usable confidence.
    pub const NONE: Self = Self(0.0);
    /// Fully trusted.
    pub const FULL: Self = Self(1.0);

    /// The raw `0.0..=1.0` value.
    pub fn value(self) -> f64 {
        self.0
    }
}

/// The outcome of one [`RouteMatcher`] update, extending a
/// [`ContinuousProjection`] with scoring confidence.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MatchStep {
    /// The accepted projection (monotone coverage, lateral, flags).
    pub projection: ContinuousProjection,
    /// Confidence in the selected candidate, separate from cost and GPS accuracy.
    pub confidence: MatchConfidence,
}

/// Stateful, incremental continuity-aware route progress matcher.
///
/// This is the single-fix analogue of [`Route::project_track_with_continuity`]:
/// each observation is matched inside a window anchored on the last covered
/// position, forward progress is bounded by `max_speed × Δt`, and coverage
/// never decreases. Using the continuity window (rather than a global nearest
/// projection) keeps progress on the correct branch of self-intersecting or
/// overlapping geometry (figure-eights, repeated loops, out-and-backs).
#[derive(Debug, Clone)]
pub struct RouteMatcher {
    config: ContinuityConfig,
    covered: f64,
    last_timestamp: Option<Timestamp>,
    last_bearing: Option<Bearing>,
}

impl RouteMatcher {
    /// Creates a matcher that starts at the beginning of the route.
    pub fn new(config: ContinuityConfig) -> Self {
        Self {
            config,
            covered: 0.0,
            last_timestamp: None,
            last_bearing: None,
        }
    }

    /// Covered distance along the route so far (monotone).
    pub fn covered(&self) -> Distance {
        Distance::from_meters(self.covered)
    }

    /// Resets progress to the start of the route.
    pub fn reset(&mut self) {
        self.covered = 0.0;
        self.last_timestamp = None;
        self.last_bearing = None;
    }

    /// Seeds the matcher with already-covered progress (e.g. a resumed run).
    /// The next observation re-anchors the time window like a fresh start.
    pub fn seed(&mut self, covered: Distance) {
        self.covered = covered.meters().clamp(0.0, f64::INFINITY);
        self.last_timestamp = None;
        self.last_bearing = None;
    }

    /// Snaps monotone coverage to `covered` without resetting the time anchor.
    /// Used for route-end completion when geometry is ambiguous at the seam.
    pub fn snap_to(&mut self, covered: Distance) {
        self.covered = self.covered.max(covered.meters());
    }

    /// Matches one observation (coordinate + time only) and advances monotone
    /// coverage. Equivalent to [`Self::update_observation`] with no sensor
    /// quality or heading.
    pub fn update(
        &mut self,
        route: &Route,
        coordinate: Coordinate,
        timestamp: Timestamp,
    ) -> ContinuousProjection {
        self.update_observation(
            route,
            &RouteObservation {
                coordinate,
                timestamp,
                accuracy: None,
                speed: None,
                bearing: None,
            },
        )
        .projection
    }

    /// Matches a full observation with multi-signal scoring (distance,
    /// heading, progress, speed) and returns the projection plus confidence.
    pub fn update_observation(&mut self, route: &Route, obs: &RouteObservation) -> MatchStep {
        let dt = match self.last_timestamp {
            Some(prev) => obs.timestamp.elapsed_since(prev).as_secs().max(0.0),
            None => f64::INFINITY,
        };
        self.last_timestamp = Some(obs.timestamp);

        let (forward, backward) = self.adaptive_window(dt, obs.accuracy);
        let (lo, hi) = route
            .window_bounds(
                Distance::from_meters(self.covered),
                Distance::from_meters(backward),
                Distance::from_meters(forward),
            )
            .unwrap_or((self.covered, self.covered));

        let candidates = route.projections_in_window(obs.coordinate, lo, hi);
        let (best, confidence) = self.score_candidates(route, obs, dt, &candidates);

        let (raw, lateral, reanchored) = match best {
            Some((raw, lateral)) => (raw, lateral, false),
            None => {
                let global = route.project(obs.coordinate);
                (
                    global.distance_along.meters(),
                    global.lateral_error.meters(),
                    true,
                )
            }
        };
        let backtracker = raw + self.config.max_backtrack.meters() < self.covered;
        self.covered = self.covered.max(raw);

        // Track a stable bearing when moving, preferring the fix's report.
        if let Some(b) = obs.bearing {
            if obs.speed.map(|s| s.mps()).unwrap_or(0.0) >= MIN_HEADING_SPEED_MPS {
                self.last_bearing = Some(b);
            }
        }

        MatchStep {
            projection: ContinuousProjection {
                distance: Distance::from_meters(self.covered),
                raw: Distance::from_meters(raw),
                lateral_error: Distance::from_meters(lateral),
                backtracker,
                reanchored,
            },
            confidence,
        }
    }

    fn adaptive_window(&self, dt: f64, accuracy: Option<Distance>) -> (f64, f64) {
        let accuracy_m = accuracy
            .map(|a| a.meters())
            .filter(|m| m.is_finite() && *m > 0.0)
            .unwrap_or(0.0);
        // Keep the disambiguating window tight; only add a modest margin for
        // uncertainty, never exceeding the configured caps by much.
        let margin = (accuracy_m * 0.5).clamp(0.0, 20.0);

        let forward = if dt.is_finite() {
            (self.config.max_speed.mps() * dt + margin)
                .min(self.config.forward_window.meters() + margin)
                .max(0.0)
        } else {
            self.config.forward_window.meters() + margin
        };
        let backward = self.config.max_backtrack.meters() + margin;
        (forward, backward)
    }

    fn score_candidates(
        &self,
        route: &Route,
        obs: &RouteObservation,
        dt: f64,
        candidates: &[Projection],
    ) -> (Option<(f64, f64)>, MatchConfidence) {
        if candidates.is_empty() {
            return (None, MatchConfidence::NONE);
        }

        let sigma_d = obs
            .accuracy
            .map(|a| a.meters())
            .filter(|m| m.is_finite() && *m > 0.0)
            .unwrap_or(SIGMA_D_DEFAULT_M)
            .clamp(SIGMA_D_MIN_M, SIGMA_D_MAX_M);

        let moving = obs
            .speed
            .map(|s| s.mps() >= MIN_HEADING_SPEED_MPS)
            .unwrap_or(false);
        let runner_bearing = if moving { obs.bearing } else { None };

        let expected_progress = if dt.is_finite() && dt > 0.0 {
            let v = obs
                .speed
                .map(|s| s.mps())
                .filter(|v| v.is_finite() && *v >= 0.0)
                .unwrap_or((self.config.max_speed.mps() * 0.5).min(3.0));
            Some(self.covered + v * dt)
        } else {
            None
        };

        let mut scored: Vec<(usize, f64, f64, f64)> = Vec::with_capacity(candidates.len()); // (idx, cost, raw, lateral)
        for (idx, c) in candidates.iter().enumerate() {
            let raw = c.distance_along.meters();
            let lateral = c.lateral_error.meters();
            let mut cost = 0.0;
            let mut terms = 0.0;

            // Distance likelihood.
            cost += (lateral * lateral) / (2.0 * sigma_d * sigma_d);
            terms += 1.0;

            // Heading likelihood (only when moving and bearings known).
            if let (Some(rb), Some(sb)) = (runner_bearing, segment_bearing(route, c.segment_index))
            {
                let diff = wrap_angle_rad(rb.as_radians() - sb.as_radians());
                // Routes can be traversed in the drawn direction; 180° means
                // opposite - penalize but don't forbid (handled softly). Use
                // the smaller of forward/reverse alignment for progress sense?
                // No: a fixed route has a defined direction; opposite travel is
                // unusual. Penalize the angular difference directly.
                cost += (diff * diff) / (2.0 * SIGMA_H_RAD * SIGMA_H_RAD);
                terms += 1.0;
            }

            // Progress likelihood (soft).
            if let Some(expected) = expected_progress {
                let ep = (raw - expected).abs();
                let sigma_p = SIGMA_P_BASE_M + sigma_d; // softer when uncertain
                cost += (ep * ep) / (2.0 * sigma_p * sigma_p);
                terms += 0.7; // soft weight
            }

            // Speed consistency.
            if dt.is_finite() && dt > 0.0 {
                let implied = (raw - self.covered) / dt;
                // Penalize implausibly fast forward jumps and large backward jumps.
                let max_v = self.config.max_speed.mps();
                let ev = if implied > max_v * 1.2 {
                    implied - max_v
                } else if implied < -max_v * 0.5 {
                    (-implied) - max_v * 0.25
                } else {
                    0.0
                };
                if ev > 0.0 {
                    cost += (ev * ev) / (2.0 * SIGMA_V_MPS * SIGMA_V_MPS);
                    terms += 0.5;
                }
            }

            // Continuity tie-breaker: when costs are nearly equal, prefer the
            // forward candidate with lowest lateral error (the same robust
            // choice as Stage 1). Encode as a tiny cost term.
            let forward_bias = if raw >= self.covered {
                lateral * 1e-4
            } else {
                (self.covered - raw) * 1e-4 + lateral * 1e-4 + 1e-3
            };
            cost += forward_bias;
            let _ = terms;

            scored.push((idx, cost, raw, lateral));
        }

        scored.sort_by(|a, b| a.1.partial_cmp(&b.1).expect("finite costs"));
        let best = &scored[0];
        let second = scored.get(1);

        // Confidence: combine fit quality, ambiguity margin, and accuracy.
        let fit = (-best.1.min(50.0) / 4.0).exp(); // cost 0 -> 1, cost 8 -> ~0.14
        let margin = second
            .map(|s| ((s.1 - best.1).max(0.0) / 2.0).min(1.0))
            .unwrap_or(1.0);
        let acc_conf = (1.0 - (sigma_d - SIGMA_D_MIN_M) / (SIGMA_D_MAX_M - SIGMA_D_MIN_M) * 0.5)
            .clamp(0.4, 1.0);
        let confidence = (fit * (0.4 + 0.6 * margin) * acc_conf).clamp(0.0, 1.0);

        (Some((best.2, best.3)), MatchConfidence(confidence))
    }
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
