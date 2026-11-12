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

/// One selectable track in Settings → Export GPX (§26): either a saved route
/// (its geometry is the track) or one recorded run.
///
/// The export chooser lists these, and [buildGpxTracks] writes exactly the
/// entries the user picked, so the dialog and the document can never disagree
/// about which tracks exist.
class GpxExportTrack {
  const GpxExportTrack({
    required this.id,
    required this.name,
    required this.kind,
    this.route,
    this.activity,
  }) : assert(
          (route == null) != (activity == null),
          'a track is either a route or an activity',
        );

  /// Stable list key: `route:<id>` or `activity:<id>`.
  final String id;

  /// The `<trk>` name, and what the chooser lists.
  final String name;

  /// What kind of track this is, for the chooser's grouping.
  final GpxExportKind kind;

  /// The saved route this entry writes, or `null` for a run.
  final Route? route;

  /// The recorded run this entry writes, or `null` for a route.
  final Activity? activity;
}

/// The two kinds of exportable track, in chooser order.
enum GpxExportKind {
  route('Routes'),
  activity('Runs');

  const GpxExportKind(this.label);

  /// Section heading in the chooser.
  final String label;
}

/// Every track Settings → Export GPX can write, in display order: saved
/// routes with geometry first, then recorded runs with a track.
///
/// Routes without geometry and runs without a recorded track are skipped,
/// because there is nothing to write for them.
List<GpxExportTrack> exportableTracks(
  List<Route> routes,
  List<Activity> activities,
) {
  final routeNames = {for (final route in routes) route.id: route.name};
  return [
    for (final route in routes)
      if (route.geometry.isNotEmpty)
        GpxExportTrack(
          id: 'route:${route.id}',
          name: route.name.isEmpty ? route.id : route.name,
          kind: GpxExportKind.route,
          route: route,
        ),
    for (final activity in activities)
      if (activity.track != null && activity.track!.isNotEmpty)
        GpxExportTrack(
          id: 'activity:${activity.id}',
          name: _activityTrackName(activity, routeNames[activity.routeId]),
          kind: GpxExportKind.activity,
          activity: activity,
        ),
  ];
}

/// Builds a GPX document holding exactly [tracks] (a chooser selection), or
/// `null` when the list is empty.
String? buildGpxTracks(List<GpxExportTrack> tracks) {
  final documents = <String>[
    for (final track in tracks)
      switch (track.route) {
        final route? => _trackXml(
            track.name,
            [for (final p in route.geometry) (p.latitude, p.longitude)],
          ),
        null => _trackXmlWithTime(track.name, track.activity!.track!),
      },
  ];
  return _document(documents);
}

/// Builds a GPX document from [routes] and [activities], or `null` when there
/// is nothing to export (no route geometry, no activity tracks).
String? buildGpx(List<Route> routes, List<Activity> activities) =>
    buildGpxTracks(exportableTracks(routes, activities));

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