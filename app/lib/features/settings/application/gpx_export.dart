// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Minimal GPX 1.1 serializer for Settings → Export GPX (M21, §26) and for
/// History's per-run export (§33 "activity → export GPX").
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
  return _document(tracks);
}

/// Builds a single-run GPX document for History's per-run export (§33
/// "activity → export GPX"), or `null` when [activity] has no recorded track
/// to write.
///
/// One `<trk>`, named after [routeName] (falling back to the stored route id,
/// then a generic label) plus the run's start, and every point carries its
/// `<time>` — and its `<ele>` when the receiver reported one.
String? buildActivityGpx({required Activity activity, String? routeName}) {
  final track = activity.track;
  if (track == null || track.isEmpty) {
    return null;
  }
  return _document([
    _trackXmlWithTime(_activityTrackName(activity, routeName), track),
  ]);
}

/// `River Loop · 2026-01-02 03:04` — the route plus the run's local start, so
/// an opened file still says which run it holds.
String _activityTrackName(Activity activity, String? routeName) {
  final label = routeName ?? activity.routeId ?? 'Run';
  final started = activity.startedAt.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '$label · ${started.year}-${two(started.month)}-${two(started.day)} '
      '${two(started.hour)}:${two(started.minute)}';
}

/// Wraps [tracks] in a GPX document, or `null` when there is nothing to wrap.
String? _document(List<String> tracks) {
  if (tracks.isEmpty) {
    return null;
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<gpx version="1.1" creator="Against Yesterday" '
      'xmlns="http://www.topografix.com/GPX/1/1">'
      '${tracks.join()}'
      '</gpx>';
}

String _trackXml(String name, List<(double, double)> points) {
  final segment = [
    for (final (lat, lon) in points)
      '<trkpt lat="$lat" lon="$lon"></trkpt>',
  ].join();
  return '<trk><name>${_escape(name)}</name><trkseg>$segment</trkseg></trk>';
}

String _trackXmlWithTime(String name, List<TrackPoint> points) {
  final segment = [
    for (final point in points)
      '<trkpt lat="${point.position.latitude}" '
      'lon="${point.position.longitude}">'
      '${point.altitudeMeters == null ? '' : '<ele>${point.altitudeMeters}</ele>'}'
      '<time>${point.timestamp.toUtc().toIso8601String()}</time>'
      '</trkpt>',
  ].join();
  return '<trk><name>${_escape(name)}</name><trkseg>$segment</trkseg></trk>';
}

String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');