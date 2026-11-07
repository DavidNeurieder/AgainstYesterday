// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Minimal GPX track-point reader for Settings → Import GPX.
///
/// The app only needs the geometry of a `<trk>`: every `<trkpt>` becomes a
/// [GeoPoint], in document order. Elevation, time and extensions are ignored
/// for the route shape, but timestamps are retained separately so imported
/// recordings can be compared statistically.
library;

import '../../../engine/models.dart';

/// A parsed GPX track: its geometry and the (possibly missing or sentinel)
/// timestamp of every point, in the same order.
class GpxTrack {
  const GpxTrack({required this.points, required this.timestamps});

  final List<GeoPoint> points;
  final List<DateTime?> timestamps;
}

/// Parses a GPX document into geometry plus per-point timestamps.
///
/// Points without a usable position are dropped, along with their timestamp.
/// Timestamps that cannot be parsed become `null` rather than failing the
/// point, so a track with bad clock data still imports its shape.
GpxTrack parseGpxTrackDetails(String contents) {
  final points = <GeoPoint>[];
  final timestamps = <DateTime?>[];
  for (final match in _trackPointDetailed.allMatches(contents)) {
    final attributes = match.group(1)!;
    final inner = match.group(2) ?? '';
    final lat = _attribute('lat', attributes);
    final lon = _attribute('lon', attributes);
    if (lat == null || lon == null) {
      continue;
    }
    points.add(GeoPoint(latitude: lat, longitude: lon));
    final timeMatch = RegExp(
      r'<time>(.*?)</time>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(inner);
    var timestamp = timeMatch?.group(1)?.trim();
    if (timestamp != null &&
        !timestamp.endsWith('Z') &&
        !RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(timestamp)) {
      timestamp = '$timestamp' 'Z';
    }
    DateTime? parsed;
    if (timestamp != null) {
      parsed = DateTime.tryParse(timestamp);
    }
    timestamps.add(parsed);
  }
  return GpxTrack(points: points, timestamps: timestamps);
}

/// Extracts every `<trkpt>` position from a GPX document, in file order.
List<GeoPoint> parseGpxTrack(String contents) =>
    parseGpxTrackDetails(contents).points;

/// Converts a geometry into a synthetic track so the engine's route matcher
/// (which works on recordings) can compare two courses. Timestamps are spaced
/// one second apart; matching is shape-based, so the absolute timing is
/// irrelevant.
List<TrackPoint> geometryToTrack(List<GeoPoint> geometry) => [
  for (var i = 0; i < geometry.length; i++)
    TrackPoint(
      position: geometry[i],
      timestamp: DateTime.fromMillisecondsSinceEpoch(i * 1000, isUtc: true),
    ),
];

/// A `<trkpt ...>` opening/self-closing tag, its attributes and inner XML.
final RegExp _trackPointDetailed = RegExp(
  r'<trkpt\b([^>]*)(?:>(.*?)</trkpt>|/>)',
  caseSensitive: false,
  dotAll: true,
);

/// One numeric attribute of a tag, whichever quote style it uses.
double? _attribute(String name, String attributes) {
  final match = RegExp(
    '$name\\s*=\\s*["\']([^"\']+)["\']',
    caseSensitive: false,
  ).firstMatch(attributes);
  return match == null ? null : double.tryParse(match.group(1)!);
}
