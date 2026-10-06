// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Raw GPS ingestion and per-sample quality (M15).
//!
//! The rest of the crate starts from a validated [`Track`] of purely
//! chronological, monotone points. Real devices do not behave that way: fixes
//! arrive out of order, get duplicated, carry implausible sensors, and
//! disappear for minutes at a time. This module owns the boundary where raw
//! observations become an auditable, processed [`Track`]:
//!
//! ```text
//! GpsTrace (raw fixes)
//!     ├── normalize()   → stable sort by timestamp, drop exact duplicates
//!     ├── to_track()    → validated Track (never panics on junk)
//!     └── process()     → detailed filter + per-sample quality & decisions
//! ```
//!
//! The core M15 rule: **never throw information away merely because it is
//! suspicious.** Every raw fix is kept in [`TrackProcessing::samples`] with its
//! quality grade and, when rejected, the exact [`RejectionReason`] — so a
//! developer with a phone can explain precisely what the engine did to every
//! ugly point instead of guessing.
//!
//! The [`Fixture`] type serializes a route + trace to JSON and back, the
//! on-disk format used by the checked-in GPS torture fixtures and by the
//! developer trace exporter.

use std::collections::{HashMap, HashSet};
use std::fmt;

use crate::error::{GpsError, TrackError};
use crate::geo::{Bearing, Coordinate};
use crate::route::Route;
use crate::track::{
    FilterConfig, FilterReason, ProcessingReport, Track, TrackPoint, filter_detailed,
};
use crate::units::{Distance, Duration, Speed, Timestamp};

/// A single raw fix exactly as a receiver reported it, before any judgement.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GpsFix {
    /// Observation time.
    pub timestamp: Timestamp,
    /// Reported position.
    pub coordinate: Coordinate,
    /// Reported horizontal accuracy, when known.
    pub accuracy: Option<Distance>,
    /// Reported altitude in meters, when known.
    pub altitude: Option<f64>,
    /// Reported ground speed in meters per second, when known.
    pub speed: Option<Speed>,
    /// Reported travel bearing, when known.
    pub bearing: Option<Bearing>,
}

impl GpsFix {
    /// Creates a fix with no optional sensor fields.
    pub fn new(timestamp: Timestamp, coordinate: Coordinate) -> Self {
        GpsFix {
            timestamp,
            coordinate,
            accuracy: None,
            altitude: None,
            speed: None,
            bearing: None,
        }
    }

    /// Converts this fix into a validated [`TrackPoint`].
    ///
    /// Non-finite optional fields surface as [`TrackError`] rather than
    /// panicking.
    pub fn track_point(&self) -> Result<TrackPoint, TrackError> {
        let mut point = TrackPoint::new(self.timestamp, self.coordinate);
        if let Some(altitude) = self.altitude {
            point = point.with_altitude(altitude)?;
        }
        if let Some(speed) = self.speed {
            point = point.with_speed(speed.mps())?;
        }
        if let Some(accuracy) = self.accuracy {
            point = point.with_accuracy(accuracy.meters())?;
        }
        if let Some(bearing) = self.bearing {
            point = point.with_bearing(bearing);
        }
        Ok(point)
    }

    /// The composite quality grade of this fix under `config`.
    ///
    /// Grading intentionally mirrors what the filter will do: a fix that
    /// cannot be trusted (no accuracy, or an implausible reported speed) is
    /// graded [`GpsQuality::Poor`] or below even before a filter rejects it.
    pub fn quality(&self, config: &FilterConfig) -> GpsQuality {
        let grade = match self.accuracy {
            None => GpsQuality::Lost,
            Some(a) if a.meters() < GOOD_ACCURACY_M => GpsQuality::Good,
            Some(a)
                if config
                    .max_accuracy
                    .is_none_or(|max| a.meters() <= max.meters()) =>
            {
                GpsQuality::Degraded
            }
            Some(_) => GpsQuality::Poor,
        };
        // A reported speed above the plausibility ceiling degrades any grade.
        let speed_plausible = config
            .max_speed
            .is_none_or(|max| self.speed.is_none_or(|s| s.mps() <= max.mps()));
        if !speed_plausible && grade != GpsQuality::Lost {
            GpsQuality::Poor
        } else {
            grade
        }
    }
}

/// Horizontal accuracy (m) below which a fix is graded "good".
pub const GOOD_ACCURACY_M: f64 = 12.0;

/// Qualitative signal quality of a fix (M15 Phase 3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpsQuality {
    /// Accurate, timely fix (typically ≤ 12 m reported accuracy).
    Good,
    /// Usable but degraded (accuracy between the good threshold and the
    /// filter's rejection ceiling).
    Degraded,
    /// Marginal: above the filter's accuracy ceiling, or an implausible
    /// reported speed — likely rejected or closed too fast to trust.
    Poor,
    /// No usable fix / no accuracy reported; the sample cannot be trusted.
    Lost,
}

impl GpsQuality {
    /// Whether a fix with this grade should feed the cleaned track.
    pub fn is_usable(&self) -> bool {
        !matches!(self, GpsQuality::Lost)
    }
}

impl fmt::Display for GpsQuality {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            GpsQuality::Good => write!(f, "good"),
            GpsQuality::Degraded => write!(f, "degraded"),
            GpsQuality::Poor => write!(f, "poor"),
            GpsQuality::Lost => write!(f, "lost"),
        }
    }
}

/// Why a raw fix was excluded from the processed track (M15 Phase 3).
///
/// The reason is recorded on the retained [`ProcessedSample`] so the decision
/// is never lost; it is *not* erased from memory. Out-of-order arrivals are
/// not a rejection category here because normalization recovers them: sorting
/// re-places late fixes into chronological order, so they are accepted rather
/// than discarded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectionReason {
    /// Another fix with the same timestamp and coordinate already occurred.
    Duplicate,
    /// The deterministic filter removed it ([`FilterReason`] for diagnostics).
    Filter(FilterReason),
}

impl fmt::Display for RejectionReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RejectionReason::Duplicate => write!(f, "duplicate fix"),
            RejectionReason::Filter(reason) => write!(f, "filter: {reason}"),
        }
    }
}

/// A processed sample: the raw fix, its quality grade, and the decision.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProcessedSample {
    /// The unaltered raw fix — never discarded.
    pub sample: GpsFix,
    /// Composite quality grade under the active [`FilterConfig`].
    pub quality: GpsQuality,
    /// Whether the fix survived into the cleaned track.
    pub accepted: bool,
    /// Why it was rejected, when it was.
    pub reason: Option<RejectionReason>,
}

/// The auditable output of [`GpsTrace::process`].
#[derive(Debug, Clone, PartialEq)]
pub struct TrackProcessing {
    /// The cleaned, chronological track (≥ 2 points, monotone timestamps).
    pub track: Track,
    /// Aggregate filtering statistics.
    pub report: ProcessingReport,
    /// One entry per *raw* fix, in original observation order.
    pub samples: Vec<ProcessedSample>,
}

impl TrackProcessing {
    /// Fixes that survived into the cleaned track.
    pub fn accepted(&self) -> usize {
        self.samples.iter().filter(|s| s.accepted).count()
    }

    /// Fixes that were excluded, with the reasons for each.
    pub fn rejected(&self) -> usize {
        self.samples.len() - self.accepted()
    }
}

/// A batch of raw GPS fixes, in any order, with possible duplicates.
///
/// The raw batch can hold junk; every consumer begins with
/// [`GpsTrace::normalized`] and the processing pipeline never panics.
#[derive(Debug, Clone, PartialEq)]
pub struct GpsTrace {
    fixes: Vec<GpsFix>,
}

impl GpsTrace {
    /// Builds a trace from at least two raw fixes.
    pub fn new(fixes: Vec<GpsFix>) -> Result<Self, GpsError> {
        if fixes.len() < 2 {
            return Err(GpsError::TooFewFixes(fixes.len()));
        }
        Ok(GpsTrace { fixes })
    }

    /// The raw fixes in the order they were received.
    pub fn fixes(&self) -> &[GpsFix] {
        &self.fixes
    }

    /// Number of raw fixes.
    pub fn len(&self) -> usize {
        self.fixes.len()
    }

    /// Whether the trace has no fixes.
    pub fn is_empty(&self) -> bool {
        self.fixes.is_empty()
    }

    /// Fixes sorted by timestamp (stable: equal timestamps keep stream order).
    pub fn sorted(&self) -> GpsTrace {
        let mut fixes = self.fixes.clone();
        fixes.sort_by_key(|fix| fix.timestamp);
        GpsTrace { fixes }
    }

    /// Drops exact `(timestamp, coordinate)` duplicates, keeping the first
    /// occurrence.
    pub fn deduplicated(&self) -> GpsTrace {
        let mut seen = HashSet::new();
        let fixes = self
            .fixes
            .iter()
            .filter(|fix| seen.insert((fix.timestamp, fix.coordinate)))
            .copied()
            .collect();
        GpsTrace { fixes }
    }

    /// Normalized = sorted, then deduplicated.
    pub fn normalized(&self) -> GpsTrace {
        self.sorted().deduplicated()
    }

    /// The raw geodesic length of the normalized fixes (sum of haversine
    /// segments). Always ≥ 0.
    pub fn distance(&self) -> Distance {
        crate::geo::polyline_length(
            &self
                .normalized()
                .fixes
                .iter()
                .map(|f| f.coordinate)
                .collect::<Vec<_>>(),
        )
    }

    /// Wall-clock span from the first to the last timestamp (≥ 0).
    pub fn duration(&self) -> Duration {
        let normalized = self.normalized();
        match (normalized.fixes.first(), normalized.fixes.last()) {
            (Some(first), Some(last)) => last.timestamp.elapsed_since(first.timestamp),
            _ => Duration::ZERO,
        }
    }

    /// Builds a validated [`Track`] from the normalized fixes.
    ///
    /// Returns [`GpsError::TooFewFixes`] if fewer than two usable fixes
    /// remain; a malformed field surfaces as [`GpsError::Track`] instead of
    /// panicking.
    pub fn to_track(&self) -> Result<Track, GpsError> {
        let normalized = self.normalized();
        if normalized.fixes.len() < 2 {
            return Err(GpsError::TooFewFixes(normalized.fixes.len()));
        }
        let points = normalized
            .fixes
            .iter()
            .map(|fix| fix.track_point())
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Track::new(points)?)
    }

    /// Runs the full M15 pipeline: normalize → track → detailed filter.
    ///
    /// The returned [`TrackProcessing`] records a decision for every raw fix,
    /// so nothing is silently erased.
    pub fn process(&self, config: &FilterConfig) -> Result<TrackProcessing, GpsError> {
        // Every normalized (sorted + deduplicated) fix maps back to its index.
        // A raw fix that is absent here was an exact duplicate: rejected.
        let normalized = self.normalized();
        let kept: HashMap<(Timestamp, Coordinate), usize> = normalized
            .fixes
            .iter()
            .enumerate()
            .map(|(index, fix)| ((fix.timestamp, fix.coordinate), index))
            .collect();

        let track = self.to_track().map_err(|err| match err {
            GpsError::Track(TrackError::TooFewPoints(_)) => GpsError::NoUsableTrack,
            other => other,
        })?;
        let (cleaned, mut report, filter_reasons) = filter_detailed(&track, config);
        // The filter reported on the *normalized* input; restate it in terms of
        // the raw stream so the log and the report always agree.
        report.input_points = self.fixes.len();
        report.removed_points = self.fixes.len() - report.output_points;

        // Map each normalized fix to its per-point filter decision.
        let decision: HashMap<(Timestamp, Coordinate), Option<FilterReason>> = track
            .points()
            .iter()
            .zip(filter_reasons.iter())
            .map(|(point, reason)| ((point.timestamp(), point.coordinate()), *reason))
            .collect();
        let cleaned_keys: HashSet<(Timestamp, Coordinate)> = cleaned
            .points()
            .iter()
            .map(|p| (p.timestamp(), p.coordinate()))
            .collect();

        let mut samples = Vec::with_capacity(self.fixes.len());
        for fix in &self.fixes {
            let key = (fix.timestamp, fix.coordinate);
            let (accepted, reason) = if !kept.contains_key(&key) {
                (false, Some(RejectionReason::Duplicate))
            } else if cleaned_keys.contains(&key) {
                (true, None)
            } else {
                (false, decision[&key].map(RejectionReason::Filter))
            };
            samples.push(ProcessedSample {
                sample: *fix,
                quality: fix.quality(config),
                accepted,
                reason,
            });
        }

        Ok(TrackProcessing {
            track: cleaned,
            report,
            samples,
        })
    }

    /// Serializes the trace to the JSON fixture schema
    /// (`{"schema_version": 1, "fixes": [...]}`).
    pub fn to_json(&self) -> String {
        format!(
            "{{\"schema_version\":{FIXTURE_SCHEMA_VERSION},\"fixes\":{}}}",
            serialize_fixes(&self.fixes)
        )
    }

    /// Parses a JSON fixture (`{"fixes": [...]}`, or a [`Fixture`] object).
    ///
    /// Malformed documents yield [`GpsError::Fixture`]; they never panic.
    pub fn from_json(bytes: &str) -> Result<GpsTrace, GpsError> {
        let root = parse_json(bytes)?;
        Fixture::trace_from_root(&root)
    }
}

/// A checked-in fixture: the canonical route the trace follows (for the
/// position invariants) plus the raw fixes.
///
/// The documented JSON schema is versioned by `schema_version` (see
/// [`FIXTURE_SCHEMA_VERSION`]). Parsing accepts legacy documents without the
/// field and rejects versions newer than this build understands.
#[derive(Debug, Clone, PartialEq)]
pub struct Fixture {
    /// The route the trace was recorded against, when embedded.
    pub route: Option<Route>,
    /// The raw fixes.
    pub trace: GpsTrace,
}

/// Fixture JSON schema version understood by this build.
///
/// * v0 (implicit): `{"route":[...], "fixes":[...]}`, absent `schema_version`.
/// * v1: adds `schema_version`, and optional sensor fields may be explicit
///   `null` (treated the same as missing).
pub const FIXTURE_SCHEMA_VERSION: i64 = 1;

impl Fixture {
    /// Parses a fixture document (`{"route":[...], "fixes":[...]}`).
    pub fn from_json(bytes: &str) -> Result<Fixture, GpsError> {
        let root = parse_json(bytes)?;
        Fixture::from_root(&root)
    }

    /// Serializes the fixture to JSON.
    pub fn to_json(&self) -> String {
        let mut out = String::from("{");
        out.push_str(&format!("\"schema_version\":{FIXTURE_SCHEMA_VERSION},"));
        if let Some(route) = &self.route {
            out.push_str("\"route\":[");
            for (i, coord) in route.geometry().iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&format!(
                    "{{\"lat\":{},\"lon\":{}}}",
                    coord.latitude(),
                    coord.longitude()
                ));
            }
            out.push_str("],");
        }
        out.push_str("\"fixes\":");
        out.push_str(&serialize_fixes(self.trace.fixes()));
        out.push('}');
        out
    }

    /// Extracts just the fix list from a fixture root object.
    fn trace_from_root(root: &JsonValue) -> Result<GpsTrace, GpsError> {
        check_schema_version(root)?;
        let fixes = fixes_from_object(root)?;
        GpsTrace::new(fixes)
    }

    /// Extracts a full fixture (route + fixes) from a root object.
    fn from_root(root: &JsonValue) -> Result<Fixture, GpsError> {
        check_schema_version(root)?;
        let route = match root.object_get("route") {
            None => None,
            Some(JsonValue::Array(points)) => {
                let mut geometry = Vec::with_capacity(points.len());
                for point in points {
                    let lon = point.field_number("lon")?;
                    let lat = point.field_number("lat")?;
                    geometry
                        .push(Coordinate::new(lat, lon).map_err(|e| fixture_err(e.to_string()))?);
                }
                Some(Route::new(geometry).map_err(|e| fixture_err(e.to_string()))?)
            }
            Some(_) => return Err(fixture_err("\"route\" must be an array")),
        };
        let fixes = fixes_from_object(root)?;
        Ok(Fixture {
            route,
            trace: GpsTrace::new(fixes)?,
        })
    }
}

/// Shorthand constructing a [`GpsError::Fixture`] from anything displayable.
fn fixture_err(message: impl Into<String>) -> GpsError {
    GpsError::Fixture(message.into())
}

/// Validates the fixture's `schema_version`.
///
/// A missing field is treated as the implicit legacy version (v0); the current
/// version is accepted; anything newer is rejected with actionable advice
/// rather than misparsed.
fn check_schema_version(root: &JsonValue) -> Result<(), GpsError> {
    match root.object_get("schema_version") {
        None => Ok(()),
        Some(JsonValue::Number(n)) => {
            let version = *n;
            if !version.is_finite() || version.fract() != 0.0 {
                return Err(fixture_err("\"schema_version\" must be an integer"));
            }
            if (version as i64) > FIXTURE_SCHEMA_VERSION {
                return Err(fixture_err(format!(
                    "unsupported fixture schema_version {version} \
                     (supported: {FIXTURE_SCHEMA_VERSION}); regenerate the fixture"
                )));
            }
            Ok(())
        }
        Some(_) => Err(fixture_err("\"schema_version\" must be an integer")),
    }
}

fn fixes_from_object(root: &JsonValue) -> Result<Vec<GpsFix>, GpsError> {
    let Some(JsonValue::Array(fixes)) = root.object_get("fixes") else {
        return Err(fixture_err("missing \"fixes\" array"));
    };
    fixes.iter().map(fix_from_value).collect()
}

/// Parses a single fix object; a `{lat,lon}` object with no timestamp is not
/// a fix and yields an error.
fn fix_from_value(value: &JsonValue) -> Result<GpsFix, GpsError> {
    let timestamp_ms = value.field_i64("timestamp_ms")?;
    let lon = value.field_number("longitude")?;
    let lat = value.field_number("latitude")?;
    let coordinate = Coordinate::new(lat, lon).map_err(|e| fixture_err(e.to_string()))?;
    let accuracy = match value.object_get("accuracy_m") {
        Some(JsonValue::Number(n)) => Some(Distance::from_meters(*n)),
        Some(JsonValue::Null) | None => None,
        Some(_) => return Err(fixture_err("\"accuracy_m\" must be a number")),
    };
    let altitude = value.optional_number("altitude_m")?;
    let speed = value.optional_number("speed_mps")?.map(Speed::from_mps);
    let bearing = match value.optional_number("bearing_deg")? {
        Some(degrees) => {
            Some(Bearing::from_degrees(degrees).map_err(|e| fixture_err(e.to_string()))?)
        }
        None => None,
    };
    Ok(GpsFix {
        timestamp: Timestamp::from_unix_ms(timestamp_ms),
        coordinate,
        accuracy,
        altitude,
        speed,
        bearing,
    })
}

fn serialize_fixes(fixes: &[GpsFix]) -> String {
    let mut out = String::from("[");
    for (i, fix) in fixes.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('{');
        out.push_str(&format!("\"timestamp_ms\":{}", fix.timestamp.unix_ms()));
        out.push_str(&format!(",\"latitude\":{},", fix.coordinate.latitude()));
        out.push_str(&format!("\"longitude\":{}", fix.coordinate.longitude()));
        if let Some(accuracy) = fix.accuracy {
            out.push_str(&format!(",\"accuracy_m\":{}", accuracy.meters()));
        }
        if let Some(altitude) = fix.altitude {
            out.push_str(&format!(",\"altitude_m\":{altitude}"));
        }
        if let Some(speed) = fix.speed {
            out.push_str(&format!(",\"speed_mps\":{}", speed.mps()));
        }
        if let Some(bearing) = fix.bearing {
            out.push_str(&format!(",\"bearing_deg\":{}", bearing.as_degrees()));
        }
        out.push('}');
    }
    out.push(']');
    out
}

// -------------------------------------------------------------------------
// Minimal, dependency-free, panic-free JSON.
// -------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum JsonValue {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    fn object_get(&self, key: &str) -> Option<&JsonValue> {
        match self {
            JsonValue::Object(fields) => fields
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    fn field_number(&self, key: &str) -> Result<f64, GpsError> {
        self.object_get(key).map_or_else(
            || Err(fixture_err(format!("missing \"{key}\""))),
            |value| match value {
                JsonValue::Number(n) => Ok(*n),
                _ => Err(fixture_err(format!("\"{key}\" must be a number"))),
            },
        )
    }

    fn field_i64(&self, key: &str) -> Result<i64, GpsError> {
        let n = self.field_number(key)?;
        if !n.is_finite() || n.fract() != 0.0 || n < i64::MIN as f64 || n > i64::MAX as f64 {
            return Err(fixture_err(format!("\"{key}\" must be an integer")));
        }
        Ok(n as i64)
    }

    /// Reads an optional numeric field. A missing field and an explicit JSON
    /// `null` are equivalent ("the sensor did not report"), which keeps the
    /// parser compatible with the Dart exporter's self-describing fixtures.
    fn optional_number(&self, key: &str) -> Result<Option<f64>, GpsError> {
        match self.object_get(key) {
            None | Some(JsonValue::Null) => Ok(None),
            Some(JsonValue::Number(n)) => Ok(Some(*n)),
            Some(_) => Err(fixture_err(format!("\"{key}\" must be a number"))),
        }
    }
}

/// Parses a JSON document. Numbers are finite-only (NaN/∞ are rejected, as in
/// real JSON). Errors are [`GpsError::Fixture`] with a human-readable reason.
fn parse_json(bytes: &str) -> Result<JsonValue, GpsError> {
    let mut cursor = Cursor {
        bytes: bytes.as_bytes(),
        pos: 0,
    };
    cursor.skip_whitespace();
    let value = cursor.value()?;
    cursor.skip_whitespace();
    if cursor.pos != cursor.bytes.len() {
        return Err(fixture_err("trailing content after JSON document"));
    }
    Ok(value)
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn skip_whitespace(&mut self) {
        while let Some(b) = self.bytes.get(self.pos)
            && matches!(b, b' ' | b'\t' | b'\n' | b'\r')
        {
            self.pos += 1;
        }
    }

    fn value(&mut self) -> Result<JsonValue, GpsError> {
        self.skip_whitespace();
        let Some(&b) = self.bytes.get(self.pos) else {
            return Err(fixture_err("empty document"));
        };
        match b {
            b'{' => self.object(),
            b'[' => self.array(),
            b'"' => Ok(JsonValue::Str(self.string()?)),
            b't' | b'f' => self.boolean(),
            b'n' => self.null(),
            b'-' | b'0'..=b'9' => self.number(),
            _ => Err(fixture_err("unexpected character")),
        }
    }

    fn object(&mut self) -> Result<JsonValue, GpsError> {
        self.pos += 1; // '{'
        let mut fields = Vec::new();
        self.skip_whitespace();
        if self.bytes.get(self.pos) == Some(&b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(fields));
        }
        loop {
            self.skip_whitespace();
            let key = self.string()?;
            self.skip_whitespace();
            if self.bytes.get(self.pos) != Some(&b':') {
                return Err(fixture_err("expected ':' in object"));
            }
            self.pos += 1;
            let value = self.value()?;
            fields.push((key, value));
            self.skip_whitespace();
            match self.bytes.get(self.pos) {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(JsonValue::Object(fields));
                }
                _ => return Err(fixture_err("expected ',' or '}' in object")),
            }
        }
    }

    fn array(&mut self) -> Result<JsonValue, GpsError> {
        self.pos += 1; // '['
        let mut items = Vec::new();
        self.skip_whitespace();
        if self.bytes.get(self.pos) == Some(&b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_whitespace();
            match self.bytes.get(self.pos) {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    return Ok(JsonValue::Array(items));
                }
                _ => return Err(fixture_err("expected ',' or ']' in array")),
            }
        }
    }

    fn string(&mut self) -> Result<String, GpsError> {
        if self.bytes.get(self.pos) != Some(&b'"') {
            return Err(fixture_err("expected string"));
        }
        self.pos += 1;
        let mut out = String::new();
        loop {
            let Some(&b) = self.bytes.get(self.pos) else {
                return Err(fixture_err("unterminated string"));
            };
            match b {
                b'"' => {
                    self.pos += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.pos += 1;
                    let Some(&escaped) = self.bytes.get(self.pos) else {
                        return Err(fixture_err("unterminated escape"));
                    };
                    let ch = match escaped {
                        b'"' => '"',
                        b'\\' => '\\',
                        b'/' => '/',
                        b'b' => '\u{0008}',
                        b'f' => '\u{000C}',
                        b'n' => '\n',
                        b'r' => '\r',
                        b't' => '\t',
                        b'u' => {
                            // \uXXXX (no surrogate pairing; sufficient for keys).
                            let hex = &self.bytes[self.pos + 1..self.pos + 5];
                            if hex.len() != 4 {
                                return Err(fixture_err("bad \\u escape"));
                            }
                            let code = std::str::from_utf8(hex)
                                .ok()
                                .and_then(|s| u32::from_str_radix(s, 16).ok())
                                .ok_or(fixture_err("bad \\u escape"))?;
                            self.pos += 4;
                            let ch =
                                char::from_u32(code).ok_or(fixture_err("bad \\u code point"))?;
                            out.push(ch);
                            self.pos += 1;
                            continue;
                        }
                        _ => return Err(fixture_err("unknown escape")),
                    };
                    out.push(ch);
                    self.pos += 1;
                }
                _ => {
                    let bytes = &self.bytes[self.pos..];
                    let idx = bytes
                        .iter()
                        .position(|&c| c == b'"' || c == b'\\')
                        .unwrap_or(bytes.len());
                    out.push_str(
                        std::str::from_utf8(&bytes[..idx])
                            .map_err(|_| fixture_err("invalid UTF-8 in string"))?,
                    );
                    self.pos += idx;
                }
            }
        }
    }

    fn boolean(&mut self) -> Result<JsonValue, GpsError> {
        if self.bytes[self.pos..].starts_with(b"true") {
            self.pos += 4;
            Ok(JsonValue::Bool(true))
        } else if self.bytes[self.pos..].starts_with(b"false") {
            self.pos += 5;
            Ok(JsonValue::Bool(false))
        } else {
            Err(fixture_err("bad boolean literal"))
        }
    }

    fn null(&mut self) -> Result<JsonValue, GpsError> {
        if self.bytes[self.pos..].starts_with(b"null") {
            self.pos += 4;
            Ok(JsonValue::Null)
        } else {
            Err(fixture_err("bad null literal"))
        }
    }

    fn number(&mut self) -> Result<JsonValue, GpsError> {
        let start = self.pos;
        if self.bytes.get(self.pos) == Some(&b'-') {
            self.pos += 1;
        }
        while self
            .bytes
            .get(self.pos)
            .is_some_and(|b| matches!(b, b'0'..=b'9' | b'.' | b'e' | b'E' | b'+' | b'-'))
        {
            self.pos += 1;
        }
        let text = std::str::from_utf8(&self.bytes[start..self.pos])
            .map_err(|_| fixture_err("invalid number"))?;
        let parsed: f64 = text.parse().map_err(|_| fixture_err("invalid number"))?;
        if !parsed.is_finite() {
            return Err(fixture_err("non-finite number"));
        }
        Ok(JsonValue::Number(parsed))
    }
}
