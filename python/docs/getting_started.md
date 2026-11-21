<!--
Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Getting started

The `against_yesterday` package is a Python interface to the Rust `gps-engine`
crate. All computations happen in Rust; Python supplies convenient objects,
properties, iteration, and typed stubs. Python 3.9 or newer is required.

## Install from a checkout

From the repository root:

```bash
make python-develop          # creates python/.venv and installs the extension
python/.venv/bin/python -c "import against_yesterday as ay; print(ay.__version__)"
```

Without the Makefile:

```bash
cd python
python -m venv .venv
source .venv/bin/activate
pip install maturin
maturin develop
python -c "import against_yesterday as ay; print(ay.__version__)"
```

For a distributable wheel use `make python-build` (output in
`python/target/wheels/`), or, once released, `pip install against-yesterday`.
Prebuilt wheels do not need a Rust toolchain. Always run Python with the
interpreter where the package was installed — a different interpreter raises
`ModuleNotFoundError: No module named 'against_yesterday'`.

## Your first track

```python
import against_yesterday as ay
from against_yesterday.enums import AttemptAxis

gpx = """<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="example" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>sample</name><trkseg>
    <trkpt lat="47.37690" lon="8.54170"><time>2024-01-01T10:00:00.000Z</time></trkpt>
    <trkpt lat="47.37710" lon="8.54190"><time>2024-01-01T10:00:20.000Z</time></trkpt>
    <trkpt lat="47.37730" lon="8.54210"><time>2024-01-01T10:00:40.000Z</time></trkpt>
  </trkseg></trk>
</gpx>
"""

track = ay.parse_gpx(gpx)
print(track.point_count, track.distance_m, track.duration_s)
for point in track:
    print(point.latitude, point.longitude, point.timestamp_ms)

filtered, report = track.filter()
simplified = filtered.simplify(tolerance_m=5.0)
analytics = simplified.analytics()
print(analytics.moving_time_ms, analytics.quality.coverage_ratio)
```

Values are in SI-style units with explicit suffixes: `_m` (metres), `_s`
(seconds), `_ms` (milliseconds), `_mps` (metres per second). See
[api.md](api.md#conventions) for the full convention list.

## Reading and writing files

```python
from pathlib import Path
import against_yesterday as ay

track = ay.Track.from_gpx_path(Path("run.gpx"))  # str or os.PathLike
track.to_gpx_path("cleaned.gpx")
```

Malformed files raise `ParseError` and write failures raise `GpxWriteError`.
Both are available from `against_yesterday.errors` and from the top-level
package; both derive from `GpxError` and `ValueError`. Catch
`ay.AgainstYesterdayError` to handle any error from this package.

## Build a route and compare two runs

```python
route = ay.Route(track.coordinates())
reference = ay.Attempt.from_track(track, route)
current = ay.Attempt.from_track(other_track, route)
comparison = ay.compare_performances(reference, current)
ghost = ay.Ghost(reference, current)
print(comparison.total_time_difference_s)
print(ghost.state_at_distance(1000.0))
```

`axis="moving"` (or `axis=AttemptAxis.MOVING`) projects using moving time
instead of the clock. More complete examples are in
[docs/examples/README.md](examples/README.md).

## Bundled demo

The repository ships four Cycling Finland GPX recordings under
`app/assets/examples/`. Run the demo with the installed environment:

```bash
python/.venv/bin/python python/examples/android_demo_tracks.py
```

GPS data: GeoPrivacy (2023), CC BY 4.0 — see `app/assets/examples/licenses/`
and `app/assets/examples/manifest.json`.

## Next steps

- [api.md](api.md) — curated API overview, method/property conventions, units,
  and validation rules.
- [examples/README.md](examples/README.md) — small runnable examples for each
  feature area.
- [../README.md](../README.md) — installation targets, performance guidance,
  and compatibility notes.
