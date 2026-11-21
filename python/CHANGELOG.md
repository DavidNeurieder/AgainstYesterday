<!--
Copyright (C) 2026 David Neurieder
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Python bindings changelog

All notable changes to the `against_yesterday` Python package are documented
here. The package version is independent of the Flutter app version.

## [Unreleased]

Planned for the 0.1.0 Python API release.

### Added

- A documented, curated Python API over the Rust engine for GPX I/O, track
  processing, routes/attempts/ghosts, live recording/replay, matching/catalogs,
  matching/canonicalization, and analytics. Full Rust 1:1 parity is not a goal.
- PEP 561 typing support: `against_yesterday/py.typed` and stubs for the
  compiled `_native` extension in `against_yesterday/_native.pyi`.
- A Python-facing exception hierarchy in `against_yesterday.errors`, re-exported
  from the top-level package: `AgainstYesterdayError`, `EngineError`,
  `InvalidInputError`, `GeoError`, `TrackError`, `GpxError`, `ParseError`,
  `GpxWriteError`, `RouteError`, `CanonicalizationError`, `AttemptError`, and
  `ProcessingError`. GPX read/write and canonicalization failures now have
  dedicated subclasses.
- String enums `AttemptAxis`, `LiveMatchStatus`, and `ReplayState` in
  `against_yesterday.enums`; plain strings are still accepted as inputs, and
  snapshots expose the enum members (which compare equal to their strings).
- Documentation: `python/docs/getting_started.md`, `python/docs/api.md`, and
  runnable examples in `python/docs/examples/README.md`. The README demo
  command now uses the environment where the bindings were installed.
- CI workflows for the Python test/type/lint matrix and for wheel builds on
  Linux, macOS, and Windows, with clean-venv import smoke tests and gated
  publishing.

### Changed

- Numeric and coordinate inputs are validated at the binding boundary: finite
  values, non-negative distances/speeds/durations, strictly positive intervals
  and step sizes, and latitude/longitude bounds. Failures raise
  `InvalidInputError` instead of reaching Rust with nonsensical values.
  Suspicious GPS measurements are still accepted for quality analysis.
- Collections are more Pythonic: `Track`, `Attempt`, and `Route` support length,
  indexing, and iteration without an explicit list copy; GPX file helpers accept
  `os.PathLike` (including `pathlib.Path`) as well as `str`.
- Simple readouts on `LiveRecorder` and `ReplaySession` are now properties
  (`distance_m`, `moving_s`, `pace_mps`, `loop_length_m`, `elapsed_for_gap_s`,
  `duration_s`, `elapsed_s`, `state`, and `LiveGhost.elapsed_time_s`). The
  historical method-call form of these accessors is kept as a compatibility
  shim for at least one minor release.
- Configuration values are read-only after construction. Create a new config
  object instead of mutating an existing one.

### Compatibility

- `EngineError` keeps its `ValueError` base, so existing `except ValueError`
  handlers continue to work; new code can catch `AgainstYesterdayError` or the
  specific subclasses.
- `CanonicalizationError` derives from `RouteError`, and `ParseError` /
  `GpxWriteError` derive from `GpxError`, so older broad handlers still match.
- Plain string values (`"clock"`, `"moving"`, `"matched"`, `"playing"`, ...) keep
  working wherever an enum is accepted.
