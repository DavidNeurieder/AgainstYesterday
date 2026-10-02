# app — Flutter client

The Flutter client for `gps_app`. See the repository root
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

169 headless tests run with `fake_async`, an in-memory store, and the
deterministic fake engine — no device or GPS required. Coverage spans the run
state machine (`test/state_machine_test.dart`), pause/resume timing
(`test/pause_resume_test.dart`), persistence & recovery
(`test/persistence_recovery_test.dart`), geometry invariants
(`test/geometry_invariants_test.dart`), PB/split boundaries
(`test/splits_boundary_test.dart`), per-phase record UI (`test/ui_state_test.dart`),
failure injection (`test/failure_injection_test.dart`), lifecycle snapshots
(`test/lifecycle_test.dart`), the Rust FFI surface
(`test/rust_engine_test.dart`, `test/rust_engine_widget_test.dart`) and the
M15 diagnostics plus fixture export (`test/diagnostics_test.dart`,
`test/fixture_export_test.dart`).

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

## Real engine

By default the app uses the deterministic `FakeEngineService`. To talk to the
Rust engine over FFI:

```bash
flutter run --dart-define=USE_RUST_ENGINE=true \
            --dart-define=GPS_ENGINE_LIB=/path/to/libgps_engine.so
```

`GPS_ENGINE_LIB` is optional: when it is empty the app opens the bare name
`libgps_engine.so`, which is what the platform loader resolves for a library
bundled inside the app.

On Android the engine must be cross-compiled per ABI and bundled as a native
library, which `tool/build_rust_engine_android.sh` does:

```bash
./tool/build_rust_engine_android.sh          # arm64-v8a + x86_64
ABIS=arm64-v8a ./tool/build_rust_engine_android.sh   # a single ABI
```

It builds `gps-engine` with the NDK clang linker for API 24 (Flutter's default
`minSdkVersion`) and installs the result into
`android/app/src/main/jniLibs/<abi>/libgps_engine.so`. Gradle packages every ABI
present in that directory — `--target-platform` only filters Flutter's own
libraries — so use `ABIS=` to keep a lean APK. The binaries are gitignored;
rerun the script after a clean checkout or a `git clean -xfd`. Add
`--dart-define=DEV_TOOLS=true` to any of these to expose the diagnostics
entry point (M15).

## Layout

- `lib/app/` — root widget, router, shell tabs, dependency injection.
- `lib/features/` — feature folders: `home`, `recording`, `result`, `routes`,
  `activity` (each `presentation/` + `application/`).
- `lib/core/` — theme and units.
- `lib/engine/` — `EngineService` facade, fake + Rust FFI implementations.
- `lib/persistence/` — stores and repositories.
- `lib/widgets/` — shared components (`performance_gap`, `route_map`,
  `route_silhouette`).