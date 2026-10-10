// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route detail renders the course through the [MapSurface] seam — the same
/// renderer as the activity track and the live run, so device builds
/// (`MAP_VIEW=true`) show the MapLibre map there and host/test builds keep
/// the hermetic painter. A recording fake asserts the scene a screen
/// produces: the full route geometry in the static, whole-route view.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/features/routes/presentation/route_detail_screen.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  testWidgets('route detail sends the course geometry to the surface',
      (tester) async {
    final surface = _RecordingMapSurface();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: [riverLoopRoute]),
          ),
          mapSurfaceProvider.overrideWithValue(surface),
        ],
        child: MaterialApp(
          theme: buildAppTheme(),
          home: const RouteDetailScreen(routeId: 'river-loop'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(surface.scenes, hasLength(1));
    final scene = surface.scenes.single;
    expect(scene.geometry, riverLoopRoute.geometry);
    expect(scene.you, riverLoopRoute.geometry.first);
    expect(scene.youProgress, 0);
    expect(scene.staticView, isTrue);
    expect(scene.ghost, isNull);
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