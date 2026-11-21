<!--
Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# API overview

This page describes the curated Python API of `against_yesterday` (version
`0.1.0`). Values and algorithms come from the Rust `gps-engine` crate; the
Python layer wraps them without reimplementing GPS logic. Not every Rust module
is exposed — see [Scope](#scope).

Import the public objects from `against_yesterday` and the exception classes
from either `against_yesterday` or `against_yesterday.errors`:

```python
import against_yesterday as ay
from against_yesterday.errors import ParseError, InvalidInputError
from against_yesterday.enums import AttemptAxis, LiveMatchStatus, ReplayState
```

The compiled extension is `against_yesterday._native`. The wheel includes a
`py.typed` marker and `_native.pyi` stubs, so type checkers see the signatures
and read-only properties listed here.

## Conventions

- **Properties, not accessors.** Simple values are read-only properties:
  `track.distance_m`, `attempt.elapsed_time_s`, `route.length_m`,
  `snapshot.match_status`. The historical method-call form of the converted
  live/replay accessors is kept as a compatibility shim; prefer the property. Changing a config after
  construction is not supported — build a new config object instead.
- **Methods compute or return collections.** Operations with arguments or
  non-trivial work are methods: `track.filter()`, `route.project(lat, lon)`,
  `attempt.time_at(distance_m)`, `analytics.to_json()`.
- **Units are part of the name.** Distances are metres, durations seconds,
  timestamps Unix milliseconds, speeds metres per second.

  | Suffix | Meaning |
  | --- | --- |
  | `_m` | metres |
  | `_s` | seconds |
  | `_ms` | milliseconds (also `timestamp_ms`) |
  | `_mps` | metres per second |
  | `_kmh` | kilometres per hour (only `FilterConfig.max_speed_kmh`) |
  | `_deg` | degrees (`bearing_deg`, latitude/longitude are plain degrees) |
  | `ms_per_km` | milliseconds per kilometre (pace) |

  Coordinates are `(latitude, longitude)` tuples in that order unless a
  property says otherwise. Pace/elevation sample lists are
  `(distance_m, value)` pairs. `route_progress`, `fraction`, `confidence`, and
  overlap/score fields are dimensionless values in `0.0..1.0`.
- **Path-like inputs.** `Track.from_gpx_path()` and `Track.to_gpx_path()`
  accept `str`, `pathlib.Path`, and other `os.PathLike` values.
- **Iteration and indexing.** `Track`, `Attempt`, and `Route` support
  `len(obj)`, `obj[i]` (negative indices allowed), and `for item in obj`. Item
  types are `TrackPoint`, `AttemptSample`, and `(latitude, longitude)` tuples
  respectively. `points()`, `samples()`, `geometry()`, and `routes()` still
  return lists for cases that need a snapshot; `RouteCatalog.routes()` is the
  explicit accessor for discovered routes.
- **Enums and strings.** `AttemptAxis` (`"clock"`, `"moving"`),
  `LiveMatchStatus` (`"none"`, `"initializing"`, `"matched"`, `"uncertain"`,
  `"off_route"`, `"reacquiring"`), and `ReplayState` (`"playing"`, `"paused"`,
  `"finished"`) live in `against_yesterday.enums`. They are `str` subclasses:
  plain strings remain valid inputs; snapshots expose the corresponding enum
  members, which compare equal to their string values.
- **Representations.** Public value objects implement a useful `__repr__`.

## Tracks and GPX

- `parse_gpx(data: str) -> Track` — parse GPX text.
- `Track(points: list[TrackPoint])` — build from points.
- `Track.from_gpx_path(path-like) -> Track`, `Track.from_gpx(data: str) -> Track`.
- `track.to_gpx() -> str`, `track.to_gpx_path(path-like) -> None`.
- Read-only properties: `point_count`, `distance_m`, `duration_s`,
  `average_speed_mps`, `elevation_gain_m`, `elevation_loss_m`, `start_time_ms`,
  `end_time_ms`.
- Methods: `moving_duration_s(config=None)`, `paused_duration_s(config=None)`,
  `moving_speed_mps(config=None)`, `points() -> list[TrackPoint]`,
  `coordinates() -> list[(lat, lon)]`,
  `filter(config=None) -> (Track, ProcessingReport)`,
  `simplify(tolerance_m=2.0, config=None) -> Track`,
  `resample_by_distance(interval_m) -> Track`, `reversed() -> Track`,
  `analytics(config=None) -> TrackAnalytics`.
- `TrackPoint(latitude, longitude, timestamp_ms, altitude_m=None,
  speed_mps=None, accuracy_m=None, bearing_deg=None)` — all fields are
  read-only properties.
- `MovingConfig(min_speed_mps=0.5, min_stop_duration_s=5.0)`,
  `FilterConfig(max_accuracy_m=50.0, max_speed_kmh=500.0, max_jump_m=200.0,
  max_time_gap_s=60.0)` with `FilterConfig.matching()`, and
  `SimplifyConfig(tolerance_m=2.0)` tune processing. `None` selects engine
  defaults. `ProcessingReport` has `input_points`, `output_points`,
  `removed_points`, `distance_before_m`, and `distance_after_m`.

## Routes and geometry

- `Route(coordinates)` — construct from `(latitude, longitude)` pairs.
  Properties: `length_m`. Methods: `geometry()`, `start()`, `end()`,
  `coordinate_at(distance_m) -> (lat, lon) | None`,
  `project(latitude, longitude) -> Projection`,
  `nearest(latitude, longitude) -> RoutePoint`, `reversed() -> Route`,
  `runs_in_reverse(start_lat, start_lon, end_lat, end_lon) -> bool`.
- `Projection` fields: `distance_along_m`, `lateral_error_m`, `fraction`,
  `latitude`, `longitude`, `segment_index`.
- `RoutePoint` fields: `distance_m`, `latitude`, `longitude`.

## Attempts, performance, and ghosts

- `Attempt.from_track(track, route, axis="clock", moving_config=None)` and
  `Attempt.from_samples(samples)`.
  Properties: `distance_m`, `elapsed_time_s`. Methods:
  `time_at(distance_m) -> seconds | None`,
  `distance_at(elapsed_s) -> metres | None`, `samples() -> list[AttemptSample]`.
- `AttemptSample(distance_m, elapsed_s)` builds a profile point;
  `AttemptMovingConfig(min_speed_mps=0.5, min_stop_duration_s=5.0)` controls
  moving-time projection.
- `compare_performances(reference, current, config=None) ->
  PerformanceComparison` with `total_time_difference_s`,
  `distance_difference_m`, and `points: list[ComparisonPoint]`
  (`distance_m`, `time_difference_s`). `ComparisonConfig(step_m=100.0)` sets
  the sampling interval.
- `Ghost(reference, current)` exposes `state_at(elapsed_s)`,
  `state_at_distance(distance_m)`, `snapshot_at(elapsed_s)`, and
  `snapshot_at_distance(distance_m)`; queries outside the profile return
  `None`. `GhostState` has `distance_m`, `time_difference_s`, and `ahead`;
  `GhostSnapshot` adds `spatial_gap_m` and `confidence`.

## Live recording and replay

- `GpsFix(timestamp_ms, latitude, longitude, accuracy_m=None, altitude_m=None,
  speed_mps=None, bearing_deg=None)` — read-only fields with matching names.
- `LiveConfig(off_route_threshold_m=30.0)`.
- `LiveGhost(samples)` takes `(distance_m, elapsed_s)` pairs. Properties:
  `elapsed_time_s`. Methods: `distance_at(elapsed_s)`, `time_at(distance_m)`,
  `snapshot(current_distance_m, moving_s) -> LiveGhostSnapshot`, `samples()`.
- `LiveRecorder(route=None, config=None)`: `set_ghost(ghost=None)`, `push(fix)`,
  `pause()`, `resume()`, `seed(distance_m, moving_s)`, `finish()`,
  `complete_route()`, `snapshot() -> LiveSnapshot`, `ghost_snapshot() ->
  LiveGhostSnapshot | None`. Properties: `distance_m`, `moving_s`, `pace_mps`,
  `loop_length_m`, `elapsed_for_gap_s`. `finish()` and `complete_route()` are
  state transitions, not resource cleanup; no context manager is required.
- `LiveSnapshot` fields: `distance_m`, `moving_s`, `pace_mps`,
  `route_progress`, `off_route_m`, `accuracy_m`, `latitude`, `longitude`,
  `match_status` (`LiveMatchStatus`), `match_confidence`. `LiveGhostSnapshot` fields:
  `distance_m`, `time_difference_s`, `ahead`, `spatial_gap_m`, `confidence`.
- `ReplaySession(fixes, route=None, ghost=None)` — properties `duration_s`,
  `elapsed_s`, `state`; methods `play()`, `pause()`, `set_speed(speed)`,
  `seek(elapsed_s)`, `advance(delta_s) -> ReplaySnapshot`, `snapshot()`.
- `ReplaySnapshot` fields include `elapsed_s`, `total_s`, `state` (`ReplayState`),
  `speed`, `applied_fixes`, `total_fixes`, `latitude`, `longitude`,
  `accuracy_m`, `distance_m`, `moving_s`, `pace_mps`, `route_progress`,
  `reversed`, `off_route_m`, `match_status` (`LiveMatchStatus`),
  `match_confidence`, and `ghost`.

## Matching and catalogs

- `compare_tracks(a, b, config=None) -> MatchScore` and
  `compare_tracks_either_direction(a, b, config=None) -> MatchScore | None`.
- `MatchScore` fields: `start_distance_m`, `end_distance_m`, `distance_ratio`,
  `spatial_overlap`, `direction_similarity`, `continuity`, `overall_score`;
  `is_match(config=None) -> bool` applies thresholds.
- `MatchConfig(lateral_tolerance_m=25.0, min_spatial_overlap=0.6,
  min_distance_ratio=0.70, max_distance_ratio=1.45,
  max_start_distance_m=150.0, max_end_distance_m=150.0)`.
- `RouteCatalog(config=None)`: `add_track(track) -> TrackAddition` (`route_id`,
  `is_new`, `matched`), `route_count() -> int`,
  `routes() -> list[DiscoveredRoute]`, `representative(route_id) -> Track |
  None`. `DiscoveredRoute` has `id`, `track_count`, and `representative`.
- `canonicalize_route(tracks, config=None) -> Route` merges recordings;
  `CanonicalizeConfig(step_m=20.0, max_lateral_m=40.0)` tunes it.

## Analytics

`track.analytics(config=None) -> TrackAnalytics` exposes `distance_m`,
`elapsed_time_ms`, `moving_time_ms`, `paused_time_ms`, `stopped_time_ms`,
`average_pace_ms_per_km`, `average_speed_mps`, `moving_speed_mps`,
`max_speed_mps`, `best_pace_ms_per_km`, `rolling_best_pace_ms_per_km`,
`smoothed_best_pace_ms_per_km`, `elevation_gain_m`, `elevation_loss_m`,
`robust_elevation_gain_m`, `robust_elevation_loss_m`, `elevation_min_m`,
`elevation_max_m`, `pace_samples`, `smoothed_pace_samples`, `elevation_samples`,
`quality`, and `to_json() -> str`.
The `robust_*` fields use a median filter and a 1 m dead band; the raw sums stay
available for audit. `rolling_best_pace_ms_per_km` uses median-smoothed rolling
windows and is `None` when no window has enough movement; the legacy single-segment
`best_pace_ms_per_km` remains unchanged. `quality` is an `AnalyticsQuality` with `accepted_samples`,
`rejected_samples`, `coverage_ratio`, `gps_gap_count`,
`has_sufficient_distance`, and `has_elevation_data`.

## Errors and validation

`against_yesterday.errors` (also re-exported at package level) defines:

```text
AgainstYesterdayError(Exception)
└── EngineError(AgainstYesterdayError, ValueError)
    ├── InvalidInputError
    ├── GeoError
    ├── TrackError
    ├── GpxError
    │   ├── ParseError
    │   └── GpxWriteError
    ├── RouteError
    │   └── CanonicalizationError
    ├── AttemptError
    └── ProcessingError
```

Binding-layer validation rejects non-finite numbers, out-of-range coordinates
(latitude −90..90, longitude −180..180, bearing 0..360), negative
distances/speeds/durations where non-negativity is required, and zero or
negative steps/intervals with `InvalidInputError`. Engine domain failures use
the specific subclasses above. `EngineError` remains a `ValueError` subclass
for compatibility. Large GPS jumps, poor accuracy, and high speeds are valid
inputs: they are reported by filtering and analytics quality, not rejected.

## Scope

The Python API is deliberately curated. Synthetic generation,
evaluate/manifest helpers, raw GPS trace and processing audit types, lower-level
route-matcher observation/status primitives, segment/section comparisons,
visualization helpers, and detailed analytics progression/rank helpers are not
wrapped. The Flutter C FFI is untouched by this package.
