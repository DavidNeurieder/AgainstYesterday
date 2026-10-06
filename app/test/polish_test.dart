// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/home/presentation/home_screen.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/widgets/performance_gap.dart';
import 'package:against_yesterday/widgets/route_map.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

/// Engine that fails [createAttempt] the first [failures] times, then
/// delegates to the real fake. Simulates a flaky engine for M14 error/retry.
class _FlakyEngine extends FakeEngineService {
  _FlakyEngine({required this.failures}) : super();

  int failures;

  @override
  Future<Attempt> createAttempt({
    required String activityId,
    required String routeId,
    required List<TrackPoint> points,
    required List<GeoPoint> routeGeometry,
  }) {
    if (failures > 0) {
      failures--;
      throw StateError('ghost preparation failed');
    }
    return super.createAttempt(
      activityId: activityId,
      routeId: routeId,
      points: points,
      routeGeometry: routeGeometry,
    );
  }
}

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) =>
      c.read(recordingControllerProvider);

  // ---------------------------------------------------------------------------
  // M14: error state + retry at the controller level
  // ---------------------------------------------------------------------------
  test('engine failure surfaces as error and retry recovers', () {
    fakeAsync((async) async {
      final engine = _FlakyEngine(failures: 1);
      final c = ProviderContainer(overrides: [
        engineServiceProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      final failed = state(c);
      expect(failed!.status, RunStatus.error);

      ctrl.retry();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 500));
      async.elapse(const Duration(milliseconds: 500));
      expect(state(c)!.status, RunStatus.ready);
    });
  });

  test('retry is a no-op when the engine keeps failing', () {
    fakeAsync((async) async {
      final engine = _FlakyEngine(failures: 100);
      final c = ProviderContainer(overrides: [
        engineServiceProvider.overrideWithValue(engine),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      expect(state(c)!.status, RunStatus.error);

      ctrl.retry();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 600));
      expect(state(c)!.status, RunStatus.error);
    });
  });

  // ---------------------------------------------------------------------------
  // M14: the Record tab shows the error screen, and retrying recovers it
  // ---------------------------------------------------------------------------
  testWidgets('record tab error state recovers via retry', (tester) async {
    final engine = _FlakyEngine(failures: 1);
    await tester.pumpWidget(ProviderScope(
      overrides: [engineServiceProvider.overrideWithValue(engine)],
      child: const AgainstYesterdayApp(),
    ));
    await tester.pumpAndSettle();

    Finder tab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));
    await tester.tap(tab('Record'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Could not start a run'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // M14: empty states on Home
  // ---------------------------------------------------------------------------
  testWidgets('home shows empty hints when repositories are empty', (tester) async {
    final store = MemoryPersistenceStore();
    await store.write('routes', '[]');
    await store.write('activities', '[]');
    await tester.pumpWidget(ProviderScope(
      overrides: [persistenceStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    expect(
      find.text('No runs yet. Your finished runs land here.'),
      findsOneWidget,
    );
    expect(
      find.text('No routes yet. Finish a run to record one.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Start a run'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // M14: accessibility — spoken labels
  // ---------------------------------------------------------------------------
  testWidgets('PerformanceGap exposes a spoken gap label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PerformanceGap(
          difference: Elapsed.seconds(12),
          distance: Distance.meters(1200),
          state: AheadBehind.ahead,
        ),
      ),
    ));
    final semantics = tester.getSemantics(find.byType(PerformanceGap));
    expect(semantics.label, contains('Ahead of PB'));
    expect(semantics.label, contains('0:12'));
    handle.dispose();
  });

  testWidgets('live map annotates YOU and ghost markers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: RouteMap(
            geometry: FakeEngineService.riverLoop,
            you: FakeEngineService.riverLoop.first,
            youProgress: 0,
            ghost: FakeEngineService.riverLoop[3],
            name: 'River Loop',
          ),
        ),
      ),
    ));
    await tester.pump();
    // Marker labels merge with the map's route-name label into one semantics
    // node, so match by pattern rather than exact label.
    expect(find.bySemanticsLabel(RegExp('Your position')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('PB ghost position')), findsWidgets);
    handle.dispose();
  });
}