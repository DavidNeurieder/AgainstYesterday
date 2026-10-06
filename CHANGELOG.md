# Changelog

All notable changes to `gps_app` (Flutter client + `gps-engine` Rust crate) are
documented here, grouped by the implementation milestones in
`specification/app_implementation_plan.txt`.

---

## [Unreleased]

### Fixes

- Attempt dates were labelled from *elapsed* time rather than calendar days, so
  on a daylight-saving day — when consecutive local midnights are 23 hours apart
  — a date that was clearly yesterday came out as "Today". Labelling now
  compares year/month/day fields in UTC (`calendarDayDifference`), where every
  day is 24 hours, so the result never depends on the machine's timezone or on
  a transition falling between the two dates. CI runs the date tests a second
  time under `TZ=Europe/Berlin` so the 23-hour day is actually exercised.
- `route_library_test.dart` pinned the attempt list to the label `Yesterday`,
  but the seeded activity is a fixed 26 hours old, so between 00:00 and 02:00
  the app correctly renders an absolute date and the test failed — a nightly CI
  flake. The label formatting is now `dateLabelFor(d, {now})` with an
  injectable clock, the widget test asserts a valid label shape, and four unit
  tests cover the relative/absolute branches directly.
- `rust_engine_test.dart` declared `late RustEngineService? engine`, so when the
  `cdylib` was absent the intended `markTestSkipped` path instead threw
  `LateInitializationError` — six hard failures on any machine without a Rust
  build. The tests now skip cleanly (and CI builds the `cdylib` so they run for
  real).
- CI: the `flutter` job now runs `cargo build --release -p gps-engine` before
  `flutter test`, so the FFI suites execute against the real engine rather than
  skipping. The `android-engine-lib` job no longer uses
  `android-actions/setup-android@v3`, which fails on the current runner image
  ("Wrong version in preinstalled sdkmanager"); it relies on the image's
  preinstalled SDK/NDK and logs what it found. The on-device job downloads the
  verified x86_64 `cdylib` from that matrix job instead of rebuilding it.

### Tooling

- **Deterministic Android NDK.** `build_rust_engine_android.sh` no longer
  picks "the newest installed NDK" (which depended on directory order and moved
  with the runner image). It now resolves, in order: `ANDROID_NDK_HOME`,
  `ANDROID_NDK_VERSION`, or a single unambiguous install — and fails with
  guidance when none of those holds. CI installs and exports
  `ANDROID_NDK_HOME=28.2.13676358`, the version `flutter.ndkVersion`
  hardcodes and Gradle therefore requires, and reports the Android SDK, NDK and
  Rust versions before cross-compiling.
- `app/tool/build_rust_engine_android.sh` cross-compiles the `gps-engine`
  `cdylib` for Android (arm64-v8a and x86_64 by default, API 24) using the NDK
  clang linker and installs it into `app/android/app/src/main/jniLibs/<abi>/`,
  so `--dart-define=USE_RUST_ENGINE=true` builds resolve the bare library name
  `libgps_engine.so` through the platform loader. Previously the Android +
  native-engine build had no documented or automated path.
- Fixed `app/tool/android_integration_test.sh` consuming its first argument as
  the AVD name unconditionally, which made it impossible to pass any flag
  through to `flutter test` (for example `--dart-define=USE_RUST_ENGINE=true`).
  A leading non-flag argument still names the AVD; `ANDROID_AVD` and
  `ANDROID_SERIAL` now override the AVD and serial.
- CI: a new `android-engine-lib` matrix job cross-compiles the `cdylib` per
  Android ABI and fails if any of the eight Dart FFI symbols is missing, and the
  on-device E2E job now runs against the real Rust engine instead of the fake
  one.
- **Skips are not a silent fallback in CI.** The Rust FFI suites skip
  themselves when the `cdylib` is unbuilt, which is right locally but would let
  a misconfigured CI job go green with less coverage than it advertises. They
  now take `--dart-define=REQUIRE_RUST_ENGINE=true` (set by the `flutter` job)
  and fail instead, naming the exact build command to run.

### Licensing

- The whole repository (`gps-engine` crate and Flutter app) is relicensed from
  `MIT OR Apache-2.0` to **`AGPL-3.0-or-later`**: SPDX id in the workspace
  `Cargo.toml` (inherited by the crate) and in `app/pubspec.yaml`, with the
  full text added as `LICENSE` at the repository root.

### M15 — Real-world reliability

**Rust engine (`gps-engine`)** — the raw-GPS quality pipeline and its replay
safety net:

- **`gps` module** — `GpsFix`/`GpsTrace` with a hand-rolled JSON codec (no
  serde): the trace normalizes late/out-of-order fixes, then filters by dropped
  duplicates, first-fix sink, accuracy, jump distance, gap and impossible speed
  (`FilterReason`), while every raw sample is retained with its
  accepted/rejected decision (`GpsQuality` grading). JSON is
  panic-free on arbitrary bytes and idempotent (round-trip proptest).
- **Replay fixtures** — `examples/generate_fixtures.rs` writes five
  deterministic raw-GPS fixtures (`tests/fixtures/`): clean loop, jitter,
  jump, dropout, out-and-back. `tests/gps_torture.rs` replays each through the
  pipeline and asserts acceptance audit, route coverage and corridor
  invariants; `tests/gps_properties.rs` fuzzes the parser and the audit
  invariant.
- **Ghost geometry invariants** — `GhostSnapshot` with distance, elapsed
  current/PB, gap, ahead/behind and a sample-spacing `confidence`
  (`conf_at_<10 m = 1.0`, `>60 m = 0.0`), plus interpolation proxy tests.
- **Continuity-aware matching** — `ContinuityConfig` (speed-bounded forward
  window with a max backtracking tolerance; `best_forward_candidate`)
  eliminates nearest-point jump artifacts on out-and-back routes, exposed as
  `MatchScore.continuity` (deliberately not folded into `overall_score`).
- Test counts are updated in the README; `cargo clippy --all-targets` and
  `cargo fmt --check` stay clean.

**Flutter app** — developer diagnostics (M15 Phase 10):

- `DEV_TOOLS` build gate (`--dart-define=DEV_TOOLS=true`); a bug-report button
  floats on the shell and opens `/dev/diagnostics`, always route-registered.
- `DiagnosticsScreen` — live readout of ENGINE (fake vs Rust + version), GPS
  (raw fix, quality, pace), TRACK (elapsed/distance/session points), ROUTE,
  GHOST (ahead/behind gap) and PERSISTENCE (recovery snapshot availability).
- One-tap **Export run as fixture JSON** copies the in-flight track (or the
  most recent saved run) in the M15 fixture schema, so a real-GPS bug can be
  pasted into `tests/fixtures/` and replayed (Phase 6/12 workflow).
- `LiveRunState` carries `startedAt` for diagnostics; `EngineService` exposes
  `engineDescription`.
- Tests: `test/diagnostics_test.dart` (gate, engine identity, live GPS/TRACK/
  GHOST readout, backgrounded snapshot, clipboard export). Flutter suite now
  159 tests.

### M15.10 — Diagnostics & fixture reliability

**Rust engine (`gps-engine`)** — fixture-schema hardening:

- `schema_version: 1` is written by `Fixture::to_json`/`GpsTrace::to_json` and
  validated by `Fixture::from_json`: legacy versionless fixtures still parse,
  newer versions are rejected with an actionable message.
- Optional sensor fields may be explicit JSON `null` (equivalent to missing),
  matching the Flutter exporter's self-describing output.
- `tests/gps_schema.rs` pins the contract — including the exact document the
  Flutter exporter emits — and `tests/gps_pipeline.rs` exercises the whole
  raw → filter/quality → continuity projection → ghost pipeline.
- Fixtures regenerated with `schema_version`.

**Flutter app** — raw-fix retention and honest exports:

- `GpsFix` raw observations are retained for the whole session
  (`RecordingController.currentFixes()`) and persisted additively with the
  completed `Activity` (`raw_fixes`), instead of keeping only the derived 25 m
  track.
- `fixture_export.dart` consumes the raw `GpsFix`es, writes `schema_version`,
  and emits missing sensor fields as explicit `null`; it never fabricates
  accuracy/altitude/speed/bearing (the old constant defaults are gone).
- Export refuses, with an explicit message, when no route geometry is
  available — demo geometry is never silently substituted. A privacy warning
  guards the clipboard copy, and the diagnostics screen reads one
  `DiagnosticsSnapshot` aggregate instead of probing repositories.
- `/dev/diagnostics` is gated in the router as well as in the shell.
- Tests: `test/fixture_export_test.dart` (schema, empty/single/multiple/
  out-of-order traces, absent fields, poor accuracy, large trace) and expanded
  `test/diagnostics_test.dart` (route gate, privacy cancel/confirm, route-less
  refusal). Flutter suite now 169 tests, and it is engine-agnostic: the same
  169 pass against the real Rust engine
  (`--dart-define=USE_RUST_ENGINE=true --dart-define=GPS_ENGINE_LIB=…`).

---

- **Test expansion** (per `ideas/test_plan.txt`) — Flutter suite grows from 89
  to 153 tests, closing behavioural gaps:
  - `test/state_machine_test.dart` — invalid transitions are strict no-ops
    (pause/finish before running, resume while running, double-pause,
    double-finish, second `beginRun`, `ensureSession`, resume-after-completion),
    GPS quality reduced→good through acquisition, distance/pace invariants at
    the loop seam.
  - `test/pause_resume_test.dart` — paused time never counts toward moving time
    or distance (multi-pause, immediate-pause, 1-second run, resume/immediate
    finish).
  - `test/persistence_recovery_test.dart` — snapshot cleared on finish,
    stale/unknown `routeId` resumes safely on river-loop geometry, headless
    runs clamp at `polylineMeters(riverLoop)`, malformed/missing/null snapshot
    documents degrade to `null`, corrupt history falls back to seeds.
  - `test/geometry_invariants_test.dart` — haversine symmetry/non-negativity/
    known reference (1° ≈ 111.19 km)/antimeridian/poles ≈ π·R; polyline
    monotonicity; `pointAlongPolyline` boundaries.
- `test/splits_boundary_test.dart` — 0.999/1.000/1.001 km thresholds,
    margin-beating the PB flips every delta negative, per-split pacing honesty.
- **UI state coverage** (`test/ui_state_test.dart`, plan Phase 11) — what the
  record flow *shows* at every phase: START disabled + hourglass while
  acquiring, controls flipping running→PAUSE / paused→RESUME, completed showing
  neither pause nor finish, and rapid pause/resume switching converging on a
  coherent state.
- **Lifecycle hygiene** (`test/failure_injection_test.dart`, plan Phase 14) — an
  active run must not leak its 2 Hz ticker into a disposed provider; regression
  guard for the on-device relaunch scenario.
- **Failure injection** (`test/failure_injection_test.dart`, plan Phase 13) —
  a dead storage backend and failing route matching must degrade safely. Fixes
  landed in `persistence/` and the controller:
  - storage reads/writes are best-effort (`_readBestEffort` /
    `_writeBestEffort`): a failed disk write no longer surfaces as an unhandled
    async exception from snapshots, finishes, or dismissals; the in-memory
    repositories stay authoritative.
  - repository `build()`s also catch `TypeError` (valid JSON, wrong shape), so
    malformed-but-parseable documents fall back to seeds instead of exploding.
  - `_persistCompletedRun` catches the whole persist pipeline (including a
    failing engine `matchRoutes` on headless finishes) and re-emits the
    completed summary with `hasUnsavedData` set rather than crashing.
- **Integration tests** — on-device E2E suite (`integration_test/app_test.dart`):
  full run journey (Home → START → pause/resume → finish → result → history),
  route-library browsing, and an interrupted-run restore across app relaunch
  (Phase 12: background snapshot → process death → resumed distance grows and
  completing clears the snapshot). Verified green on a real Samsung device and
  an Android 16 (x86_64) emulator.
- **Android emulator runner** — `app/tool/android_integration_test.sh` boots a
  headless AVD (default `test_phone`) and runs the suite against it; CI gained
  a `flutter analyze`/`flutter test` job and an `android-integration-test` job
  (`reactivecircus/android-emulator-runner`).

---

## 2026-09-14

### M14 — Polish

- **Animations** — record-flow phases crossfade and slide between pre-run /
  live / complete; the PAUSED overlay fades in and out; the PB gap color flips
  crossfade instead of snapping; the run-complete headline springs in
  (`easeOutBack`).
- **Haptics** — tactile feedback on START, PAUSE/RESUME, FINISH, VIEW RESULT,
  DONE, and route/activity card taps.
- **Accessibility** — spoken semantic labels for the PB gap and map markers
  (decorative text excluded); raised muted-text contrast to WCAG-AA on both
  surfaces; theme-scaled text on the START button, GPS pill, and map label.
- **Error handling** — engine/preparation failures surface as a real error
  state (previously never emitted) with a `Try again` recovery path.
- **Empty & loading states** — inline empty hints on Home for no activities /
  no routes; an hourglass GPS cue while acquiring a fix.
- **Battery & performance** — `RepaintBoundary` isolates the live map layer so
  2 Hz tick repaints don't bleed into the rest of the UI.

### M13 — Background recording

- Wall-clock (drift-free) elapsed timing via `package:clock`, so throttled or
  suspended background timers can't inflate pace.
- `WidgetsBindingObserver` lifecycle forwarding on `GpsApp`; backgrounding
  snapshots the run immediately, foregrounding resyncs the clock.
- Interrupted-run recovery: `RunSnapshot` (status, started-at, moving time,
  distance, loop, route) is persisted and resumed on next launch.
- Tests: `test/lifecycle_test.dart` (snapshot round-trip, throttled snapshots,
  lifecycle snapshot, resume/dismiss semantics, end-to-end backgrounding).

### M12 — Route library

- Routes tab with course cards (silhouette, runs count, PB) and route detail:
  static map, PB / Average / Last stats, a performance bar chart with a dashed
  PB baseline, and attempt history (`Today` / `Yesterday` / date labels).
- `computeRouteStats` merges seeded counters with real attempt history.
- Tests: `test/route_stats_test.dart`, `test/route_library_test.dart`.

### M11 — Results

- Run-complete interstitial with `NEW PERSONAL BEST` detection, VIEW RESULT
  and DONE actions.
- Result screen with per-km splits — cumulative deltas against the PB — plus
  activity detail from Home history.
- Split logic in `features/result/application/splits.dart`.
- Tests: `test/splits_test.dart`, extended `recording_flow_test.dart`.

### M10 — Persistence

- Repository layer over a pluggable store: `JsonFileStore` (device),
  `MemoryPersistenceStore` (tests), `NoopPersistenceStore` (default).
- Finished runs saved as activities; routes and history loaded reactively.
- Activity icons link to their detail screen from Home.

---

## 2026-09-13

### M9 — Rust integration

- `RustEngineService` FFI bridge over the `gps-engine` crate (`cdylib`).
- `EngineService` abstraction consumed everywhere; build-time switch via
  `--dart-define=USE_RUST_ENGINE=true` and `GPS_ENGINE_LIB`.
- Ghost preparation, route matching, and recording generation work with either
  engine behind the same facade.

### M8 — Map

- Self-contained `RouteMap` painter: route trace, travelled portion, YOU and
  PB-ghost markers, follow camera, pan, and a `Recenter` button.

### M7 — Live run UI

- Live screen: distance, moving time, pace, the hero PB gap, pause/resume and
  finish controls, plus a GPS-quality pill.

### M6 — Recording state machine

- `RecordingController` (Riverpod `Notifier`) implementing
  `preparing → gpsAcquiring → ready → running ⇄ paused → finishing → completed`.

### M5 — Home

- Greeting, "Start a run" primary action, route cards and recent activities.

### M2–M4 — Foundations

- **M4** — deterministic `FakeEngineService` (seeded, reproducible tracks) so
  the UI is fully buildable without the real engine.
- **M3** — local domain models: `Route`, `Activity`, `Attempt`, `Ghost`,
  `GhostState`, `LiveRunState`, `RunStatus`, plus `Distance`/`Elapsed`/`Speed`.
- **M2** — design system: semantic colors (AHEAD/BEHIND/PB/GPS WARNING),
  typography, spacing, cards/buttons, and the `PerformanceGap` component.

### M1 — Shell

- App root, theme, shell navigation (Home / Record / Routes), go_router
  routing, and Riverpod dependency injection.

---

## 2026-09-12 … 2026-09-13 — Rust engine (`gps-engine` v0.1)

Work on the standalone engine that later powers the app (M9):

- **GPX input & matching** — GPX ↔ Track adapter (RFC 3339 times, Garmin speed
  extension), pairwise route matching with structured `MatchScore`
  diagnostics.
- **Route discovery & canonicalization** — cluster recordings into routes and
  derive one robust canonical route per cluster.
- **Performance & ghost** — GPS → route distance → elapsed-time projection
  (`time_at`/`distance_at`), pointwise `ComparisonPoint`s, and the PB-vs-live
  `GhostState` duel.
- **CLI** — `inspect`, `process`, `compare`, `discover`, `evaluate`,
  `benchmark`.
- **Quality** — property-based testing (`proptest`), a synthetic labeled
  corpus (`testdata/synthetic/` + `manifest.json`), an `evaluate` example that
  reports the confusion matrix (precision 1.000, recall 0.778 at defaults), a
  benchmark harness, GPX robustness tests (parser never panics), and 179
  passing tests.