// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! CDylib C API used by the app's FFI bridge (M9 — "swap the implementation
//! underneath the same UI").
//!
//! A tiny, dependency-free binary transport. Every entry point takes a byte
//! buffer (`input`/`input_len`) owned by the caller and returns a heap
//! buffer via `*output`/`*output_len` that the caller releases with
//! [`gps_free`]. Multi-byte values are little-endian; strings are
//! `u32`-length-prefixed UTF-8.
//!
//! Status codes:
//! - `0` — success;
//! - `1` — malformed input (truncated or invalid protocol data);
//! - `2` — engine error; a message is available via [`gps_last_error`].
//!
//! Every handler validates pointers and bounds before touching memory and
//! catches panics at the boundary so an engine bug can never unwind foreign
//! code.

use std::cell::RefCell;
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char, c_int};
use std::mem::size_of;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

use crate::attempt::{Attempt, AttemptAxis, AttemptSample, MovingAxisConfig};
use crate::filtering::EstimatorConfig;
#[cfg(test)]
use crate::filtering::estimate_fixes;
use crate::geo::{Coordinate, polyline_length};
use crate::ghost::Ghost;
use crate::gps::{GpsFix, GpsTrace};
use crate::live::{LiveConfig, LiveGhost, LiveRecorder};
use crate::replay::{ReplaySession, ReplayState};
use crate::route::{MatchConfig, Route, compare, compare_either_direction};
use crate::synthetic::Rng;
use crate::track::segments::compare_route_segments;
use crate::track::{FilterConfig, MovingConfig, Track, TrackPoint};
use crate::units::{Distance, Duration, Speed, Timestamp};

/// Success.
const ST_OK: c_int = 0;
/// Malformed input buffer.
const ST_INVALID: c_int = 1;
/// Engine error (see [`gps_last_error`]).
const ST_ERROR: c_int = 2;

/// Largest request the boundary will copy into the engine. Real recordings are
/// far smaller; this bounds hostile or corrupt callers before allocation.
const MAX_INPUT_BYTES: usize = 64 * 1024 * 1024;
/// Largest length-prefixed string accepted from a request.
const MAX_STRING_BYTES: usize = 1024 * 1024;
/// Collection limits. These are checked before any allocation or element loop,
/// not used merely as an initial-capacity hint.
const MAX_POINTS: usize = 1_000_000;
const MAX_FIXES: usize = 1_000_000;
const MAX_COORDINATES: usize = 1_000_000;
const MAX_ATTEMPTS: usize = 100_000;
const MAX_SAMPLES_PER_ATTEMPT: usize = 100_000;

thread_local! {
    static LAST_ERROR: RefCell<Arc<CStr>> =
        RefCell::new(Arc::from(c"ok"));
}

fn set_error(msg: &str) {
    LAST_ERROR.with(|cell| {
        // Error text comes from the engine and must never make the FFI panic,
        // even if a detail string contains an interior NUL.
        let mut text: Vec<u8> = msg
            .bytes()
            .map(|byte| if byte == 0 { b'?' } else { byte })
            .collect();
        text.push(0);
        if let Ok(c) = CStr::from_bytes_with_nul(&text) {
            *cell.borrow_mut() = Arc::from(c);
        }
    });
}

/// Human-readable text of the most recent error, NUL-terminated and valid for
/// the lifetime of the thread until the next failing call.
#[unsafe(no_mangle)]
pub extern "C" fn gps_last_error() -> *const c_char {
    LAST_ERROR.with(|err| err.borrow().as_ptr() as *const c_char)
}

/// A fixed, process-lifetime C string holding the engine version
/// (`"<major>.<minor>.<patch>"`).
#[unsafe(no_mangle)]
pub extern "C" fn gps_capi_version() -> *const c_char {
    fn version() -> &'static CStr {
        static VERSION: std::sync::OnceLock<CString> = std::sync::OnceLock::new();
        let c = VERSION.get_or_init(|| CString::new(env!("CARGO_PKG_VERSION")).unwrap());

        // SAFETY: `c` is owned by the process-lifetime `OnceLock`, so the
        // returned pointer outlives every `gps_capi_version` call.
        unsafe { CStr::from_ptr(c.as_ptr()) }
    }
    version().as_ptr()
}

/// Frees a buffer previously returned by a `gps_*` call.
///
/// # Safety
/// `ptr` must be the payload pointer of a successful earlier call (or null).
/// [`alloc_out`] stores the length in one aligned `usize` word immediately
/// before the payload, and this function reconstructs the same `Vec<usize>`
/// allocation that produced it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }

    // SAFETY: the payload starts exactly one `usize` after the base of the
    // `Vec<usize>` allocated by `alloc_out`, so casting back and stepping one
    // word lands on a correctly aligned, initialized header.
    let header = unsafe { (ptr as *mut usize).sub(1) };
    // SAFETY: `header` is the first word of a live allocation whose header was
    // written by `alloc_out`; only the owner of `ptr` calls this function.
    let len = unsafe { header.read() };
    let word_bytes = size_of::<usize>();
    let payload_words = len / word_bytes + usize::from(len % word_bytes != 0);
    let Some(total_words) = 1usize.checked_add(payload_words) else {
        return;
    };

    // SAFETY: `header` is the base pointer of the `Vec<usize>` created in
    // `alloc_out`; `total_words` is the same length/capacity used there, every
    // word was initialized, and this call consumes the allocation exactly once.
    let words = unsafe { Vec::from_raw_parts(header, total_words, total_words) };
    drop(words);
}

// ---------------------------------------------------------------------------
// Wire plumbing
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Wr {
    data: Vec<u8>,
}

impl Wr {
    fn u8(&mut self, v: u8) {
        self.data.push(v);
    }
    fn u32(&mut self, v: u32) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn u64(&mut self, v: u64) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn f64(&mut self, v: f64) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
    fn i64(&mut self, v: i64) {
        self.data.extend_from_slice(&v.to_le_bytes());
    }
}

struct Rd<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Rd<'a> {
    fn new(data: &'a [u8]) -> Self {
        Rd { data, pos: 0 }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self
            .pos
            .checked_add(n)
            .ok_or_else(|| "integer overflow while reading".to_string())?;
        let bytes = self
            .data
            .get(self.pos..end)
            .ok_or_else(|| format!("truncated buffer at byte {0}", self.pos))?;
        self.pos = end;
        Ok(bytes)
    }

    fn remaining(&self) -> usize {
        self.data.len() - self.pos
    }

    /// Reads a `u32` element count and validates it before any allocation.
    ///
    /// `min_bytes` is the smallest encoding of one element, so this also
    /// rejects a huge count before the element loop can run. The arithmetic is
    /// checked even though `count <= max` keeps it in range in practice.
    fn read_count(&mut self, max: usize, min_bytes: usize, label: &str) -> Result<usize, String> {
        let count = self.u32()? as usize;
        if count > max {
            return Err(format!("{label} count {count} exceeds limit {max}"));
        }
        let needed = count
            .checked_mul(min_bytes)
            .ok_or_else(|| format!("integer overflow sizing {label}"))?;
        if needed > self.remaining() {
            return Err(format!(
                "truncated buffer: {label} needs at least {needed} bytes, {} remain",
                self.remaining()
            ));
        }
        Ok(count)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn i64(&mut self) -> Result<i64, String> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn f64(&mut self) -> Result<f64, String> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }
    fn str(&mut self) -> Result<String, String> {
        let n = self.u32()? as usize;
        if n > MAX_STRING_BYTES {
            return Err(format!(
                "string length {n} exceeds limit {MAX_STRING_BYTES}"
            ));
        }
        let bytes = self.take(n)?;
        String::from_utf8(bytes.to_vec()).map_err(|e| format!("invalid UTF-8: {e}"))
    }
    fn done(&self, op: &str) -> Result<(), String> {
        if self.pos == self.data.len() {
            Ok(())
        } else {
            Err(format!(
                "{op}: {} trailing bytes in request",
                self.data.len() - self.pos
            ))
        }
    }
}

/// Allocates one `Vec<usize>` containing an aligned length header followed by
/// the payload bytes, and returns a pointer just past the header.
///
/// Using one allocation with one layout keeps `gps_free` exact: it reads the
/// header as a `usize` (never unaligned) and rebuilds the very same vector.
fn alloc_out(bytes: Vec<u8>) -> (*mut u8, usize) {
    let len = bytes.len();
    let word_bytes = size_of::<usize>();
    let payload_words = len / word_bytes + usize::from(len % word_bytes != 0);
    let total_words = 1usize
        .checked_add(payload_words)
        .expect("output buffer size overflow");

    // Initializing every word keeps the reconstructed `Vec<usize>` fully
    // defined, including the padding tail of the final partial word.
    let mut words = vec![0usize; total_words];
    words[0] = len;
    if len > 0 {
        // SAFETY: one `usize` past the base is inside the allocation and at
        // least `len` bytes remain; `bytes` is a separate live allocation.
        let dst = unsafe { words.as_mut_ptr().add(1).cast::<u8>() };
        // SAFETY: `dst..dst+len` and `bytes` are disjoint, writable/readable,
        // and both large enough for the copy.
        unsafe { ptr::copy_nonoverlapping(bytes.as_ptr(), dst, len) };
    }

    // SAFETY: `words` has at least one word, so stepping one word lands at the
    // first payload byte, which is valid for `u8` access.
    let payload = unsafe { words.as_mut_ptr().add(1).cast::<u8>() };
    std::mem::forget(words);
    (payload, len)
}

/// Runs a handler over the input, marshals its output, and reports failures.
/// Never unwinds.
fn dispatch(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
    handler: impl FnOnce(&[u8]) -> Result<Vec<u8>, String>,
) -> c_int {
    if output.is_null() || output_len.is_null() {
        return fail(ST_INVALID, "null pointer passed to the engine");
    }

    // Initialize the out-params before any other check so a failed call never
    // leaves a stale pointer that a caller might free twice.
    // SAFETY: both pointers were checked non-null and the caller promises they
    // point to writable storage.
    unsafe {
        *output = ptr::null_mut();
        *output_len = 0;
    }

    if input_len > MAX_INPUT_BYTES {
        return fail(ST_INVALID, "input buffer exceeds the engine limit");
    }
    if input.is_null() && input_len > 0 {
        return fail(ST_INVALID, "null pointer passed to the engine");
    }
    // SAFETY: a non-null `input` promises `input_len` readable bytes; a null
    // input with zero length is treated as an empty buffer.
    let data: &[u8] = if input.is_null() {
        &[]
    } else {
        // SAFETY: a non-null `input` promises `input_len` readable bytes.
        unsafe { slice::from_raw_parts(input, input_len) }
    };
    // Allocation is inside the catch too: no panic from marshalling the reply
    // may unwind into foreign code.
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(*mut u8, usize), String> {
        let bytes = handler(data)?;
        Ok(alloc_out(bytes))
    }));
    match result {
        Ok(Ok((out_ptr, len))) => {
            // SAFETY: the caller promised `output`/`output_len` point to
            // writable storage.
            unsafe {
                *output = out_ptr;
                *output_len = len;
            }
            ST_OK
        }
        Ok(Err(msg)) => fail(ST_ERROR, &msg),
        Err(_) => fail(ST_ERROR, "panic while handling request"),
    }
}

fn fail(code: c_int, msg: &str) -> c_int {
    set_error(msg);
    code
}

// ---------------------------------------------------------------------------
// Shared encodings
// ---------------------------------------------------------------------------

// Smallest valid encoding of one element, used only to reject impossible
// counts before allocation. Optional fields are still bounds-checked on read.
const POINT_MIN_BYTES: usize = 8 + 8 + 1 + 8;
const COORDINATE_BYTES: usize = 8 + 8;
const FIX_MIN_BYTES: usize = 8 + 8 + 8 + 1;
const SAMPLE_BYTES: usize = 8 + 8;
const ANALYTICS_ROW_BYTES: usize = 8 + 8 + 8;
const ANALYTICS_PAIR_BYTES: usize = 8 + 8;

fn read_finite_f64(rd: &mut Rd<'_>, field: &str) -> Result<f64, String> {
    let value = rd.f64()?;
    if value.is_finite() {
        Ok(value)
    } else {
        Err(format!("{field} must be finite"))
    }
}

fn read_nonnegative_f64(rd: &mut Rd<'_>, field: &str) -> Result<f64, String> {
    let value = read_finite_f64(rd, field)?;
    if value >= 0.0 {
        Ok(value)
    } else {
        Err(format!("{field} must be non-negative"))
    }
}

/// `[u32 n]` then per point: `f64 lat, f64 lon, u8 has_altitude, [f64 altitude],
/// i64 unix-ms timestamp`.
fn read_points(rd: &mut Rd<'_>) -> Result<Vec<TrackPoint>, String> {
    let n = rd.read_count(MAX_POINTS, POINT_MIN_BYTES, "point")?;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let lat = rd.f64()?;
        let lon = rd.f64()?;
        let has_alt = rd.u8()?;
        let coord = Coordinate::new(lat, lon).map_err(|e| format!("point {i}: {e}"))?;
        let timestamp = Timestamp::from_unix_ms(rd.i64()?);
        let mut point = TrackPoint::new(timestamp, coord);
        if has_alt != 0 {
            let altitude = rd.f64()?;
            point = point
                .with_altitude(altitude)
                .map_err(|e| format!("point {i}: {e}"))?;
        }
        out.push(point);
    }
    Ok(out)
}

/// `[u32 n]` then per coordinate: `f64 lat, f64 lon`.
fn read_coordinates(rd: &mut Rd<'_>) -> Result<Vec<Coordinate>, String> {
    let n = rd.read_count(MAX_COORDINATES, COORDINATE_BYTES, "coordinate")?;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let lat = rd.f64()?;
        let lon = rd.f64()?;
        out.push(Coordinate::new(lat, lon).map_err(|e| format!("coordinate {i}: {e}"))?);
    }
    Ok(out)
}

/// `[u32 n]` then per fix:
/// `f64 lat, f64 lon, i64 unix-ms, u8 mask, [f64]*` where mask bit 0 =
/// accuracy (m), 1 = altitude (m), 2 = speed (m/s), 3 = bearing (deg).
fn read_fixes(rd: &mut Rd<'_>) -> Result<Vec<GpsFix>, String> {
    let n = rd.read_count(MAX_FIXES, FIX_MIN_BYTES, "fix")?;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        out.push(read_fix(rd, i)?);
    }
    Ok(out)
}

/// Reads one raw fix, validating optional sensors at the boundary.
///
/// Finite bearing degrees keep the domain's normalization into `[0, 2π)`;
/// non-finite values are errors rather than silently becoming "absent".
/// Accuracy and speed are physical magnitudes and must be non-negative;
/// altitude may be negative but must be finite. Unix-ms timestamps are
/// accepted as any `i64`, matching the domain model.
fn read_fix(rd: &mut Rd<'_>, i: usize) -> Result<GpsFix, String> {
    let lat = rd.f64()?;
    let lon = rd.f64()?;
    let coord = Coordinate::new(lat, lon).map_err(|e| format!("fix {i}: {e}"))?;
    let timestamp = Timestamp::from_unix_ms(rd.i64()?);
    let mask = rd.u8()?;
    let mut fix = GpsFix::new(timestamp, coord);
    if mask & 0x01 != 0 {
        let accuracy = read_nonnegative_f64(rd, "fix accuracy")?;
        fix.accuracy = Some(Distance::from_meters(accuracy));
    }
    if mask & 0x02 != 0 {
        fix.altitude = Some(read_finite_f64(rd, "fix altitude")?);
    }
    if mask & 0x04 != 0 {
        let speed = read_nonnegative_f64(rd, "fix speed")?;
        fix.speed = Some(crate::units::Speed::from_mps(speed));
    }
    if mask & 0x08 != 0 {
        let degrees = read_finite_f64(rd, "fix bearing")?;
        fix.bearing = Some(
            crate::geo::Bearing::from_degrees(degrees)
                .map_err(|e| format!("fix {i}: bearing: {e}"))?,
        );
    }
    Ok(fix)
}

#[allow(dead_code)]
fn write_fix(w: &mut Wr, fix: &GpsFix) {
    w.f64(fix.coordinate.latitude());
    w.f64(fix.coordinate.longitude());
    w.i64(fix.timestamp.unix_ms());
    let mut mask = 0u8;
    if fix.accuracy.is_some() {
        mask |= 0x01;
    }
    if fix.altitude.is_some() {
        mask |= 0x02;
    }
    if fix.speed.is_some() {
        mask |= 0x04;
    }
    if fix.bearing.is_some() {
        mask |= 0x08;
    }
    w.u8(mask);
    if let Some(accuracy) = fix.accuracy {
        w.f64(accuracy.meters());
    }
    if let Some(altitude) = fix.altitude {
        w.f64(altitude);
    }
    if let Some(speed) = fix.speed {
        w.f64(speed.mps());
    }
    if let Some(bearing) = fix.bearing {
        w.f64(bearing.as_degrees());
    }
}

fn read_live_ghost(rd: &mut Rd<'_>) -> Result<Option<LiveGhost>, String> {
    let has = rd.u8()? != 0;
    if !has {
        return Ok(None);
    }
    let samples = read_attempt(rd)?
        .into_iter()
        .map(|s| (s.distance, s.elapsed))
        .collect();
    Ok(Some(LiveGhost { samples }))
}

/// `[u32 n]` then per sample: `f64 distance_m, f64 elapsed_s`.
fn read_attempt(rd: &mut Rd<'_>) -> Result<Vec<AttemptSample>, String> {
    let n = rd.read_count(MAX_SAMPLES_PER_ATTEMPT, SAMPLE_BYTES, "attempt sample")?;
    let mut out = Vec::with_capacity(n);
    for _ in 0..n {
        let distance = Distance::from_meters(read_nonnegative_f64(rd, "sample distance")?);
        let elapsed = Duration::from_secs(read_nonnegative_f64(rd, "sample elapsed")?);
        out.push(AttemptSample { distance, elapsed });
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `gps_process_track`
///
/// In: `str id, [points]`.
/// Out: `u32 input_points, u32 output_points, f64 original_distance_m,
/// f64 processed_distance_m, f64 duration_s, f64 moving_time_s`.
fn process_track(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let _id = rd.str()?; // identity lives in the app layer; echoed by the caller
    let points = read_points(&mut rd)?;
    rd.done("process_track")?;

    let track = Track::new(points).map_err(|e| e.to_string())?;
    let original = track.distance().meters();

    // The FFI's point encoding has no accuracy/speed fields, so each point is
    // offered to the promoted estimator as a bare fix with default accuracy.
    // The layout and field order below are unchanged; only the values reflect
    // the new production filter.
    let fixes: Vec<GpsFix> = track
        .points()
        .iter()
        .map(|point| GpsFix {
            timestamp: point.timestamp(),
            coordinate: point.coordinate(),
            accuracy: point.accuracy().map(Distance::from_meters),
            altitude: point.altitude(),
            speed: point.speed().map(Speed::from_mps),
            bearing: point.bearing(),
        })
        .collect();
    let estimator_config = EstimatorConfig::production();
    let (audit, adaptive) = GpsTrace::new(fixes)
        .map_err(|e| e.to_string())?
        .process_adaptive_result(&FilterConfig::default(), &estimator_config)
        .map_err(|e| e.to_string())?;
    let processed = audit
        .track
        .resample_by_distance(Distance::from_meters(25.0))
        .map_err(|e| e.to_string())?;
    let duration = track.duration().as_secs();

    let mut w = Wr::default();
    w.u32(track.len() as u32);
    w.u32(processed.len() as u32);
    w.f64(original);
    w.f64(adaptive.distance.meters());
    w.f64(duration);
    w.f64(adaptive.moving.as_secs());
    Ok(w.data)
}

/// `gps_match_routes`
///
/// In: `[points] a, [points] b`.
/// Out: `f64 start_distance_m, f64 end_distance_m, f64 distance_ratio,
/// f64 spatial_overlap, f64 direction_similarity, f64 overall_score,
/// u8 same_route`.
fn match_routes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let a = read_points(&mut rd)?;
    let b = read_points(&mut rd)?;
    rd.done("match_routes")?;

    let t_a = Track::new(a).map_err(|e| e.to_string())?;
    let t_b = Track::new(b).map_err(|e| e.to_string())?;
    let score = compare(&t_a, &t_b);
    let same_route = compare_either_direction(&t_a, &t_b, &MatchConfig::default()).is_some();

    let mut w = Wr::default();
    w.f64(score.start_distance.meters());
    w.f64(score.end_distance.meters());
    w.f64(score.distance_ratio);
    w.f64(score.spatial_overlap);
    w.f64(score.direction_similarity);
    w.f64(score.overall_score);
    w.u8(same_route as u8);
    Ok(w.data)
}

/// `gps_create_attempt`
///
/// In: `str activity_id, str route_id, [points], [coordinates], [u8 axis]?`.
/// Out: `f64 elapsed_s, u32 sample_count, then per sample:
/// f64 distance_m, f64 elapsed_s`.
fn create_attempt(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let _activity_id = rd.str()?;
    let _route_id = rd.str()?;
    let points = read_points(&mut rd)?;
    let geometry = read_coordinates(&mut rd)?;
    let axis = if rd.pos < rd.data.len() {
        if rd.u8()? == 1 {
            AttemptAxis::Moving
        } else {
            AttemptAxis::Clock
        }
    } else {
        AttemptAxis::Clock
    };
    rd.done("create_attempt")?;

    let track = Track::new(points).map_err(|e| e.to_string())?;
    let route = Route::new(geometry).map_err(|e| e.to_string())?;
    let attempt = Attempt::from_track_with(&track, &route, axis, &MovingAxisConfig::default());

    let mut w = Wr::default();
    w.f64(attempt.elapsed_time.as_secs());
    w.u32(attempt.samples.len() as u32);
    for sample in &attempt.samples {
        w.f64(sample.distance.meters());
        w.f64(sample.elapsed.as_secs());
    }
    Ok(w.data)
}

/// `gps_route_info`
///
/// In: `[points]` (TrackPoint encoding).
/// Out: `f64 length_m, f64 duration_s` computed from the raw points in
/// order, with no filtering.
fn route_info(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let points = read_points(&mut rd)?;
    rd.done("route_info")?;

    let coords: Vec<Coordinate> = points.iter().map(|p| p.coordinate()).collect();
    let length = polyline_length(&coords).meters();
    let duration = if points.len() >= 2 {
        points
            .last()
            .expect("len>=2")
            .timestamp()
            .elapsed_since(points.first().expect("len>=2").timestamp())
            .as_secs()
    } else {
        0.0
    };
    let mut w = Wr::default();
    w.f64(length);
    w.f64(duration.max(0.0));
    Ok(w.data)
}

/// `gps_compare_route_segments`
///
/// In: `f64 route_distance_m, f64 segment_distance_m, u32 attempt_count,
/// then per attempt: [u32 sample_count, per sample: f64 distance_m, f64 elapsed_s]`.
/// Out: `u32 segment_count, then per segment:
/// u32 index, f64 start_distance_m, f64 end_distance_m,
/// u32 attempt_count, per attempt: f64 duration_s, f64 avg_speed_mps, u8 complete,
/// f64 min_speed_mps, f64 max_speed_mps, f64 mean_speed_mps, f64 speed_spread_mps`.
fn compare_route_segments_impl(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let route_distance = Distance::from_meters(read_nonnegative_f64(&mut rd, "route distance")?);
    let segment_distance =
        Distance::from_meters(read_nonnegative_f64(&mut rd, "segment distance")?);
    let attempt_count = rd.read_count(MAX_ATTEMPTS, 4, "route segment attempt")?;
    let mut attempts = Vec::with_capacity(attempt_count);
    for i in 0..attempt_count {
        let n = rd.read_count(MAX_SAMPLES_PER_ATTEMPT, SAMPLE_BYTES, "attempt sample")?;
        let mut samples = Vec::with_capacity(n);
        for j in 0..n {
            let distance = Distance::from_meters(read_nonnegative_f64(
                &mut rd,
                &format!("sample {i}.{j} distance"),
            )?);
            let elapsed = Duration::from_secs(read_nonnegative_f64(
                &mut rd,
                &format!("sample {i}.{j} elapsed"),
            )?);
            samples.push(crate::attempt::AttemptSample { distance, elapsed });
        }
        let attempt = crate::attempt::Attempt::from_samples(samples).map_err(|e| e.to_string())?;
        attempts.push(attempt);
    }
    rd.done("compare_route_segments")?;

    let comparison = compare_route_segments(&attempts, segment_distance, route_distance)
        .map_err(|e| e.to_string())?;

    let mut w = Wr::default();
    w.u32(comparison.len() as u32);
    for c in &comparison {
        w.u32(c.index as u32);
        w.f64(c.start_distance.meters());
        w.f64(c.end_distance.meters());
        w.u32(c.segments.len() as u32);
        for s in &c.segments {
            w.f64(s.duration.as_secs());
            w.f64(s.average_speed.mps());
            w.u8(s.complete as u8);
        }
        w.f64(c.min_speed.mps());
        w.f64(c.max_speed.mps());
        w.f64(c.mean_speed.mps());
        w.f64(c.speed_spread.mps());
    }
    Ok(w.data)
}

fn ghost_state_at(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let reference_samples = read_attempt(&mut rd)?;
    let current_samples = read_attempt(&mut rd)?;
    let distance = Distance::from_meters(read_nonnegative_f64(&mut rd, "ghost distance")?);
    rd.done("ghost_state_at")?;

    let reference = Attempt::from_samples(reference_samples).map_err(|e| e.to_string())?;
    let current = Attempt::from_samples(current_samples).map_err(|e| e.to_string())?;
    let state = Ghost::new(reference, current)
        .state_at_distance(distance)
        .unwrap_or(crate::ghost::GhostState {
            distance,
            time_difference: Duration::ZERO,
            ahead: false,
        });

    let mut w = Wr::default();
    w.f64(state.distance.meters());
    w.f64(state.time_difference.as_secs());
    w.u8(state.ahead as u8);
    Ok(w.data)
}

/// `gps_live_ghost_gap`
///
/// In: `[attempt] reference, f64 current_distance_m, f64 moving_seconds, f64 loop_length_m`.
/// Out: `f64 distance_m, f64 time_difference_s, u8 ahead`.
fn live_ghost_gap_impl(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let reference_samples = read_attempt(&mut rd)?;
    let current_distance =
        Distance::from_meters(read_nonnegative_f64(&mut rd, "current distance")?);
    let moving_seconds = Duration::from_secs(read_nonnegative_f64(&mut rd, "moving seconds")?);
    let loop_length = Distance::from_meters(read_nonnegative_f64(&mut rd, "loop length")?);
    rd.done("live_ghost_gap")?;

    let reference = Attempt::from_samples(reference_samples).map_err(|e| e.to_string())?;
    let state =
        crate::ghost::live_ghost_gap(&reference, current_distance, moving_seconds, loop_length);

    let mut w = Wr::default();
    w.f64(state.distance.meters());
    w.f64(state.time_difference.as_secs());
    w.u8(state.ahead as u8);
    Ok(w.data)
}
///
/// In: `[coordinates], f64 speed_mps, f64 sample_every_s, f64 noise_m`.
/// Out: `[points]` (like [`read_points`], timestamps in unix-ms).
fn generate_recording(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let geometry = read_coordinates(&mut rd)?;
    let speed = rd.f64()?;
    let sample_every = rd.f64()?;
    let noise = rd.f64()?;
    rd.done("generate_recording")?;

    if !speed.is_finite() || speed <= 0.0 {
        return Err("speed must be finite and positive".into());
    }
    if !sample_every.is_finite() || sample_every <= 0.0 {
        return Err("sample interval must be finite and positive".into());
    }
    if !noise.is_finite() || noise < 0.0 {
        return Err("noise must be finite and non-negative".into());
    }

    let route = Route::new(geometry).map_err(|e| e.to_string())?;
    let length = route.length().meters();
    let step = speed * sample_every;

    let mut body = Wr::default();
    let mut count = 0u32;
    let n_full = (length / step).min(1_000_000.0).floor() as usize;
    let mut rng = Rng::new(42);

    let emit = |lat: f64, lon: f64, ts_ms: i64, body: &mut Wr, count: &mut u32| {
        body.f64(lat);
        body.f64(lon);
        body.u8(0);
        body.i64(ts_ms);
        *count += 1;
    };

    for i in 0..n_full {
        let d = step * (i as f64 + 1.0);
        let at = route
            .coordinate_at(Distance::from_meters(d))
            .ok_or_else(|| "route too short for sample step".to_string())?;
        let jittered = jitter(at, noise, &mut rng);
        let ts = (d / speed * 1000.0).round() as i64;
        emit(
            jittered.latitude(),
            jittered.longitude(),
            ts,
            &mut body,
            &mut count,
        );
    }

    let end = route
        .coordinate_at(Distance::from_meters(length))
        .ok_or_else(|| "route has no endpoint".to_string())?;
    let jittered = jitter(end, noise, &mut rng);
    let end_ts = (length / speed * 1000.0).round() as i64;
    emit(
        jittered.latitude(),
        jittered.longitude(),
        end_ts,
        &mut body,
        &mut count,
    );

    let mut w = Wr::default();
    w.u32(count);
    w.data.extend(body.data);
    Ok(w.data)
}

/// Displaces a coordinate by uniform noise within `noise_m`, mirroring the
/// fake engine's deterministic style (fixed seed RNG).
fn jitter(c: Coordinate, noise: f64, rng: &mut Rng) -> Coordinate {
    if noise <= 0.0 {
        return c;
    }
    let angle = rng.unit() * std::f64::consts::TAU;
    let radius = noise * rng.unit();
    let dlat = radius * angle.cos() / 111_320.0;
    let dlon = radius * angle.sin() / (111_320.0 * c.latitude().to_radians().cos().max(0.01));
    Coordinate::new(c.latitude() + dlat, c.longitude() + dlon).unwrap_or(c)
}

// ---------------------------------------------------------------------------
// Opaque handle registry
// ---------------------------------------------------------------------------

/// Handle kinds are encoded in the high byte so cross-type use is rejected
/// before any registry lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum HandleKind {
    Live,
    Replay,
}

const HANDLE_TAG_LIVE: u8 = 0xA1;
const HANDLE_TAG_REPLAY: u8 = 0xB2;
const HANDLE_GENERATION_MASK: u64 = 0x00FF_FFFF;
const MAX_HANDLE_GENERATION: u32 = HANDLE_GENERATION_MASK as u32;

impl HandleKind {
    fn tag(self) -> u8 {
        match self {
            HandleKind::Live => HANDLE_TAG_LIVE,
            HandleKind::Replay => HANDLE_TAG_REPLAY,
        }
    }

    fn from_tag(tag: u8) -> Result<Self, String> {
        match tag {
            HANDLE_TAG_LIVE => Ok(HandleKind::Live),
            HANDLE_TAG_REPLAY => Ok(HandleKind::Replay),
            _ => Err("unknown handle type".into()),
        }
    }

    fn name(self) -> &'static str {
        match self {
            HandleKind::Live => "live",
            HandleKind::Replay => "replay",
        }
    }
}

/// A slot's contents are removed on free while the `Arc` may still be held by
/// an in-flight operation. Later users then see `None` instead of a dangling
/// object, and a free waits for an operation already in progress.
struct Slot<T> {
    value: Mutex<Option<T>>,
}

struct KindSlots<T> {
    next_index: u32,
    reusable: Vec<u32>,
    generations: HashMap<u32, u32>,
    slots: HashMap<u32, Arc<Slot<T>>>,
}

impl<T> Default for KindSlots<T> {
    fn default() -> Self {
        KindSlots {
            next_index: 0,
            reusable: Vec::new(),
            generations: HashMap::new(),
            slots: HashMap::new(),
        }
    }
}

impl<T> KindSlots<T> {
    fn allocate(&mut self, value: T, kind: HandleKind) -> Result<u64, String> {
        loop {
            let index = match self.reusable.pop() {
                Some(index) => index,
                None => {
                    let index = self.next_index;
                    self.next_index = self
                        .next_index
                        .checked_add(1)
                        .ok_or_else(|| format!("{} handle index space exhausted", kind.name()))?;
                    index
                }
            };
            let generation = self.generations.entry(index).or_insert(1);
            // Retire an index rather than wrap its generation and revive a
            // stale handle.
            if *generation > MAX_HANDLE_GENERATION {
                continue;
            }
            let handle = encode_handle(kind, *generation, index);
            self.slots.insert(
                index,
                Arc::new(Slot {
                    value: Mutex::new(Some(value)),
                }),
            );
            return Ok(handle);
        }
    }

    fn slot(&self, decoded: &DecodedHandle) -> Result<Arc<Slot<T>>, String> {
        let current = self.generations.get(&decoded.index).copied().unwrap_or(0);
        if current != decoded.generation {
            return Err(format!("stale {} handle", decoded.kind.name()));
        }
        self.slots
            .get(&decoded.index)
            .cloned()
            .ok_or_else(|| format!("invalid or freed {} handle", decoded.kind.name()))
    }

    fn remove(&mut self, decoded: &DecodedHandle) -> Option<Arc<Slot<T>>> {
        if self.generations.get(&decoded.index).copied() != Some(decoded.generation) {
            return None;
        }
        let slot = self.slots.remove(&decoded.index)?;
        if let Some(generation) = self.generations.get_mut(&decoded.index) {
            if *generation < MAX_HANDLE_GENERATION {
                *generation += 1;
                self.reusable.push(decoded.index);
            } else {
                self.generations.remove(&decoded.index);
            }
        }
        Some(slot)
    }
}

#[derive(Debug, Clone, Copy)]
struct DecodedHandle {
    kind: HandleKind,
    generation: u32,
    index: u32,
}

#[derive(Default)]
struct Registry {
    live: KindSlots<LiveRecorder>,
    replay: KindSlots<ReplaySession>,
}

fn registry() -> MutexGuard<'static, Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY
        .get_or_init(|| Mutex::new(Registry::default()))
        .lock()
        .unwrap_or_else(|err| err.into_inner())
}

fn encode_handle(kind: HandleKind, generation: u32, index: u32) -> u64 {
    ((kind.tag() as u64) << 56)
        | (((generation as u64) & HANDLE_GENERATION_MASK) << 32)
        | index as u64
}

fn decode_handle(handle: u64) -> Result<DecodedHandle, String> {
    if handle == 0 {
        return Err("null handle".into());
    }
    let kind = HandleKind::from_tag((handle >> 56) as u8)?;
    let generation = ((handle >> 32) & HANDLE_GENERATION_MASK) as u32;
    if generation == 0 {
        return Err("invalid handle generation".into());
    }
    Ok(DecodedHandle {
        kind,
        generation,
        index: handle as u32,
    })
}

fn with_live<T>(
    handle: u64,
    operation: impl FnOnce(&mut LiveRecorder) -> Result<T, String>,
) -> Result<T, String> {
    let decoded = decode_handle(handle)?;
    if decoded.kind != HandleKind::Live {
        return Err("handle type mismatch: expected a live handle".into());
    }
    let slot = registry().live.slot(&decoded)?;
    let mut guard = slot.value.lock().unwrap_or_else(|err| err.into_inner());
    let recorder = guard
        .as_mut()
        .ok_or_else(|| "live handle was already freed".to_string())?;
    operation(recorder)
}

fn with_replay<T>(
    handle: u64,
    operation: impl FnOnce(&mut ReplaySession) -> Result<T, String>,
) -> Result<T, String> {
    let decoded = decode_handle(handle)?;
    if decoded.kind != HandleKind::Replay {
        return Err("handle type mismatch: expected a replay handle".into());
    }
    let slot = registry().replay.slot(&decoded)?;
    let mut guard = slot.value.lock().unwrap_or_else(|err| err.into_inner());
    let session = guard
        .as_mut()
        .ok_or_else(|| "replay handle was already freed".to_string())?;
    operation(session)
}

fn free_live_handle(handle: u64) -> Result<(), String> {
    let decoded = decode_handle(handle)?;
    if decoded.kind != HandleKind::Live {
        return Err("handle type mismatch: expected a live handle".into());
    }
    let slot = registry()
        .live
        .remove(&decoded)
        .ok_or_else(|| "invalid or freed live handle".to_string())?;
    // Waiting here ensures a concurrent operation finishes before the free
    // returns; any operation that arrives later sees an empty slot.
    let mut guard = slot.value.lock().unwrap_or_else(|err| err.into_inner());
    *guard = None;
    Ok(())
}

fn free_replay_handle(handle: u64) -> Result<(), String> {
    let decoded = decode_handle(handle)?;
    if decoded.kind != HandleKind::Replay {
        return Err("handle type mismatch: expected a replay handle".into());
    }
    let slot = registry()
        .replay
        .remove(&decoded)
        .ok_or_else(|| "invalid or freed replay handle".to_string())?;
    let mut guard = slot.value.lock().unwrap_or_else(|err| err.into_inner());
    *guard = None;
    Ok(())
}

// ---------------------------------------------------------------------------
// Live recorder (opaque handle)
// ---------------------------------------------------------------------------

fn live_new(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let has_route = rd.u8()? != 0;
    let route = if has_route {
        Some(Route::new(read_coordinates(&mut rd)?).map_err(|e| e.to_string())?)
    } else {
        None
    };
    let ghost = read_live_ghost(&mut rd)?;
    rd.done("live_new")?;

    let mut rec = LiveRecorder::new(LiveConfig::default(), route);
    rec.set_ghost(ghost);
    let handle = registry().live.allocate(rec, HandleKind::Live)?;
    let mut w = Wr::default();
    w.u64(handle);
    Ok(w.data)
}

fn live_push(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let fix = read_fix(&mut rd, 0)?;
    rd.done("live_push")?;
    with_live(handle, |rec| {
        rec.push(fix);
        Ok(Vec::new())
    })
}

fn live_pause(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_pause")?;
    with_live(handle, |rec| {
        rec.pause();
        Ok(Vec::new())
    })
}

fn live_resume(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_resume")?;
    with_live(handle, |rec| {
        rec.resume();
        Ok(Vec::new())
    })
}

fn live_finish(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_finish")?;
    with_live(handle, |rec| {
        rec.finish();
        Ok(Vec::new())
    })
}

fn live_seed(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let distance = Distance::from_meters(read_nonnegative_f64(&mut rd, "seed distance")?);
    let moving = Duration::from_secs(read_nonnegative_f64(&mut rd, "seed moving time")?);
    rd.done("live_seed")?;
    with_live(handle, |rec| {
        rec.seed(distance, moving);
        Ok(Vec::new())
    })
}

fn live_set_ghost(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let ghost = read_live_ghost(&mut rd)?;
    rd.done("live_set_ghost")?;
    with_live(handle, |rec| {
        rec.set_ghost(ghost);
        Ok(Vec::new())
    })
}

fn live_snapshot(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_snapshot")?;
    with_live(handle, |rec| {
        let snap = rec.snapshot();
        let ghost = rec.ghost_snapshot();

        let mut w = Wr::default();
        w.f64(snap.distance.meters());
        w.f64(snap.moving.as_secs());
        w.f64(snap.pace.mps());
        w.f64(snap.route_progress);
        if let Some(off) = snap.off_route {
            w.u8(1);
            w.f64(off.meters());
        } else {
            w.u8(0);
            w.f64(0.0);
        }
        if let Some(acc) = snap.accuracy {
            w.u8(1);
            w.f64(acc.meters());
        } else {
            w.u8(0);
            w.f64(0.0);
        }
        if let Some(pos) = snap.position {
            w.u8(1);
            w.f64(pos.latitude());
            w.f64(pos.longitude());
        } else {
            w.u8(0);
            w.f64(0.0);
            w.f64(0.0);
        }
        if let Some(g) = ghost {
            w.u8(1);
            w.f64(g.state.distance.meters());
            w.f64(g.state.time_difference.as_secs());
            w.u8(g.state.ahead as u8);
            w.f64(g.spatial_gap.meters());
            w.f64(g.confidence);
        } else {
            w.u8(0);
            w.f64(0.0);
            w.f64(0.0);
            w.u8(0);
            w.f64(0.0);
            w.f64(0.0);
        }
        w.u8(snap.match_status as u8);
        w.f64(snap.match_confidence);
        // Append-only ghost evidence. The v1 prefix above is byte-stable; older
        // readers that ignore trailing bytes keep working unchanged.
        if let Some(g) = ghost {
            w.u8(g.match_status as u8);
            w.f64(g.match_confidence.map(|c| c.value()).unwrap_or(0.0));
            match g.position_confidence {
                Some(confidence) => {
                    w.u8(1);
                    w.f64(confidence.value());
                }
                None => {
                    w.u8(0);
                    w.f64(0.0);
                }
            }
            w.u8(g.reliable() as u8);
        } else {
            w.u8(0);
            w.f64(0.0);
            w.u8(0);
            w.f64(0.0);
            w.u8(0);
        }
        Ok(w.data)
    })
}

/// Frees a live handle returned by `gps_live_new`. Null, stale, and
/// cross-type handles are ignored.
///
/// # Safety
/// `handle` may be any `u64`; only a live handle from `gps_live_new` has an
/// effect.
#[unsafe(no_mangle)]
pub extern "C" fn gps_live_free(handle: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let _ = free_live_handle(handle);
    }));
}

#[unsafe(no_mangle)]
/// Cleans a recording ([points]) and returns a [ProcessedTrack]-shaped report.
///
/// # Safety
/// `input`/`input_len` must describe `input_len` readable bytes; `output` and
/// `output_len` must point to writable storage.
pub unsafe extern "C" fn gps_process_track(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, process_track)
}

#[unsafe(no_mangle)]
/// Compares two tracks geometrically and reports the match metrics.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_match_routes(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, match_routes)
}

#[unsafe(no_mangle)]
/// Reduces a recording plus route geometry onto the route distance axis.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_create_attempt(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, create_attempt)
}

#[unsafe(no_mangle)]
/// Compares multiple attempts section-by-section along a canonical route.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_compare_route_segments(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(
        input,
        input_len,
        output,
        output_len,
        compare_route_segments_impl,
    )
}
#[unsafe(no_mangle)]
/// Evaluates a ghost duel at a fixed route distance.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_ghost_state_at(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, ghost_state_at)
}

#[unsafe(no_mangle)]
/// Live-run ghost gap estimate (constant cruise pace).
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_live_ghost_gap(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_ghost_gap_impl)
}

#[unsafe(no_mangle)]
/// Synthesizes a deterministic recording along a geometry at a given speed.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_generate_recording(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, generate_recording)
}

#[unsafe(no_mangle)]
/// Computes raw geodesic length and duration for a point sequence.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_route_info(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, route_info)
}

#[unsafe(no_mangle)]
/// Creates a stateful live recorder and returns an opaque handle.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_live_new(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_new)
}

#[unsafe(no_mangle)]
/// Feeds one raw fix into a live recorder.
///
/// # Safety
/// See [`gps_process_track`]; the handle in the request must be live.
pub unsafe extern "C" fn gps_live_push(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_push)
}

#[unsafe(no_mangle)]
/// Pauses a live recorder.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_pause(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_pause)
}

#[unsafe(no_mangle)]
/// Resumes a live recorder.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_resume(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_resume)
}

#[unsafe(no_mangle)]
/// Flushes the closing chord of a live recorder.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_finish(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_finish)
}

#[unsafe(no_mangle)]
/// Seeds a live recorder from a persisted snapshot.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_seed(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_seed)
}

#[unsafe(no_mangle)]
/// Replaces the ghost profile of a live recorder.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_set_ghost(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_set_ghost)
}

#[unsafe(no_mangle)]
/// Reads the current snapshot of a live recorder.
///
/// # Safety
/// See [`gps_live_push`].
pub unsafe extern "C" fn gps_live_snapshot(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, live_snapshot)
}

// ---------------------------------------------------------------------------
// Replay (opaque handle)
// ---------------------------------------------------------------------------

fn replay_new(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let fixes = read_fixes(&mut rd)?;
    let has_route = rd.u8()? != 0;
    let route = if has_route {
        Some(Route::new(read_coordinates(&mut rd)?).map_err(|e| e.to_string())?)
    } else {
        None
    };
    let ghost = read_live_ghost(&mut rd)?;
    rd.done("replay_new")?;

    let session = ReplaySession::with_ghost(fixes, route, ghost);
    let handle = registry().replay.allocate(session, HandleKind::Replay)?;
    let mut w = Wr::default();
    w.u64(handle);
    Ok(w.data)
}

fn write_replay_snapshot(w: &mut Wr, snap: &crate::replay::ReplaySnapshot) {
    w.f64(snap.elapsed.as_secs());
    w.f64(snap.total.as_secs());
    w.u8(match snap.state {
        ReplayState::Playing => 0,
        ReplayState::Paused => 1,
        ReplayState::Finished => 2,
    });
    w.f64(snap.speed);
    w.u32(snap.applied_fixes as u32);
    w.u32(snap.total_fixes as u32);
    if let Some(pos) = snap.position {
        w.u8(1);
        w.f64(pos.latitude());
        w.f64(pos.longitude());
    } else {
        w.u8(0);
        w.f64(0.0);
        w.f64(0.0);
    }
    if let Some(acc) = snap.accuracy {
        w.u8(1);
        w.f64(acc.meters());
    } else {
        w.u8(0);
        w.f64(0.0);
    }
    w.f64(snap.distance.meters());
    w.f64(snap.moving.as_secs());
    w.f64(snap.pace.mps());
    w.f64(snap.route_progress);
    w.u8(snap.reversed as u8);
    if let Some(off) = snap.off_route {
        w.u8(1);
        w.f64(off.meters());
    } else {
        w.u8(0);
        w.f64(0.0);
    }
    if let Some(g) = &snap.ghost {
        w.u8(1);
        w.f64(g.state.distance.meters());
        w.f64(g.state.time_difference.as_secs());
        w.u8(g.state.ahead as u8);
        w.f64(g.spatial_gap.meters());
        w.f64(g.confidence);
    } else {
        w.u8(0);
        w.f64(0.0);
        w.f64(0.0);
        w.u8(0);
        w.f64(0.0);
        w.f64(0.0);
    }
    w.u8(snap.match_status as u8);
    w.f64(snap.match_confidence);
    // Append-only ghost evidence, mirroring the live snapshot suffix.
    if let Some(g) = &snap.ghost {
        w.u8(snap.match_status as u8);
        w.f64(g.match_confidence.map(|c| c.value()).unwrap_or(0.0));
        match g.position_confidence {
            Some(confidence) => {
                w.u8(1);
                w.f64(confidence.value());
            }
            None => {
                w.u8(0);
                w.f64(0.0);
            }
        }
        // Replay has no live matcher; its existing match status is the only
        // match evidence available to the ghost.
        let reliable = g.confidence >= crate::live::MIN_TRUSTED_GHOST_CONFIDENCE
            && matches!(
                snap.match_status,
                crate::live::LiveMatchStatus::None | crate::live::LiveMatchStatus::Matched
            )
            && g.match_confidence
                .is_none_or(|c| c.value() >= crate::live::MIN_TRUSTED_GHOST_CONFIDENCE)
            && g.position_confidence
                .is_none_or(|c| c.value() >= crate::live::MIN_TRUSTED_GHOST_CONFIDENCE);
        w.u8(reliable as u8);
    } else {
        w.u8(0);
        w.f64(0.0);
        w.u8(0);
        w.f64(0.0);
        w.u8(0);
    }
}

fn replay_play(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("replay_play")?;
    with_replay(handle, |session| {
        session.play();
        Ok(Vec::new())
    })
}

fn replay_pause(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("replay_pause")?;
    with_replay(handle, |session| {
        session.pause();
        Ok(Vec::new())
    })
}

fn replay_seek(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let elapsed = Duration::from_secs(read_nonnegative_f64(&mut rd, "seek elapsed")?);
    rd.done("replay_seek")?;
    with_replay(handle, |session| {
        session.seek(elapsed);
        Ok(Vec::new())
    })
}

fn replay_set_speed(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let speed = read_finite_f64(&mut rd, "replay speed")?;
    if speed <= 0.0 {
        return Err("replay speed must be positive".into());
    }
    rd.done("replay_set_speed")?;
    with_replay(handle, |session| {
        session.set_speed(speed);
        Ok(Vec::new())
    })
}

fn replay_advance(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let delta = Duration::from_secs(read_nonnegative_f64(&mut rd, "advance delta")?);
    rd.done("replay_advance")?;
    with_replay(handle, |session| {
        let snap = session.advance(delta);
        let mut w = Wr::default();
        write_replay_snapshot(&mut w, &snap);
        Ok(w.data)
    })
}

fn replay_snapshot(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("replay_snapshot")?;
    with_replay(handle, |session| {
        let snap = session.snapshot();
        let mut w = Wr::default();
        write_replay_snapshot(&mut w, &snap);
        Ok(w.data)
    })
}

#[unsafe(no_mangle)]
/// Creates a replay session and returns its handle.
///
/// # Safety
/// See [`gps_process_track`].
pub unsafe extern "C" fn gps_replay_new(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_new)
}

#[unsafe(no_mangle)]
/// Starts or resumes replay.
///
/// # Safety
/// See [`gps_live_push`]; the handle must be a live replay handle.
pub unsafe extern "C" fn gps_replay_play(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_play)
}

#[unsafe(no_mangle)]
/// Pauses replay.
///
/// # Safety
/// See [`gps_replay_play`].
pub unsafe extern "C" fn gps_replay_pause(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_pause)
}

#[unsafe(no_mangle)]
/// Seeks replay to an elapsed time in seconds.
///
/// # Safety
/// See [`gps_replay_play`].
pub unsafe extern "C" fn gps_replay_seek(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_seek)
}

#[unsafe(no_mangle)]
/// Sets the replay speed multiplier.
///
/// # Safety
/// See [`gps_replay_play`].
pub unsafe extern "C" fn gps_replay_set_speed(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_set_speed)
}

#[unsafe(no_mangle)]
/// Advances replay by a real-time delta (seconds) and returns a snapshot.
///
/// # Safety
/// See [`gps_replay_play`].
pub unsafe extern "C" fn gps_replay_advance(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_advance)
}

#[unsafe(no_mangle)]
/// Returns the current replay snapshot.
///
/// # Safety
/// See [`gps_replay_play`].
pub unsafe extern "C" fn gps_replay_snapshot(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    dispatch(input, input_len, output, output_len, replay_snapshot)
}

#[unsafe(no_mangle)]
/// Frees a replay handle. Null, stale, and cross-type handles are ignored.
///
/// # Safety
/// `handle` may be any `u64`; only a replay handle from `gps_replay_new` has an
/// effect.
pub extern "C" fn gps_replay_free(handle: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let _ = free_replay_handle(handle);
    }));
}

/// Analyzes a track and returns a JSON document describing its analytics.
///
/// # Safety
/// Follows the same pointer contract as the other `gps_*` entry points.
#[unsafe(no_mangle)]
pub extern "C" fn gps_analyze_track(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    use crate::analytics::TrackAnalytics;

    dispatch(input, input_len, output, output_len, |data| {
        let mut rd = Rd::new(data);
        let points = read_points(&mut rd)?;
        rd.done("analyze_track")?;
        let track = Track::new(points).map_err(|e| format!("{e}"))?;
        let analytics = TrackAnalytics::from_track(&track, &MovingConfig::default());
        Ok(analytics.to_json().into_bytes())
    })
}

/// Computes route statistics and returns a JSON document.
#[unsafe(no_mangle)]
pub extern "C" fn gps_route_stats(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    use crate::analytics::RouteStats;

    dispatch(input, input_len, output, output_len, |data| {
        let mut rd = Rd::new(data);
        // pb seconds as i64 ms; -1 means None.
        let pb_raw = rd.i64()?;
        let pb = if pb_raw < 0 {
            None
        } else {
            Some(pb_raw as f64 / 1000.0)
        };
        let attempt_count = rd.u32()?;
        if attempt_count as usize > MAX_ATTEMPTS {
            return Err(format!(
                "attempt count {attempt_count} exceeds limit {MAX_ATTEMPTS}"
            ));
        }
        let n = rd.read_count(MAX_ATTEMPTS, ANALYTICS_ROW_BYTES, "route stat attempt")?;
        let mut attempts = Vec::with_capacity(n);
        for i in 0..n {
            let started = rd.i64()?;
            let dur = read_nonnegative_f64(&mut rd, &format!("attempt {i} duration"))?;
            let dist = read_nonnegative_f64(&mut rd, &format!("attempt {i} distance"))?;
            attempts.push((started, dur, dist));
        }
        rd.done("route_stats")?;
        let stats = RouteStats::compute(pb, attempt_count, &attempts);
        Ok(stats.to_json().into_bytes())
    })
}

/// Computes per-kilometer splits and the gap-to-PB curve, returning JSON.
#[unsafe(no_mangle)]
pub extern "C" fn gps_pace_analysis(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    use crate::analytics::PaceAnalysis;

    dispatch(input, input_len, output, output_len, |data| {
        let mut rd = Rd::new(data);
        // pb seconds as i64 ms; -1 means no PB.
        let pb_raw = rd.i64()?;
        let pb_seconds = if pb_raw < 0 {
            None
        } else {
            Some(pb_raw as f64 / 1000.0)
        };
        let route_meters = read_nonnegative_f64(&mut rd, "route meters")?;
        let has_start = rd.u8()? != 0;
        let route_start = if has_start {
            Some(Coordinate::new(rd.f64()?, rd.f64()?).map_err(|e| format!("route start: {e}"))?)
        } else {
            None
        };
        let track_meters = read_nonnegative_f64(&mut rd, "track meters")?;
        let points = read_points(&mut rd)?;
        rd.done("pace_analysis")?;
        let analysis = match pb_seconds {
            Some(pb) => PaceAnalysis::compute(&points, route_start, route_meters, pb, track_meters),
            None => PaceAnalysis {
                splits: Vec::new(),
                gap_curve: Vec::new(),
            },
        };
        Ok(analysis.to_json().into_bytes())
    })
}

/// Computes PB progression events for route attempts.
///
/// In: `i64 seed_best_ms (-1 none), u32 n, n*(i64 started_ms, f64 duration_s)`.
/// Out: `u32 m, m*(u32 index, u8 has_previous, f64 previous_s)`.
#[unsafe(no_mangle)]
pub extern "C" fn gps_route_progression(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    use crate::analytics::{Attempt, pb_progression};

    dispatch(input, input_len, output, output_len, |data| {
        let mut rd = Rd::new(data);
        let seed_raw = rd.i64()?;
        let seed = if seed_raw < 0 {
            None
        } else {
            Some(seed_raw as f64 / 1000.0)
        };
        let n = rd.read_count(MAX_ATTEMPTS, ANALYTICS_PAIR_BYTES, "progression attempt")?;
        let mut attempts: Vec<Attempt> = Vec::with_capacity(n);
        for i in 0..n {
            let started = rd.i64()?;
            let dur = read_nonnegative_f64(&mut rd, &format!("attempt {i} duration"))?;
            attempts.push((started, dur, f64::NAN));
        }
        rd.done("route_progression")?;
        let events = pb_progression(&attempts, seed);
        let mut w = Wr::default();
        w.u32(events.len() as u32);
        for e in events {
            w.u32(e.index as u32);
            match e.previous_seconds {
                Some(p) => {
                    w.u8(1);
                    w.f64(p);
                }
                None => {
                    w.u8(0);
                    w.f64(0.0);
                }
            }
        }
        Ok(w.data)
    })
}

/// Computes 1-based rank of a target attempt among attempts ordered by
/// fastest duration.
///
/// In: `u32 target_index, u32 n, n*(i64 started_ms, f64 duration_s)`.
/// Out: `u8 has_rank, u32 rank`.
#[unsafe(no_mangle)]
pub extern "C" fn gps_route_rank(
    input: *const u8,
    input_len: usize,
    output: *mut *mut u8,
    output_len: *mut usize,
) -> c_int {
    use crate::analytics::{Attempt, attempt_rank};

    dispatch(input, input_len, output, output_len, |data| {
        let mut rd = Rd::new(data);
        let target = rd.u32()? as usize;
        if target > MAX_ATTEMPTS {
            return Err(format!(
                "target index {target} exceeds limit {MAX_ATTEMPTS}"
            ));
        }
        let n = rd.read_count(MAX_ATTEMPTS, ANALYTICS_PAIR_BYTES, "rank attempt")?;
        let mut attempts: Vec<Attempt> = Vec::with_capacity(n);
        for i in 0..n {
            let started = rd.i64()?;
            let dur = read_nonnegative_f64(&mut rd, &format!("attempt {i} duration"))?;
            attempts.push((started, dur, f64::NAN));
        }
        rd.done("route_rank")?;
        let mut w = Wr::default();
        match attempt_rank(&attempts, target) {
            Some(rank) => {
                w.u8(1);
                w.u32(rank);
            }
            None => {
                w.u8(0);
                w.u32(0);
            }
        }
        Ok(w.data)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Round-trips every handler against an empty input buffer: the engine
    /// must never panic at the boundary and never dereference garbage.
    #[test]
    fn empty_input_is_reported_as_invalid() {
        let mut out: *mut u8 = std::ptr::null_mut();
        let mut out_len = 0usize;
        let stub_data: [u8; 0] = [];
        let status = dispatch(
            stub_data.as_ptr(),
            0,
            &mut out as *mut *mut u8,
            &mut out_len,
            process_track,
        );
        assert_eq!(status, ST_ERROR);
    }

    #[test]
    fn live_snapshot_appends_ghost_evidence_after_the_v1_prefix() {
        // Live handle: no route, ghost with two dense samples.
        let mut input = Wr::default();
        input.u8(0);
        input.u8(1);
        input.u32(2);
        input.f64(0.0);
        input.f64(0.0);
        input.f64(100.0);
        input.f64(50.0);
        let handle_bytes = live_new(&input.data).expect("live_new succeeds");
        let mut handle_rd = Rd::new(&handle_bytes);
        let handle = handle_rd.u64().expect("handle");
        handle_rd.done("live_new").expect("handle prefix only");

        let mut request = Wr::default();
        request.u64(handle);
        let output = live_snapshot(&request.data).expect("live_snapshot succeeds");
        gps_live_free(handle);

        let mut rd = Rd::new(&output);
        for _ in 0..4 {
            rd.f64().expect("distance/moving/pace/progress");
        }
        assert_eq!(rd.u8().expect("has off"), 0);
        rd.f64().expect("off");
        assert_eq!(rd.u8().expect("has accuracy"), 0);
        rd.f64().expect("accuracy");
        assert_eq!(rd.u8().expect("has position"), 0);
        rd.f64().expect("latitude");
        rd.f64().expect("longitude");
        assert_eq!(rd.u8().expect("has ghost"), 1);
        rd.f64().expect("ghost distance");
        rd.f64().expect("ghost difference");
        rd.u8().expect("ghost ahead");
        rd.f64().expect("ghost spatial gap");
        let spacing_confidence = rd.f64().expect("ghost spacing confidence");
        assert_eq!(rd.u8().expect("match status"), 0);
        assert_eq!(rd.f64().expect("match confidence"), 0.0);

        // Append-only evidence: status, match confidence, optional position
        // confidence (presence + value), reliable flag.
        assert_eq!(
            rd.u8().expect("ghost match status"),
            crate::live::LiveMatchStatus::None as u8
        );
        assert_eq!(rd.f64().expect("ghost match confidence"), 0.0);
        assert_eq!(rd.u8().expect("has ghost position confidence"), 0);
        assert_eq!(rd.f64().expect("ghost position confidence"), 0.0);
        assert_eq!(rd.u8().expect("ghost reliable"), 1);
        rd.done("live_snapshot").expect("no trailing bytes");
        assert!(spacing_confidence > 0.0 && spacing_confidence <= 1.0);
    }

    #[test]
    fn process_track_keeps_the_v1_layout_and_promoted_values() {
        let id = "legacy-layout";
        let raw = [
            (52.5_f64, 13.4_f64, 0_i64),
            (52.501, 13.4, 10_000),
            (52.502, 13.4, 20_000),
        ];

        // In: str id, [points] where each point is lat, lon, has_altitude, ms.
        let mut input = Wr::default();
        input.u32(id.len() as u32);
        input.data.extend_from_slice(id.as_bytes());
        input.u32(raw.len() as u32);
        for (lat, lon, ms) in raw {
            input.f64(lat);
            input.f64(lon);
            input.u8(0);
            input.i64(ms);
        }

        let output = process_track(&input.data).expect("process_track succeeds");
        assert_eq!(output.len(), 40, "v1 output layout changed");

        // Out: u32 input, u32 output, then four f64 axes in the original order.
        let mut rd = Rd::new(&output);
        let input_points = rd.u32().expect("input count");
        let output_points = rd.u32().expect("output count");
        let original = rd.f64().expect("original distance");
        let processed = rd.f64().expect("processed distance");
        let duration = rd.f64().expect("duration");
        let moving = rd.f64().expect("moving time");
        rd.done("process_track").expect("no trailing bytes");

        let track = Track::new(
            raw.iter()
                .map(|&(lat, lon, ms)| {
                    TrackPoint::new(
                        Timestamp::from_unix_ms(ms),
                        Coordinate::new(lat, lon).expect("valid coordinate"),
                    )
                })
                .collect(),
        )
        .expect("valid track");
        let fixes: Vec<GpsFix> = track
            .points()
            .iter()
            .map(|point| GpsFix {
                timestamp: point.timestamp(),
                coordinate: point.coordinate(),
                accuracy: None,
                altitude: None,
                speed: None,
                bearing: None,
            })
            .collect();
        let adaptive = estimate_fixes(&fixes, &EstimatorConfig::production());

        assert_eq!(input_points, track.len() as u32);
        // The resampled point count may exceed the input count; only the
        // field's position and type are part of the v1 contract.
        assert!(output_points > 0);
        // Miri interprets some platform-specific math rather than executing
        // it, so identical sources can differ in the last bit there.
        if cfg!(miri) {
            assert!((original - track.distance().meters()).abs() < 1e-6);
            assert!((processed - adaptive.distance.meters()).abs() < 1e-6);
        } else {
            assert_eq!(original, track.distance().meters());
            assert_eq!(processed, adaptive.distance.meters());
        }
        assert_eq!(duration, track.duration().as_secs());
        assert_eq!(moving, adaptive.moving.as_secs());

        // The promoted axis is genuinely different from the old resampled
        // geodesic; a byte-stable layout must not hide value drift.
        let (filtered, _) = track.filter(&FilterConfig::default());
        let legacy = filtered
            .resample_by_distance(Distance::from_meters(25.0))
            .expect("resample")
            .distance()
            .meters();
        assert!(
            (processed - legacy).abs() > 1.0,
            "processed={processed} legacy={legacy}"
        );
    }

    fn new_live_handle() -> u64 {
        let mut input = Wr::default();
        input.u8(0); // no route
        input.u8(0); // no ghost
        let bytes = live_new(&input.data).expect("live_new succeeds");
        let mut rd = Rd::new(&bytes);
        let handle = rd.u64().expect("handle");
        rd.done("live_new").expect("handle only");
        handle
    }

    fn new_replay_handle() -> u64 {
        let mut input = Wr::default();
        input.u32(0); // no fixes
        input.u8(0); // no route
        input.u8(0); // no ghost
        let bytes = replay_new(&input.data).expect("replay_new succeeds");
        let mut rd = Rd::new(&bytes);
        let handle = rd.u64().expect("handle");
        rd.done("replay_new").expect("handle only");
        handle
    }

    #[test]
    fn alloc_out_round_trips_empty_normal_large_and_repeated_buffers() {
        // Null is always a valid no-op for the public free function.
        // SAFETY: `gps_free` documents null as a no-op.
        unsafe { gps_free(std::ptr::null_mut()) };

        let payloads: [Vec<u8>; 4] = [Vec::new(), vec![42], vec![7; 4_096], vec![0xAB; 131_073]];
        for payload in payloads {
            let (ptr, len) = alloc_out(payload.clone());
            assert_eq!(len, payload.len());
            // SAFETY: `ptr` is a live `alloc_out` payload of exactly `len`
            // readable bytes and has not been freed yet.
            let bytes = unsafe { slice::from_raw_parts(ptr, len) };
            assert_eq!(bytes, payload);
            // SAFETY: `ptr` is consumed exactly once here.
            unsafe { gps_free(ptr) };
        }

        let mut allocations = Vec::new();
        for value in 0..64u8 {
            let (ptr, len) = alloc_out(vec![value; 17]);
            allocations.push((ptr, len, value));
        }
        for (ptr, len, value) in allocations {
            // SAFETY: every pointer is still live and points at 17 bytes.
            let bytes = unsafe { slice::from_raw_parts(ptr, len) };
            assert_eq!(bytes, &vec![value; 17]);
            // SAFETY: each pointer is freed exactly once.
            unsafe { gps_free(ptr) };
        }
    }

    #[test]
    fn dispatch_rejects_oversized_and_null_inputs_without_dereferencing_them() {
        let mut out: *mut u8 = std::ptr::dangling_mut();
        let mut out_len = usize::MAX;

        // A non-null but deliberately invalid pointer is safe only because the
        // size guard rejects the request before any slice is created.
        let bogus = std::ptr::dangling::<u8>();
        let status = dispatch(
            bogus,
            MAX_INPUT_BYTES + 1,
            &mut out as *mut *mut u8,
            &mut out_len,
            process_track,
        );
        assert_eq!(status, ST_INVALID);
        assert!(out.is_null());
        assert_eq!(out_len, 0);

        let status = dispatch(
            std::ptr::null(),
            1,
            &mut out as *mut *mut u8,
            &mut out_len,
            process_track,
        );
        assert_eq!(status, ST_INVALID);

        let status = dispatch(
            std::ptr::null(),
            0,
            std::ptr::null_mut(),
            &mut out_len,
            process_track,
        );
        assert_eq!(status, ST_INVALID);
    }

    #[test]
    fn dispatch_never_unwinds_and_last_error_stays_a_c_string() {
        let mut out: *mut u8 = std::ptr::dangling_mut();
        let mut out_len = usize::MAX;
        let out_ptr = &mut out as *mut *mut u8;
        let len_ptr = &mut out_len as *mut usize;

        let status = dispatch(std::ptr::null(), 0, out_ptr, len_ptr, |_| panic!("boom"));
        assert_eq!(status, ST_ERROR);
        assert!(out.is_null());
        assert_eq!(out_len, 0);

        let status = dispatch(std::ptr::null(), 0, out_ptr, len_ptr, |_| {
            Err("detail\0with-nul".into())
        });
        assert_eq!(status, ST_ERROR);
        // SAFETY: `gps_last_error` returns a process-lifetime, NUL-terminated
        // C string owned by this thread's `LAST_ERROR` cell.
        let message = unsafe { CStr::from_ptr(gps_last_error()) }
            .to_str()
            .expect("last error is UTF-8");
        assert!(message.contains("detail?with-nul"), "{message}");
    }

    #[test]
    fn handles_reject_invalid_stale_freed_and_cross_type_uses() {
        let live = new_live_handle();
        let replay = new_replay_handle();
        assert_ne!(live, replay);

        with_live(live, |rec| {
            rec.pause();
            Ok(())
        })
        .expect("valid live handle works");
        with_replay(replay, |session| {
            session.pause();
            Ok(())
        })
        .expect("valid replay handle works");

        assert!(with_live(0, |rec| Ok(rec.snapshot())).is_err());
        assert!(with_replay(u64::MAX, |session| Ok(session.snapshot())).is_err());
        assert!(with_replay(live, |session| Ok(session.snapshot())).is_err());
        assert!(with_live(replay, |rec| Ok(rec.snapshot())).is_err());

        free_live_handle(live).expect("first free succeeds");
        assert!(free_live_handle(live).is_err(), "double free is rejected");
        assert!(with_live(live, |rec| Ok(rec.snapshot())).is_err());
        free_replay_handle(replay).expect("first free succeeds");
        assert!(free_replay_handle(replay).is_err());
        assert!(with_replay(replay, |session| Ok(session.snapshot())).is_err());

        // The public free functions must tolerate arbitrary values.
        gps_live_free(live);
        gps_replay_free(replay);
        gps_live_free(0);
        gps_replay_free(u64::MAX);
    }

    #[test]
    fn freed_handle_cannot_alias_a_reused_slot() {
        let first = new_live_handle();
        free_live_handle(first).expect("free first");
        let second = new_live_handle();
        assert_ne!(first, second, "generation must change on reuse");
        assert!(with_live(first, |rec| Ok(rec.snapshot())).is_err());
        with_live(second, |rec| {
            rec.pause();
            Ok(())
        })
        .expect("current handle still works");
        free_live_handle(second).expect("free second");
    }

    #[test]
    fn multiple_handles_keep_independent_state() {
        let a = new_live_handle();
        let b = new_live_handle();
        with_live(a, |rec| {
            rec.seed(Distance::from_meters(100.0), Duration::from_secs(10.0));
            Ok(())
        })
        .expect("seed a");
        let distance_a = with_live(a, |rec| Ok(rec.snapshot().distance.meters())).expect("a");
        let distance_b = with_live(b, |rec| Ok(rec.snapshot().distance.meters())).expect("b");
        assert_eq!(distance_a, 100.0);
        assert_eq!(distance_b, 0.0);
        free_live_handle(a).expect("free a");
        free_live_handle(b).expect("free b");
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn concurrent_handle_operations_are_serialized() {
        let handle = new_live_handle();
        let threads: Vec<_> = (0..8)
            .map(|_| {
                std::thread::spawn(move || {
                    with_live(handle, |rec| {
                        rec.pause();
                        rec.resume();
                        Ok(())
                    })
                    .expect("concurrent operation succeeds");
                })
            })
            .collect();
        for thread in threads {
            thread.join().expect("worker does not panic");
        }
        free_live_handle(handle).expect("free after all users finish");
    }

    #[test]
    #[cfg_attr(miri, ignore)]
    fn free_waits_for_an_in_flight_operation() {
        use std::sync::mpsc;
        use std::time::Duration;

        let handle = new_live_handle();
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            with_live(handle, |rec| {
                entered_tx.send(()).expect("signal entered");
                release_rx.recv().expect("wait for release");
                rec.pause();
                Ok(())
            })
            .expect("operation succeeds");
        });

        entered_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("worker entered");
        let (started_tx, started_rx) = mpsc::channel();
        let (freed_tx, freed_rx) = mpsc::channel();
        let freer = std::thread::spawn(move || {
            started_tx.send(()).expect("signal free started");
            free_live_handle(handle).expect("free succeeds");
            freed_tx.send(()).expect("signal free finished");
        });
        started_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("free started");
        assert!(
            freed_rx.recv_timeout(Duration::from_millis(100)).is_err(),
            "free returned while an operation was still in progress"
        );

        release_tx.send(()).expect("release worker");
        worker.join().expect("worker does not panic");
        freer.join().expect("freer does not panic");
        assert!(
            with_live(handle, |_| Ok(())).is_err(),
            "freed handle must not resolve"
        );
    }

    #[test]
    fn element_counts_are_capped_before_allocation() {
        for (count, label) in [
            ((MAX_POINTS + 1) as u32, "point"),
            ((MAX_COORDINATES + 1) as u32, "coordinate"),
            ((MAX_FIXES + 1) as u32, "fix"),
            ((MAX_SAMPLES_PER_ATTEMPT + 1) as u32, "attempt sample"),
        ] {
            let mut input = Wr::default();
            input.u32(count);
            // The readers reject the count even when the buffer is short,
            // proving the limit is checked before any element loop.
            let message = match label {
                "point" => read_points(&mut Rd::new(&input.data)).unwrap_err(),
                "coordinate" => read_coordinates(&mut Rd::new(&input.data)).unwrap_err(),
                "fix" => read_fixes(&mut Rd::new(&input.data)).unwrap_err(),
                _ => read_attempt(&mut Rd::new(&input.data)).unwrap_err(),
            };
            assert!(message.contains("exceeds limit"), "{label}: {message}");
        }

        let mut segments = Wr::default();
        segments.f64(1_000.0);
        segments.f64(100.0);
        segments.u32((MAX_ATTEMPTS + 1) as u32);
        assert!(
            compare_route_segments_impl(&segments.data)
                .unwrap_err()
                .contains("exceeds limit")
        );

        let mut nested = Wr::default();
        nested.f64(1_000.0);
        nested.f64(100.0);
        nested.u32(1);
        nested.u32((MAX_SAMPLES_PER_ATTEMPT + 1) as u32);
        assert!(
            compare_route_segments_impl(&nested.data)
                .unwrap_err()
                .contains("exceeds limit")
        );
    }

    #[test]
    fn read_fix_validates_optional_sensors() {
        fn fix_bytes(mask: u8, values: &[f64]) -> Vec<u8> {
            let mut w = Wr::default();
            w.f64(52.5);
            w.f64(13.4);
            w.i64(0);
            w.u8(mask);
            for value in values {
                w.f64(*value);
            }
            w.data
        }

        let valid = fix_bytes(0x0F, &[5.0, -12.0, 3.5, 450.0]);
        let fix = read_fix(&mut Rd::new(&valid), 0).expect("valid fix");
        assert_eq!(fix.accuracy.expect("accuracy").meters(), 5.0);
        assert_eq!(fix.altitude, Some(-12.0), "negative altitude is valid");
        assert_eq!(fix.speed.expect("speed").mps(), 3.5);
        assert_eq!(
            fix.bearing.expect("bearing").as_degrees(),
            90.0,
            "finite bearing degrees are normalized"
        );

        for (mask, values, field) in [
            (0x01, &[-1.0][..], "accuracy"),
            (0x02, &[f64::NAN][..], "altitude"),
            (0x04, &[-1.0][..], "speed"),
            (0x08, &[f64::INFINITY][..], "bearing"),
        ] {
            let bytes = fix_bytes(mask, values);
            let error = read_fix(&mut Rd::new(&bytes), 0).unwrap_err();
            assert!(error.contains(field), "{error}");
        }
    }
}
