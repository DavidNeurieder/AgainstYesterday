# app — Flutter client

The Flutter client of Against Yesterday. See the repository root
[`README.md`](../README.md) for the full picture.

## Run

```bash
flutter pub get
flutter run
```

## Tests & analysis

```bash
flutter analyze
flutter test
```

212 headless tests run with `fake_async`, an in-memory store, and the
deterministic fake engine — no device or GPS required. Coverage spans the run
state machine (`test/state_machine_test.dart`), pause/resume timing
(`test/pause_resume_test.dart`), persistence & recovery
(`test/persistence_recovery_test.dart`), geometry invariants
(`test/geometry_invariants_test.dart`), PB/split boundaries
(`test/splits_boundary_test.dart`), per-phase record UI (`test/ui_state_test.dart`),
failure injection (`test/failure_injection_test.dart`), lifecycle snapshots
(`test/lifecycle_test.dart`), calendar-day date labels including DST
boundaries (`test/route_library_test.dart`), the Rust FFI surface
(`test/rust_engine_test.dart`, `test/rust_engine_widget_test.dart`), the
device-GPS source (`test/device_gps_test.dart`), the controller's real-GPS
mode (`test/recording_controller_device_test.dart`) and the M15 diagnostics
plus fixture export (`test/diagnostics_test.dart`,
`test/fixture_export_test.dart`). The M16 design system
(`test/ui_kit_test.dart`) pins the shared `core/ui` building blocks and the
shell restructure (Home / Routes / History tabs, pushed record flow, settings
stub) is covered in `test/widget_test.dart`, and the M17 Home rework — the
"READY TO RACE" featured-route hero plus the first-launch "Your first race
awaits." empty state — in `test/widget_test.dart` and `test/ui_state_test.dart`.

The two Rust FFI suites skip themselves, with an explanation, when the cdylib
has not been built — normal on a fresh checkout. CI passes
`--dart-define=REQUIRE_RUST_ENGINE=true`, which turns that skip into a failure
so a green job always actually ran them:

```bash
cargo build --release -p gps-engine          # target/release/libgps_engine.so
flutter test --dart-define=REQUIRE_RUST_ENGINE=true
```

## On-device integration tests

`integration_test/app_test.dart` drives the real app end to end on an
emulator/device (real clock, real timers): record a run (Home → READY → START
→ pause/resume → FINISH → result → DONE → history) and browse the route
library.

```bash
flutter test integration_test -d <device>
```

On Android, `tool/android_integration_test.sh` boots a headless emulator and
runs the suite against it:

```bash
./tool/android_integration_test.sh          # default AVD "test_phone"
./tool/android_integration_test.sh pixel_6  # specific AVD
```

A leading non-flag argument names the AVD; anything else is forwarded to
`flutter test`, so the suite can be run against the real engine:

```bash
./tool/android_integration_test.sh --dart-define=USE_RUST_ENGINE=true
```

`ANDROID_AVD` and `ANDROID_SERIAL` override the AVD name and device serial.

## Real engine

The engine is auto-selected: when its native library loads, the app talks to
the Rust engine over FFI; otherwise it falls back to the deterministic
`FakeEngineService`. Force either side with `USE_RUST_ENGINE`:

```bash
flutter run --dart-define=USE_RUST_ENGINE=true    # require the Rust engine
flutter run --dart-define=USE_RUST_ENGINE=false   # always the fake
flutter run --dart-define=USE_RUST_ENGINE=true \
            --dart-define=GPS_ENGINE_LIB=/path/to/libgps_engine.so
```

`GPS_ENGINE_LIB` is optional: when it is empty the app opens the bare name
`libgps_engine.so`, which is what the platform loader resolves for a library
bundled inside the app. On Android the engine must be cross-compiled per ABI
and bundled as a native library, which `tool/build_rust_engine_android.sh`
does:

```bash
./tool/build_rust_engine_android.sh          # arm64-v8a + x86_64
ABIS=arm64-v8a ./tool/build_rust_engine_android.sh   # a single ABI
```

It builds `gps-engine` with the NDK clang linker for API 24 (Flutter's default
`minSdkVersion`) and installs the result into
`android/app/src/main/jniLibs/<abi>/libgps_engine.so`, so the next
`flutter build apk` (debug or release) auto-selects the Rust engine on the
device. Gradle packages every ABI present in that directory —
`--target-platform` only filters Flutter's own libraries — so use `ABIS=` to
keep a lean APK. The binaries are gitignored; rerun the script after a clean
checkout or a `git clean -xfd`. Add `--dart-define=DEV_TOOLS=true` to any of
these to expose the diagnostics entry point (M15).

## Real phone GPS

A plain `flutter run`/`flutter test` replays the deterministic demo timeline
(no receiver needed — deterministic and cheap); the app starts with an empty
route catalog and records freely until the user builds routes by finishing
runs. A `USE_DEVICE_GPS=true` build records the phone's real fixes: the
geolocator plugin streams 1 Hz positions into the recording controller, and
position, distance, pace, the raw-fix buffer and the persisted track all come
from the receiver.

```bash
flutter build apk --debug --dart-define=USE_DEVICE_GPS=true
```

`make build`, `make install` and `make build-release` pass the define for you.
On a recognised route the live fix snaps onto that route's geometry for the
ghost gap (never rewinding accumulated distance); an unrecognised line
accumulates ground distance as a new route. The Android manifest carries
`ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION`, and `Info.plist` declares
`NSLocationWhenInUseUsageDescription`. Refusals (services off, permission
denied) surface as the recoverable `RunStatus.error` (M14). Host tests never
touch the plugin: they either keep the demo timeline or inject a
deterministic `GpsSource` through `deviceGpsProvider`. The diagnostics GPS
section names the active source.

## Layout

- `lib/app/` — root widget, router, shell tabs, dependency injection.
- `lib/features/` — feature folders: `home`, `recording`, `result`, `routes`,
  `history`, `settings`, `activity` (each `presentation/` + `application/`).
- `lib/core/` — theme, units, and the shared `ui` design system
  (`core/ui/`): buttons, empty/loading/error states, sections, the PB gap
  line and split rows.
- `lib/engine/` — `EngineService` facade, fake + Rust FFI implementations,
  and the device `GpsSource`/geolocator bridge.
- `lib/persistence/` — stores and repositories.
- `lib/widgets/` — shared components (`performance_gap`, `route_map`,
  `route_silhouette`).

## License

`AGPL-3.0-or-later` — the whole repository, this app included. The full text is
in [../LICENSE](../LICENSE), the SPDX id is declared in `pubspec.yaml`, and
every source file here opens with a
`SPDX-License-Identifier: AGPL-3.0-or-later` header.
