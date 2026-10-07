// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Domain models — lightweight Dart representations of Rust engine concepts
/// (§5 of the app plan). Pure data plus small derived helpers; they never
/// contain algorithms that duplicate the Rust engine.
library;

import 'dart:math' as math;

import '../core/units.dart';

/// A geographic position in decimal degrees (WGS84).
class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      (latitude - other.latitude).abs() < 1e-9 &&
      (longitude - other.longitude).abs() < 1e-9;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

/// One recorded GPS fix.
class TrackPoint {
  const TrackPoint({
    required this.position,
    this.altitudeMeters,
    required this.timestamp,
  });

  final GeoPoint position;
  final double? altitudeMeters;
  final DateTime timestamp;
}

/// One *raw* GPS observation (M15 Phase 12): the mobile receiver's direct
/// output, kept unprocessed so a later pipeline (or a re-run with new filters)
/// can replay the original signal instead of a derived track.
///
/// Richer than a [TrackPoint] — which is the *processed* form the engine
/// consumes — a fix carries the receiver's own accuracy/altitude/speed/bearing
/// estimates. Any of them may be `null` when the hardware did not report it;
/// the app must never invent a value to fill the gap.
class GpsFix {
  const GpsFix({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.accuracyMeters,
    this.altitudeMeters,
    this.speedMetersPerSecond,
    this.bearingDegrees,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;

  /// Horizontal accuracy (68% confidence radius) in meters, when reported.
  final double? accuracyMeters;
  final double? altitudeMeters;
  final double? speedMetersPerSecond;
  final double? bearingDegrees;
}

/// Cumulative sample on the route distance axis: how far, by what time.
class AttemptSample {
  const AttemptSample({required this.distance, required this.elapsed});

  final Distance distance;
  final Elapsed elapsed;
}

/// A canonical route the user can run again.
class Route {
  const Route({
    required this.id,
    required this.name,
    required this.distance,
    required this.geometry,
    this.attemptCount = 0,
    this.personalBest,
  });

  final String id;
  final String name;
  final Distance distance;
  final List<GeoPoint> geometry;
  final int attemptCount;
  final Elapsed? personalBest;
}

/// A completed or in-progress recording.
class Activity {
  const Activity({
    required this.id,
    this.routeId,
    required this.startedAt,
    this.duration,
    this.distance,
    this.performance,
    this.track,
    this.rawFixes,
  });

  final String id;
  final String? routeId;
  final DateTime startedAt;
  final Elapsed? duration;
  final Distance? distance;

  /// Provisional result caption (§43), e.g. `24:22 · 1st`.
  final String? performance;

  /// Processed fixes, persisted as a blob alongside the metadata (§27).
  final List<TrackPoint>? track;

  /// Raw GPS observations retained before processing (M15 Phase 12). Persisted
  /// additively so the complete source trace survives the recording lifecycle
  /// and can be exported/replayed later — not just the derived [track].
  final List<GpsFix>? rawFixes;
}

/// One attempt reduced to the route axis (GPS → distance ↔ elapsed time).
class Attempt {
  const Attempt({
    required this.activityId,
    required this.routeId,
    required this.elapsed,
    required this.samples,
  });

  final String activityId;
  final String routeId;
  final Elapsed elapsed;
  final List<AttemptSample> samples;
}

/// A reference attempt (the PB) to ghost against.
class Ghost {
  const Ghost({required this.attemptId, required this.samples});

  final String attemptId;
  final List<AttemptSample> samples;
}

/// Where the live run stands relative to the ghost at a given distance.
class GhostState {
  const GhostState({
    required this.distance,
    required this.timeDifference,
    required this.ahead,
  });

  final Distance distance;

  /// `current - reference`: positive means the live run is *behind*.
  final Elapsed timeDifference;

  /// `true` when the live run is ahead of the reference at this distance.
  final bool ahead;
}

/// Structured similarity report between two recorded routes.
class MatchScore {
  const MatchScore({
    required this.startDistance,
    required this.endDistance,
    required this.distanceRatio,
    required this.spatialOverlap,
    required this.directionSimilarity,
    required this.overallScore,
  });

  final Distance startDistance;
  final Distance endDistance;

  /// Recording length ratio (a/b), 0..∞.
  final double distanceRatio;

  /// Fraction of each track near the other's geometry, 0..1.
  final double spatialOverlap;

  /// Directional agreement of matched segments, 0..1.
  final double directionSimilarity;

  /// Provisional aggregate, 0..1.
  final double overallScore;
}

/// A route-match decision plus its diagnostics.
class RouteMatchResult {
  const RouteMatchResult({required this.score, required this.sameRoute});

  final MatchScore score;
  final bool sameRoute;
}

/// Report returned by [`EngineService.processTrack`].
class ProcessedTrack {
  const ProcessedTrack({
    required this.id,
    required this.inputPoints,
    required this.outputPoints,
    required this.originalDistance,
    required this.processedDistance,
    required this.duration,
    required this.movingTime,
  });

  final String id;
  final int inputPoints;
  final int outputPoints;
  final Distance originalDistance;
  final Distance processedDistance;
  final Elapsed duration;
  final Elapsed movingTime;
}

/// Recording state machine states (§8).
enum RunStatus {
  idle,
  preparing,
  gpsAcquiring,
  ready,
  running,
  paused,
  finishing,
  completed,
  error,
}

/// A recoverable snapshot of an in-progress run (M13, §28). Persisted while
/// the app runs in the background so a killed process can be resumed.
class RunSnapshot {
  const RunSnapshot({
    required this.status,
    required this.startedAt,
    required this.movingSeconds,
    required this.distanceMeters,
    required this.loopMeters,
    this.routeId,
  });

  /// `running` or `paused` when the app left the foreground.
  final RunStatus status;
  final DateTime startedAt;
  final double movingSeconds;
  final double distanceMeters;
  final double loopMeters;
  final String? routeId;
}

/// Why a run failed to start (M14), rendered on the error screen.
class RunError {
  const RunError({required this.message, this.gpsSettingsAction = false});

  /// Human-readable reason; the error screen shows it verbatim.
  final String message;

  /// Set when the failure is a device-GPS activation problem (services off or
  /// permission denied), so the error screen can offer to open the matching
  /// system settings.
  final bool gpsSettingsAction;
}

/// Live recording state delivered to the UI at roughly 1–2 Hz (§7).
///
/// The UI is a pure projection of this state (§9): every screen reads it and
/// derives what to show — it never mutates recording logic itself.
class LiveRunState {
  const LiveRunState({
    required this.status,
    required this.elapsed,
    required this.distance,
    this.currentPosition,
    required this.pace,
    this.ghostGap,
    required this.routeProgress,
    this.gpsQuality = 'good',
    this.hasUnsavedData = false,
    this.route,
    this.ghostPosition,
    this.startedAt,
    this.error,
  });

  final RunStatus status;
  final Elapsed elapsed;
  final Distance distance;
  final GeoPoint? currentPosition;
  final Speed pace;

  /// How the live run compares to the ghost at the current distance.
  final GhostState? ghostGap;

  /// Fraction of the route completed, 0..1.
  final double routeProgress;

  /// 'good' | 'reduced' | 'poor' (§17).
  final String gpsQuality;

  /// True while the run holds state that isn't persisted yet (§9). Cleared
  /// once the completed run is saved (M11).
  final bool hasUnsavedData;

  /// The selected route, when recognised (§11). `null` = "new route".
  final Route? route;

  /// Rendered position of the PB ghost at the live runner's *elapsed* time
  /// (the runner races the ghost, §14). `null` when racing no ghost.
  final GeoPoint? ghostPosition;

  /// Wall-clock start of the run session — exposed for diagnostics
  /// (M15 Phase 10), e.g. to compute sample ages or fixture timestamps.
  final DateTime? startedAt;

  /// Why the run failed to start, when the status is [RunStatus.error]. Lives
  /// only while the error state is live — cleared as soon as the run moves on.
  final RunError? error;
}

/// Position along a polyline at [distanceMeters] from its start (linear
/// interpolation on segment length). Returns `null` when out of range.
///
/// NOTE: a pure display/rendering helper for the fake engine and map; the real
/// engine (M9) owns geometry interpolation.
GeoPoint? pointAlongPolyline(List<GeoPoint> geometry, double distanceMeters) {
  if (geometry.isEmpty || distanceMeters < 0) {
    return null;
  }
  var walked = 0.0;
  for (var i = 1; i < geometry.length; i++) {
    final segment = haversineMeters(geometry[i - 1], geometry[i]);
    if (walked + segment >= distanceMeters) {
      final fraction = (distanceMeters - walked) / segment;
      final t = fraction.clamp(0.0, 1.0);
      return GeoPoint(
        latitude:
            geometry[i - 1].latitude +
            (geometry[i].latitude - geometry[i - 1].latitude) * t,
        longitude:
            geometry[i - 1].longitude +
            (geometry[i].longitude - geometry[i - 1].longitude) * t,
      );
    }
    walked += segment;
  }
  return geometry.last;
}

/// How the live run compares to the reference at a point on the route (§45).
enum AheadBehind {
  ahead,
  behind,
  tied,
  unknown;

  static AheadBehind fromGap(GhostState gap) {
    if (gap.timeDifference.seconds == 0) {
      return AheadBehind.tied;
    }
    return gap.ahead ? AheadBehind.ahead : AheadBehind.behind;
  }
}

/// Great-circle distance in meters (haversine approximation).
///
/// NOTE: this duplicate of the Rust `geo` distance exists *only* so the fake
/// engine and UI can render deterministic demo data. The real engine (M9)
/// owns distance — the fake never needs to be numerically identical.
double haversineMeters(GeoPoint a, GeoPoint b) {
  const earthRadiusM = 6_371_000.0;
  final dLat = _rad(a.latitude - b.latitude);
  final dLon = _rad(a.longitude - b.longitude);
  final lat1 = _rad(a.latitude);
  final lat2 = _rad(b.latitude);
  final sLat = math.sin(dLat / 2);
  final sLon = math.sin(dLon / 2);
  final h = sLat * sLat + math.cos(lat1) * math.cos(lat2) * sLon * sLon;
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Total along-polyline distance of a list of positions, in meters.
double polylineMeters(List<GeoPoint> points) {
  var total = 0.0;
  for (var i = 1; i < points.length; i++) {
    total += haversineMeters(points[i - 1], points[i]);
  }
  return total;
}

double _rad(double degrees) => degrees * (3.141592653589793 / 180.0);
