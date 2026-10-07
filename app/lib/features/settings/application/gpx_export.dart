// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Minimal GPX 1.1 serializer for Settings → Export GPX (M21, §26).
///
/// One `<trk>` per route (its geometry as the track) and per activity (its
/// recorded track). No XML dependency: the format this app writes is small
/// and fixed, so plain string building keeps it dependency-free.
library;

import '../../../engine/models.dart';

/// Builds a GPX document from [routes] and [activities], or `null` when there
/// is nothing to export (no route geometry, no activity tracks).
String? buildGpx(List<Route> routes, List<Activity> activities) {
  final tracks = <String>[
    for (final route in routes)
      if (route.geometry.isNotEmpty)
        _trackXml(route.name, [for (final p in route.geometry) (p.latitude, p.longitude)]),
    for (final activity in activities)
      if (activity.track != null && activity.track!.isNotEmpty)
        _trackXml(
          activity.routeId ?? 'run',
          [
            for (final p in activity.track!)
              (p.position.latitude, p.position.longitude),
          ],
        ),
  ];
  if (tracks.isEmpty) {
    return null;
  }
  final body = tracks.join();
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="Against Yesterday" '
      'xmlns="http://www.topografix.com/GPX/1/1">'
      '$body'
      '</gpx>';
}

String _trackXml(String name, List<(double, double)> points) {
  final segment = [
    for (final (lat, lon) in points)
      '<trkpt lat="$lat" lon="$lon"></trkpt>',
  ].join();
  return '<trk><name>${_escape(name)}</name><trkseg>$segment</trkseg></trk>';
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');