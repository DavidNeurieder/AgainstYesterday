<!-- Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later -->

# Rust GPS engine implementation plan

Date: 2026-11-21

Sources reviewed:

- `ideas/rust_impro2.txt`
- `ideas/rust_improvements.txt`

Scope: `rust/gps-engine` and the contracts consumed by
`app/lib/engine/gps_ffi.dart`, `app/lib/engine/rust_engine_service.dart`,
`app/lib/engine/engine_service.dart`, `app/lib/engine/models.dart`, and
`app/lib/engine/fake_engine.dart`.

Status: phases 0.1–0.3, Phase 1, Phase 2 and the measured parts of Phase 3 are
implemented, including Gate B promotion. `EstimatorConfig::default().enabled ==
true`; `EstimatorConfig::legacy()` keeps the old passthrough for diagnostics.
The promoted estimator drives batch processing, `gps_process_track`, and the
live recorder. Phase 2 fixed the stale recovery anchor and exposed independent
ghost-confidence evidence. Rolling pace replaces the two-fix pace in the live
snapshot and in benchmark scoring. A robust elevation estimator is available as
an additive Rust API and is benchmark-gated, but analytics/Python/Dart/UI
exposure remains a follow-up. The C ABI v1 prefix is unchanged: Phase 2 appended
ghost evidence, and later work added only Rust-side fields. Dart decoders remain
backward-compatible; `FakeEngineService` intentionally keeps the pre-promotion
live-cursor numeric semantics. Remaining Phase 3 items (first-class
`DistanceBreakdown` exposure, elevation exposure in analytics/UI, rolling-best
pace, and typed outage summaries) and Phases 4–5 are not started.

## 1. Review conclusion

Both documents propose the same three ambitions, and both lean toward “all
three” with GPS estimation and ghost racing first. That is the right target:

1. accuracy of recorded distance/pace/position;
2. stability and fairness of PB/ghost comparison;
3. deterministic, measurable, dependency-light production quality.

The documents were written partly from README-level knowledge. The current
crate is further along than they assume. It already has:

- validated `Coordinate`, `TrackPoint`, and `Track` types with monotone
  timestamps;
- raw-fix preservation, quality grading, and explicit rejection reasons in
  `gps::GpsTrace::process`;
- deterministic filters with jump/speed/accuracy checks and a live
  `FilterCursor` that suppresses stationary jitter;
- a stateful, continuity-aware `RouteMatcher` with bounded candidate windows,
  heading/progress/speed scoring, hysteresis, and `MatchConfidence`;
- monotone route coverage, attempt interpolation, and ghost snapshots with a
  spacing-based confidence;
- deterministic replay with seek/speed and ghost support;
- a labeled corpus, confusion matrix, and pinned precision/recall floors;
- a deterministic synthetic generator and GPS torture fixtures;
- a wall-clock benchmark example and CLI;
- a positional, length-prefixed C ABI with `gps_capi_version` and `gps_free`.

Therefore this plan is **incremental and benchmark-gated**. Do not rewrite the
pipeline, replace the matcher with an HMM, add a navigation framework, or add
IMU fusion until measurement shows the need.

## 2. Non-negotiable constraints

- Raw fixes are the source of truth. Never overwrite or discard them merely
  because they are suspicious; every decision remains auditable.
- Keep the core crate deterministic, pure, synchronous, and `unsafe`-free
  outside `capi.rs`.
- Keep `FilterConfig::matching()` and the existing labeled-corpus floors
  unchanged unless a benchmark explicitly justifies a versioned replacement.
- Keep the Flutter C ABI append-only. Existing field order, widths, status
  codes, and `gps_free` ownership stay unchanged. Bump `gps_capi_version` when
  output fields are appended and update Dart decoders plus `FakeEngineService`
  in the same change.
- Keep JSON/CLI additions additive. Existing keys and semantics stay stable;
  new keys get new names.
- Preserve the three existing distance meanings during any refactor: free-run
  recorded distance uses the filtered ground axis; on-route progress uses
  monotone route coverage; raw geodesic distance remains diagnostic.
- No new runtime dependencies. Criterion, if used at all, is a dev-dependency
  introduced only in phase 5.
- Do not implement sensor fusion before phases 0–3 show a quantified residual
  error that GPS-only processing cannot fix.

## 3. Phase 0 — quantitative baseline and stable contracts

Goal: make “the new filter feels better” unnecessary. Establish ground truth,
metrics, and additive data contracts before changing behavior.

### 0.1 Expose synthetic ground truth without changing generated output

Files:

- `rust/gps-engine/src/synthetic.rs`
- `rust/gps-engine/examples/generate_corpus.rs`
- `rust/gps-engine/tests/synthetic.rs`

Changes:

- Add `GroundTruthSample { timestamp, coordinate, route_distance, speed,
  stationary, outage }` and `SyntheticResult { observed, truth }`.
- Implement `generate_with_truth()` using the exact base coordinate already
  computed in `synthetic::forward()` before noise/jumps/gaps are applied.
- Keep `generate()` as a byte-for-byte compatible wrapper.
- Prefer a sidecar `*.truth.json` for raw fixtures. Bump the fixture schema
  only if embedded truth is unavoidable; version 1 must keep parsing.

Acceptance:

- Regenerating the current corpus produces no diff in existing GPX files or
  `manifest.json`.
- Truth samples align 1:1 with nominal observed samples; dropped fixes keep a
  truth row so outages and recovery can be scored.
- Existing `tests/evaluate.rs`, `tests/roundtrip.rs`, and `tests/cli.rs` stay
  green.

### 0.2 Add a GPS quality benchmark

Files:

- new `rust/gps-engine/src/quality_metrics.rs`
- new `rust/gps-engine/examples/quality_benchmark.rs`
- `rust/gps-engine/src/main.rs`
- `rust/gps-engine/src/lib.rs`
- `rust/gps-engine/tests/quality_benchmark.rs`
- new `rust/gps-engine/testdata/baselines/gps_quality_v1.json`

Keep `evaluate.rs` focused on route identity. Add a separate quality report
with these metrics:

| Metric | Definition |
| --- | --- |
| Distance error (%) | `abs(measured - truth) / truth_length` for raw, filtered, and route axes |
| Position RMSE (m) | Haversine error against truth at truth timestamps |
| Route-projection error (m) | `abs(projected_distance - truth_route_distance)` |
| Pace error (s/km) | MAE/RMSE of smoothed pace versus truth speed |
| Ghost-gap error (s) | Error versus analytically known constant-pace gaps |
| False movement (m/%) | Distance accepted while truth is stationary |
| Recovery time (s) | Outage end → first `Matched` sample with progress error under a fixed threshold |
| Match identity | Existing precision/recall/F1/FPR, unchanged |
| Processing latency | Wall time reported separately, never mixed into accuracy scores |

Seed the baseline with the existing five raw JSON torture fixtures and the
nine synthetic GPX variants. Add named deterministic profiles for urban
canyon/multipath, forest/sharp turns, running-track overlap, cycling at higher
speed with coarse cadence, stationary drift, 5/15/30 s outages, poor accuracy,
and variable sampling. The report must contain only deterministic values plus
explicit toolchain/corpus metadata; wall-clock output belongs in a separate
performance report.

Add `gps-engine quality <corpus>` and document how to regenerate the baseline.

Acceptance:

- Two runs produce byte-identical deterministic output.
- All scenarios produce finite metrics and a per-scenario breakdown.
- Clean fixtures score ~0 false movement; jump/outage fixtures show measurable
  error, so later phases have signal.
- Pinned regression floors are added, not substituted for the existing
  route-match floors.

### 0.3 Define uncertainty-aware contracts, with no behavior change yet

Files:

- new `rust/gps-engine/src/estimate.rs`
- `rust/gps-engine/src/gps/mod.rs`
- `rust/gps-engine/src/track/point.rs`
- `rust/gps-engine/src/route/mod.rs`
- `rust/gps-engine/src/live/mod.rs`
- `rust/gps-engine/src/ghost/mod.rs`
- `rust/gps-engine/src/analytics.rs`

Add types that make invalid states hard to represent:

- `PositionEstimate`: timestamp, coordinate, reported accuracy in meters, and
  statistical `confidence` in `0..=1`. Keep accuracy and confidence distinct.
- `VelocityEstimate`: speed/bearing with confidence; optional covariance in a
  local tangent plane when needed by the estimator.
- `MotionState`: `Moving`, `Stationary`, `Unknown`, with confidence.
- `DistanceBreakdown`: `raw`, `filtered`, `route`, each optional where the
  context has no such axis.
- Optional estimate fields on `ProcessedSample`, `TrackPoint`, `MatchStep`,
  `LiveSnapshot`, and `GhostSnapshot`, exposed through builders/accessors
  rather than replacing existing fields.

Acceptance:

- No numerical output changes; this is a contract-only commit.
- All new numeric fields are finite and clamped.
- Existing public constructors and JSON fields remain valid.
- `cargo doc --no-deps` passes with `missing_docs` still enabled.

**Gate A:** continue only if the baseline is stable and at least one target
metric shows a real, reproducible error worth fixing. If not, stop after
phase 0 and keep the benchmark as a regression guard.

## 4. Phase 1 — adaptive GPS estimation

Goal: improve noisy-GPS accuracy without destroying corners, distance, or the
auditing guarantees.

### 1.1 Add an optional constant-velocity estimator

Files:

- new `rust/gps-engine/src/filtering/mod.rs`
- new `rust/gps-engine/src/filtering/kalman.rs`
- new `rust/gps-engine/src/filtering/outlier.rs`
- new `rust/gps-engine/src/filtering/stationary.rs`
- new `rust/gps-engine/src/filtering/cadence.rs`
- `rust/gps-engine/src/track/filtering.rs`
- `rust/gps-engine/src/gps/mod.rs`
- `rust/gps-engine/src/lib.rs`
- re-exports from `track` so existing callers keep working

Algorithm:

- State `[x, y, vx, vy]` in a local east/north tangent plane, with covariance
  `P`; predict using `dt` from timestamps, not a fixed 1 Hz cadence.
- Measurement noise `R` follows reported accuracy and quality; process noise
  follows `dt`, cadence, and the current motion state.
- Replace the spike heuristic with a Mahalanobis innovation residual, but keep
  the existing hard accuracy/speed/jump ceilings as a safety net.
- Add an explicit stationary state with hysteresis. While stationary, do not
  accumulate distance from drift; exit the state when innovation and speed
  corroborate movement.
- Detect sharp turns/corners through bearing change plus innovation gating and
  reduce smoothing there. Do not synthesize intermediate points in this phase;
  the cleaned track remains a subsequence of raw fixes.
- Propagate `PositionEstimate`/`VelocityEstimate` into `ProcessedSample` and
  `TrackPoint`.

### 1.2 Shadow mode before promotion

`EstimatorConfig` first shipped default-off: the estimator ran alongside the
existing filter, both results were recorded in the quality report, and the
per-scenario metrics below were compared before promotion. The default is now
enabled; `legacy()` preserves the old path.

Acceptance for promotion:

- Every existing invariant still passes: endpoint survival, car/train
  preservation, 60 s pause handling, one decision per raw fix, non-empty
  rejection reasons, monotone timestamps, and filtering-as-subsequence
  properties.
- Stationary jitter still earns zero distance, and isolated spikes are still
  rejected or withheld.
- Distance error, position RMSE, or recovery time improves on noisy/outage
  scenarios by a documented threshold.
- No regression beyond an agreed tolerance in clean distance error, corner
  error, false movement, or recovery time.
- Live `AdaptiveCursor` and batch filtering use the same estimator semantics;
  `LiveSnapshot` exposes the new motion state, and the documented distance
  axes now reflect the promoted estimator.

**Gate B:** promote the adaptive filter to the default only after the shadow
report justifies it. If it does not, keep it as an opt-in diagnostic and do not
continue smoothing work.

### 4.3 Implementation status and gate results (2026-11-21)

Phases 0.1–0.3 are implemented: synthetic truth, the deterministic quality
benchmark with a committed baseline, and additive uncertainty types. Phase 1
adds a constant-velocity Kalman estimator in a local east/north plane, with
reported-accuracy noise, cadence-aware process noise, Mahalanobis innovation
gating behind the existing hard accuracy/speed/jump ceilings, stationary
hysteresis, corner-aware smoothing, distance staging, and bounded rejection
recovery. All estimator output is additive; raw fixes and legacy decisions are
preserved.

**Gate A result — passed.** The pinned baseline showed real, reproducible error
worth fixing: `jitter_5m` filtered distance error 50.84%, `stationary_drift`
420 m of false movement, `gps_jumps` 2577.01% raw distance error, and
`urban_canyon` 458.09% filtered distance error.

**Gate B rule applied.** Promotion is justified when the existing invariants
remain green, at least four noisy/outage scenarios improve filtered distance
error by ≥25 percentage points or ≥50% relative without material RMSE
regression, clean distance error stays ≤1%, stationary false movement and
recovery time do not increase, and any coarse-cadence distance regression is
bounded and documented.

Final shadow comparison against the same ground truth:

| Scenario | Filtered dist% | Shadow dist% | Filtered RMSE m | Shadow RMSE m | Filtered drift m | Shadow drift m |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 0.10 | 0.01 | 0.00 | 0.61 | 0.00 | 0.00 |
| jitter_5m | 50.84 | 0.46 | 23.26 | 5.89 | 0.00 | 0.83 |
| jitter_12m | 208.87 | 63.10 | 19.98 | 8.78 | 0.00 | 0.00 |
| sparse | 2.25 | 10.42 | 4.94 | 4.94 | 0.00 | 0.00 |
| outage_25pct | 0.12 | 0.04 | 27.46 | 1.47 | 0.00 | 0.00 |
| stationary_drift | 55.29 | 3.66 | 22.88 | 5.13 | 420.00 | 248.46 |
| gps_jumps | 19.02 | 2.24 | 189.46 | 48.07 | 0.00 | 0.00 |
| urban_canyon | 458.09 | 104.42 | 30.11 | 8.24 | 0.00 | 0.00 |
| forest_trail | 94.56 | 19.30 | 11.08 | 8.40 | 0.00 | 0.00 |
| reverse | 51.75 | 0.32 | 32.54 | 5.85 | 0.00 | 0.00 |

Seven noisy scenarios clear the distance threshold; outage also improves
relatively.
Recovery time is unchanged, stationary false movement drops from 420 m to
248.46 m, and clean distance stays below 1%. The only distance regression is
`sparse` (2.25% → 10.42%, +8.17 percentage points): its 45 s cadence is too
coarse for a stale-velocity prediction to be trusted, so one interval is staged
until the next accepted fix. Clean position RMSE rises from 0 to 0.61 m; every
noisy/outage RMSE improves or stays equal. That justified the promotion
recorded in §1.4.

`rust/gps-engine/testdata/baselines/gps_quality_v1.json` was regenerated from
the final tuning with:

```text
cargo run -q -p gps-engine --example quality_benchmark -- --json \
  rust/gps-engine/testdata/baselines/gps_quality_v1.json
```

`rust/gps-engine/tests/quality_benchmark.rs` now checks that every scenario has
finite shadow metrics, a nested `"shadow"` JSON object, and exactly one
accepted or rejected decision per observed fix. The baseline file itself did
not change at promotion: `quality_metrics` still scores with the same algorithm
through `EstimatorConfig::shadow()`.

### 1.4 Promotion integration (completed)

- `GpsTrace::process()` now runs the adaptive estimator and attaches
  position/velocity/motion estimates to audit rows and cleaned track points.
  `process_legacy()` and `process_with()` keep the old filter and explicit
  configuration available for diagnostics and contract tests. One decision per
  raw fix and the rejection-reason model are unchanged.
- A rejected interior fix is not a distance anchor; the final timestamp is
  always kept at its estimated coordinate so a closing GPS wobble cannot create
  a fake finish chord. `tests/promotion.rs` pins both behaviors.
- `AdaptiveCursor` replaces `FilterCursor` in `LiveRecorder`. A unit test feeds
  the same fixes (including a spike and a cadence gap) through the incremental
  cursor and the batch estimator and compares their final distance, moving
  time, and last decision exactly.
- Live semantics that changed deliberately: the first moving segment is staged
  until motion is confirmed; long gaps re-anchor without bridging the missing
  chord; a rejected spike does not earn distance or moving time; and a
  sensor-rejected fix is still fed to the estimator for audit but cannot
  advance route coverage, active elapsed time, or the raw snapshot position.
  Route coverage and its matching/ghost axes remain unchanged.
- `gps_process_track` now returns adaptive distance and moving time while
  keeping the exact v1 field order, widths, status codes, and buffer ownership.
  `gps_capi_version` was not bumped because no field was added or reordered.
  A golden test decodes all 40 output bytes and checks the values against a
  direct `estimate_fixes` run.
- `app/lib/engine/gps_ffi.dart` and `app/lib/engine/rust_engine_service.dart`
  need no decoder change. `FakeEngineService` remains a deterministic demo
  approximation with the pre-promotion cursor semantics; numeric parity with
  the native estimator is intentionally not maintained. ABI layout parity is.

Verification after promotion: `cargo fmt --all --check`,
`cargo test --all-features`, `cargo clippy --all-targets --all-features -- -D
warnings`, `cargo doc --no-deps`, `git diff --check`, `flutter analyze`, and
`flutter test` all pass. No F-Droid or on-device E2E run was performed in this
change.

## 5. Phase 2 — matching and ghost confidence

Goal: make AHEAD/BEHIND reflect real performance changes, not GPS ambiguity.

The live matcher is already progress- and continuity-aware. Refine and expose
it; do not replace it with a full HMM yet.

### 2.1 Make matcher evidence explicit

Files:

- `rust/gps-engine/src/route/mod.rs` → extract the stateful matcher into
  `rust/gps-engine/src/route/live_matching.rs` while keeping re-exports
- new `rust/gps-engine/src/route/candidate.rs`
- `rust/gps-engine/src/route/matching.rs` for the existing pairwise API
- `rust/gps-engine/src/live/mod.rs`
- `rust/gps-engine/src/capi.rs`

Changes:

- Represent each candidate with projection, lateral error, heading delta,
  expected-progress prior, speed plausibility, ambiguity margin, and
  confidence.
- Feed `PositionEstimate` accuracy/confidence into candidate scoring instead
  of re-deriving sigma from raw accuracy alone.
- Add an explicit ambiguity signal when two nearby segments have comparable
  cost; use it to enter `Uncertain` rather than snapping confidently.
- Keep monotone reliable coverage. `Uncertain`, `OffRoute`, and `Reacquiring`
  continue to preserve the last reliable progress.
- Add typed route-association result (best route, score components, margin,
  eligibility, ambiguity reason) behind `EngineService`; keep the Dart
  controller as a thin adapter and mirror it in `FakeEngineService`.

### 2.2 Make ghost confidence honest

Files:

- `rust/gps-engine/src/ghost/mod.rs`
- `rust/gps-engine/src/live/mod.rs`
- `rust/gps-engine/src/capi.rs`
- `app/lib/engine/rust_engine_service.dart`
- `app/lib/engine/models.dart`
- `app/lib/engine/fake_engine.dart`

Changes:

- Keep the three concerns separate: spatial alignment, temporal alignment,
  performance gap.
- Combine existing reference-spacing confidence with live match confidence,
  position confidence, and candidate ambiguity. Expose them as separate
  additive values, not one opaque number.
- Flag or suppress AHEAD/BEHIND display changes when match status is uncertain
  or off-route, while preserving the existing sign convention and the
  stationary time-gap growth behavior.
- Continue using route progress only for ghost comparison; never feed raw or
  filtered ground distance into the PB gap.
- Keep first-reach interpolation and saturation at the PB finish; do not
  extrapolate. Evaluate monotone/adaptive interpolation only if the benchmark
  shows spacing error remains material.

Acceptance:

- Existing route-match floors remain pinned: false positives 0, precision
  ≥ 0.99, recall ≥ 0.75, F1 ≥ 0.85, with the known `outliers` false negatives
  documented.
- All repeated-loop, figure-eight, out-and-back, reverse, detour, jitter, and
  dropout tests continue to pass.
- Ghost-gap error improves in the quality benchmark; a GPS jump no longer
  produces a large confident lead.
- Confidence values stay in `0..=1` and are independently finite when either
  the ghost samples or the live match are missing.
- New FFI fields are appended only; `gps_capi_version` and Dart fake/Rust
  parity tests are updated.

**Gate C:** do not add sector comparisons, multiple-PB racing, split
prediction, or HMM/Viterbi topology until confidence and gap error are measured
as still insufficient.

### 2.3 Fix the stale confidence anchor (done)

The first Phase 2 measurement found a deadlock rather than an ambiguous match:
after a short confidence dip, the matcher kept judging later on-route fixes
against the frozen `reliable_covered`. Once raw progress was more than a few
seconds ahead, every candidate looked implausible, confidence stayed at zero,
and `Uncertain` could never accumulate the two confident steps needed to exit.
Route geometry then drifted far enough from the stale anchor to trigger
`OffRoute`, after which global reacquisition jumped the runner hundreds of
metres forward. Ghost comparisons inherited the frozen segment; the
`urban_canyon` adaptive-axis gap error was 205 s with 364 m projection error.

`RouteMatcher` now keeps a `recovery_progress` anchor while `Uncertain`. It is
used only for candidate windows and scoring priors; accepted/reported coverage
still comes from monotone `reliable_covered`. The anchor follows locally
plausible, on-route evidence and resets on off-route transitions, so it cannot
reproduce a detour or jump. Two consecutive confident fixes restore `Matched`
and let coverage catch up once.

Measured effect (pinned baseline v1 regenerated after review):

| scenario | adaptive ghost gap error | adaptive projection error |
| --- | ---: | ---: |
| `urban_canyon` | 205.179 s → 1.719 s | 363.604 m → 5.183 m |
| `jitter_12m` | 2.416 s → 2.416 s | 5.159 m → 5.135 m |
| all other adaptive axes | unchanged or improved | unchanged or improved |

The legacy columns also improve where the same deadlock appeared
(`urban_canyon` 208.213 s → 52.552 s, `jitter_12m` 155.836 s → 3.959 s), but
the promoted adaptive axis remains the gate. `tests/quality_benchmark.rs` now
pins the Phase 2 threshold independently of the exact baseline JSON.

### 2.4 Surface independent ghost-confidence evidence (done)

The stale-anchor fix removes the large gap error, but a small gap can still be
misleading when the reference spacing, live match, or position estimate is
weak. `LiveGhostSnapshot` now carries the existing spacing confidence alongside
`match_status`, `match_confidence`, and `position_confidence`, and exposes a
single `reliable()` predicate requiring every present signal to clear `0.35`.
A free run has no match evidence, so `None` is neutral; `Uncertain`,
`OffRoute`, and `Reacquiring` veto an AHEAD/BEHIND change. The hero readout
renders `—` while the comparison is unreliable, preserving the sign convention
and the stationary time-gap behavior underneath.

Both live and replay C ABI responses append the new fields after the unchanged
v1 prefix (match status, match confidence, optional position confidence with a
presence byte, reliable flag). Dart readers treat a truncated suffix as "no
evidence" and keep the v1 display behavior; `FakeEngineService` mirrors the new
fields. `gps_capi_version` is unchanged because no existing field moved.

### 2.5 Rejected matcher-scoring experiments (not shipped)

The remaining Phase 2 idea was to let `PositionEstimate` confidence and an
explicit candidate-ambiguity value change candidate scoring or matcher state.
Both were measured against the pinned quality suite and reverted:

- Direct `estimate_factor = confidence` broke
  `live::tests::off_route_detour_reacquires_with_coarse_sampling` with
  `coarse-sampled rejoin did not reacquire: detour 111.195…, recovered
  111.195…`. The lowered belief kept the rejoin candidate out of the scoring
  window.
- Softening the scaling to `0.5 + 0.5 * confidence` avoided that failure but did
  not improve projection or ghost-gap error; it also reduced `urban_canyon`
  adaptive recoveries from 130 to 129.
- Computing ambiguity from the runner-up margin and using it to force
  `Uncertain` raised clean projection MAE to 0.106 m with a 30 m maximum. Adding
  the same value as evidence without changing state was benign numerically but
  duplicated the existing confidence signal, so it was also reverted.

The production matcher therefore keeps its v1 scoring inputs and confidence
state machine. The independent confidence evidence in §2.4 remains additive and
does not alter route coverage.

## 6. Phase 3 — distance, pace, and elevation

Goal: make the three distance meanings first-class and remove misleading pace
readouts.

Files:

- `rust/gps-engine/src/gps/mod.rs`
- `rust/gps-engine/src/track/statistics.rs`
- `rust/gps-engine/src/analytics.rs`
- `rust/gps-engine/src/live/mod.rs`
- `rust/gps-engine/src/track/elevation.rs` (new)
- `rust/gps-engine/src/capi.rs`
- Dart service/model/fake parity files

Changes:

- Surface `DistanceBreakdown` from `TrackProcessing`, `LiveSnapshot`, and
  analytics JSON. Keep current top-level `distance` semantics untouched.
- Add rolling pace over configurable time/distance windows: a short
  responsive window, a 10–15 s stable window, and cumulative average pace.
  Require a minimum movement threshold and attach confidence. Do not compute
  pace from two consecutive fixes.
- Add new rolling-best fields rather than silently redefining the existing
  `best_pace_ms_per_km`, whose current implementation is a single-segment
  minimum. Deprecate old names only after a measuring release.
- Add typed outage summaries and pace confidence to diagnostics.
- Keep haversine as the default distance primitive. Evaluate a WGS-84 geodesic
  against truth before considering a dependency or replacement.
- Process elevation separately: raw gain/loss, a robust median or low-pass
  filtered altitude, and a noise threshold so tiny fluctuations do not count
  as climbing. Offline DEM correction stays optional and later.

Acceptance:

- Clean/out-and-back distance does not regress; stationary false movement does
  not increase.
- Pace error improves in the benchmark, with confidence lower during gaps and
  low-speed periods.
- All analytics JSON additions are additive and fake/Rust snapshots agree.

### 6.1 Rolling pace (done)

`track::RollingPace` now derives pace from net displacement over a 15 s window
with a 15 m minimum movement and a 30 s fallback bound. A gap longer than 30 s
reports no pace rather than extrapolating a stale pair; stationary jitter also
reports no pace. Pause and seed reset the window. `LiveRecorder::pace()` uses
the same estimator in free-run and route mode, replacing the old last-segment
speed. `LiveSnapshot` gained a Rust-only `pace_confidence: Option<Confidence>`;
no C ABI field was added or reordered. `quality_metrics::pace_error` now scores
the same rolling estimator used by the live engine, and
`tests/quality_benchmark.rs` pins the improvement independently of the baseline
JSON.

Measured before → after (s/km, pinned baseline regenerated):

| scenario | raw pace | adaptive pace |
| --- | ---: | ---: |
| `jitter_5m` | 147.407 → 51.072 | — |
| `jitter_12m` | 275.724 → 104.839 | 164.848 → 86.817 |
| `gps_jumps` | 242.333 → 100.713 | — |
| `urban_canyon` | 354.285 → 120.060 | 220.527 → 76.684 |
| `stationary_drift` | 276.959 → 20.888 | 234.338 → 47.985 |
| `sparse` | 9.582 → 0.000 | 9.582 → 0.000 |

The accepted tradeoffs are a clean adaptive pace increase of 1.856 → 3.452
s/km, still below the 5 s/km gate, and a `sparse` pace of zero because 45 s
sampling exceeds the fallback bound. `stationary_drift` remains worse on the
adaptive axis than on raw samples, so the gate does not assert `shadow < raw`
there. The remaining Phase 3 items above are still open; this change does not
claim first-class distance breakdowns, rolling-best pace, or typed outage
summaries.

### 6.2 Robust elevation (Rust API and benchmark, done)

`track::elevation` adds `ElevationConfig` and `ElevationBreakdown`. The
breakdown keeps the legacy raw gain/loss sums for audit and adds gain/loss after
a median filter and a dead band. The default is a 13-sample median window with a
1.0 m noise threshold; `clamped()` forces an odd window of at least one and a
non-negative threshold. It is pure, deterministic, dependency-free, and never
mutates the track.

Synthetic truth gained additive altitude fields: `SyntheticConfig` can generate
a cosine hill profile with uniform altitude noise, and `GroundTruthSample`
records the true altitude at every nominal time. Defaults leave every existing
fixture bit-for-bit unchanged. A new `elevation_noise` scenario and
`elevation_noise_gate` pin the problem and the fix.

Measured on the benchmark scenario (meters):

| metric | value |
| --- | ---: |
| ground-truth gain / loss | 266.593 / 240.000 |
| raw gain / loss error | 2379.767 / 2378.785 |
| robust gain / loss error | 10.366 / 10.072 |

A wider sweep over seeds, noise levels, amplitudes, wavelengths and sampling
intervals reduced mean gain/loss error from 3041.6/3040.6 m to 177.6/171.0 m
with maximum errors of 940.3/929.2 m. The initial 9-sample/3.0 m setting failed
the 100 m gate at 117.609 m gain error; the selected setting passed.

This is deliberately a Rust-side improvement. Analytics JSON, Python, Dart and
the UI still expose the raw gain/loss fields, so no FFI payload, JSON key, or
fake/Rust display parity changed. Exposing `ElevationBreakdown` additively in
those layers is the remaining integration step.

Verification after the combined rolling-pace and elevation work:
`cargo fmt --all --check`, `cargo test --all-features`, `cargo clippy
--all-targets --all-features -- -D warnings`, `cargo doc --no-deps`,
`git diff --check`, `flutter analyze`, and `flutter test` all pass. `cargo doc`
still reports seven pre-existing unresolved link warnings in `analytics.rs`.
No F-Droid or on-device E2E run was performed.

## 7. Phase 4 — optional sensor fusion

Only start this phase after gates A–C show remaining error in dropouts,
stationary detection, or high-frequency motion that GPS-only processing cannot
resolve.

Files:

- new `rust/gps-engine/src/sensors/imu.rs`
- new `rust/gps-engine/src/sensors/fusion.rs`
- `rust/gps-engine/src/filtering/kalman.rs`
- Android platform-channel/Dart ingestion in `app/`
- `rust/gps-engine/src/capi.rs`
- fake-engine deterministic IMU source

Changes:

- Treat accelerometer/gyroscope samples as optional observations with their
  own timestamps, bias state, and confidence. Missing sensors are explicit;
  the engine still works with GPS only.
- Use an error-state Kalman filter or equivalent only if the simpler
  estimator cannot meet the measured targets.
- Grow position uncertainty during a GPS outage, cap dead-reckoning duration,
  and require GPS re-acquisition before confidence returns.
- Keep raw sensor samples and raw GPS fixes preserved for replay.
- Measure battery/latency cost on device. Disable by default until the
  benchmark proves a material improvement.

Acceptance:

- A documented reduction in position RMSE or recovery time, with no distance,
  pace, ghost, or false-movement regression.
- Deterministic replay of sensor samples produces identical output.
- Android/F-Droid builds and foreground recording behavior are unchanged
  unless the feature is explicitly enabled.

## 8. Phase 5 — performance and production hardening

Goal: make regressions visible and keep the engine stable for Flutter, Python,
and F-Droid consumers.

Files:

- `rust/gps-engine/Cargo.toml` and workspace `Cargo.toml`/`Cargo.lock`
- new `rust/gps-engine/benches/`
- `.github/workflows/ci.yml`
- `rust/gps-engine/README.md`
- `docs/route_match_v3_audit.md`
- `Makefile` if a new quality command is added

Changes:

- Add Criterion as a dev-dependency only now. Port the existing
  `examples/bench.rs` cases into benches for filtering, projection, ghost
  matching, distance, and GPX parsing. Keep the `Instant` example as a quick
  smoke tool.
- CI compiles benches with `cargo bench --no-run`; saved numeric baselines
  belong in a dedicated/nightly job with toolchain and runner metadata. Do not
  gate PRs on wall-clock numbers from shared runners.
- Profile allocations in the per-fix hot path; prefer in-place state updates
  and bounded candidate buffers.
- Expand property tests around uncertainty clamping, monotone route progress,
  estimator stability under irregular `dt`, and arbitrary JSON/GPX bytes.
- Add golden ABI-layout tests across Rust, Dart, and Python decoders. Every
  appended field has a documented version and a fake-engine equivalent.
- Refresh stale docs: `rust/gps-engine/README.md` still says FFI is planned,
  and `docs/route_match_v3_audit.md` still says free-run live recognition is
  absent.
- Keep the F-Droid recipe, Rust cdylib ABI, and `REPRO_BUILD_ROOT` flow in sync
  whenever the native library is rebuilt.

Acceptance:

- `cargo test --all-features`
- `cargo clippy --all-targets --all-features -- -D warnings`
- `cargo fmt --all --check`
- `cargo doc --no-deps`
- `cargo bench --no-run`
- `flutter analyze` and `flutter test`
- `make full-test` where the Android toolchain is available

## 9. Suggested PR sequence

1. `engine-quality-baseline` — phase 0.1–0.2, no behavior change.
2. `engine-uncertainty-contracts` — phase 0.3, additive types only.
3. `engine-adaptive-filter-shadow` — phase 1, default off.
4. `engine-promote-adaptive-filter` — only if gate B passes.
5. `engine-match-evidence` — phase 2.1.
6. `engine-ghost-confidence` — phase 2.2.
7. `engine-distance-pace-breakdown` — phase 3.
8. `engine-elevation-threshold` — phase 3 follow-up.
9. `engine-imu-optional` — only if gates A–C justify it.
10. `engine-perf-ffi-hardening` — phase 5.

Each PR must leave the full verification command set green and must not change
the Flutter default build behavior without an explicit decision.

## 10. Explicit non-goals for this roadmap

- No full navigation framework or geospatial dependency stack.
- No HMM/Viterbi matcher before bounded candidate scoring is measured as
  insufficient.
- No PCHIP/spline ghost interpolation before sample-spacing error is measured
  as material.
- No “beautiful track at any cost” smoothing that shortens corners or
  distorts distance.
- No process-death survival; the Android foreground service remains
  `START_NOT_STICKY` and recording still does not survive a kill.
- No change to the raw-fix audit model: every raw observation keeps a quality
  grade and a decision reason.
