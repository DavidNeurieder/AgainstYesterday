# Route matching v3 — M0 audit & baseline

Date: 2026-06-08  
Branch: `improve_app` (HEAD `26f90b5` at audit start)

This note captures the current implementation, contracts, and the policy decisions used for M1–M7. It is the M0 deliverable: verify before changing, and keep `FakeEngineService`/tests in parity with any engine behavior change.

## 1. End-to-end flow (current)

### Live recording
- **Entry/UI:** `recording_controller.dart` (`recordingControllerProvider`, persistent) drives the run state machine (`preparing → gpsAcquiring → ready → running ⇄ paused → finishing → completed`).
- **Fix sources:** device GPS via `DeviceGpsSource`/geolocator when `USE_DEVICE_GPS=true` (and Android foreground `location` service managed by `RunForegroundLifespan`/`RecordingForegroundService`), otherwise a deterministic scenario/demo timeline (`_FakeLiveRun`/scenario ticks).
- **Engine handle:** `EngineService.createLiveRun({route, ghostSamples})` returns a `LiveRunHandle`.
  - Rust: `gps_live_new` (`rust/gps-engine/src/capi.rs`) builds `LiveRecorder` (`rust/gps-engine/src/live/mod.rs`) with optional `Route` geometry and optional `LiveGhost` samples. Push/pause/resume/finish/seed/setGhost/free exposed over FFI.
  - Fake: `_FakeLiveRun` in `app/lib/engine/fake_engine.dart` mirrors behavior for host tests.
- **Ownership split:** Rust/fake handle owns live calculations (filtering, distance, moving time, pace, route progress/off-route, ghost, match status/confidence). Dart owns the raw-fix buffer (`_RecSession.rawFixes`), wall-clock/timer/foreground lifecycle, snapshot persistence, and post-run finalization.
- **State to UI:** `LiveSnapshot` (engine) → `LiveRunState` (Dart, includes `matchStatus` int, `matchConfidence`, track derived from raw fixes for map) via controller `_emit`.

### Persistence / recovery
- **In-progress:** `RunSnapshot` persisted via `RunSnapshotRepository` (`persistence.dart`), serialized in `serialization.dart` (`runSnapshotToJson`/`parseRunSnapshot`).
  - Fields today: `status`, `startedAt`, `movingSeconds`, `clockSeconds`, `distanceMeters`, `loopMeters`, `routeId` (no raw-fix list, no track, no ghost/match context embedded in snapshot model).
  - Recovery: `resumeFromSnapshot` restores session/timers and recreates handle context as available; exact restored fidelity (raw fixes, ghost, on-route progress) must be preserved/hardened in M1 (treat as audit finding: snapshot is lossy relative to full in-memory session).
- **Completed activity:** `_persistCompletedRun` builds `Activity` with `id`, optional `routeId`, `startedAt`, `duration`, `distance`, processed `track` (`_synthesizeTrack` from raw fixes when no richer track), and `rawFixes` (`List.unmodifiable(session.rawFixes)`), then saves via `ActivityRepository`. Route assignment for route-less runs is attempted once here via `_recognizeRoute`.

### Route matching today
- **Pairwise comparison API:** `EngineService.matchRoutes({a,b})` / `gps_match_routes` (`capi.rs::match_routes`) builds `Track`s and returns `MatchScore` + `sameRoute` using `compare` + `compare_either_direction(..., MatchConfig::default())` (`rust/gps-engine/src/route/matching.rs`).
  - `MatchConfig::default()`: lateral tolerance 25 m, `min_spatial_overlap` 0.6, `distance_ratio` 0.70–1.45, `max_start_distance` 150 m, `max_end_distance` 150 m. `is_match()` requires proximity, ratio, and overlap (direction not part of boolean; `direction_similarity` reported). Continuity is reported but not in the boolean/overall decision as coded.
  - Reverse direction: `compare_either_direction` can accept reversed runs for identity (direction reported separately) — pairwise only.
- **Live continuity matcher:** `RouteMatcher` (`rust/gps-engine/src/route/mod.rs`) is stateful, windowed, with hysteresis and states `Initializing/Matched/Uncertain/OffRoute/Reacquiring`; used by `LiveRecorder` only when a route is attached. Exposed as `LiveMatchStatus`/confidence in snapshots.
- **Final selection (Dart, current):** `_recognizeRoute` scores every stored route (`route.geometry` converted to a synthetic timed track), keeps best `sameRoute` with `overallScore > 0.5` and `track.length >= 5` (`aa4a9eb`). No live catalog recognition for free runs.
- **Route discovery/catalog:** `rust/gps-engine/src/route/discovery.rs` provides `RouteCatalog`/`DiscoveredRoute`/`TrackAddition` (incremental clustering, compares against representatives using prepared geometry, picks best overall score or seeds new). Not currently wired into live recognition/final classification flows in the app path audited here (verify usage before relying on it).

## 2. Distance/time semantics (must preserve)

- **On route (`LiveRecorder` with route):** progress/distance axis is route **coverage** (running max projection along route) — monotone, prevents rewind on loops/crossings/jumps. Moving time gated by ground speed >= motion floor (not jump withholding). Off-route reported from continuity match/lateral error; finish-snap behavior exists (`FINISH_SNAP_M`).
- **Free run:** filtered geodesic axis via `FilterCursor` (engine filter/jump classification and motion semantics). No route coverage.
- **Active/clock elapsed:** controller tracks wall-clock stopwatch (`clockElapsed`) separately from moving elapsed used for PB/ghost comparisons; ghost gap comparisons must use the correct axis/time basis (stationary-gap fix already uses active/moving semantics per recent commits — do not regress).
- **Invariant:** matching/ghost must never reset or corrupt recorded distance/moving/elapsed totals; raw fixes and recorded track remain the source record.

## 3. Gaps vs plan

- No live multi-route/candidate recognition for free runs; no mid-run ghost start on a discovered route.
- `matchRoutes` is pairwise/stateless; final classification is Dart-side best-score selection, not a deterministic policy engine (partial/attempt eligibility, reverse/branch/model consistency, idempotent reprocessing not formalized).
- Current `MatchConfig`/`is_match` rejects many partial/late-join cases (ratio/overlap/start-end proximity) — identity vs full-attempt policy must be separated.
- `RunSnapshot` does not persist raw fixes/track/ghost context; recovery fidelity is limited (harden in M1).
- Match status is an int code in Dart models/live state; existing pairwise `RouteMatchResult` name will collide with proposed live/final result types (M5).
- `FakeEngineService` must mirror any new live recognition/classification behavior.

## 4. Policy decisions (defaults for implementation; calibrate with fixtures)

These defaults are chosen to be conservative and data-safe. They should live in centralized engine config and be tuned with fixtures/real traces (M7).

- **Identity match (provisional/final association candidate):** requires sustained geometric/directional/continuity evidence above a configurable confidence; allows partial coverage and mid-route joins when unambiguous. Ambiguity (e.g. out-and-back multiple plausible progress positions, parallel streets, weak GPS) => non-confident / no progress claim.
- **Full-course attempt (PB/attempt eligible):** identity-matched **and** coverage >= 90% of route length (configurable), direction consistent with route’s attempt model, minimum quality/length satisfied, and end-state consistent with a complete pass (tolerant finish window). A partial but identity-matched activity is a valid saved activity: classify as *partial association* if representable, otherwise **unclassified** (never counted as full PB attempt, never forced into wrong route).
- **New route creation:** only from finalized, sufficiently long and good-quality recordings that are not confidently explained by any existing route (per policy margin). Do not create routes from tiny/noisy traces.
- **Reverse direction:** pairwise geometry may be similar, but live progress/PB comparison is directional. Default: treat reverse as **not** a same-direction full attempt; classify consistently with existing route/history model (separate directional handling) — confirm/adjust in M4 against current data model.
- **Live ghost display:** only when match is confident, route/progress is unambiguous, and comparison basis is meaningful; no jump on first match (baseline/smoothing/hold). Degrade on uncertainty/off-route/dropout.
- **Idempotency:** final classification/persistence must be safe to re-run (no duplicate route/attempt links, no PB regression, stable outcome for same inputs); failed classification leaves activity saved.

## 5. M0 acceptance

- Baseline/contracts/gaps documented (this file).
- Invariants and policy defaults recorded for implementation and testing; refine with evidence during M1–M4.
- Next: **M1** harden recording independence/recovery and add invariant tests + fake parity.
