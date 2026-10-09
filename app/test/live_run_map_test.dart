// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Phase 1 of the offline map: the live run screen talks to the map only
/// through [MapSurface] and hands it the race scene — route geometry, YOU, the
/// PB ghost and the travelled fraction. A recording fake proves the scene is
/// what the renderer gets, with no native map in the test.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';

import 'test_catalog.dart';

void main() {
  group('live run screen → MapSurface scene', () {
    testWidgets('sends route, YOU, ghost and progress to the surface',
        (tester) async {
      final surface = _RecordingMapSurface();
      final route = riverLoopRoute;
      final state = LiveRunState(
        status: RunStatus.running,
        elapsed: const Elapsed.seconds(61),
        distance: const Distance.meters(800),
        pace: const Speed.metersPerSecond(3.2),
        routeProgress: 0.16,
        route: route,
        currentPosition: route.geometry[1],
        ghostPosition: route.geometry[0],
      );

      await _pump(tester, surface, state);

      expect(surface.scenes, hasLength(1));
      final scene = surface.scenes.single;
      expect(scene.geometry, route.geometry);
      expect(scene.you, route.geometry[1]);
      expect(scene.ghost, route.geometry[0]);
      expect(scene.youProgress, 0.16);
      expect(scene.name, route.name);
      expect(scene.staticView, isFalse);
    });

    testWidgets('falls back to the first route point before the first fix',
        (tester) async {
      final surface = _RecordingMapSurface();
      final route = parkLoopRoute;
      final state = LiveRunState(
        status: RunStatus.running,
        elapsed: const Elapsed.zero(),
        distance: const Distance.zero(),
        pace: const Speed.metersPerSecond(3.2),
        routeProgress: 0,
        route: route,
      );

      await _pump(tester, surface, state);

      expect(surface.scenes.single.you, route.geometry.first);
      expect(surface.scenes.single.ghost, isNull);
    });
  });
}

Future<void> _pump(
  WidgetTester tester,
  _RecordingMapSurface surface,
  LiveRunState state,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [mapSurfaceProvider.overrideWithValue(surface)],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: LiveRunScreen(state: state),
      ),
    ),
  );
  await tester.pumpAndSettle();
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