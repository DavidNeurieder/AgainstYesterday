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

  // §33 "activity → export GPX": History's per-run export. The run starts are
  // built as *local* `DateTime`s so `toLocal()` is the identity and the name's
  // stamp is deterministic on any machine (the UTC fixture above is not).
  Activity localActivity({List<TrackPoint>? track}) => Activity(
        id: 'act-010',
        routeId: 'river-loop',
        startedAt: DateTime(2026, 1, 2, 3, 4, 5),
        track: track ?? [TrackPoint(position: const GeoPoint(latitude: 52.5, longitude: 13.4), timestamp: _epoch)],
      );

  group('buildActivityGpx', () {
    test('is null when the run has no track', () {
      expect(
        buildActivityGpx(activity: activityWithTrack(track: const [])),
        isNull,
      );
      expect(
        buildActivityGpx(activity: Activity(id: 'a', startedAt: _epoch)),
        isNull,
      );
    });

    test('names the single <trk> after the route and the run start', () {
      final gpx = buildActivityGpx(
        activity: localActivity(),
        routeName: 'River Loop',
      )!;
      expect(gpx, startsWith('<?xml version="1.0" encoding="UTF-8"?>'));
      expect('<trk>'.allMatches(gpx).length, 1);
      expect(gpx, contains('<name>River Loop · 2026-01-02 03:04</name>'));
    });

    test('writes each point time as UTC ISO-8601', () {
      final gpx = buildActivityGpx(
        activity: localActivity(),
        routeName: 'River Loop',
      )!;
      expect(gpx, contains('<trkpt lat="52.5" lon="13.4">'));
      expect(gpx, contains('<time>2026-01-01T00:00:00.000Z</time>'));
    });

    test('writes elevation only when the receiver reported it', () {
      final withEle = buildActivityGpx(
        activity: localActivity(track: [
          TrackPoint(
            position: const GeoPoint(latitude: 52.5, longitude: 13.4),
            altitudeMeters: 42.5,
            timestamp: _epoch,
          ),
        ]),
        routeName: 'River Loop',
      )!;
      expect(withEle, contains('<ele>42.5</ele>'));

      final withoutEle = buildActivityGpx(
        activity: localActivity(),
        routeName: 'River Loop',
      )!;
      expect(withoutEle, isNot(contains('<ele>')));
    });

    test('falls back to the stored route id, then a generic label', () {
      final byId = buildActivityGpx(activity: localActivity())!;
      expect(byId, contains('<name>river-loop · '));

      final unnamed = buildActivityGpx(
        activity: Activity(
          id: 'a',
          startedAt: DateTime(2026, 1, 2),
          track: [
            TrackPoint(
              position: const GeoPoint(latitude: 1, longitude: 2),
              timestamp: _epoch,
            ),
          ],
        ),
      )!;
      expect(unnamed, contains('<name>Run · 2026-01-02 00:00</name>'));
    });

    test('escapes XML-special characters in the run name', () {
      final gpx = buildActivityGpx(
        activity: localActivity(),
        routeName: 'Tom & Jerry <"Lakes">',
      )!;
      expect(
        gpx,
        contains('<name>Tom &amp; Jerry &lt;&quot;Lakes&quot;&gt; · '),
      );
    });
  });

  group('gpxActivityFileName', () {
    Activity run({required DateTime startedAt, String? routeId}) => Activity(
          id: 'act-011',
          routeId: routeId,
          startedAt: startedAt,
        );

    test('slugs the route and stamps the run start', () {
      expect(
        gpxActivityFileName(
          activity: run(startedAt: DateTime(2026, 1, 2, 3, 4, 5)),
          routeName: 'River Loop',
        ),
        'against-yesterday-river-loop-2026-01-02-030405.gpx',
      );
    });

    test('folds accents and collapses punctuation', () {
      expect(
        gpxActivityFileName(
          activity: run(startedAt: DateTime(2026, 1, 2, 3, 4, 5)),
          routeName: 'Hügelrunde (North)!',
        ),
        'against-yesterday-hugelrunde-north-2026-01-02-030405.gpx',
      );
    });

    test('falls back to the stored route id, then to the bare stamp', () {
      expect(
        gpxActivityFileName(
          activity: run(
            startedAt: DateTime(2026, 1, 2, 3, 4, 5),
            routeId: 'park-5k',
          ),
        ),
        'against-yesterday-park-5k-2026-01-02-030405.gpx',
      );
      expect(
        gpxActivityFileName(activity: run(startedAt: DateTime(2026, 1, 2, 3, 4, 5))),
        'against-yesterday-2026-01-02-030405.gpx',
      );
    });
  });
}