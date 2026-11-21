<!--
Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Python binding benchmarks (skeletons)

This directory holds small, **stdlib-only** benchmark harnesses for the
`against_yesterday` Python bindings. They are skeletons on purpose: they build
deterministic synthetic data, print timings, and do **not** assert or compare
against thresholds. Absolute numbers are environment-specific (CPU, OS, Python
build, Rust profile, data shape), so only compare runs recorded on the same
machine with the same toolchain. Keep the version banner with any numbers you
save.

## Prerequisites and running

From the repository root, install the bindings once and then invoke the scripts
with the virtualenv interpreter:

```sh
make python-develop
python/.venv/bin/python python/benchmarks/benchmark_track.py
python/.venv/bin/python python/benchmarks/benchmark_matching.py
```

Both scripts work from the repo root, use `argparse`, time work with
`time.perf_counter`, and derive all coordinates/timestamps from fixed constants
(no randomness). `--versions` prints the toolchain banner and exits.

Common options:

| Option | Scripts | Meaning |
| --- | --- | --- |
| `--sizes 100,10000,100000` | both | Comma-separated sample counts per track (repeatable flag; default `100,10000,100000`). |
| `--repeat 3` | both | Timed repetitions per case; the script reports best and mean. Default `3`. |
| `--include-million` | both | Add the `1,000,000`-sample stress case, which is skipped by default. Passing `--sizes 1000000` explicitly also opts in. |
| `--variants 4` | matching | Number of deterministically perturbed variants compared with the one reference track. Default `4`. |
| `--workers 4` | matching | Thread count for the `ThreadPoolExecutor` case. Default `4`. |
| `--versions` | both | Print versions/platform and exit. |

Examples:

```sh
python/.venv/bin/python python/benchmarks/benchmark_track.py --sizes 100,10000 --repeat 5
python/.venv/bin/python python/benchmarks/benchmark_matching.py --sizes 10000 --variants 8 --workers 8
python/.venv/bin/python python/benchmarks/benchmark_track.py --include-million --repeat 1 | tee million-track-bench.txt
```

## What is measured

`benchmark_track.py` builds one deterministic `ay.Track` per size and times:

- `Track.filter()`
- `Track.simplify()`
- `Track.resample_by_distance()`
- `Track.analytics()`
- `Track.to_gpx()` and `ay.parse_gpx()` (round-trip text conversion)
- track iteration (`for point in track`, streaming via the native iterator)

Track construction and per-case cleanup happen outside the timed windows; a
construction line is printed as context. Large intermediates (`Track` results,
the GPX string) are released as soon as a case finishes. Iteration deliberately
consumes the iterator instead of calling `points()` so no extra point list is
built.

`benchmark_matching.py` builds one reference track and `N` perturbed variants
and times:

- `ay.compare_tracks()`
- `ay.compare_tracks_either_direction()`
- `ay.canonicalize_route()`
- `ay.compare_performances()` (using attempts built from the reference route)
- a `ThreadPoolExecutor` case that fans `compare_tracks()` calls out over
  `--workers` threads (the "concurrent tracks" scenario)

Attempts, routes, and the work list are prepared before the relevant timed
window. If the engine rejects a synthetic input for a particular case, that
case prints an error and the remaining cases still run.

Wall time is the elapsed `time.perf_counter()` duration for each repetition.
Peak RSS, where available, comes from `resource.getrusage(...).ru_maxrss` and is
the **process-wide high-water mark so far**, not a per-call delta — read it as
"the run reached at least this much memory". On platforms without `resource`
it prints `n/a`.

## Scenarios

- **100 samples** — smoke test and per-call overhead.
- **10,000 samples** — a short run.
- **100,000 samples** — a long activity.
- **1,000,000 samples** — memory/throughput stress case, opt-in only via
  `--include-million` (or an explicit `--sizes 1000000`). Do not run it by
  accident on a small machine.
- **Concurrent tracks** — the matching script's thread-pool case; scale with
  `--workers` and `--variants`.

## Recording toolchain versions

The banner at the top of every run includes the binding version, Python
version, interpreter path, and platform, so `tee` is enough to capture the
context alongside the numbers. For a fuller record, capture these too:

```sh
python/.venv/bin/python python/benchmarks/benchmark_track.py --versions
python/.venv/bin/python --version
python/.venv/bin/python -c 'import against_yesterday as ay; print(ay.__version__)'
python/.venv/bin/pip --version
python/.venv/bin/maturin --version
rustc --version
cargo --version
uname -a
```

The native extension is built from the workspace at the repo root; its compiler
is pinned by `rust-toolchain.toml`, so include that version (and whether the
library was built in debug or release) when comparing results. `make
python-develop` builds the editable install used above.
