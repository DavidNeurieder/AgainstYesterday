// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! FFI-boundary safety tests.
//!
//! Only the byte buffer contract is fuzzed: the caller-pointer contract cannot
//! be fuzzed meaningfully, so every request uses valid pointers to owned bytes.
//! These tests assert that arbitrary protocol bytes cannot unwind or leave a
//! stale output pointer behind, even for stateful live/replay entry points.

use std::ffi::c_int;

use gps_engine::capi::{
    gps_analyze_track, gps_compare_route_segments, gps_create_attempt, gps_free,
    gps_generate_recording, gps_ghost_state_at, gps_live_finish, gps_live_ghost_gap, gps_live_new,
    gps_live_pause, gps_live_push, gps_live_resume, gps_live_seed, gps_live_set_ghost,
    gps_live_snapshot, gps_match_routes, gps_pace_analysis, gps_process_track, gps_replay_advance,
    gps_replay_new, gps_replay_pause, gps_replay_play, gps_replay_seek, gps_replay_set_speed,
    gps_replay_snapshot, gps_route_info, gps_route_progression, gps_route_rank, gps_route_stats,
};
use proptest::prelude::*;

type EntryPoint = unsafe extern "C" fn(*const u8, usize, *mut *mut u8, *mut usize) -> c_int;

/// Every request/response entry point in the v1 ABI.
const ENTRY_POINTS: &[EntryPoint] = &[
    gps_process_track,
    gps_match_routes,
    gps_create_attempt,
    gps_compare_route_segments,
    gps_ghost_state_at,
    gps_live_ghost_gap,
    gps_generate_recording,
    gps_route_info,
    gps_live_new,
    gps_live_push,
    gps_live_pause,
    gps_live_resume,
    gps_live_finish,
    gps_live_seed,
    gps_live_set_ghost,
    gps_live_snapshot,
    gps_replay_new,
    gps_replay_play,
    gps_replay_pause,
    gps_replay_seek,
    gps_replay_set_speed,
    gps_replay_advance,
    gps_replay_snapshot,
    gps_analyze_track,
    gps_route_stats,
    gps_route_progression,
    gps_route_rank,
    gps_pace_analysis,
];

/// Calls one entry point with a valid request buffer and checks the out-params
/// before releasing any returned allocation.
fn call(entry: EntryPoint, bytes: &[u8]) -> c_int {
    // A sentinel proves a failed call clears stale output state.
    let mut out: *mut u8 = std::ptr::dangling_mut::<u8>();
    let mut out_len = usize::MAX;
    // SAFETY: `bytes` is a live slice of `bytes.len()` readable bytes, and the
    // two out-params point at writable locals for the duration of the call.
    let status = unsafe { entry(bytes.as_ptr(), bytes.len(), &mut out, &mut out_len) };

    assert!((0..=2).contains(&status), "unknown status {status}");
    if status == 0 {
        assert!(
            !out.is_null(),
            "successful calls return an allocated buffer"
        );
        // SAFETY: status 0 promises exactly one `alloc_out` buffer in `out`.
        unsafe { gps_free(out) };
    } else {
        assert!(out.is_null(), "failed calls must not leave a stale pointer");
        assert_eq!(out_len, 0);
    }
    status
}

/// Miri interprets proptest's file persistence and is much slower, so keep the
/// same boundary coverage with fewer cases and no filesystem access there.
fn config() -> ProptestConfig {
    let mut config = ProptestConfig::with_cases(if cfg!(miri) { 16 } else { 256 });
    config.failure_persistence = None;
    config
}

proptest! {
    #![proptest_config(config())]

    #[test]
    fn arbitrary_request_bytes_never_unwind(bytes in prop::collection::vec(any::<u8>(), 0..512)) {
        for entry in ENTRY_POINTS {
            call(*entry, &bytes);
        }
    }
}

#[test]
fn null_request_and_null_out_params_are_rejected() {
    for entry in ENTRY_POINTS {
        // A null input with zero length is a valid empty request; handlers may
        // reject its contents, but must clear the out-params and never unwind.
        let status = call(*entry, &[]);
        assert_ne!(status, 0);

        // The engine returns before touching out-params when `output` is null,
        // so only the status is observable here.
        let status = unsafe { entry(std::ptr::null(), 0, std::ptr::null_mut(), &mut 0usize) };
        assert_eq!(status, 1, "null out-param is malformed input");
    }

    // SAFETY: null is a documented no-op.
    unsafe { gps_free(std::ptr::null_mut()) };
}
