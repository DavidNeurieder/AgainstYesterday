# against-yesterday (Python)

Python bindings for the `gps-engine` Rust crate from [Against Yesterday](https://github.com/DavidNeurieder/AgainstYesterday).

The package exposes a curated, Pythonic API over the engine for GPX I/O, track
processing, route/attempt/ghost racing, live recording/replay, matching, and
analytics. The API may evolve while the engine is in the `0.x` series. See
[docs/getting_started.md](docs/getting_started.md),
[docs/api.md](docs/api.md), and [docs/examples/README.md](docs/examples/README.md)
for the longer guides.

## Installation

The bindings need Python 3.9 or newer. From a repository checkout, the simplest
path is the Makefile target, which creates `python/.venv` and installs an
editable build:

```bash
make python-develop
# or, equivalently:
cd python && python -m venv .venv && .venv/bin/pip install maturin && .venv/bin/maturin develop
```

A distributable wheel is produced by `make python-build`
(`python/target/wheels/`). Once a release is published, install it with
`pip install against-yesterday`; wheels are built without requiring a Rust
toolchain on the user's machine. The package ships a PEP 561 `py.typed` marker
and a `_native.pyi` stub for the compiled `_native` extension, so editors,
mypy, and pyright see typed properties and method signatures.

Run all commands below with the interpreter that has the bindings installed
(`python/.venv/bin/python` from the repository root, or an activated venv).

## GPX I/O

```python
from pathlib import Path
import against_yesterday as ay

track = ay.parse_gpx(xml_string)            # GPX text
track = ay.Track.from_gpx_path(Path("run.gpx"))  # str or os.PathLike
xml = track.to_gpx()                        # GPX text
track.to_gpx_path(Path("processed.gpx"))    # str or os.PathLike
```

Reading malformed or incomplete GPX raises a `ParseError`; write failures raise
`GpxWriteError`. Both derive from `GpxError`.

## Track processing

```python
track = ay.Track.from_gpx_path("run.gpx")
filtered, report = track.filter()           # default quality filters
simple = filtered.simplify(tolerance_m=2.0)
resampled = simple.resample_by_distance(interval_m=5.0)
analytics = resampled.analytics()
print(analytics.distance_m, analytics.moving_time_ms)
print(track.point_count, track.duration_s, track.average_speed_mps)
```

`filter()` returns the new track plus a `ProcessingReport` describing removed
points and distance before/after. Configuration objects (`MovingConfig`,
`FilterConfig`, `SimplifyConfig`) are constructed once and reused; their values
are read-only properties. `Track` supports `len(track)`, `track[i]`, and
iteration over `TrackPoint` values; `track.points()` and `track.coordinates()`
return lists when a snapshot is needed.

## Routes, attempts, and ghosts

```python
route = ay.Route(track.coordinates())
reference = ay.Attempt.from_track(reference_track, route)
current = ay.Attempt.from_track(track, route)
comparison = ay.compare_performances(reference, current)
ghost = ay.Ghost(reference, current)
state = ghost.state_at_distance(1000.0)
print(comparison.total_time_difference_s, state.time_difference_s if state else None)
```

Use `Attempt.from_samples([...])` for a hand-built profile, `axis="moving"` (or
`AttemptAxis.MOVING` from `against_yesterday.enums`) to project onto moving time,
and `attempt.time_at()` /
`attempt.distance_at()` to query the profile. Attempts support length, indexing,
and iteration over `AttemptSample`. `Ghost.state_at*()` returns a `GhostState`;
`snapshot_at*()` adds spatial gap and confidence.

## Live recording and replay

```python
ghost = ay.LiveGhost([(s.distance_m, s.elapsed_s) for s in attempt.samples()])
recorder = ay.LiveRecorder(route=route)
recorder.set_ghost(ghost)
recorder.push(ay.GpsFix(1_700_000_000_000, 52.5, 13.4, accuracy_m=5.0))
snapshot = recorder.snapshot()
print(snapshot.distance_m, snapshot.match_status)

session = ay.ReplaySession(fixes, route=route, ghost=ghost)
session.play()
replay_snapshot = session.advance(1.0)
```

`LiveRecorder.finish()` and `complete_route()` are state transitions, not
resource releases; these objects do not own files, sockets, or threads, so no
context manager is needed. Snapshot status strings (`"matched"`, `"off_route"`,
`"playing"`, ...) can be compared with the `LiveMatchStatus` and `ReplayState`
enums; plain strings are also accepted where an enum is an input.

## Matching and route discovery

```python
score = ay.compare_tracks(track_a, track_b)
matched = ay.compare_tracks_either_direction(track_a, track_b)
score.is_match()                      # optional MatchConfig override

catalog = ay.RouteCatalog()
addition = catalog.add_track(track_a)  # route_id, is_new, matched
routes = catalog.routes()              # list of DiscoveredRoute
canonical = ay.canonicalize_route([track_a, track_b_variant])
```

`compare_tracks*()` return `MatchScore` values with component scores;
`canonicalize_route()` merges recordings into one `Route` and may raise
`CanonicalizationError` when the inputs are inconsistent.

## Error handling and validation

All package errors derive from `AgainstYesterdayError` and are available both
from `against_yesterday.errors` and at the top level (`ay.ParseError`,
`ay.InvalidInputError`, ...). `EngineError` remains a `ValueError` subclass, so
existing `except ValueError` handlers keep working.

```python
import against_yesterday as ay
from against_yesterday.errors import InvalidInputError, ParseError

try:
    track = ay.Track.from_gpx_path("run.gpx")
    resampled = track.resample_by_distance(interval_m=0)
except ParseError as exc:
    print("bad GPX:", exc)
except InvalidInputError as exc:
    print("bad argument:", exc)
except ay.AgainstYesterdayError as exc:
    print("other engine error:", exc)
```

Coordinates must be finite and within ±90° / ±180°; distances, speeds, and
durations must be finite and non-negative where applicable; intervals and step
sizes must be strictly positive. Invalid values fail at the binding boundary
with `InvalidInputError`. Suspicious but legitimate GPS data (large jumps,
low accuracy, high speed) is *not* rejected; it is reported through filtering
and analytics quality instead. See [docs/api.md](docs/api.md#errors-and-validation)
for the full hierarchy.

## Scope

This is a curated API, not a 1:1 wrapper of the Rust crate. Synthetic data
generation, evaluate/manifest helpers, raw GPS trace and processing audit
types, low-level matcher observation/status primitives, segment/section
comparisons, visualization helpers, and detailed analytics progression/rank
helpers are intentionally out of scope. No GPS algorithms are reimplemented in
Python and the Flutter C FFI is unchanged.

## Bundled demo attribution

The demo tracks in `app/assets/examples/` (the same recordings shipped with the
Android app) are Cycling Finland GPS data by GeoPrivacy (2023), licensed
CC BY 4.0. See `app/assets/examples/licenses/` and
`app/assets/examples/manifest.json` for the full attribution. Keep this notice
when redistributing the sample data.

## Performance and large tracks

Filtering, matching, canonicalization, analytics, and GPX I/O run in the Rust
engine; the Python layer mainly constructs and inspects values. Converting a
large track to Python lists (`points()`, `coordinates()`, `samples()`) allocates
one Python object per item, so iterate the track/attempt directly when scanning
data and avoid repeated conversions of the same input. For very large files
(100k+ points), consider resampling first and reusing one parsed `Track` across
operations. The expensive pure-Rust operations (`filter`, `simplify`,
`resample_by_distance`, `analytics`, `compare_tracks*`, `compare_performances`,
and `canonicalize_route`) release the GIL while they run; Python object
construction at the boundary still needs it.

## Compatibility and migration

The package is in the `0.x` series: API changes may happen, but names and units
are kept stable where possible. Distances use `_m`, durations `_s`, timestamps
`_ms`, speeds `_mps`, and pace samples milliseconds per kilometre. Simple
readouts such as `moving_s` are now properties; the historical method-call form
(`recorder.moving_s()`) is kept as a compatibility shim for at least one minor
release. Prefer the property form in new code. Plain strings still work
everywhere an enum is accepted.
`CanonicalizationError` is a subclass of `RouteError`, and `ParseError` /
`GpxWriteError` are subclasses of `GpxError`, so older broad `except` clauses
continue to match. See [CHANGELOG.md](CHANGELOG.md).

## Development

From the repository root, the Makefile can set up a local virtual environment in
`python/.venv` and build/test the bindings:

```bash
make python-develop  # editable install into python/.venv
make python-build    # release wheel in python/target/wheels/
make python-test     # develop + pytest
make python-clean    # remove Python build artifacts
```

Or manually with maturin:

```bash
cd python
python -m venv .venv
source .venv/bin/activate
pip install maturin pytest
maturin develop
pytest
```

## Example script

After building/installing the bindings, run the bundled demo with the same
environment the bindings were installed into:

```bash
# From the repository root:
python/.venv/bin/python python/examples/android_demo_tracks.py

# Or from python/ with an activated venv:
source .venv/bin/activate
python examples/android_demo_tracks.py
```

A bare `python python/examples/android_demo_tracks.py` using a different
interpreter raises `ModuleNotFoundError`. The script loads the demo tracks,
prints summaries/analytics, compares runs against a reference route
(attempt/ghost/performance comparison), and demonstrates route
matching/canonicalization.

## License

AGPL-3.0-or-later, consistent with the Against Yesterday repository.
