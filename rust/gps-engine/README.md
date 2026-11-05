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
cargo run --bin gps-engine -- map        a.gpx [more.gpx|dirs...] [--out map.html]
cargo run --bin gps-engine -- discover   ./tracks/
cargo run --bin gps-engine -- evaluate   testdata/synthetic/
cargo run --bin gps-engine -- benchmark  ./tracks/
```

`inspect`/`process` summarize a track; `compare` prints the structured
`MatchScore` metrics plus a SAME/DIFFERENT classification; `map` writes a
self-contained HTML page that overlays one or more tracks on a MapLibre
basemap; `discover` clusters tracks into routes; `evaluate` runs the
labeled-corpus metrics against a `manifest.json`; `benchmark` times discovery
and the pairwise matrix (§34/§36/§37 of the crate plan). Only the benchmark
reads the wall clock. `map`, `benchmark`, `discover` and `group` all load their corpus
the same tolerant way: unreadable recordings are reported on stderr and
skipped, and a corpus with no usable track fails. `group` clusters the
corpus and copies each recording into `<out>/route_<id>/` so tracks on
the same route land in the same folder (`--move` to move instead). `evaluate` is the one command
that needs ground truth:
it reads `manifest.json` from the corpus directory (a missing manifest reports
the path plus a hint and the synthetic corpus as an example) and loads only the
recordings the manifest references, so unrelated or corrupt files in the same
directory are ignored.

Matching is O(pairs × points²) by design, but the constant work is paid once:
`PreparedTrack` indexes a recording's polyline, segment boxes, cumulative
distances, and 50 m length basis, and `compare_prepared` /
`compare_either_direction_prepared` reuse it across a whole catalog. Before any
geometry is touched, a pair is rejected by a bounding-box + start/end +
length-ratio gate, and a pair whose boxes never come within the lateral
tolerance scores exactly zero overlap without a point loop. `discover` caches
one index per route representative, so adding a recording is a cheap lookup
against each existing route rather than a re-derived polyline per comparison.
On the 2063-file Geoprivacy corpus (1985 valid tracks, ~600 points each) the
full discovery + 1985² pairwise benchmark dropped from tens of hours to 57 s in
a release build (about 7 minutes unoptimised, which is why the CLI prints a
note when it is running a debug build).

The `map` page is plain HTML: the CLI stays offline, while the browser fetches
MapLibre GL JS (BSD-3-Clause) and OpenFreeMap's "Liberty" style when the page
is opened. Tracks get distinct colours, start/finish markers, a legend with
distance/duration/point count, and a click popup. Map data is attributed in
the page (OpenStreetMap, ODbL). After writing the file the CLI hands it to the
platform's default browser (`xdg-open`, `open`, or `start`); `--no-open` skips
that, and `--out -` prints the document to stdout instead (never opened).
`--title` sets the page title and `--style-url` points the page at another
style document (for example a self-hosted tile server). Without a reachable
style the page falls back to a plain background and still draws the routes.
Recordings the engine rejects (for example non-monotonic timestamps) are
reported on stderr and skipped, so one corrupt file does not hide the rest;
only a run with no usable track at all fails.
A single file input defaults to a sibling `.html`; several inputs or a
directory default to `map.html` in the current directory.

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
| `viz`       | self-contained HTML map for inspecting tracks in a browser  |
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
