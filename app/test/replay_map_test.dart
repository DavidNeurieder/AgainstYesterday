// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Replay owns the map camera.
///
/// The scene handed to the surface must carry the *current* replay position —
/// the recorded start on the first frame — and keep moving with playback. A
/// recording fake pins that without a native map, so a regression cannot hide
/// behind the renderer.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/activity/presentation/replay_screen.dart';
import 'package:against_yesterday/features/map/map_surface.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

void main() {
  // A deterministic 1 Hz recording of the River Loop, so replay time maps
  // straight onto fixes.
  final recording = FakeEngineService().generateRecording();
  final fixes = [
    for (final p in recording)
      GpsFix(
        timestamp: p.timestamp,
        latitude: p.position.latitude,
        longitude: p.position.longitude,
        altitudeMeters: p.altitudeMeters,
      ),
  ];
  final activity = Activity(
    id: 'act-replay',
    routeId: FakeEngineService.riverLoopId,
    startedAt: recording.first.timestamp,
    duration: Elapsed.seconds(
      recording.last.timestamp
          .difference(recording.first.timestamp)
          .inSeconds
          .toDouble(),
    ),
    distance: const Distance.kilometers(4.76),
    performance: '24:22 · 1st',
    rawFixes: fixes,
  );

  Future<_RecordingMapSurface> pumpReplay(WidgetTester tester) async {
    final surface = _RecordingMapSurface();
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
          home: const ReplayScreen(activityId: 'act-replay'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return surface;
  }

  testWidgets('opens on the recorded start, not on the end of the run',
      (tester) async {
    final surface = await pumpReplay(tester);

    expect(surface.scenes, isNotEmpty);
    final scene = surface.scenes.last;
    expect(scene.geometry, riverLoopRoute.geometry);
    expect(scene.staticView, isFalse);
    expect(
      scene.followLocked,
      isTrue,
      reason: 'replay owns the camera, so playback must stay centred on YOU',
    );
    // At elapsed 0 the engine has applied the first fix: the map opens where
    // the replay is, never on the recording's finish.
    expect(scene.you.latitude, closeTo(fixes.first.latitude, 1e-9));
    expect(scene.you.longitude, closeTo(fixes.first.longitude, 1e-9));
    expect(scene.youProgress, lessThan(0.1));
  });

  testWidgets('hands the surface each new replay position as it advances',
      (tester) async {
    final surface = await pumpReplay(tester);
    final start = surface.scenes.last.you;

    await tester.tap(find.byKey(const ValueKey('replay-toggle')));
    await tester.pump();
    // 3 s of 1x playback in 100 ms frames: a single larger jump is dropped by
    // the screen's ticker on purpose.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final scene = surface.scenes.last;
    expect(scene.youProgress, greaterThan(0));
    expect(
      haversineMeters(scene.you, start),
      greaterThan(1),
      reason: 'the surface must be handed the new position, not the start',
    );
    expect(scene.followLocked, isTrue);
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
