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

- The app talks to the engine only through the `EngineService` abstraction;
  builds default to the deterministic `FakeEngineService`.
- `USE_RUST_ENGINE` and `REQUIRE_RUST_ENGINE` are compile-time `--dart-define`
  flags, not environment variables.
- Android cdylibs land in `app/android/app/src/main/jniLibs/<abi>/` via
  `app/tool/build_rust_engine_android.sh`; they are gitignored, so rerun the
  script after a clean checkout before building with `USE_RUST_ENGINE=true`.

## Licensing

- AGPL-3.0-or-later for the whole repo. New files open with a
  `Copyright (C) <year> David Neurieder` line and an
  `SPDX-License-Identifier: AGPL-3.0-or-later` header.