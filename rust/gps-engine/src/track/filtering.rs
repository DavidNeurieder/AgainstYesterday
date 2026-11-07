// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPS point filtering.
//!
//! Filtering removes obvious junk (bad sensor readings, spikes, impossible
//! jumps) without erasing legitimate movement. The first and last points of a
//! track are always preserved, so a filtered track is never shortened to
//! nothing.

use crate::geo::{distance, polyline_length};
use crate::gps::GpsFix;
use crate::units::{Distance, Duration, Speed};

use super::model::Track;
use super::point::TrackPoint;

/// Configuration controlling which points are removed.
#[derive(Debug, Clone, PartialEq)]
pub struct FilterConfig {
    /// Points whose reported horizontal accuracy is worse than this are
    /// removed. `None` disables the check.
    pub max_accuracy: Option<Distance>,
    /// Points whose reported speed exceeds this are removed, and points whose
    /// adjacent segments imply a faster-than-threshold speed are removed as
    /// spikes. `None` disables the check.
    pub max_speed: Option<Speed>,
    /// Points adjacent to a segment longer than this are removed.
    /// `None` disables the check.
    pub max_jump: Option<Distance>,
    /// Gaps longer than this are treated as pauses: the resampler and speed
    /// checks never bridge them. `None` means every gap is bridgeable.
    pub max_time_gap: Option<Duration>,
}

impl Default for FilterConfig {
    fn default() -> Self {
        FilterConfig {
            max_accuracy: Some(Distance::from_meters(50.0)),
            // 500 km/h: far above any car or train (high-speed rail included),
            // still below GPS artifacts.
            max_speed: Some(Speed::from_kmh(500.0)),
            max_jump: Some(Distance::from_meters(200.0)),
            max_time_gap: Some(Duration::from_secs(60.0)),
        }
    }
}

impl FilterConfig {
    /// The tighter denoising profile the matching recipe uses
    /// ([`crate::standard_pipeline`] and the CLI's `compare`/`discover`/
    /// `evaluate` commands).
    ///
    /// Matching a run or a ride wants aggressive spike removal — a single GPS
    /// spike swings the geometry and drops the overlap ratio — so it filters at
    /// a run/ride ceiling far below [`FilterConfig::default`], which also has to
    /// admit cars and trains. Keeping the two apart lets recordings of every
    /// vehicle survive the filter while the matcher stays tuned for the
    /// run/ride corpus it is measured on.
    pub fn matching() -> Self {
        FilterConfig {
            max_speed: Some(Speed::from_kmh(90.0)),
            ..FilterConfig::default()
        }
    }
}

/// What a filtering pass did to a track.
#[derive(Debug, Clone, PartialEq)]
pub struct ProcessingReport {
    /// Points fed into the filter.
    pub input_points: usize,
    /// Points that survived.
    pub output_points: usize,
    /// Points removed (`input - output`).
    pub removed_points: usize,
    /// Total geodesic length before filtering.
    pub distance_before: Distance,
    /// Total geodesic length after filtering.
    pub distance_after: Distance,
}

/// Why an individual point was dropped by the filter.
///
/// M15: filtering must be *auditable* — every removed raw sample keeps a
/// reason, so a developer staring at ugly device data can see exactly what the
/// engine decided and why (never throw the raw observation away silently).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterReason {
    /// Reported horizontal accuracy exceeded [`FilterConfig::max_accuracy`].
    TooInaccurate,
    /// Reported speed exceeded [`FilterConfig::max_speed`].
    ImpossibleSpeed,
    /// Adjacent segments imply a faster-than-threshold movement (a spike).
    Jump,
}

impl std::fmt::Display for FilterReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FilterReason::TooInaccurate => write!(f, "accuracy exceeded limit"),
            FilterReason::ImpossibleSpeed => write!(f, "speed exceeded limit"),
            FilterReason::Jump => write!(f, "impossible jump between neighbours"),
        }
    }
}

/// Applies `config` to `track`, returning the filtered track and a report of
/// what was removed and how much distance changed.
pub fn filter(track: &Track, config: &FilterConfig) -> (Track, ProcessingReport) {
    let (track, report, _reasons) = filter_detailed(track, config);
    (track, report)
}

/// Applies `config` and, additionally, records a per-input-point decision.
///
/// `reasons[i]` is `Some(why)` when input point `i` was removed and `None` when
/// it survived. The vector is always the same length as `track.points()`.
pub fn filter_detailed(
    track: &Track,
    config: &FilterConfig,
) -> (Track, ProcessingReport, Vec<Option<FilterReason>>) {
    let points = track.points();
    let input_count = points.len();
    let distance_before = polyline_length(&track.coordinates());

    let mut reasons: Vec<Option<FilterReason>> = vec![None; input_count];

    // Pass 1: drop points that fail the sensor-quality checks.
    let mut kept: Vec<usize> = Vec::with_capacity(input_count);
    for (i, point) in points.iter().enumerate() {
        if i == 0 || i == input_count - 1 {
            kept.push(i);
            continue;
        }
        if !passes_sensor_checks(point, config) {
            reasons[i] = Some(sensor_rejection_reason(point, config));
            continue;
        }
        kept.push(i);
    }

    // Pass 2: drop interior points that are impossible spikes. A point is a
    // spike only when BOTH the segment leading into it (from the last
    // surviving point) and the segment leading out of it (toward the next
    // candidate) are jumps. Anchoring on the last surviving point prevents a
    // single bad point from dragging its innocent neighbours down with it.
    let mut result: Vec<TrackPoint> = Vec::with_capacity(kept.len());
    let mut prev = kept[0];
    result.push(points[prev]);
    for k in 1..kept.len() - 1 {
        let i = kept[k];
        let next = kept[k + 1];
        let incoming_jump = is_jump(&points[prev], &points[i], config);
        let outgoing_jump = is_jump(&points[i], &points[next], config);
        if incoming_jump && outgoing_jump {
            reasons[i] = Some(FilterReason::Jump);
            continue;
        }
        result.push(points[i]);
        prev = i;
    }
    let last = kept[kept.len() - 1];
    if last != prev {
        result.push(points[last]);
    }

    let distance_after =
        polyline_length(&result.iter().map(|p| p.coordinate()).collect::<Vec<_>>());
    let output_count = result.len();

    (
        Track::from_unchecked(result),
        ProcessingReport {
            input_points: input_count,
            output_points: output_count,
            removed_points: input_count - output_count,
            distance_before,
            distance_after,
        },
        reasons,
    )
}

/// The sensor-quality rule that failed for `point`, mirroring
/// [`passes_sensor_checks`]'s checking order.
fn sensor_rejection_reason(point: &TrackPoint, config: &FilterConfig) -> FilterReason {
    if let Some(max) = config.max_accuracy
        && let Some(accuracy) = point.accuracy()
        && accuracy > max.meters()
    {
        return FilterReason::TooInaccurate;
    }
    FilterReason::ImpossibleSpeed
}

/// Internal sensor-quality rules: reported accuracy and reported speed.
pub(crate) fn passes_sensor_checks(point: &TrackPoint, config: &FilterConfig) -> bool {
    passes_sensor_values(point.accuracy(), point.speed(), config)
}

/// Sensor-quality rules for a raw fix (the live path's input shape).
pub(crate) fn fix_passes_sensor_checks(fix: &GpsFix, config: &FilterConfig) -> bool {
    passes_sensor_values(
        fix.accuracy.map(|accuracy| accuracy.meters()),
        fix.speed.map(|speed| speed.mps()),
        config,
    )
}

/// The shared accuracy/speed test behind both point and fix checks.
fn passes_sensor_values(accuracy: Option<f64>, speed: Option<f64>, config: &FilterConfig) -> bool {
    if let Some(max) = config.max_accuracy
        && let Some(accuracy) = accuracy
        && accuracy > max.meters()
    {
        return false;
    }
    if let Some(max) = config.max_speed
        && let Some(speed) = speed
        && speed > max.mps()
    {
        return false;
    }
    true
}

/// Whether the segment `a → b` looks like an impossible movement.
///
/// A segment is a jump if it is longer than `max_jump`, or if — provided it is
/// shorter than `max_time_gap` (so it is a real, connected movement) — its
/// implied speed exceeds `max_speed`.
pub(crate) fn is_jump(a: &TrackPoint, b: &TrackPoint, config: &FilterConfig) -> bool {
    is_jump_between(
        a.timestamp(),
        a.coordinate(),
        b.timestamp(),
        b.coordinate(),
        config,
    )
}

/// The same jump rule applied to two raw fixes.
pub(crate) fn fix_is_jump(a: &GpsFix, b: &GpsFix, config: &FilterConfig) -> bool {
    is_jump_between(a.timestamp, a.coordinate, b.timestamp, b.coordinate, config)
}

/// The shared jump test behind [`is_jump`] and [`fix_is_jump`].
fn is_jump_between(
    a_timestamp: crate::units::Timestamp,
    a_coordinate: crate::geo::Coordinate,
    b_timestamp: crate::units::Timestamp,
    b_coordinate: crate::geo::Coordinate,
    config: &FilterConfig,
) -> bool {
    let gap = distance(a_coordinate, b_coordinate);

    if let Some(max) = config.max_jump
        && gap.meters() > max.meters()
    {
        return true;
    }

    let dt = b_timestamp.elapsed_since(a_timestamp).as_secs();
    if dt <= 0.0 {
        return false;
    }

    if let Some(max_gap) = config.max_time_gap
        && dt > max_gap.as_secs()
    {
        // A pause: do not interpret the spatial separation as movement.
        return false;
    }

    if let Some(max) = config.max_speed {
        let speed = gap.meters() / dt;
        return speed > max.mps();
    }

    false
}

/// The ceilings an incremental [`FilterCursor`] applies.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorConfig {
    /// The batch filter's rules, reused point by point.
    pub filter: FilterConfig,
    /// Ground slower than this earns neither distance nor moving time. The app
    /// adds this floor on top of the engine filter so a stationary phone's
    /// sub-metre correction jitter never accrues.
    pub motion_floor: Speed,
}

impl Default for CursorConfig {
    fn default() -> Self {
        CursorConfig {
            filter: FilterConfig::default(),
            motion_floor: Speed::from_mps(0.5),
        }
    }
}

/// Incremental `distance_after`: feed raw fixes in timestamp order.
///
/// At any moment [`FilterCursor::distance`] tracks the engine's
/// `distance_after` for the fixes seen *so far*. Because the batch filter keeps
/// the last point unconditionally, the undecided final segment is counted too —
/// unless its step is an implausible jump ([`fix_is_jump`]), in which case it is
/// withheld until the next fix corroborates it as a real teleport or refutes it
/// as a spike (which is then retracted).
#[derive(Debug, Clone)]
pub struct FilterCursor {
    config: CursorConfig,

    /// The last surviving point (the batch filter's pass-2 anchor).
    anchor: Option<GpsFix>,

    /// The latest sensor-clean fix whose outgoing segment is not yet known.
    pending: Option<GpsFix>,
    pending_is_jump: bool,

    committed_meters: f64,
    committed_seconds: f64,
    pending_meters: f64,
    pending_seconds: f64,

    last_speed: Speed,
}

impl FilterCursor {
    /// Creates an empty cursor.
    pub fn new(config: CursorConfig) -> Self {
        FilterCursor {
            config,
            anchor: None,
            pending: None,
            pending_is_jump: false,
            committed_meters: 0.0,
            committed_seconds: 0.0,
            pending_meters: 0.0,
            pending_seconds: 0.0,
            last_speed: Speed::ZERO,
        }
    }

    /// The ceilings this cursor applies.
    pub fn config(&self) -> &CursorConfig {
        &self.config
    }

    /// Whether a fix's own sensor fields pass the engine's first pass.
    pub fn accepts(&self, fix: &GpsFix) -> bool {
        fix_passes_sensor_checks(fix, &self.config.filter)
    }

    /// Geodesic length of the surviving fixes so far.
    pub fn distance(&self) -> Distance {
        Distance::from_meters(self.committed_meters + self.pending_meters)
    }

    /// Moving seconds spanned by those surviving segments.
    pub fn moving(&self) -> Duration {
        Duration::from_secs(self.committed_seconds + self.pending_seconds)
    }

    /// Whether the latest step is an implausible jump still withheld from the
    /// axis.
    pub fn is_holding_jump(&self) -> bool {
        self.pending.is_some() && self.pending_is_jump
    }

    /// Speed of the most recent segment that earned distance and time, or
    /// [`Speed::ZERO`] when the last decision earned neither.
    pub fn last_segment_speed(&self) -> Speed {
        self.last_speed
    }

    /// Feeds one raw fix. A fix the sensor itself rejects is ignored entirely:
    /// it neither bridges nor breaks the chain (engine pass 1).
    pub fn add(&mut self, fix: GpsFix) {
        if !self.accepts(&fix) {
            return;
        }
        let Some(anchor) = self.anchor else {
            self.anchor = Some(fix); // the first surviving point is always kept
            return;
        };

        if let Some(pending) = self.pending
            && !(self.pending_is_jump && fix_is_jump(&pending, &fix, &self.config.filter))
        {
            // The pending point has at least one plausible neighbour: keep it.
            self.commit(anchor, pending);
            self.anchor = Some(pending);
        }
        // Otherwise it is an isolated spike: dropped, the anchor stays put so
        // the next genuine fix is measured locally instead of from the bad one.
        let anchor = self.anchor.expect("a first fix is always anchored");
        self.pending = Some(fix);
        self.pending_is_jump = fix_is_jump(&anchor, &fix, &self.config.filter);
        self.recompute_pending();
    }

    /// Closes the chain at FINISH. The engine always keeps the final point, so
    /// a withheld closing chord (its step looked like a jump) is counted here
    /// rather than lost. Calling this does not double-count a segment that was
    /// already counted.
    pub fn flush(&mut self) {
        if let (Some(anchor), Some(pending)) = (self.anchor, self.pending) {
            self.commit(anchor, pending);
        }
        self.pending = None;
        self.pending_is_jump = false;
        self.recompute_pending();
    }

    /// Clears the chain but keeps everything it has already banked.
    ///
    /// A deliberate pause is not a bridgeable segment, so the next fix becomes
    /// a fresh anchor; the live run's accumulated distance and moving time
    /// remain exactly where they were.
    pub fn reset_chain(&mut self) {
        self.committed_meters += self.pending_meters;
        self.committed_seconds += self.pending_seconds;
        self.clear_chain();
    }

    /// Clears the chain *and* the banked totals (the batch-filter reset).
    pub fn reset(&mut self) {
        self.committed_meters = 0.0;
        self.committed_seconds = 0.0;
        self.clear_chain();
    }

    /// Restores totals recovered from a snapshot, dropping any partial chain.
    pub fn seed(&mut self, distance: Distance, moving: Duration) {
        self.committed_meters = distance.meters().max(0.0);
        self.committed_seconds = moving.as_secs().max(0.0);
        self.clear_chain();
    }

    /// The chain forgets its anchors and undecided segment.
    fn clear_chain(&mut self) {
        self.anchor = None;
        self.pending = None;
        self.pending_is_jump = false;
        self.pending_meters = 0.0;
        self.pending_seconds = 0.0;
        self.last_speed = Speed::ZERO;
    }

    /// Bank one surviving step.
    fn commit(&mut self, a: GpsFix, b: GpsFix) {
        let (meters, seconds) = self.segment(a, b);
        self.committed_meters += meters;
        self.committed_seconds += seconds;
        self.last_speed = earned_speed(meters, seconds);
    }

    /// Recompute the undecided tail after the anchor or pending changed.
    fn recompute_pending(&mut self) {
        let Some(pending) = self.pending else {
            self.pending_meters = 0.0;
            self.pending_seconds = 0.0;
            return;
        };
        if self.pending_is_jump {
            // An implausible jump is withheld until the next fix corroborates
            // it; the last earned speed stays as it was.
            self.pending_meters = 0.0;
            self.pending_seconds = 0.0;
            return;
        }
        let anchor = self.anchor.expect("a pending fix always has an anchor");
        let (meters, seconds) = self.segment(anchor, pending);
        self.pending_meters = meters;
        self.pending_seconds = seconds;
        self.last_speed = earned_speed(meters, seconds);
    }

    /// The ground and time a surviving step earns, or nothing when it is slower
    /// than the motion floor or its timestamps do not move forward.
    fn segment(&self, a: GpsFix, b: GpsFix) -> (f64, f64) {
        let seconds = b.timestamp.elapsed_since(a.timestamp).as_secs();
        if seconds <= 0.0 {
            return (0.0, 0.0);
        }
        let meters = distance(a.coordinate, b.coordinate).meters();
        if meters / seconds < self.config.motion_floor.mps() {
            return (0.0, 0.0);
        }
        (meters, seconds)
    }
}

/// Speed of an earned segment, or zero when it earned nothing.
fn earned_speed(meters: f64, seconds: f64) -> Speed {
    if seconds > 0.0 {
        Speed::from_mps(meters / seconds)
    } else {
        Speed::ZERO
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::Coordinate;
    use crate::units::Timestamp;

    /// Metres per degree of latitude used by the fixtures (1° ≈ 111.195 km).
    const METERS_PER_DEGREE: f64 = 111_195.0;

    fn fix(lat: f64, lon: f64, second: i64) -> GpsFix {
        GpsFix::new(
            Timestamp::from_unix_secs(second as f64),
            Coordinate::new(lat, lon).unwrap(),
        )
    }

    fn cursor() -> FilterCursor {
        FilterCursor::new(CursorConfig::default())
    }

    #[test]
    fn teleport_between_clusters_is_bridged_not_stalled() {
        // Short clusters of jitter joined by big jumps the receiver only
        // reported on arrival. Every point survives, so the filtered length is
        // the full polyline's net meridional span.
        let base = 52.500_00;
        let fixes = [
            fix(base, 13.400_00, 1),
            fix(base + 0.000_02, 13.400_00, 2),
            fix(base + 0.002_00, 13.400_00, 3),
            fix(base + 0.002_02, 13.400_00, 4),
            fix(base + 0.010_00, 13.400_00, 9),
            fix(base + 0.010_02, 13.400_00, 10),
        ];
        let mut filter = cursor();
        for sample in fixes {
            filter.add(sample);
        }
        let expected = 0.010_02 * METERS_PER_DEGREE;
        assert!((filter.distance().meters() - expected).abs() < 1.0);
    }

    #[test]
    fn isolated_spike_is_dropped_and_anchor_holds() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11)); // real stride
        filter.add(fix(52.501_00, 13.410_00, 21)); // ~680 m spike
        filter.add(fix(52.502_00, 13.400_00, 31)); // back on the line

        let expected = 2.0 * 0.001 * METERS_PER_DEGREE;
        assert!((filter.distance().meters() - expected).abs() < 1.0);
    }

    #[test]
    fn sensor_rejected_fix_neither_bridges_nor_breaks_the_chain() {
        for bad in [
            GpsFix {
                accuracy: Some(Distance::from_meters(80.0)),
                ..fix(52.500_10, 13.400_00, 2)
            },
            GpsFix {
                speed: Some(Speed::from_mps(200.0)),
                ..fix(52.500_10, 13.400_00, 2)
            },
        ] {
            let mut filter = cursor();
            filter.add(fix(52.500_00, 13.400_00, 1));
            filter.add(bad);
            filter.add(fix(52.500_02, 13.400_00, 3));
            let expected = 0.000_02 * METERS_PER_DEGREE;
            assert!((filter.distance().meters() - expected).abs() < 1.0);
        }
    }

    #[test]
    fn sub_floor_jitter_earns_no_distance() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_000, 1));
        filter.add(fix(52.500_00, 13.400_003, 2));
        filter.add(fix(52.500_00, 13.400_006, 3));
        assert_eq!(filter.distance().meters(), 0.0);
        assert_eq!(filter.moving().as_secs(), 0.0);
    }

    #[test]
    fn implausible_jump_is_withheld_until_the_next_fix_refutes_it() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11));
        let step = 0.001 * METERS_PER_DEGREE;
        filter.add(fix(52.501_00, 13.410_00, 21));
        assert!((filter.distance().meters() - step).abs() < 1.0);
        assert!(filter.is_holding_jump());

        filter.add(fix(52.502_00, 13.400_00, 31));
        assert!((filter.distance().meters() - 2.0 * step).abs() < 1.0);
    }

    #[test]
    fn a_step_past_the_jump_ceiling_is_withheld_however_slow() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.502_00, 13.400_00, 31));
        assert_eq!(filter.distance().meters(), 0.0);
        assert!(filter.is_holding_jump());

        filter.add(fix(52.502_10, 13.400_00, 32));
        let expected = 0.002_1 * METERS_PER_DEGREE;
        assert!((filter.distance().meters() - expected).abs() < 1.0);
    }

    #[test]
    fn flush_keeps_the_final_point_even_when_its_step_looked_like_a_jump() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.502_00, 13.400_00, 3));
        assert_eq!(filter.distance().meters(), 0.0);

        filter.flush();
        let expected = 0.002 * METERS_PER_DEGREE;
        assert!((filter.distance().meters() - expected).abs() < 1.0);
    }

    #[test]
    fn a_car_or_train_step_is_kept_not_read_as_a_spike() {
        let mut filter = cursor();
        let step_meters = 80.0;
        let step_degrees = step_meters / METERS_PER_DEGREE;
        for i in 0..10 {
            filter.add(fix(52.5 + i as f64 * step_degrees, 13.400_00, i + 1));
        }
        assert!((filter.distance().meters() - 9.0 * step_meters).abs() < 1.0);
    }

    #[test]
    fn a_repeated_coordinate_at_a_new_timestamp_earns_nothing() {
        let mut filter = cursor();
        for second in 1..=10 {
            filter.add(fix(52.500_00, 13.400_00, second));
        }
        assert_eq!(filter.distance().meters(), 0.0);
        assert_eq!(filter.moving().as_secs(), 0.0);
    }

    #[test]
    fn a_repeated_timestamp_is_not_an_instantaneous_hop() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.500_02, 13.400_00, 2));
        let after_real_step = filter.distance().meters();
        assert!(after_real_step > 0.0);

        filter.add(fix(52.500_02, 13.400_00, 2));
        assert_eq!(filter.distance().meters(), after_real_step);
        assert!((filter.moving().as_secs() - 1.0).abs() < 1e-9);
    }

    #[test]
    fn an_out_of_order_timestamp_adds_no_distance() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11));
        let forward_only = filter.distance().meters();
        assert!((forward_only - 0.001 * METERS_PER_DEGREE).abs() < 1.0);

        filter.add(fix(52.502_00, 13.400_00, 5));
        assert_eq!(
            filter.distance().meters(),
            forward_only,
            "a negative time delta must earn no distance"
        );
        assert!(
            (filter.moving().as_secs() - 10.0).abs() < 1e-9,
            "a negative time delta must add no moving time"
        );
    }

    #[test]
    fn a_duplicate_fix_inside_a_pause_is_reset_away_not_bridged() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11));
        assert!((filter.distance().meters() - 0.001 * METERS_PER_DEGREE).abs() < 1.0);

        filter.reset();
        assert_eq!(filter.distance().meters(), 0.0);
        assert_eq!(filter.moving().as_secs(), 0.0);

        filter.add(fix(52.501_00, 13.400_00, 61));
        assert_eq!(filter.distance().meters(), 0.0);
    }

    #[test]
    fn reset_chain_banks_totals_but_starts_a_fresh_anchor() {
        let mut filter = cursor();
        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11));
        let banked = filter.distance().meters();
        assert!(banked > 0.0);

        filter.reset_chain();
        assert!((filter.distance().meters() - banked).abs() < 1e-9);
        assert!((filter.moving().as_secs() - 10.0).abs() < 1e-9);

        // The first fix after a pause is only a new anchor.
        filter.add(fix(52.501_00, 13.400_00, 61));
        assert!((filter.distance().meters() - banked).abs() < 1e-9);
    }

    #[test]
    fn seed_restores_snapshot_totals() {
        let mut filter = cursor();
        filter.seed(Distance::from_meters(4_500.0), Duration::from_secs(1_200.0));
        assert_eq!(filter.distance().meters(), 4_500.0);
        assert_eq!(filter.moving().as_secs(), 1_200.0);

        filter.add(fix(52.500_00, 13.400_00, 1));
        filter.add(fix(52.501_00, 13.400_00, 11));
        assert!(filter.distance().meters() > 4_500.0);
    }
}
