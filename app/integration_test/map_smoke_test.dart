// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// On-device map smoke (offline map Phase 4).
///
/// Renders the real MapLibre map — native view, real style document pulled
/// over the network — and waits for the style to load and the first scene to
/// be drawn, so a broken maplibre integration fails on the device instead of
/// only on a phone in someone's pocket. Needs network, so it is nightly /
/// connected-only: the suite skips unless launched with
/// `--dart-define=MAP_VIEW=true`, which the harness does for `--map-smoke`
/// (`./tool/android_integration_test.sh --map-smoke`). Off-network CI stays
/// hermetic.
///
/// Run with:
///
/// ```bash
/// ./tool/android_integration_test.sh --map-smoke
/// ```
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/features/map/maplibre_map_surface.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:integration_test/integration_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

/// Mirrors the app's own define semantics (`map_surface.dart`).
const String _mapView = String.fromEnvironment('MAP_VIEW');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'renders the live scene on the real MapLibre map',
    // Skipped unless launched with --dart-define=MAP_VIEW=true (the
    // --map-smoke harness invocation): the real map needs network.
    skip: _mapView != 'true',
    (tester) async {
      final ready = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: MaplibreRouteMap(
              scene: MapScene(
                geometry: FakeEngineService.riverLoop,
                you: FakeEngineService.riverLoop.first,
                youProgress: 0.3,
                staticView: true,
              ),
              onReady: ready.complete,
            ),
          ),
        ),
      );

      // Style load, source/layer setup and the first camera move happen on the
      // native side. Generous: a cold emulator pulled the style+tiles slowly.
      await ready.future
          .timeout(const Duration(seconds: 60), onTimeout: () {
        fail(
          'MapLibre did not reach style-loaded within 60 s. The map likely '
          'failed to initialise or the style document was unreachable.',
        );
      });

      await tester.pumpAndSettle();
      expect(find.byType(MapLibreMap), findsOneWidget);
    },
  );
}