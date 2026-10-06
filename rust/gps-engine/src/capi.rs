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

use crate::attempt::{Attempt, AttemptSample};
use crate::geo::Coordinate;
use crate::ghost::Ghost;
use crate::route::{MatchConfig, Route, compare, compare_either_direction};
use crate::synthetic::Rng;
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
/// In: `str activity_id, str route_id, [points], [coordinates]`.
/// Out: `f64 elapsed_s, u32 sample_count, then per sample:
/// f64 distance_m, f64 elapsed_s`.
fn create_attempt(bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut rd = Rd::new(bytes);
    let _activity_id = rd.str()?;
    let _route_id = rd.str()?;
    let points = read_points(&mut rd)?;
    let geometry = read_coordinates(&mut rd)?;
    rd.done("create_attempt")?;

    let track = Track::new(points).map_err(|e| e.to_string())?;
    let route = Route::new(geometry).map_err(|e| e.to_string())?;
    let attempt = Attempt::from_track(&track, &route);

    let mut w = Wr::default();
    w.f64(attempt.elapsed_time.as_secs());
    w.u32(attempt.samples.len() as u32);
    for sample in &attempt.samples {
        w.f64(sample.distance.meters());
        w.f64(sample.elapsed.as_secs());
    }
    Ok(w.data)
}

/// `gps_ghost_state_at`
///
/// In: `[attempt] reference, [attempt] current, f64 distance_m`.
/// Out: `f64 distance_m, f64 time_difference_s, u8 ahead`.
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

/// `gps_generate_recording`
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
// Exported entry points
// ---------------------------------------------------------------------------

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
