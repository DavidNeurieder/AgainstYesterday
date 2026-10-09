# Release checklist

Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later

The release-acceptance gates from the Android testing plan, adopted for this
repo (see `specification/android_test_plan_adoption.txt`). A release candidate
is ready only when every applicable gate below passes. A larger number of
passing tests is **not** a gate on its own.

Each gate marks what [CI] already enforces automatically and what [manual]
needs a person and a device. CI job names refer to
`.github/workflows/ci.yml` and `.github/workflows/nightly.yml`.

## Gate 1 — Functional correctness

- [ ] [CI] `flutter` job: `flutter analyze` clean, `flutter test` green
      (309 tests, 1 skipped only for the unbuilt FFI cdylib), including the
      real Rust engine over FFI.
- [ ] [CI] `test` job: `cargo fmt --check`, `cargo clippy -D warnings`,
      `cargo test --all-features`, `cargo doc`.
- [ ] Distance and race figures match deterministic fixtures, never the
      production helper: `test/gps_edge_cases_test.dart`,
      `test/race_outcomes_test.dart`, `rust/gps-engine/tests/gps_*.rs`.

## Gate 2 — Android permissions

- [ ] [CI] Widget coverage of the refusal states: services off → `GPS
      UNAVAILABLE` and the settings affordance (`test/polish_test.dart`,
      `test/device_gps_test.dart`).
- [ ] [CI] `android-integration-test` (API 34): `--device-gps` suite grants the
      permission while the test runs and fails if it cannot
      (`REQUIRE_DEVICE_GPS`).
- [ ] [manual] On a device: first grant, denial → retry, permanent denial →
      settings, revocation mid-session, and disabled location services. Confirm
      location is not collected before authorization and stops after denial.

## Gate 3 — Recording integrity

- [ ] [CI] Start, pause, resume, finish and save
      (`test/pause_resume_test.dart`, `test/record_route_test.dart`,
      `test/recording_flow_test.dart`).
- [ ] [CI] Interrupted-run recovery (`test/persistence_recovery_test.dart`,
      `test/lifecycle_test.dart`) and the on-device relaunch test
      (`integration_test/app_test.dart`).
- [ ] [CI] Exactly one activity is persisted across a rapid
      start/pause/resume/finish (`test/gps_edge_cases_test.dart`).
- [ ] [manual] Long recording survives screen-off and low-memory pressure
      (see the endurance matrix).

## Gate 4 — GPS reliability

- [ ] [CI] No false READY, no fabricated movement, no phantom jump across an
      outage, a stale fix, or the date line
      (`test/gps_edge_cases_test.dart`), plus the Rust torture/fixture suites
      (`rust/gps-engine/tests/gps_torture.rs`).
- [ ] [CI] The location subscription is stopped on completion/pause
      (`_stopDeviceStream` in the recording controller).
- [ ] [manual] Walk outside, under tree cover, and through a tunnel: the run
      must pause movement (not distance or the stopwatch) rather than invent it.

## Gate 5 — Device coverage

- [ ] [CI] Full journey on API 34 and the record-and-save smoke on API 24, the
      oldest supported release, on every PR.
- [ ] [CI] Nightly: API 36 smoke.
- [ ] [manual] The device matrix below (a reference Pixel and one other
      manufacturer).

## Gate 6 — Stability

- [ ] [CI] Nightly `repeat` job runs the demo journey twice with a fresh
      install between runs, so state leakage and flakes surface.
- [ ] [manual] No unexplained flakes in repeated runs and no known critical
      crashes in the release candidate.

## Gate 7 — Performance

- [ ] [manual] Endurance, battery, memory, and responsiveness meet the budgets
      in the endurance matrix below. There is no automated gate yet.

## Gate 8 — Release artifact

- [ ] [manual] `make build-release` (release APK with `USE_DEVICE_GPS=true` and
      the Rust cdylibs bundled) installs, launches, and preserves data.
- [ ] [manual] The release build — minified, **separate from the debug build** —
      passes the smoke below. Never sign off on a debug artifact alone.

---

## Manual device matrix

Run the whole journey on at least one reference Pixel and one other
manufacturer (OEM background restrictions differ). Tick each device.

| Device | API | Grant | Record | Race | Relaunch | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| Pixel (reference) | 36 | | | | | |
| Pixel (reference) | 24 | | | | | min supported |
| Other OEM | 34 | | | | | e.g. Samsung/Xiaomi |

## Endurance and environment

- [ ] 30-minute run: the stopwatch, distance, and ghost gap stay consistent;
      the screen may sleep.
- [ ] 2-hour run: no memory growth, no dropped fixes, the activity saves.
- [ ] Battery: estimate the drain for a one-hour run and confirm it is
      acceptable.
- [ ] Storage almost full: the run still saves or fails with the retry
      affordance, never silently.
- [ ] Upgrade over existing data: install the new build on top of an install
      with routes, activities, and an interrupted-run snapshot; the library is
      intact and the interrupted run restores.
- [ ] Release-APK smoke: sideload the minified release APK, record a short run,
      finish, view the result, and relaunch.

## Privacy

- [ ] Location is not collected before the user authorizes it.
- [ ] A denial does not leave collection running.
- [ ] Completed recordings hold only their intended coordinates.
- [ ] Deleted activities are unreachable through normal flows.
- [ ] Release logs do not expose raw coordinates.
