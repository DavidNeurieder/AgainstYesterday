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
  define so installed phone artifacts record real GPS.
- Android cdylibs land in `app/android/app/src/main/jniLibs/<abi>/` via
  `app/tool/build_rust_engine_android.sh`; they are gitignored, so rerun the
  script after a clean checkout. `make install` and `make build-release` run
  it for you so the device artifact carries the real engine.

## Licensing

- AGPL-3.0-or-later for the whole repo. New files open with a
  `Copyright (C) <year> David Neurieder` line and an
  `SPDX-License-Identifier: AGPL-3.0-or-later` header.