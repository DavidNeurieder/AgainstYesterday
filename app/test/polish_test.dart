// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/home/presentation/home_screen.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/widgets/performance_gap.dart';
import 'package:against_yesterday/widgets/route_map.dart';

import 'test_catalog.dart';

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

/// A device GPS source that refuses acquisition, for the M14 activation tests.
class _RefusingGpsSource implements GpsSource {
  _RefusingGpsSource(this.reason);

  final String reason;
  int settingsOpened = 0;

  @override
  String get description => 'test device GPS';

  @override
  Future<String?> ensureAvailable() async => reason;

  @override
  Stream<GpsFix> fixes() => const Stream.empty();

  @override
  Future<void> openSettings() async {
    settingsOpened++;
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
  // M14: the record flow shows the error screen, and retrying recovers it
  // ---------------------------------------------------------------------------
  testWidgets('record flow error state recovers via retry', (tester) async {
    final engine = _FlakyEngine(failures: 1);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        engineServiceProvider.overrideWithValue(engine),
        // Seed a route so the flow picks one to prepare a ghost with.
        persistenceStoreProvider.overrideWithValue(
          seededStore(routes: [riverLoopRoute]),
        ),
      ],
      child: const AgainstYesterdayApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
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
  // M14: a device-GPS activation refusal surfaces the real reason and points
  // at the matching settings, instead of blaming the engine.
  // ---------------------------------------------------------------------------
  testWidgets('GPS activation refusal names the problem and opens settings',
      (tester) async {
    final refusal = _RefusingGpsSource(
      'Location services are off. Turn on GPS, then try again.',
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [deviceGpsProvider.overrideWithValue(refusal)],
      child: const AgainstYesterdayApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RECORD ROUTE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('GPS UNAVAILABLE'), findsOneWidget);
    expect(
      find.textContaining('Location services are off.'),
      findsOneWidget,
    );
    expect(find.text('Open location settings'), findsOneWidget);

    await tester.tap(find.text('Open location settings'));
    await tester.pump();
    expect(refusal.settingsOpened, 1);
  });

  // ---------------------------------------------------------------------------
  // M14: empty states on Home
  // ---------------------------------------------------------------------------
  testWidgets('home shows the empty state when the catalog is empty', (tester) async {
    final store = MemoryPersistenceStore();
    await store.write('routes', '[]');
    await store.write('activities', '[]');
    await tester.pumpWidget(ProviderScope(
      overrides: [persistenceStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Your first race awaits.'), findsOneWidget);
    expect(
      find.text('Record a route and start competing against yourself.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'RECORD ROUTE'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // M14: accessibility — spoken labels
  // ---------------------------------------------------------------------------
  testWidgets('PerformanceGap exposes a spoken gap label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: PerformanceGap(
            difference: Elapsed.seconds(12),
            distance: Distance.meters(1200),
            state: AheadBehind.ahead,
          ),
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