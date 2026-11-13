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
    testWidgets('draws the route as the base and the run on top',
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

      // The screen rebuilds once the engine-backed splits resolve; every
      // build asks for the same scene, so the latest one is the settled one.
      expect(surface.scenes, isNotEmpty);
      final scene = surface.scenes.last;
      // The course is the map; the run's own fixes are the overlay.
      expect(scene.geometry, riverLoopRoute.geometry);
      expect(scene.track, [for (final p in track) p.position]);
      expect(scene.you, track.first.position);
      expect(scene.youProgress, 1);
      expect(scene.staticView, isTrue);
      expect(scene.ghost, isNull);
    });

    testWidgets('every run of a route gets the same base map', (tester) async {
      final reverseTrack = [
        for (final p in track.reversed) p,
      ];
      final activities = [
        Activity(
          id: 'act-a',
          routeId: 'river-loop',
          startedAt: DateTime.utc(2026, 1, 2),
          duration: const Elapsed.seconds(1502),
          distance: const Distance.kilometers(4.75),
          track: track,
        ),
        Activity(
          id: 'act-b',
          routeId: 'river-loop',
          startedAt: DateTime.utc(2026, 1, 3),
          duration: const Elapsed.seconds(1520),
          distance: const Distance.kilometers(4.76),
          track: reverseTrack,
        ),
      ];

      Future<List<MapScene>> scenesFor(String id) async {
        final local = _RecordingMapSurface();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              persistenceStoreProvider.overrideWithValue(
                seededStore(
                  activities: activities,
                  routes: [riverLoopRoute],
                ),
              ),
              mapSurfaceProvider.overrideWithValue(local),
            ],
            child: MaterialApp(
              theme: buildAppTheme(),
              home: ActivityDetailScreen(key: ValueKey(id), activityId: id),
            ),
          ),
        );
        await tester.pumpAndSettle();
        return local.scenes;
      }

      final first = (await scenesFor('act-a')).last;
      final second = (await scenesFor('act-b')).last;

      expect(first.geometry, riverLoopRoute.geometry);
      expect(second.geometry, riverLoopRoute.geometry);
      expect(first.track, isNot(second.track));
    });

    testWidgets('a run without a track still shows the shared route map',
        (tester) async {
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

      final scene = surface.scenes.last;
      expect(scene.geometry, riverLoopRoute.geometry);
      expect(scene.track, isEmpty);
      expect(scene.you, riverLoopRoute.geometry.first);
      expect(scene.staticView, isTrue);
    });
  });
}

/// Captures the scene a screen asked to draw, without a native map.
class _RecordingMapSurface implements MapSurface {
  final scenes = <MapScene>[];

  @override
  Widget build(BuildContext context, MapScene scene, {bool fullscreen = true}) {
    scenes.add(scene);
    return const SizedBox.shrink();
  }
}