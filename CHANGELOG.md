# Changelog

All notable changes to the Against Yesterday project (Flutter client +
`gps-engine` Rust crate) are
documented here, grouped by the implementation milestones in
`specification/app_implementation_plan.txt`.

---

## [Unreleased]

### Added

- On-emulator end-to-end tests with simulated GPS (M30): a new
  `integration_test/device_gps_test.dart` records a route and races a saved
  one against fixes that arrive through the real geolocator platform channel
  (`USE_DEVICE_GPS=true`), so acquisition, recording and the race axis run on
  the same path a phone uses. The harness
  `tool/android_integration_test.sh --device-gps` drives it: it grants the
  location permission while `flutter test` runs, pre-flights location
  services and the emulator geo console, and feeds 1 Hz positions along the
  saved route's start segment over that console. Getting there needed two
  fixes in `DeviceGpsSource`: the fused client gates its update request on
  Google Play services' location-settings check, which never resolves on an
  offline emulator, so `fixes()` now forces the plain `LocationManager`
  client on Android, and the service acquisition check got a timeout instead
  of hanging forever. Wired up as `make connected-test-gps` and as a second,
  sequential run inside the CI `android-integration-test` job (M30).

- First-launch onboarding (§34): a fresh install opens on three swipeable
  screens — "Against Yesterday / Race your best." → "Choose a route. / Your
  previous best becomes your opponent." → "See the gap. / Know exactly when
  you're winning or losing." — and GET STARTED drops the user straight into
  record-a-route, never more than three screens and no account step. The
  gate lives in the settings store: hermetic (test/demo) stores never
  onboard, a real install shows the intro until the settings document
  records it as seen, and documents written before this milestone count as
  already seen. The milestone also wires the device store itself — `main()`
  now hands the app a `JsonFileStore` rooted in the application documents
  directory (via `path_provider`), so settings, routes, activities and
  snapshots finally survive a restart on a phone instead of the in-memory
  `NoopPersistenceStore` default (M29).
- Accessibility audit (§32): the palette is pinned to WCAG AA — every text
  token keeps ≥4.5:1 on all three surfaces (muted text, the ghost grey and
  the error red were nudged lighter, and destructive buttons got their own
  darker fill so the white label still reads), splits now spell out ahead
  or behind instead of leaning on green or amber, the map's PB chip is a
  readable size and colour, the detail back button is named for screen
  readers, and a new suite checks the contrast maths, the colour
  alternatives, the spoken names and the 48 px touch targets (M28).
- Consistent error screens (§33): every failure lands on one ErrorScreen
  skeleton — title bar, icon, headline, reason, recovery actions. A GPS
  refusal headlines GPS UNAVAILABLE and offers the matching location
  settings; a race whose route vanished from the catalog shows COULDN'T
  LOAD ROUTE with RETRY, which reloads the catalog and drops back into
  the pre-race as soon as the route is back; and a failed disk write no
  longer costs the run — a failing route matcher now just saves the run
  without a route, the activity is held in memory, and the finish and
  result screens show an inline COULDN'T SAVE ACTIVITY block whose TRY
  AGAIN rewrites the storage (M27).
- The performance graph (§23): the result screen's GAP TO YOUR BEST chart
  plots how far ahead of (green) or behind (amber) your personal best you
  were at every 100 m of the covered distance, against a dashed zero rule
  with an AHEAD/BEHIND gutter so the direction never rests on colour
  alone. The line follows the same constant-speed PB model as the splits,
  the distance axis honours the display unit, screen readers get a spoken
  summary of the finish gap, and the chart appears once 250 m are covered
  — between the performance bar and the splits (M26).
- The race speaks up when GPS gets shaky (§17) and when you wander off
  the line (§18): a weak-signal banner sits above the readout whenever the
  latest fix's accuracy drops out of the good bucket (<15 m good, 15–40 m
  reduced, ≥40 m poor — the pill keeps the exact level), and a centred
  OFF ROUTE card floats over the map with the metres back to the route.
  The race screen stays visible underneath and both clear themselves the
  moment the state recovers. Only a recognised route can be left, and the
  demo runner tracks the geometry exactly, so the overlays never fire in
  normal play (M25).
- Responsive layout (§31): a regression suite pumps every primary screen
  — Home, Routes, History, Settings, both detail screens, the whole race
  flow, and the live run in landscape — at the 320/390/430 px phone range
  (Flutter's test runner fails on any RenderFlex overflow). Fixes it
  turned up: the finish screen scrolls when its content cannot fit the
  smallest phones while staying centered when it can, and the settings
  Units control wraps onto its own line instead of pushing past the card
  edge (M24).
- Deliberate animation (§30): Home's hero and recent cards fade up in a
  subtle stagger, the result screen's stats arrive in sequence, and a PB
  finish gets its moment — a springing trophy, the "0:04 FASTER" gain and
  the previous-PB line behind the NEW PERSONAL BEST heading (ideas §20).
  The race gap's digits now tween between ticks instead of snapping, while
  the AHEAD/BEHIND state and semantics stay instant. Everything is one-shot
  and drops out entirely when animations are disabled (M23). Ghost/YOU
  marker interpolation already shipped with §14, the countdown with M19.
- History (§24–§25) grows up: activities group under calendar-month headers
  ("October", "October 2025" for other years), each row shows the route,
  time and "distance · Today/Yesterday/date", runs that stood up their
  route's best carry a gold trophy, and everything else trails a `+0:44`
  delta versus the route's current PB. The light filter set is route chips
  plus "PBs only" (the plan's All/Running/Cycling would need a sport field
  a running-only app doesn't have). Shared date labels moved out of the
  route-detail screen into `core/date_labels.dart` (M22).
- Settings (§26) replace the M16 stub: Race (Haptics, Countdown), Display
  (Units), Data (Export GPX, Delete all data) and About (version, privacy,
  licenses). Both toggles are wired for real — every tick in the app now goes
  through one haptics gate, and turning Countdown off makes a route race START
  jump straight into the run the way a plain `/record` does. Units switches
  between kilometers and miles for distance, pace and speed on every readout
  (hero, cards, live, complete, result, history, details); the engine keeps
  meters and seconds, only the display changes. Export GPX copies the route
  catalog and recorded tracks as a GPX 1.1 document to the clipboard; Delete
  all data wipes the store behind a confirm. The app is still a dark-only,
  running-only design, so there is no theme or default-activity row yet
  (M21).
- The result screen closes the race loop (§29): after a route race, RACE
  AGAIN drops straight back into that route's pre-race (fresh session, still
  the 3-2-1-GO countdown), with DONE leaving the loop; route-less results
  keep DONE alone (M20).
- Races are now route-bound (§9–§11): Home's hero, every route card's RACE
  button, and a route detail's RACE YOUR BEST open that route's pre-race
  (named screen, GPS-ready gate, big START), and pressing START plays a
  full-screen 3-2-1-GO countdown before the timer starts (§11, ~2.6 s total,
  large animated number, scale/fade per step). Plainer `/record` entries
  still start on the button press (M19).
- A record-a-route flow (§8) reaches the shell from Home's empty state and
  the Routes tab's permanent "Record Route" action: a pushed full-screen flow
  that gates on GPS, records distance + time (no ghost — simpler than a
  race), then asks for a name and saves the route with this first attempt as
  its baseline PB. The finished activity is tagged to the new route so it
  appears in History and the route's attempt list (M18). The deterministic
  scenario timeline now walks the demo loop during route-less recordings so
  a route can actually be recorded on a fresh demo install; device-GPS
  recordings keep their own receiver timeline.
- Home is reworked around the race loop (§4–5): with a route catalog it shows
  a "READY TO RACE" hero — the featured route's name, distance, PB and a big
  "RACE YOUR BEST" button into the pre-run — above a truncated "Recent"
  activity list; on a fresh install it shows the "Your first race awaits."
  empty state whose "RECORD ROUTE" button opens the record flow. The full
  route catalog lives on the Routes tab, History stays the full activity view
  (M17).
- The navigation shell is reworked to **Home / Routes / History** tabs; the
  recording flow is a pushed full-screen route off Home's primary action
  (M16). A settings stub and the History tab take the space the Record tab
  used; the gear on Home opens Settings.
- A shared design system under `app/lib/core/ui/` — `PrimaryButton`,
  `EmptyState` (full + inline), `LoadingState`, `ErrorState`, `SectionHeader`,
  `StatRow`, `MetricDisplay`, `GapLine`, `SplitRow` and `tabular()` figures —
  replaces the per-screen re-implementations that had drifted (10/12/18/20 px
  button radii, duplicated gap lines and split rows across the complete /
  result / activity screens).

### Changed

- Real-GPS recordings now gate movement on the ground the receiver actually
  covered. A fix must clear a 0.5 m/s motion floor (measured between fixes, or
  a receiver-reported speed corroborated by matching displacement) before it
  adds moving time, distance or pace. A parked phone — even one serving a
  stale cached speed — freezes moving time, keeps distance at zero and shows
  "— /km" instead of a phantom cruise pace, while still buffering the raw
  fixes for the persisted track.
- The app no longer ships pre-recorded demo data. The route catalog and
  activity history start empty on a fresh install — users build both by
  finishing runs. Recording without a route is always a free run (no synthetic
  ghost geometry) in every mode; host tests and the E2E seed their own
  fixtures through `app/test/test_catalog.dart`. The deterministic fake GPS
  timeline and the River Loop engine fixture remain for host/test exploration.
- The live run can now record the phone's **real GPS**. A build with
  `USE_DEVICE_GPS=true` streams 1 Hz fixes from the geolocator plugin into the
  recording controller, so position, distance, pace, the raw-fix buffer and the
  persisted track all come from the receiver (Android `ACCESS_FINE_LOCATION`,
  iOS `NSLocationWhenInUseUsageDescription`). On a recognised route the live
  fix snaps onto that route's geometry for the ghost gap (never rewinding
  accumulated distance); an unrecognised line accumulates ground distance as a
  new route. Refused services/permission surface as the recoverable recording
  ERROR state. Without the define the app keeps the deterministic demo
  timeline — the host/test/E2E default — and `make build`, `make install` and
  `make build-release` pass the define so installed phone artifacts record
  real GPS. The diagnostics GPS section names the live source.
- The engine is now auto-selected at build time instead of defaulting to the
  fake. A build whose native `libgps_engine.so` loads (the Android cdylibs
  bundled into the APK by `app/tool/build_rust_engine_android.sh`, or a host
  library pointed at with `GPS_ENGINE_LIB`) runs the real `gps-engine`
  pipeline; a build without it falls back to the deterministic
  `FakeEngineService` demo. `USE_RUST_ENGINE` stays meaningful as a tri-state
  flag — unset means auto, `true` requires the Rust engine (a missing library
  becomes a startup error, as CI uses for the FFI suites), `false` always uses
  the fake. `make install` and `make build-release` now run the Android
  cross-compile first, so a device artifact carries the real engine by
  default.
- The project is now called **Against Yesterday** (previously `gps_app`). The
  repository and every user-visible string — Android launcher label, Flutter
  and Linux GTK window titles, iOS bundle name — carry the new name. The
  pubspec package became `against_yesterday`, so all imports moved to
  `package:against_yesterday/…`; the `GpsApp` widget class became
  `AgainstYesterdayApp`; and the platform identifiers moved out of the
  `dev.gpsapp.*` namespace into `dev.neurieder.against_yesterday` (Android
  applicationId/namespace, Linux `APPLICATION_ID`) and
  `dev.neurieder.againstyesterday` (iOS bundle IDs), which also re-identifies
  where the app installs.

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
- Finishing a run (FINISH, or DONE on the summary) used to complete on the
  *next* 500 ms timer tick; dismissing in the finishing→complete gap cancelled
  the timer and re-armed a fresh session, so the finished run was dropped
  without saving — a race the KVM/software-GPU CI emulator hit reliably
  ("the finished run never appears as a third Home tile"). `finishRun()`
  completes synchronously now, so the background save starts the instant the
  user finishes and no longer depends on a tick surviving until dismissal.

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

- The whole repository (`gps-engine` crate and Flutter app) is licensed under
  **`AGPL-3.0-or-later`**: SPDX id in the workspace `Cargo.toml` (inherited by
  the crate) and in `app/pubspec.yaml`, with the full text added as `LICENSE`
  at the repository root.
- The grant is now stated everywhere it can be: all 128 hand-written source
  files (Dart, Rust, Kotlin/Gradle, shell, iOS and Linux runner code) open with
  `Copyright (C) 2026 David Neurieder` and
  `SPDX-License-Identifier: AGPL-3.0-or-later`, and `app/README.md` and
  `rust/gps-engine/README.md` gained the License sections they lacked.
  `LICENSE` itself stays the verbatim AGPL-3.0 text — it can only say
  "version 3"; the "or later" is what the SPDX id records.

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