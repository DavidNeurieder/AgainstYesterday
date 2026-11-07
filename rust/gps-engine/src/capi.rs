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
use std::ffi::{CStr, CString, c_char, c_int};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::sync::Arc;

use crate::attempt::{Attempt, AttemptAxis, AttemptSample, MovingAxisConfig};
use crate::geo::{Coordinate, polyline_length};
use crate::ghost::Ghost;
use crate::gps::GpsFix;
use crate::live::{LiveConfig, LiveGhost, LiveRecorder};
use crate::route::{MatchConfig, Route, compare, compare_either_direction};
use crate::synthetic::Rng;
use crate::track::segments::compare_route_segments;
use crate::track::{FilterConfig, MovingConfig, Track, TrackPoint};
use crate::units::{Distance, Duration, Timestamp};

/// Success.
const ST_OK: c_int = 0;
/// Malformed input buffer.
const ST_INVALID: c_int = 1;
/// Engine error (see [`gps_last_error`]).
const ST_ERROR: c_int = 2;

thread_local! {
    static LAST_ERROR: RefCell<Arc<CStr>> =
        RefCell::new(Arc::from(c"ok"));
}

fn set_error(msg: &str) {
    LAST_ERROR.with(|cell| {
        let mut text = msg.as_bytes().to_vec();
        text.push(0);
        *cell.borrow_mut() =
            Arc::from(CStr::from_bytes_with_nul(&text).expect("last error is valid UTF-8 + NUL"));
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
/// An 8-byte little-endian length header written by [`alloc_out`] just before
/// the payload is read back so the allocation can be restored exactly.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_free(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }

    // SAFETY: `ptr` is the payload of a successful earlier `alloc_out`, which
    // wrote an 8-byte length header immediately before it.
    let len = unsafe { *(ptr as *mut u64).offset(-1) } as usize;
    // SAFETY: reconstructing `len + 8` bytes starting 8 before `ptr` restores
    // the exact allocation made by `alloc_out`.
    let full = unsafe { slice::from_raw_parts_mut(ptr.offset(-8), len + 8) };
    // SAFETY: `full` was returned by the allocator as a `Box<[u8]>`, so
    // `from_raw` + drop is the uniquely-owning free.
    unsafe {
        drop(Box::from_raw(full));
    }
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

/// Allocates a payload buffer with an 8-byte little-endian length header;
/// returns a pointer to the payload (after the header) plus its length.
fn alloc_out(bytes: Vec<u8>) -> (*mut u8, usize) {
    let len = bytes.len();
    let mut vec = Vec::with_capacity(len + 8);
    vec.extend_from_slice(&(len as u64).to_le_bytes());
    vec.extend_from_slice(&bytes);
    let head = vec.as_mut_ptr();
    std::mem::forget(vec);

    // SAFETY: `head` points at the start of an allocation of at least 8
    // bytes; adding 8 lands inside it, aligned for `u8`.
    (unsafe { head.add(8) }, len)
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
    if (input.is_null() && input_len > 0) || output.is_null() || output_len.is_null() {
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
    match catch_unwind(AssertUnwindSafe(|| handler(data))) {
        Ok(Ok(bytes)) => {
            let (ptr, len) = alloc_out(bytes);

            // SAFETY: the caller promised `output`/`output_len` point to
            // writable storage.
            unsafe {
                *output = ptr;
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

/// `[u32 n]` then per point: `f64 lat, f64 lon, u8 has_altitude, [f64 altitude],
/// i64 unix-ms timestamp`.
fn read_points(rd: &mut Rd<'_>) -> Result<Vec<TrackPoint>, String> {
    let n = rd.u32()? as usize;
    let mut out = Vec::with_capacity(n.min(1_000_000));
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
    let n = rd.u32()? as usize;
    let mut out = Vec::with_capacity(n.min(1_000_000));
    for i in 0..n {
        let lat = rd.f64()?;
        let lon = rd.f64()?;
        out.push(Coordinate::new(lat, lon).map_err(|e| format!("coordinate {i}: {e}"))?);
    }
    Ok(out)
}

#[allow(dead_code)]
/// `[u32 n]` then per fix:
/// `f64 lat, f64 lon, i64 unix-ms, u8 mask, [f64]*` where mask bit 0 =
/// accuracy (m), 1 = altitude (m), 2 = speed (m/s), 3 = bearing (deg).
fn read_fixes(rd: &mut Rd<'_>) -> Result<Vec<GpsFix>, String> {
    let n = rd.u32()? as usize;
    let mut out = Vec::with_capacity(n.min(1_000_000));
    for i in 0..n {
        out.push(read_fix(rd, i)?);
    }
    Ok(out)
}

fn read_fix(rd: &mut Rd<'_>, i: usize) -> Result<GpsFix, String> {
    let lat = rd.f64()?;
    let lon = rd.f64()?;
    let coord = Coordinate::new(lat, lon).map_err(|e| format!("fix {i}: {e}"))?;
    let timestamp = Timestamp::from_unix_ms(rd.i64()?);
    let mask = rd.u8()?;
    let mut fix = GpsFix::new(timestamp, coord);
    if mask & 0x01 != 0 {
        fix.accuracy = Some(Distance::from_meters(rd.f64()?));
    }
    if mask & 0x02 != 0 {
        fix.altitude = Some(rd.f64()?);
    }
    if mask & 0x04 != 0 {
        fix.speed = Some(crate::units::Speed::from_mps(rd.f64()?));
    }
    if mask & 0x08 != 0 {
        let degrees = rd.f64()?;
        fix.bearing = crate::geo::Bearing::from_degrees(degrees).ok();
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
    let n = rd.u32()? as usize;
    let mut out = Vec::with_capacity(n.min(1_000_000));
    for _ in 0..n {
        let distance = Distance::from_meters(rd.f64()?);
        let elapsed = Duration::from_secs(rd.f64()?);
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
    let (filtered, _report) = track.filter(&FilterConfig::default());
    let processed = filtered
        .resample_by_distance(Distance::from_meters(25.0))
        .map_err(|e| e.to_string())?;
    let duration = track.duration().as_secs();
    let moving = track.moving_duration(&MovingConfig::default()).as_secs();

    let mut w = Wr::default();
    w.u32(track.len() as u32);
    w.u32(processed.len() as u32);
    w.f64(original);
    w.f64(processed.distance().meters());
    w.f64(duration);
    w.f64(moving);
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
    let route_distance = Distance::from_meters(rd.f64()?);
    let segment_distance = Distance::from_meters(rd.f64()?);
    let attempt_count = rd.u32()? as usize;
    let mut attempts = Vec::with_capacity(attempt_count.min(1_000_000));
    for _ in 0..attempt_count {
        let n = rd.u32()? as usize;
        let mut samples = Vec::with_capacity(n.min(1_000_000));
        for _ in 0..n {
            let distance = Distance::from_meters(rd.f64()?);
            let elapsed = Duration::from_secs(rd.f64()?);
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
    let distance = Distance::from_meters(rd.f64()?);
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
    let current_distance = Distance::from_meters(rd.f64()?);
    let moving_seconds = Duration::from_secs(rd.f64()?);
    let loop_length = Distance::from_meters(rd.f64()?);
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
    let handle = (Box::into_raw(Box::new(rec)) as usize) as u64;
    let mut w = Wr::default();
    w.u64(handle);
    Ok(w.data)
}

/// # Safety
/// `handle` must be a live handle returned by `gps_live_new` and not yet freed.
unsafe fn live_ref(handle: u64) -> Result<&'static mut LiveRecorder, String> {
    if handle == 0 {
        return Err("null live handle".into());
    }
    // SAFETY: the handle was produced by `Box::into_raw` in `live_new` and is
    // valid until `gps_live_free` consumes it. The caller owns the handle and
    // does not alias it across threads.
    Ok(unsafe { &mut *(handle as usize as *mut LiveRecorder) })
}

fn live_push(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let fix = read_fix(&mut rd, 0)?;
    rd.done("live_push")?;
    // SAFETY: see `live_ref`.
    // SAFETY: see `live_ref`.
    let rec = unsafe { live_ref(handle)? };
    rec.push(fix);
    Ok(Vec::new())
}

fn live_pause(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_pause")?;
    // SAFETY: see `live_ref`.
    unsafe { live_ref(handle)? }.pause();
    Ok(Vec::new())
}

fn live_resume(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_resume")?;
    // SAFETY: see `live_ref`.
    unsafe { live_ref(handle)? }.resume();
    Ok(Vec::new())
}

fn live_finish(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_finish")?;
    // SAFETY: see `live_ref`.
    unsafe { live_ref(handle)? }.finish();
    Ok(Vec::new())
}

fn live_seed(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let distance = Distance::from_meters(rd.f64()?);
    let moving = Duration::from_secs(rd.f64()?);
    rd.done("live_seed")?;
    // SAFETY: see `live_ref`.
    unsafe { live_ref(handle)? }.seed(distance, moving);
    Ok(Vec::new())
}

fn live_set_ghost(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    let ghost = read_live_ghost(&mut rd)?;
    rd.done("live_set_ghost")?;
    // SAFETY: see `live_ref`.
    unsafe { live_ref(handle)? }.set_ghost(ghost);
    Ok(Vec::new())
}

fn live_snapshot(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let handle = rd.u64()?;
    rd.done("live_snapshot")?;
    // SAFETY: see `live_ref`.
    let rec = unsafe { live_ref(handle)? };
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
    Ok(w.data)
}

/// Frees a live handle returned by `gps_live_new`. Null is ignored.
///
/// # Safety
/// `handle` must be a live handle from `gps_live_new`, or zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gps_live_free(handle: u64) {
    if handle == 0 {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: see `live_ref`; this consumes the handle exactly once.
        unsafe {
            drop(Box::from_raw(handle as usize as *mut LiveRecorder));
        }
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
}
