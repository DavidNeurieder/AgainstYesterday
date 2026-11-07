// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Minimal GPX track-point reader for Settings → Import GPX.
///
/// The app only needs the geometry of a `<trk>`: every `<trkpt>` becomes a
/// [GeoPoint], in document order. Elevation, time and extensions are ignored —
/// imported tracks are routes, and the recording pipeline owns live fixes.
/// Like the exporter this is dependency-free string/regex work; the format we
/// accept is the small, fixed one every GPX writer emits.
library;

import '../../../engine/models.dart';

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

/// Extracts every `<trkpt>` position from a GPX document, in file order.
///
/// Both attribute orders are accepted (`lat` before or after `lon`), as are
/// self-closing tags and double- or single-quoted values. Malformed points are
/// skipped rather than failing the whole file.
List<GeoPoint> parseGpxTrack(String contents) {
  final points = <GeoPoint>[];
  for (final tag in _trackPoint.allMatches(contents)) {
    final attributes = tag.group(1)!;
    final lat = _attribute('lat', attributes);
    final lon = _attribute('lon', attributes);
    if (lat == null || lon == null) {
      continue;
    }
    points.add(GeoPoint(latitude: lat, longitude: lon));
  }
  return points;
}

/// A `<trkpt ...>` opening/self-closing tag and its attribute string.
final RegExp _trackPoint = RegExp(r'<trkpt\b([^>]*)>', caseSensitive: false);

/// One numeric attribute of a tag, whichever quote style it uses.
double? _attribute(String name, String attributes) {
  final match = RegExp(
    '$name\\s*=\\s*["\']([^"\']+)["\']',
    caseSensitive: false,
  ).firstMatch(attributes);
  return match == null ? null : double.tryParse(match.group(1)!);
}
