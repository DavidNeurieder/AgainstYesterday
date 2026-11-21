<!--
Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Examples

Small examples using the current `against_yesterday` API. Paste the sections in
order into a single file and run it with the environment where the bindings were
installed:

```bash
python/.venv/bin/python my_example.py
```

A bare `python` using another interpreter raises `ModuleNotFoundError`. The
full demo using the bundled GPX recordings is
`python/examples/android_demo_tracks.py` (see the root [README](../../README.md)).

## Parse, filter, simplify, resample, and analyze

```python
import against_yesterday as ay

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
assert track.point_count == 3
print(track.distance_m, track.duration_s)

filtered, report = track.filter()
print(report.input_points, report.output_points, report.removed_points)
simple = filtered.simplify(tolerance_m=5.0)
resampled = simple.resample_by_distance(interval_m=5.0)
print(ay.Track.from_gpx(resampled.to_gpx()).point_count)

analytics = track.analytics()
print(analytics.distance_m, analytics.moving_time_ms)
print(analytics.quality.accepted_samples, analytics.to_json()[:80])
```

For a real file, use `ay.Track.from_gpx_path("run.gpx")` and
`track.to_gpx_path("processed.gpx")`; `pathlib.Path` works too.

## Route, attempt, performance comparison, and ghost

```python
route = ay.Route(track.coordinates())
assert route.length_m > 0.0

attempt = ay.Attempt.from_track(track, route)
print(attempt.distance_m, attempt.elapsed_time_s, attempt.time_at(0.0))

slower = ay.Attempt.from_samples([
    ay.AttemptSample(0.0, 0.0),
    ay.AttemptSample(attempt.distance_m, attempt.elapsed_time_s + 10.0),
])
comparison = ay.compare_performances(attempt, slower)
print(comparison.total_time_difference_s)

ghost = ay.Ghost(attempt, slower)
state = ghost.state_at_distance(attempt.distance_m)
print(state.time_difference_s if state else None, state.ahead if state else None)
```

Use `axis="moving"` (or `AttemptAxis.MOVING` from `against_yesterday.enums`)
with `Attempt.from_track()` to project onto moving time. `Track` and `Attempt`
also support `len(...)`, indexing, and iteration.

## Matching, catalog, and canonicalization

```python
score = ay.compare_tracks(track, track)
assert score.is_match() is True
either = ay.compare_tracks_either_direction(track, track)
print(score.overall_score, score.spatial_overlap, either is not None)

catalog = ay.RouteCatalog()
addition = catalog.add_track(track)
print(addition.route_id, addition.is_new, catalog.route_count())
for discovered in catalog.routes():
    print(discovered.id, discovered.track_count, discovered.representative.point_count)

canonical = ay.canonicalize_route([track, track])
print(canonical.length_m)
```

`canonicalize_route()` raises `CanonicalizationError` (a `RouteError`
subclass) when the inputs cannot be merged.

## Live recording and replay

```python
base_ms = 1_700_000_000_000
fixes = [
    ay.GpsFix(base_ms + i * 1000, 52.5 + i * 0.00005, 13.4)
    for i in range(10)
]
ghost = ay.LiveGhost([(i * 5.0, float(i)) for i in range(20)])
route = ay.Route([(fix.latitude, fix.longitude) for fix in fixes])

recorder = ay.LiveRecorder(route=route)
recorder.set_ghost(ghost)
for fix in fixes:
    recorder.push(fix)
snapshot = recorder.snapshot()
print(snapshot.distance_m, snapshot.match_status, recorder.ghost_snapshot() is not None)

session = ay.ReplaySession(fixes, route=route, ghost=ghost)
session.play()
replay_snapshot = session.advance(5.0)
print(replay_snapshot.applied_fixes, replay_snapshot.state, session.elapsed_s)
```

`ReplaySession` also has `pause()`, `set_speed(speed)`, `seek(elapsed_s)` and
`snapshot()`; `LiveRecorder` has `seed()`, `pause()`, `resume()`, `finish()`
and `complete_route()` for explicit state transitions.

## Error handling

```python
from against_yesterday.errors import InvalidInputError, ParseError

try:
    ay.parse_gpx("not a GPX document")
except ParseError as exc:
    print("GPX error:", exc)

try:
    track.resample_by_distance(interval_m=0.0)
except InvalidInputError as exc:
    print("validation error:", exc)
```

All package errors derive from `AgainstYesterdayError`; `EngineError` (and
therefore every specific error) is also a `ValueError`.
