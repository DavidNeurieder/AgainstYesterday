# gps-engine

A standalone, platform-independent Rust engine for:

```
GPS data → Track → cleaned Track → Route → Attempts → Performance → Ghost
```

It powers route matching and "you vs your previous self" ghost racing for
running and cycling. The crate has **no** Flutter, SQLite, network, or mobile
bindings: it is a pure, deterministic, synchronous library plus a small CLI.

## Run

```
cargo test
cargo run --example evaluate
cargo run --example analyze
cargo run --release --example bench -- --tracks 200
cargo run --example generate_corpus
cargo doc --no-deps
```

The `evaluate` example (§38–§40) turns the labeled corpus into a confusion
matrix with precision/recall/F1/false-positive-rate. The `bench` example (§34)
generates a deterministic synthetic corpus and times projection, processing,
discovery and the pairwise matching matrix. The `generate_corpus` example
(§33) writes the synthetic GPX corpus under `testdata/synthetic/`.

Everything can be exercised on Linux without a phone, GPS chip, or internet
connection.

## CLI

A companion binary ships with the library:

```
cargo run --bin gps-engine -- inspect    testdata/unit/noisy_loop.gpx
cargo run --bin gps-engine -- process    testdata/synthetic/clean.gpx --out /tmp/clean.gpx
cargo run --bin gps-engine -- compare    a.gpx b.gpx
cargo run --bin gps-engine -- discover   ./tracks/
cargo run --bin gps-engine -- evaluate   testdata/synthetic/
cargo run --bin gps-engine -- benchmark  ./tracks/
```

`inspect`/`process` summarize a track; `compare` prints the structured
`MatchScore` metrics plus a SAME/DIFFERENT classification; `discover` clusters
tracks into routes; `evaluate` runs the labeled-corpus metrics against a
`manifest.json`; `benchmark` times discovery and the pairwise matrix
(§34/§36/§37 of the crate plan). Only the benchmark reads the wall clock.

## Module map

| Module      | Responsibility                                              |
|-------------|-------------------------------------------------------------|
| `units`     | `Distance`, `Duration`, `Speed`, `Timestamp` newtypes       |
| `geo`       | distance, bearing, interpolation, polyline, projection      |
| `track`     | `TrackPoint` / `Track` model, validation, statistics        |
| `track`     | processing: filter / simplify / resample-by-distance       |
| `route`     | canonical `Route` model + projection to the distance axis   |
| `route`     | pairwise matching: structured `MatchScore` diagnostics      |
| `route`     | discovery: cluster recordings into routes (`RouteCatalog`)  |
| `route`     | canonicalization: one robust `Route` from a cluster         |
| `attempt`   | GPS → route distance → elapsed time (`time_at`, `distance_at`) |
| `attempt`   | performance comparison: pointwise `ComparisonPoint`s        |
| `ghost`     | PB-vs-live duel: `GhostState { distance, difference, ahead }` |
| `gpx`       | GPX ↔ `Track` adapter (RFC 3339 times, Garmin speed ext)   |
| `synthetic` | deterministic synthetic GPS generation for tests            |
| `evaluate`  | standard pipeline, §39 manifest, confusion matrix (§38–40)  |
| `error`     | typed errors                                                |

Planned (later phases): FFI bindings for Flutter (`#43` postpones them, along
with SQLite/network features). Matching exposes individual metrics (start/end
distance, length ratio, spatial overlap, direction) rather than one magic
score — the provisional `overall_score` is documented as tunable against the
labeled corpus, and the matcher's conservative geometry defaults are measured
(see below).

## Labeled-corpus metrics (§38–§40)

`examples/generate_corpus.rs` produces a deterministic corpus (ten recordings
of one ~4.9 km loop — clean / noisy / sparse / gapped / stopped / outliers /
reversed / detour — plus one genuinely different route) and a `manifest.json`
of ground truth for every pair. `cargo run --example evaluate` reports the
confusion matrix (currently, with `MatchConfig` defaults):

```
precision:           1.000        recall: 0.778        F1: 0.875
false-positive rate: 0.000
```

Precision-first is deliberate (§23/§40): no different route is ever accepted.
The measured recall gap is exactly the `outliers.gpx` family — its remaining
spikes keep it just under the 0.6 spatial-overlap floor, a documented false
negative; `tests/evaluate.rs` pins these floors so any regression trips it.

## Fixtures (§33)

Three categories, deliberately never mixed:

- `testdata/unit/` — tiny hand-written GPX fixtures (loaded by
  [`tests/gpx.rs`](tests/gpx.rs)).
- `testdata/synthetic/` — generated from a known loop by
  `examples/generate_corpus.rs` (clean/noisy/sparse/gapped/stopped/outliers/
  reversed/detour + `other.gpx`, and the §39 `manifest.json`), round-tripped
  by `tests/roundtrip.rs` and evaluated by `tests/evaluate.rs`.
- `testdata/real/` — your own recordings; `testdata/real/*.gpx` is git-ignored.
  External datasets are for the FFI milestone.

## GPX boundary robustness (§41)

GPX is user-controlled external data. `tests/gpx_robustness.rs` asserts the
parser never panics on arbitrary bytes/text/XML (property-tested), and covers
empty documents, broken XML, invalid coordinates, missing/duplicate
timestamps, huge multi-megabyte tracks, and multiple `<trk>`/`<trkseg>`
flattening — every path returns a typed `GpxError`, never a panic.

## Engine complete (§44)

The full v0.1 pipeline from the plan is implemented and verified:

```
GPX → Track → validation → filtering → simplification → resampling → Route
    → Attempt / Matcher → Discovery → canonical route → Performance → Ghost
```

`cargo test` runs 178 tests (plus property cases) with no phone, GPS chip, or
internet connection — the definition of "engine complete" in §44.

## License

`AGPL-3.0-or-later` — the whole repository, this crate included. The full text
is in [../../LICENSE](../../LICENSE), the SPDX id comes from the
workspace `Cargo.toml`, and every source file here opens with a
`SPDX-License-Identifier: AGPL-3.0-or-later` header.
