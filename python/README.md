# against-yesterday (Python)

Python bindings for the `gps-engine` Rust crate from [Against Yesterday](https://github.com/DavidNeurieder/AgainstYesterday).

The package exposes a curated, Pythonic API over the engine for GPX I/O, track
processing, route/attempt/ghost racing, live recording/replay, matching, and
analytics. The API may evolve while the engine is in the `0.x` series.

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

The repository includes bundled demo GPX tracks (the same recordings shipped with
the Android app, CC BY 4.0 GeoPrivacy 2023) under `app/assets/examples/`. After
building/installing the bindings, you can run:

```bash
python python/examples/android_demo_tracks.py
```

This loads the demo tracks, prints summaries/analytics, compares runs against a
reference route (attempt/ghost/performance comparison), and demonstrates route
matching/canonicalization.

## Quick examples

### GPX and track processing

```python
import against_yesterday as ay

track = ay.Track.from_gpx_path("run.gpx")
filtered, report = track.filter()
simple = filtered.simplify(tolerance_m=2.0)
resampled = simple.resample_by_distance(interval_m=5.0)
analytics = resampled.analytics()
print(analytics.distance_m, analytics.moving_time_ms)
resampled.to_gpx_path("processed.gpx")
```

### Route, attempt, and ghost comparison

```python
route = ay.Route(track.coordinates())
reference = ay.Attempt.from_track(reference_track, route)
current = ay.Attempt.from_track(track, route)
comparison = ay.compare_performances(reference, current)
ghost = ay.Ghost(reference, current)
state = ghost.state_at_distance(1000.0)
print(comparison.total_time_difference_s, state.time_difference_s if state else None)
```

### Live recording / replay

```python
ghost = ay.LiveGhost([(d, t) for d, t in reference_profile])
recorder = ay.LiveRecorder(route=route)
recorder.set_ghost(ghost)
recorder.push(ay.GpsFix(timestamp_ms, lat, lon, accuracy_m=5.0))
snapshot = recorder.snapshot()

session = ay.ReplaySession(fixes, route=route, ghost=ghost)
session.play()
snap = session.advance(1.0)
```

### Matching and route discovery

```python
score = ay.compare_tracks(track_a, track_b)
matched = ay.compare_tracks_either_direction(track_a, track_b)

catalog = ay.RouteCatalog()
addition = catalog.add_track(track_a)
routes = catalog.routes()
canonical = ay.canonicalize_route([track_a, track_b_variant])
```

## License

AGPL-3.0-or-later, consistent with the Against Yesterday repository.
