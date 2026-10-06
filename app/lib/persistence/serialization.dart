// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// JSON codec for the persisted domain models (M10, §27).
///
/// Handles the compact blob format for routes and activities. Timestamps are
/// epoch-milliseconds (UTC) per track point and ISO-8601 for session starts;
/// keep this in sync with [`Activity`] / [`Route`] in `engine/models.dart`.
library;

import 'dart:convert';

import '../core/units.dart';
import '../engine/models.dart';

Map<String, Object?> _geoJson(GeoPoint p) => {
  'lat': p.latitude,
  'lon': p.longitude,
};

GeoPoint _geoFrom(Map<String, Object?> json) => GeoPoint(
  latitude: (json['lat']! as num).toDouble(),
  longitude: (json['lon']! as num).toDouble(),
);

Map<String, Object?> _pointJson(TrackPoint p) => {
  'lat': p.position.latitude,
  'lon': p.position.longitude,
  'alt': ?p.altitudeMeters,
  't': p.timestamp.millisecondsSinceEpoch,
};

TrackPoint _pointFrom(Map<String, Object?> json) => TrackPoint(
  position: GeoPoint(
    latitude: (json['lat']! as num).toDouble(),
    longitude: (json['lon']! as num).toDouble(),
  ),
  altitudeMeters: json['alt'] == null ? null : (json['alt']! as num).toDouble(),
  timestamp: DateTime.fromMillisecondsSinceEpoch(
    json['t']! as int,
    isUtc: true,
  ),
);

Map<String, Object?> _fixJson(GpsFix f) => {
  't': f.timestamp.millisecondsSinceEpoch,
  'lat': f.latitude,
  'lon': f.longitude,
  'accuracy_m': f.accuracyMeters,
  'altitude_m': f.altitudeMeters,
  'speed_mps': f.speedMetersPerSecond,
  'bearing_deg': f.bearingDegrees,
};

GpsFix _fixFrom(Map<String, Object?> json) => GpsFix(
  timestamp: DateTime.fromMillisecondsSinceEpoch(
    json['t']! as int,
    isUtc: true,
  ),
  latitude: (json['lat']! as num).toDouble(),
  longitude: (json['lon']! as num).toDouble(),
  accuracyMeters: (json['accuracy_m'] as num?)?.toDouble(),
  altitudeMeters: (json['altitude_m'] as num?)?.toDouble(),
  speedMetersPerSecond: (json['speed_mps'] as num?)?.toDouble(),
  bearingDegrees: (json['bearing_deg'] as num?)?.toDouble(),
);

Map<String, Object?> _routeJson(Route r) => {
  'id': r.id,
  'name': r.name,
  'distance_m': r.distance.meters,
  'geometry': [for (final p in r.geometry) _geoJson(p)],
  'attempt_count': r.attemptCount,
  'pb_s': ?r.personalBest?.seconds,
};

Route _routeFrom(Map<String, Object?> json) => Route(
  id: json['id']! as String,
  name: json['name']! as String,
  distance: Distance.meters((json['distance_m']! as num).toDouble()),
  geometry: [
    for (final point in json['geometry']! as List)
      _geoFrom(point as Map<String, Object?>),
  ],
  attemptCount: json['attempt_count']! as int,
  personalBest: json['pb_s'] == null
      ? null
      : Elapsed.seconds((json['pb_s']! as num).toDouble()),
);

Map<String, Object?> _activityJson(Activity a) {
  final track = a.track;
  final rawFixes = a.rawFixes;
  return {
    'id': a.id,
    'route_id': ?a.routeId,
    'started_at': a.startedAt.toUtc().toIso8601String(),
    'duration_s': ?a.duration?.seconds,
    'distance_m': ?a.distance?.meters,
    'performance': ?a.performance,
    if (track != null) 'track': [for (final p in track) _pointJson(p)],
    if (rawFixes != null) 'raw_fixes': [for (final f in rawFixes) _fixJson(f)],
  };
}

Activity _activityFrom(Map<String, Object?> json) => Activity(
  id: json['id']! as String,
  routeId: json['route_id'] as String?,
  startedAt: DateTime.parse(json['started_at']! as String).toUtc(),
  duration: json['duration_s'] == null
      ? null
      : Elapsed.seconds((json['duration_s']! as num).toDouble()),
  distance: json['distance_m'] == null
      ? null
      : Distance.meters((json['distance_m']! as num).toDouble()),
  performance: json['performance'] as String?,
  track: json['track'] == null
      ? null
      : [
          for (final point in json['track']! as List)
            _pointFrom(point as Map<String, Object?>),
        ],
  rawFixes: json['raw_fixes'] == null
      ? null
      : [
          for (final fix in json['raw_fixes']! as List)
            _fixFrom(fix as Map<String, Object?>),
        ],
);

/// Serializes a route list to a compact JSON string.
String routeListToJson(List<Route> routes) =>
    const JsonEncoder().convert([for (final r in routes) _routeJson(r)]);

/// Parses a route list previously written by [routeListToJson].
List<Route> parseRouteList(String json) => [
  for (final route in (jsonDecode(json) as List).cast<Map<String, Object?>>())
    _routeFrom(route),
];

/// Serializes an activity list to a compact JSON string.
String activityListToJson(List<Activity> activities) =>
    const JsonEncoder().convert([for (final a in activities) _activityJson(a)]);

/// Parses an activity list previously written by [activityListToJson].
List<Activity> parseActivityList(String json) => [
  for (final activity
      in (jsonDecode(json) as List).cast<Map<String, Object?>>())
    _activityFrom(activity),
];

/// Serializes an in-progress run snapshot (M13, §28) to a compact JSON string.
String runSnapshotToJson(RunSnapshot snapshot) => const JsonEncoder().convert({
  'status': snapshot.status.name,
  'started_at': snapshot.startedAt.toUtc().toIso8601String(),
  'moving_s': snapshot.movingSeconds,
  'distance_m': snapshot.distanceMeters,
  'loop_m': snapshot.loopMeters,
  'route_id': ?snapshot.routeId,
});

/// Parses a run snapshot previously written by [runSnapshotToJson].
RunSnapshot parseRunSnapshot(String json) {
  final map = (jsonDecode(json) as Map).cast<String, Object?>();
  return RunSnapshot(
    status: RunStatus.values.firstWhere(
      (s) => s.name == map['status'],
      orElse: () => RunStatus.running,
    ),
    startedAt: DateTime.parse(map['started_at']! as String).toUtc(),
    movingSeconds: (map['moving_s']! as num).toDouble(),
    distanceMeters: (map['distance_m']! as num).toDouble(),
    loopMeters: (map['loop_m']! as num).toDouble(),
    routeId: map['route_id'] as String?,
  );
}
