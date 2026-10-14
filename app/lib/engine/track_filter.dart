// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Online mirror of the Rust engine's track filter (M15).
///
/// The engine filters a whole track in two passes (`gps-engine`'s
/// `track::filtering`): it first drops fixes the sensor itself marks unusable
/// (`max_accuracy` / `max_speed`), then drops a *point* only when both of its
/// neighbouring segments look implausible (`max_jump` / implied speed) — so a
/// genuine teleport (a fix re-acquired after a tunnel or a pocketed phone) is
/// kept while an isolated spike is removed. The run's distance is then the
/// geodesic length of the surviving points, `ProcessingReport::distance_after`.
///
/// The live device path cannot batch: fixes arrive one at a time. [TrackFilter]
/// applies the same rules incrementally, deferring a point's keep/drop decision
/// until its outgoing segment is known, so a free run reports the engine's own
/// number instead of the raw consecutive-fix chord sum.
library;

import 'models.dart';

/// The ceilings a [TrackFilter] applies, mirroring the Rust `FilterConfig`
/// defaults plus the app's own motion floor (which stops a stationary phone's
/// sub-metre correction jitter from slowly accruing).
class TrackFilterConfig {
  const TrackFilterConfig({
    this.maxAccuracyMeters = 50.0,
    this.maxSpeedMps = 500.0 / 3.6,
    this.maxJumpMeters = 200.0,
    this.maxTimeGapSeconds = 60.0,
    this.motionFloorMps = 0.5,
  });

  /// A fix reporting a horizontal accuracy worse than this (metres) is junk.
  final double? maxAccuracyMeters;

  /// A fix reporting ground speed past this (m/s, ~500 km/h) is a GPS artifact,
  /// not motion.
  final double? maxSpeedMps;

  /// A single step longer than this (metres) is a jump.
  final double? maxJumpMeters;

  /// A gap longer than this (seconds) is a pause: its separation is never read
  /// as speed.
  final double? maxTimeGapSeconds;

  /// Ground slower than this (m/s) earns neither distance nor moving time — the
  /// anti-jitter floor the app adds on top of the engine.
  final double motionFloorMps;
}

/// Whether a fix's own sensor fields disqualify it (engine pass 1).
bool trackFilterAccepts(GpsFix fix, TrackFilterConfig config) {
  final accuracy = config.maxAccuracyMeters;
  if (accuracy != null &&
      fix.accuracyMeters != null &&
      fix.accuracyMeters! > accuracy) {
    return false;
  }
  final speed = config.maxSpeedMps;
  if (speed != null &&
      fix.speedMetersPerSecond != null &&
      fix.speedMetersPerSecond! > speed) {
    return false;
  }
  return true;
}

/// Whether the step from [a] to [b] is implausible (the engine's `is_jump`).
///
/// A step longer than [TrackFilterConfig.maxJumpMeters] is a jump; a step
/// across a gap wider than [TrackFilterConfig.maxTimeGapSeconds] is a pause and
/// never a jump — its separation must not be read as speed.
bool trackIsJump(GpsFix a, GpsFix b, TrackFilterConfig config) {
  final gap = haversineMeters(_pointOf(a), _pointOf(b));
  final maxJump = config.maxJumpMeters;
  if (maxJump != null && gap > maxJump) {
    return true;
  }
  final delta = b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
  if (delta <= 0) {
    return false;
  }
  final maxGap = config.maxTimeGapSeconds;
  if (maxGap != null && delta > maxGap) {
    return false;
  }
  final maxSpeed = config.maxSpeedMps;
  if (maxSpeed != null && gap / delta > maxSpeed) {
    return true;
  }
  return false;
}

GeoPoint _pointOf(GpsFix fix) =>
    GeoPoint(latitude: fix.latitude, longitude: fix.longitude);

/// Incremental `distance_after`: feed raw fixes in timestamp order.
///
/// At any moment [distanceMeters] tracks the engine's `distance_after` for the
/// fixes seen *so far*. Because the engine keeps the last point unconditionally,
/// the undecided final segment is counted too — unless its step is an
/// implausible jump ([trackIsJump]), in which case it is withheld until the
/// next fix corroborates it as a real teleport or refutes it as a spike (which
/// is then retracted).
class TrackFilter {
  TrackFilter({this.config = const TrackFilterConfig()});

  final TrackFilterConfig config;

  /// The last surviving point (the engine's pass-2 anchor).
  GpsFix? _anchor;

  /// The latest sensor-clean fix whose outgoing segment is not yet known.
  GpsFix? _pending;
  bool _pendingIsJump = false;

  double _committedMeters = 0;
  double _committedSeconds = 0;
  double _pendingMeters = 0;
  double _pendingSeconds = 0;

  /// Geodesic length of the surviving fixes so far.
  double get distanceMeters => _committedMeters + _pendingMeters;

  /// Moving seconds spanned by those surviving segments.
  double get movingSeconds => _committedSeconds + _pendingSeconds;

  /// Whether the latest step is an implausible jump still withheld from the
  /// axis.
  bool get isHoldingJump => _pending != null && _pendingIsJump;

  /// Feeds one raw fix. A fix the sensor itself rejects is ignored entirely: it
  /// neither bridges nor breaks the chain (engine pass 1).
  void add(GpsFix fix) {
    if (!trackFilterAccepts(fix, config)) {
      return;
    }
    if (_anchor == null) {
      _anchor = fix; // the first surviving point is always kept
      return;
    }
    final pending = _pending;
    if (pending != null &&
        !(_pendingIsJump && trackIsJump(pending, fix, config))) {
      // The pending point has at least one plausible neighbour: keep it.
      _commit(_anchor!, pending);
      _anchor = pending;
    }
    // Otherwise it is an isolated spike: dropped, the anchor stays put so the
    // next genuine fix is measured locally instead of from the bad one.
    _pending = fix;
    _pendingIsJump = trackIsJump(_anchor!, fix, config);
    _recomputePending();
  }

  /// Closes the chain at FINISH. The engine always keeps the final point, so a
  /// withheld closing chord (its step looked like a jump) is counted here rather
  /// than lost — the free run ends on the same `distance_after` the batch
  /// filter would produce. Calling this does not double-count a segment that was
  /// already counted.
  void flush() {
    final anchor = _anchor;
    final pending = _pending;
    if (anchor != null && pending != null) {
      _commit(anchor, pending);
    }
    _pending = null;
    _pendingIsJump = false;
    _recomputePending();
  }

  /// Clears the chain — a deliberate pause is not a bridgeable segment.
  void reset() {
    _anchor = null;
    _pending = null;
    _pendingIsJump = false;
    _committedMeters = 0;
    _committedSeconds = 0;
    _pendingMeters = 0;
    _pendingSeconds = 0;
  }

  void _commit(GpsFix a, GpsFix b) {
    final segment = _segment(a, b);
    _committedMeters += segment.meters;
    _committedSeconds += segment.seconds;
  }

  void _recomputePending() {
    final pending = _pending;
    if (pending == null || _pendingIsJump) {
      // An implausible jump is withheld until the next fix corroborates it.
      _pendingMeters = 0;
      _pendingSeconds = 0;
      return;
    }
    final segment = _segment(_anchor!, pending);
    _pendingMeters = segment.meters;
    _pendingSeconds = segment.seconds;
  }

  /// The ground and time a surviving step earns, or nothing when it is slower
  /// than the motion floor or its timestamps do not move forward.
  ({double meters, double seconds}) _segment(GpsFix a, GpsFix b) {
    final seconds = b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
    if (seconds <= 0) {
      return (meters: 0, seconds: 0);
    }
    final meters = haversineMeters(_pointOf(a), _pointOf(b));
    if (meters / seconds < config.motionFloorMps) {
      return (meters: 0, seconds: 0);
    }
    return (meters: meters, seconds: seconds);
  }
}
