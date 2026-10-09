// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Phase 2 of the offline map: activity detail puts the recorded run's track
/// on the map. A recording fake asserts the scene the renderer receives — the
/// full track geometry in the static, whole-route view.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/activity/presentation/activity_detail_screen.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  final track = <TrackPoint>[
    TrackPoint(
      position: const GeoPoint(latitude: 52.52, longitude: 13.38),
      timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5),
    ),
    TrackPoint(
      position: const GeoPoint(latitude: 52.532, longitude: 13.386),
      timestamp: DateTime.utc(2026, 1, 2, 3, 5, 5),
    ),
    TrackPoint(
      position: const GeoPoint(latitude: 52.52, longitude: 13.392),
      timestamp: DateTime.utc(2026, 1, 2, 3, 6, 5),
    ),
    TrackPoint(
      position: const GeoPoint(latitude: 52.508, longitude: 13.386),
      timestamp: DateTime.utc(2026, 1, 2, 3, 7, 5),
    ),
  ];

  group('activity detail → MapSurface scene', () {
    testWidgets('sends the recorded track geometry to the surface',
        (tester) async {
      final surface = _RecordingMapSurface();
      final activity = Activity(
        id: 'act-track',
        routeId: 'river-loop',
        startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        duration: const Elapsed.seconds(1502),
        distance: const Distance.kilometers(4.75),
        performance: '24:22 · 1st',
        track: track,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            persistenceStoreProvider.overrideWithValue(
              seededStore(activities: [activity], routes: [riverLoopRoute]),
            ),
            mapSurfaceProvider.overrideWithValue(surface),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const ActivityDetailScreen(activityId: 'act-track'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(surface.scenes, hasLength(1));
      final scene = surface.scenes.single;
      expect(scene.geometry, [for (final p in track) p.position]);
      expect(scene.you, track.first.position);
      expect(scene.youProgress, 1);
      expect(scene.staticView, isTrue);
      expect(scene.ghost, isNull);
    });

    testWidgets('leaves the map out for a run without a track', (tester) async {
      final surface = _RecordingMapSurface();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            persistenceStoreProvider.overrideWithValue(
              seededStore(
                activities: [seedActivity(id: 'act-001')],
                routes: [riverLoopRoute],
              ),
            ),
            mapSurfaceProvider.overrideWithValue(surface),
          ],
          child: MaterialApp(
            theme: buildAppTheme(),
            home: const ActivityDetailScreen(activityId: 'act-001'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(surface.scenes, isEmpty);
    });
  });
}

/// Captures the scene a screen asked to draw, without a native map.
class _RecordingMapSurface implements MapSurface {
  final scenes = <MapScene>[];

  @override
  Widget build(BuildContext context, MapScene scene) {
    scenes.add(scene);
    return const SizedBox.shrink();
  }
}