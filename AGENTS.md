# AGENTS.md

Against Yesterday — a Flutter GPS running/cycling app (`app/`) whose route/ghost
pipeline is a Rust engine (`rust/gps-engine`) in a Cargo workspace at the repo
root. App name/IDs: package `against_yesterday`, Android applicationId
`dev.neurieder.against_yesterday`, display name "Against Yesterday".

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
- Android builds need **JDK 21** (MapLibre compiles with Java 21) even though
  the app targets Java 17. CI's Android job pins Temurin 21; the Makefile exports
  a detected JDK 21 as `JAVA_HOME` when one is not already set.

## Engine notes

- The app talks to the engine only through the `EngineService` abstraction.
  The engine is auto-selected at build time: the native Rust engine is used
  when its library loads, otherwise the deterministic `FakeEngineService`
  is the fallback.
- `USE_RUST_ENGINE`, `REQUIRE_RUST_ENGINE`, `GPS_ENGINE_LIB`, `USE_DEVICE_GPS`
  and `DEV_TOOLS` are compile-time `--dart-define` flags, not environment
  variables. `USE_RUST_ENGINE` is tri-state: unset (auto), `true` (require,
  missing library is a startup error), `false` (always the fake).
  `USE_DEVICE_GPS=true` reads the live run from the phone receiver via
  geolocator; without it the recording replays the deterministic demo timeline
  (the host/test/E2E default). `make build`/`install`/`build-release` pass the
  define (plus `MAP_VIEW=true`, see below) so installed phone artifacts record
  real GPS and render with the MapLibre map. While the receiver streams, the
  controller keeps an Android foreground `location` service
  (`RecordingForegroundService`, started/stopped over the
  `dev.neurieder.against_yesterday/recording` platform channel) so fixes keep
  arriving with the screen off — Android 12+ delivers no location to a
  backgrounded app without one. The service holds no GPS logic of its own;
  on non-Android hosts and scenario runs the `RunForegroundLifespan` seam is a
  no-op.
- Android cdylibs land in `app/android/app/src/main/jniLibs/<abi>/` via
  `app/tool/build_rust_engine_android.sh`; they are gitignored, so rerun the
  script after a clean checkout. `make install` and `make build-release` run
  it for you so the device artifact carries the real engine.

## Map notes

- Screens draw route/track geometry through the `MapSurface` abstraction
  (`lib/features/map/`), never a concrete map widget — the live run, the
  activity track and the route-detail course map all go through it. `MAP_VIEW`
  selects the renderer at build time: unset/`false` = the self-contained
  painter (`RouteMap`), `true` = the MapLibre renderer (`maplibre_gl`). The
  painter is the default, so host tests and desktop stay hermetic; device
  artifacts opt in — `make build`/`install`/`build-release` pass
  `MAP_VIEW=true`, and without it the route-detail download button and the
  offline region list never appear (`offlineMapsAvailableProvider` is false).
- `MAP_STYLE_URL` overrides the MapLibre style document (default OpenFreeMap
  Liberty). Map data is OpenStreetMap (ODbL) and must be attributed; offline
  regions are per-route downloads, not bundled (see
  `ideas/offline_map_plan.txt`).

## Licensing

- AGPL-3.0-or-later for the whole repo. New files open with a
  `Copyright (C) <year> David Neurieder` line and an
  `SPDX-License-Identifier: AGPL-3.0-or-later` header.