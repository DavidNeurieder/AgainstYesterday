# AGENTS.md

Against Yesterday — a Flutter GPS running/cycling app (`app/`) whose route/ghost
pipeline is a Rust engine (`rust/gps-engine`) in a Cargo workspace at the repo
root. App name/IDs: package `against_yesterday`, Android applicationId
`app.against_yesterday`, display name "Against Yesterday".

## Working conventions

- Do NOT watch or poll GitHub Actions after pushing (`gh run watch`, `gh run
  list/view`). Commit, push, and stop — unless the user asks about CI.
- Only commit/push when the user asks. Commit style: imperative subject; body
  ends with a `Verified: ...` line.
- Run `git status` to confirm the current branch before committing.
- Prefer the Makefile at the repo root for common commands (`make build`,
  `make build-release`, `make install`, `make lint`, `make test`, `make
  run`, `make full-test`, `make clean`).

## Commands

- Flutter, from `app/`: `flutter pub get`, `flutter analyze`, `flutter test`.
- Rust, from the repo root (Cargo workspace): `cargo test --all-features`,
  `cargo clippy --all-targets --all-features -- -D warnings`,
  `cargo fmt --all --check`, `cargo build --release -p gps-engine`.
- CI (`.github/workflows/ci.yml`) mirrors these plus an on-device E2E suite.
- Rust is pinned by `rust-toolchain.toml` at the repo root. rustup applies it
  to cargo/rustc calls made from this workspace, so local, CI and F-Droid
  builds use the same compiler regardless of the user's default toolchain.
  Bump the version there; do not add toolchain overrides to recipes or CI.
  CI preinstalls that exact toolchain via `.github/actions/setup-pinned-rust`,
  which reads `rust-toolchain.toml`. Keep using that action instead of installing
  `stable`: otherwise rustup defers the pinned install to the first
  cargo/maturin call, which can fail with a clippy component conflict on hosted
  runners.
- Android builds need **JDK 21** (MapLibre compiles with Java 21) even though
  the app targets Java 17. CI's Android job pins Temurin 21; the Makefile exports
  a detected JDK 21 as `JAVA_HOME` when one is not already set.
- `make build-release` and F-Droid use `app/tool/repro_build.sh`, which copies
  the source tree to `/tmp/against-yesterday-repro-build` before running Flutter.
  Dart AOT embeds the absolute URI of Flutter's generated plugin registrant in
  `libapp.so`; the fixed path is what makes local and F-Droid APKs byte-identical.
  Override the path with `REPRO_BUILD_ROOT` and the Flutter executable with
  `FLUTTER_BIN`. The same script also rebuilds the Rust cdylib, so keep its ABI
  and the F-Droid recipe in sync.

## Engine notes

- The app talks to the engine only through the `EngineService` abstraction.
  The engine is auto-selected at build time: the native Rust engine is used
  when its library loads, otherwise the deterministic `FakeEngineService`
  is the fallback.
- `USE_RUST_ENGINE`, `REQUIRE_RUST_ENGINE`, `GPS_ENGINE_LIB`, `USE_DEVICE_GPS`
  and `DEV_TOOLS` are compile-time `--dart-define` flags, not environment
  variables. `USE_RUST_ENGINE` is tri-state: unset (auto), `true` (require,
  missing library is a startup error), `false` (always the fake).
  `USE_DEVICE_GPS` is an opt-out: a phone build reads the live run from the
  receiver via geolocator by default, while `USE_DEVICE_GPS=false` replays the
  deterministic demo timeline (what the host tests and the on-device demo
  suite pass). `true` forces the receiver on any platform. `make
  build`/`install`/`build-release` restate the default so the log says what was
  built, but a plain `flutter build apk` already records real GPS and renders
  with the MapLibre map. While the receiver streams, the
  controller keeps an Android foreground `location` service
  (`RecordingForegroundService`, started/stopped over the
  `app.against_yesterday/recording` platform channel) so fixes keep
  arriving with the screen off — Android 12+ delivers no location to a
  backgrounded app without one. Startup is observable: a typed failure
  (`RunForegroundLifespan`, `ForegroundStartFailure`) becomes a
  `BackgroundProtection.unavailable` banner and a diagnostics row; the run
  itself keeps recording screen-on. Because the foreground-service exemption
  only exists on Android 12+, the app also declares
  `ACCESS_BACKGROUND_LOCATION` — on Android 10/11 a missing "Allow all the
  time" grant is a typed `background-denied` start failure, and the service
  holds a partial wake lock + asks once for the battery-optimization
  exemption (the OEM power-manager killer). Process death is explicitly
  unsupported: the service is `START_NOT_STICKY` and recording does not
  survive a kill. The service holds no GPS logic of its own; on non-Android
  hosts and scenario runs the `RunForegroundLifespan` seam is a no-op (see
  `docs/android_foreground_recording.md`).
- Android cdylibs land in `app/android/app/src/main/jniLibs/<abi>/` via
  `app/tool/build_rust_engine_android.sh`; they are gitignored, so rerun the
  script after a clean checkout. `make install` and `make build-release` run
  it for you so the device artifact carries the real engine.

## Map notes

- Screens draw route/track geometry through the `MapSurface` abstraction
  (`lib/features/map/`), never a concrete map widget — the live run, the
  activity track and the route-detail course map all go through it. The
  renderer is `flutter_map` (raster OpenStreetMap tiles) on Linux desktop, the
  self-contained painter (`RouteMap`) in host/widget tests, and otherwise
  selected at build time by `MAP_VIEW`, which defaults to the MapLibre
  renderer (`maplibre_gl`); `MAP_VIEW=false` opts out to the painter. Host
  tests stay hermetic because the seam forces the painter under
  `FLUTTER_TEST`. The route-detail download button and the offline region
  list follow `offlineMapsAvailableProvider`, which is false on the desktop
  and in host tests and true on a MapLibre device build; the hermetic
  on-device E2E passes `MAP_VIEW=false` explicitly.
- `MAP_STYLE_URL` overrides the MapLibre style document (default OpenFreeMap
  Liberty) and `MAP_TILE_URL` overrides the desktop raster tile template
  (default the public OSM tile server — point it at a self-hosted server for
  anything beyond light use). Map data is OpenStreetMap (ODbL) and must be
  attributed; offline regions are per-route downloads, not bundled (see
  `ideas/offline_map_plan.txt`).

## Licensing

- AGPL-3.0-or-later for the whole repo. New files open with a
  `Copyright (C) <year> David Neurieder` line and an
  `SPDX-License-Identifier: AGPL-3.0-or-later` header.