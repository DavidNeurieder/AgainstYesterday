// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/settings/application/gpx_export.dart';
import 'package:against_yesterday/features/settings/application/track_export.dart';
import 'package:flutter_test/flutter_test.dart';

final _epoch = DateTime.utc(2026, 1, 1);

/// M21 §26: the GPX document the Settings export writes, and the file name it
/// lands under in Downloads.
void main() {
  const route = Route(
    id: 'river-loop',
    name: 'River Loop',
    distance: Distance.kilometers(4.76),
    geometry: [
      GeoPoint(latitude: 52.5, longitude: 13.4),
      GeoPoint(latitude: 52.5005, longitude: 13.4005),
    ],
  );

  Activity activityWithTrack({List<TrackPoint>? track}) => Activity(
        id: 'act-009',
        routeId: 'river-loop',
        startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        track: track ??
            [
              TrackPoint(
                position: GeoPoint(latitude: 52.5, longitude: 13.4),
                timestamp: _epoch,
              ),
            ],
      );

  group('buildGpx', () {
    test('is null when there is nothing to export', () {
      expect(buildGpx(const [], const []), isNull);
      expect(buildGpx(const [route], const []), isNotNull);
    });

    test('emits one <trk> per route geometry', () {
      final gpx = buildGpx([route], const [])!;
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect('<trk>'.allMatches(gpx).length, 1);
      expect(gpx, contains('<name>River Loop</name>'));
      expect(gpx, contains('<trkpt lat="52.5" lon="13.4"></trkpt>'));
    });

    test('emits one <trk> per recorded activity track', () {
      final track = [
        TrackPoint(
          position: GeoPoint(latitude: 52.5, longitude: 13.4),
          timestamp: _epoch,
        ),
        TrackPoint(
          position: GeoPoint(latitude: 52.5005, longitude: 13.4005),
          timestamp: _epoch,
        ),
      ];
      final gpx = buildGpx(const [], [activityWithTrack(track: track)])!;
      expect('<trk>'.allMatches(gpx).length, 1);
      expect(gpx, contains('<trkpt lat="52.5005" lon="13.4005"></trkpt>'));
    });

    test('skips empty geometry and nameless metadata safely', () {
      final empty = Route(
        id: 'empty',
        name: 'Empty',
        distance: const Distance.kilometers(0),
        geometry: const [],
      );
      final gpx = buildGpx([route, empty], const [])!;
      expect('<trk>'.allMatches(gpx).length, 1);
    });

    test('escapes XML-special characters in track names', () {
      final special = Route(
        id: 'amp',
        name: 'Tom & Jerry <"Lakes">',
        distance: const Distance.kilometers(1),
        geometry: const [GeoPoint(latitude: 1, longitude: 2)],
      );
      final gpx = buildGpx([special], const [])!;
      expect(
        gpx,
        contains('<name>Tom &amp; Jerry &lt;&quot;Lakes&quot;&gt;</name>'),
      );
      expect(gpx, isNot(contains('& <')));
    });
  });

  group('gpxFileName', () {
    test('is a timestamped, collision-free name', () {
      final name = gpxFileName(DateTime(2026, 10, 9, 14, 15, 30));
      expect(name, 'against-yesterday-2026-10-09-141530.gpx');
    });

    test('pads hour, minute and second to two digits', () {
      final name = gpxFileName(DateTime(2026, 1, 2, 3, 4, 5));
      expect(name, 'against-yesterday-2026-01-02-030405.gpx');
    });
  });
}