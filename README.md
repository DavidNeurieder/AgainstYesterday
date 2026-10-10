# Against Yesterday

A GPS run/cycling app built around one idea: **every route is a race with your
own personal best.** You run against a "ghost" of your PB, and the live gap —
AHEAD or BEHIND — is the hero metric of the whole experience.

```
Flutter app  →  EngineService (facade)  →  Rust engine (FFI)
                                   ↘  FakeEngineService (deterministic, for dev)
```

## Features

- **Record runs** — a state machine driving `preparing → GPS acquiring →
  ready → running ⇄ paused → finishing → completed`, with live distance, pace,
  elapsed time and the PB gap.
- **Ghost racing** — every route carries a PB; run against its ghost live on
  the map, and finish the run to see where you were faster or slower.
- **Map** — route and track geometry drawn through one `MapSurface` seam. The
  default is a self-contained painter (no map SDK) that stays hermetic on host
  and desktop; device builds opt into the MapLibre renderer (the engine behind
  Organic Maps) with `MAP_VIEW=true`: the route, the travelled portion, the YOU
  and PB-ghost markers and a follow camera with recenter.
- **Offline maps** — per-route regions downloaded straight from the route page
  ("Download offline map") and managed in Settings → Map: progress while a
  region downloads, delete with confirmation, and the OSM attribution.
  Downloads are user-initiated, size-capped and one at a time, so the app never
  floods the tile provider.
- **Route library** — course cards with PB/average/last stats, a performance
  chart of every attempt, and attempt history.
- **Results & history** — run-complete interstitial with NEW PERSONAL BEST
  detection, a splits breakdown, activity detail, and home history.
- **Background recording** — wall-clock timing and persisted run snapshots, so
  an interrupted run survives process death and resumes where it left off.
- **GPX export** — Settings saves every route and recorded run as one GPX file
  straight into the Android Downloads folder (MediaStore on API 29+, the
  legacy storage grant below it).
- **Polish** — phase transitions, haptics, WCAG-AA contrast and semantics
  labels, error/empty/loading states, and repaint isolation.
- **Developer diagnostics** — a `DEV_TOOLS` gated readout of the live engine /
  GPS / track / route / ghost / persistence state, plus one-tap export of the
  current run as a raw-GPS fixture for regression replay.

## Repository layout

| Path                     | What it is                                              |
|--------------------------|---------------------------------------------------------|
| `app/`                   | The Flutter client (`lib/`, `test/`)                    |
| `rust/gps-engine/`       | The Rust engine: GPX → track → route → ghost pipeline   |
| `specification/`         | Plans: app implementation, UI/UX, engine, datasets      |
| `Cargo.toml`             | Cargo workspace root for the Rust crate                 |

The app consumes the engine only through the `EngineService` abstraction, so
it never talks to raw FFI — the native Rust engine is selected automatically
when its library is present, and the fake is the fallback, without touching
UI code.

## Landing page

A static landing page lives in [`docs/`](docs/) and is published at
<https://davidneurieder.github.io/AgainstYesterday/>.

## Getting started

```bash
# Flutter client
cd app
flutter pub get
flutter run

# Rust engine
cargo test
cargo run --example analyze
```

CI (`/.github/workflows/ci.yml`) runs `cargo fmt --check`, `cargo clippy -D
warnings`, `cargo test --all-features`, `cargo doc --no-deps`, Flutter's
`flutter analyze` + `flutter test`, a cross-compile of the engine `cdylib` for
each Android ABI (asserting the FFI symbols are exported), and the on-device E2E
suite on a headless Android emulator (`flutter test integration_test`).

## Using the real Rust engine

The engine is selected at build time from `USE_RUST_ENGINE`:

- **not set (default)** — auto: the native Rust engine is used when its
  library loads, otherwise the deterministic `FakeEngineService` (the
  dev/demo fallback, also used in tests);
- `=true` — require the Rust engine (a missing library becomes a startup
  error);
- `=false` — always the fake.

The Android cdylib is cross-compiled per ABI and packaged as a native library
by `app/tool/build_rust_engine_android.sh` (NDK clang linker, API 24), which
installs it into `app/android/app/src/main/jniLibs/<abi>/` — where Gradle
picks it up and the bare name `libgps_engine.so` resolves on the device. That
is also why `make install` and `make build-release` run it first:

```bash
./app/tool/build_rust_engine_android.sh            # arm64-v8a + x86_64
cd app && flutter build apk --release
```

The binaries are gitignored build artifacts; rerun the script after a fresh
checkout. To force the fake (demonstration/test builds), use
`--dart-define=USE_RUST_ENGINE=false`. On host workloads point the build at a
library with `--dart-define=GPS_ENGINE_LIB=/path/to/libgps_engine.so`; when
empty the app opens the bare name `libgps_engine.so`. Add
`--dart-define=DEV_TOOLS=true` to any of these builds to expose the M15
diagnostics entry point.

## Using the real phone GPS

A plain `flutter run`/`flutter test` replays the deterministic demo timeline
(roughly the ~4.8 km "River Loop" walkable on the host — the app's catalog
itself stays empty until the user builds routes), so the flow is explorable
with no phone. To record *actual* device fixes, build with `USE_DEVICE_GPS`:

```bash
cd app && flutter build apk --debug --dart-define=USE_DEVICE_GPS=true
```

`make build`, `make install` and `make build-release` pass the define for you,
so the installed app races real GPS while hosts and the emulator E2E keep the
deterministic timeline. Device mode reads 1 Hz fixes through the geolocator
plugin (the app requests `ACCESS_FINE_LOCATION` on Android and uses
`NSLocationWhenInUseUsageDescription` on iOS): live position, distance, pace
and the raw-fix buffer all come from the receiver, a real run on a recognised
route snaps onto that route's geometry for the ghost gap, and an unrecognised
line accumulates ground distance as a new route. Movement is gated on the
ground actually covered — a running fix must clear a 0.5 m/s floor (measured
between fixes, or a receiver speed backed by matching displacement), so a
parked phone doesn't count moving time, drift distance, or show a phantom
cruise pace ("— /km") from a stale cached speed. The recorder's TIME is a
separate wall-clock stopwatch — it runs from START and pauses with PAUSE, so
it stays alive while you stand still even though distance, pace and the saved
PB wait for real movement. Refusals (services off or permission denied)
surface as the recoverable recording ERROR state. The diagnostics screen's GPS
section prints which source is live.

## Offline map & map licensing

Device builds can render through MapLibre Native (the engine behind Organic
Maps) and download routes for offline use:

```bash
cd app && flutter build apk --debug \
  --dart-define=USE_DEVICE_GPS=true --dart-define=MAP_VIEW=true
```

`MAP_VIEW` is tri-state, mirroring `USE_RUST_ENGINE`: unset/`false` keeps the
self-contained painter (the hermetic host/test/desktop default), `true`
requires the MapLibre renderer. `MAP_STYLE_URL` overrides the style document
(default OpenFreeMap Liberty) — point it at a self-hosted tile server for
anything beyond per-route downloads. **Without `MAP_VIEW=true` the download
button and the offline region list never appear**, so the device targets pass
the define for you: `make build`, `make install` and `make build-release` all
build with `MAP_VIEW=true` (plus `USE_DEVICE_GPS=true`). Android builds with
MapLibre need JDK 21 (the plugin compiles with Java 21); the Makefile exports
a detected JDK 21 as `JAVA_HOME` and CI pins Temurin 21, so `make
build`/`install` just work.

Offline regions are per-route, user-initiated and size-capped (zoom 12–15
under a client-side tile budget), one download at a time, managed in Settings →
Map. **No tiles are bundled** — see [docs/map_licensing.md](docs/map_licensing.md)
for the engine (BSD-3-Clause), data (OSM, ODbL) and tile-service licenses, the
attribution requirement, and the recorded no-bundled-region decision.

## Developer diagnostics

Build with the diagnostics entry point enabled (`M15`):

```bash
cd app
flutter run --dart-define=DEV_TOOLS=true
```

A small bug-report button floats at the top right of every tab and opens the
diagnostics screen (gated in both the shell and the router): the active engine
implementation, the live GPS fix, track / route / ghost readouts, and the
persisted recovery snapshot. **Export run as fixture JSON** serializes the
*raw* fixes retained for the in-flight run (or the most recent saved run) in
the M15 fixture schema and copies it to the clipboard after a privacy
confirmation:

```json
{"schema_version":1,
 "route":[{"lat":..,"lon":..}],
 "fixes":[{"timestamp_ms":..,"latitude":..,"longitude":..,
           "accuracy_m":..,"altitude_m":..,"speed_mps":..,"bearing_deg":..}]}
```

Raw fixes are the receiver's own observations, captured before any processing
and persisted with the completed activity; sensor fields the device never
reported are emitted as explicit `null` — never invented — and a recording
with no route geometry refuses export rather than substituting demo data.
Paste the document into `rust/gps-engine/tests/fixtures/` and drive it through
the Rust pipeline (`GpsTrace::from_json` → `process` → invariants, see
`tests/gps_torture.rs`) — a real-device GPS bug becomes a permanent regression
test. On the device side the same readout answers "why did the ghost jump?"
without guessing.

## Tests

```bash
cd app && flutter analyze && flutter test   # Flutter: 355 tests (1 skipped: Rust FFI)
cargo test                                   # Rust: 204 tests + property cases

# the same Flutter suite against the real Rust engine over FFI
cargo build --release                        # produces target/release/libgps_engine.so
cd app && flutter test --dart-define=USE_RUST_ENGINE=true \
  --dart-define=GPS_ENGINE_LIB=../target/release/libgps_engine.so
```

The Flutter tests run headlessly with `fake_async`, an in-memory store, and
the deterministic fake engine — no phone, GPS chip, or network needed. The
Rust suite additionally replays five checked-in raw-GPS fixtures
(`tests/fixtures/clean_loop.json`, `gps_jitter.json`, `gps_jump.json`,
`gps_dropout.json`, `out_and_back.json`) through the filter/quality pipeline —
`cargo run --example generate_fixtures` regenerates them — and asserts the
trace round-trips through its own JSON. `tests/gps_schema.rs` pins the fixture
schema (`schema_version`, explicit `null` sensor fields, rejection of newer
versions) against the exact document the Flutter exporter emits, and
`tests/gps_pipeline.rs` drives a fixture end-to-end from raw fixes to a ghost
snapshot.

The on-device suites (`app/integration_test/`) run on an emulator through
`app/tool/android_integration_test.sh` (`--device-gps` selects the
real-receiver suite, `--map-smoke` the real-MapLibre map smoke — nightly only,
it needs the network — and `--smoke` narrows the demo suite to the
record-and-save journey; see the script header for the environment knobs). CI
runs the full journey on API 34 and the smoke on API 24 for every PR; the
nightly workflow adds API 36, a repeated run to catch flakes, and the map
smoke. On a red run the harness preserves the app log, a screenshot, and the
location/permission dumps under `app/build/integration-artifacts/<suite>/`.
Release sign-off uses the gates in
[docs/release_checklist.md](docs/release_checklist.md).

## Status

Milestones M1–M29 are implemented (see [CHANGELOG.md](CHANGELOG.md)). The app
ships with an empty catalog — no pre-recorded routes or demo history — and
records a free run until the user builds routes by finishing runs. On the
host/tests the deterministic fake GPS timeline (the ~4.8 km "River Loop"
fixture) keeps the whole loop explorable with no phone; a `USE_DEVICE_GPS=true`
build records the phone receiver's real fixes instead.
M15 added the raw-GPS quality model, checked-in replay fixtures, ghost
geometry invariants and continuity-aware matching on the Rust side, plus the
developer diagnostics screen on the app side. It also retains the raw fixes
through the recording lifecycle (exported, never fabricated) and gates the
diagnostics route, not just its entry button.
M16–M29 closed the loop the plan asks for: record, race, result, PB alerts,
entrance motion, responsive layouts, settings, history, consistent error
screens, a WCAG-checked palette and the three-screen first-launch intro —
with `main()` now persisting settings, routes, activities and snapshots to
the device's application documents directory across restarts.
The offline-map roadmap added a renderer seam (`MapSurface`, painter default,
MapLibre on device), a live-run map with YOU/PB markers and follow, the
recorded-track map on activity detail, and per-route offline regions with
Settings management — see the staging plan in
`ideas/offline_map_plan.txt` and the licensing page above for what is bundled
and what is downloaded.

## License

`AGPL-3.0-or-later` for the whole repository — the `gps-engine` crate and the
Flutter app alike. The full text is in [LICENSE](LICENSE); the Rust workspace
declares the SPDX id in `Cargo.toml` and the app in `pubspec.yaml`, and every
source file carries a `SPDX-License-Identifier: AGPL-3.0-or-later` header.

