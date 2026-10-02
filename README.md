# gps_app

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
- **Route map** — self-contained painter (no map SDK): the route, the travelled
  portion, the YOU and PB-ghost markers, a follow camera with recenter.
- **Route library** — course cards with PB/average/last stats, a performance
  chart of every attempt, and attempt history.
- **Results & history** — run-complete interstitial with NEW PERSONAL BEST
  detection, a splits breakdown, activity detail, and home history.
- **Background recording** — wall-clock timing and persisted run snapshots, so
  an interrupted run survives process death and resumes where it left off.
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
it never talks to raw FFI. Swap `FakeEngineService` for `RustEngineService` at
build time without touching UI code.

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

The app defaults to the deterministic `FakeEngineService` (also used in
tests). To build against the native FFI engine instead:

```bash
flutter run --dart-define=USE_RUST_ENGINE=true
flutter run --dart-define=USE_RUST_ENGINE=true \
            --dart-define=GPS_ENGINE_LIB=/path/to/libgps_engine.so
```

The library is built as a `cdylib` by the `gps-engine` crate for this purpose.
`GPS_ENGINE_LIB` is optional — when empty the app opens the bare name
`libgps_engine.so`, so a library bundled inside the app is found by the
platform loader.

On Android the `cdylib` has to be cross-compiled per ABI and packaged as a
native library. `app/tool/build_rust_engine_android.sh` builds it with the NDK
clang linker (API 24) and installs it into
`app/android/app/src/main/jniLibs/<abi>/`, which is where Gradle picks it up:

```bash
./app/tool/build_rust_engine_android.sh            # arm64-v8a + x86_64
cd app && flutter build apk --release --dart-define=USE_RUST_ENGINE=true
```

Those binaries are gitignored build artifacts; rerun the script after a fresh
checkout. Add `--dart-define=DEV_TOOLS=true` to any of these builds to expose
the M15 diagnostics entry point.

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
cd app && flutter analyze && flutter test   # Flutter: 169 tests
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

## Status

Milestones M1–M15 are implemented (see [CHANGELOG.md](CHANGELOG.md)). The demo
ships with a seeded catalog and a deterministic fake GPS timeline (the ~4.8 km
"River Loop"), so the whole loop is explorable on any device or in tests.
M15 added the raw-GPS quality model, checked-in replay fixtures, ghost
geometry invariants and continuity-aware matching on the Rust side, plus the
developer diagnostics screen on the app side. It also retains the raw fixes
through the recording lifecycle (exported, never fabricated) and gates the
diagnostics route, not just its entry button.

## License

`AGPL-3.0-or-later` for the whole repository — the `gps-engine` crate and the
Flutter app alike. The full text is in [LICENSE](LICENSE); the Rust workspace
declares the SPDX id in `Cargo.toml` and the app in `pubspec.yaml`.

Note that AGPL differs from MIT/Apache mainly in section 13: users who interact
with the software over a network must be offered the corresponding source. The
app is not published to pub.dev (`publish_to: none`), but the same terms apply
to it and to any build you distribute.