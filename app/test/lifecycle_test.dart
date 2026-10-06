// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/persistence/serialization.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) =>
      c.read(recordingControllerProvider);

  // ---------------------------------------------------------------------------
  // Unit: RunSnapshot JSON round-trip
  // ---------------------------------------------------------------------------
  test('RunSnapshot round-trips through JSON', () {
    final now = DateTime.utc(2026, 8, 1, 12, 0);
    final snapshot = RunSnapshot(
      status: RunStatus.running,
      startedAt: now,
      movingSeconds: 42.3,
      distanceMeters: 1234.5,
      loopMeters: 4760.0,
      routeId: FakeEngineService.riverLoopId,
    );
    final json = runSnapshotToJson(snapshot);
    final restored = parseRunSnapshot(json);

    expect(restored.status, RunStatus.running);
    expect(restored.startedAt, now);
    expect(restored.movingSeconds, closeTo(42.3, 0.01));
    expect(restored.distanceMeters, closeTo(1234.5, 0.1));
    expect(restored.loopMeters, closeTo(4760, 0.1));
    expect(restored.routeId, FakeEngineService.riverLoopId);
  });

  test('RunSnapshot survives null routeId', () {
    final snapshot = RunSnapshot(
      status: RunStatus.paused,
      startedAt: DateTime.utc(2026, 8, 1),
      movingSeconds: 10,
      distanceMeters: 200,
      loopMeters: 300,
    );
    final restored = parseRunSnapshot(runSnapshotToJson(snapshot));
    expect(restored.routeId, isNull);
    expect(restored.status, RunStatus.paused);
  });

  // ---------------------------------------------------------------------------
  // Unit: snapshot written while running (via _advance throttling)
  // ---------------------------------------------------------------------------
  test('snapshot is written periodically while running', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000)); // ready
      ctrl.beginRun();

      // The snapshot is throttled (every 5 s). Advance the wall clock past it.
      async.elapse(const Duration(seconds: 6));
      final raw = store.read('run_snapshot');
      expect(raw, isNotNull);
      expect(raw, isNot('null'));
      final snap = parseRunSnapshot(raw!);
      expect(snap.movingSeconds, greaterThan(3));
      expect(snap.distanceMeters, greaterThan(0));
      expect(snap.routeId, FakeEngineService.riverLoopId);
    });
  });

  // ---------------------------------------------------------------------------
  // Unit: appBackgrounded writes an immediate snapshot
  // ---------------------------------------------------------------------------
  test('appBackgrounded snapshots immediately', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.elapse(const Duration(seconds: 2));

      // No snapshot yet (throttled 5 s).
      expect(store.read('run_snapshot'), isNull);

      // Background the app.
      ctrl.appBackgrounded();
      final raw = store.read('run_snapshot');
      expect(raw, isNotNull);
      final snap = parseRunSnapshot(raw!);
      expect(snap.movingSeconds, greaterThan(1.5));
    });
  });

  // ---------------------------------------------------------------------------
  // Unit: dismissRun clears the snapshot
  // ---------------------------------------------------------------------------
  test('dismissRun clears snapshot', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.elapse(const Duration(seconds: 2));
      ctrl.appBackgrounded();
      expect(store.read('run_snapshot'), isNotNull);

      ctrl.dismissRun();
      expect(store.read('run_snapshot'), 'null');
      expect(state(c), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Unit: resumeFromSnapshot restores a session
  // ---------------------------------------------------------------------------
  test('resumeFromSnapshot restores moving time, distance, and status', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.elapse(const Duration(seconds: 4));

      final live = state(c)!;
      final snapshot = RunSnapshot(
        status: RunStatus.running,
        startedAt: DateTime.utc(2026, 1, 1),
        movingSeconds: live.elapsed.seconds,
        distanceMeters: live.distance.meters,
        loopMeters: 4760.0,
        routeId: FakeEngineService.riverLoopId,
      );

      // "Kill" the current session.
      ctrl.dismissRun();
      expect(state(c), isNull);

      // Resume from the snapshot.
      await ctrl.resumeFromSnapshot(snapshot);
      async.flushMicrotasks();
      final restored = state(c)!;
      expect(restored.status, RunStatus.running);
      expect(restored.elapsed.seconds, closeTo(4, 0.01));
      expect(restored.distance.meters, closeTo(live.distance.meters, 1));
      expect(restored.route?.id, FakeEngineService.riverLoopId);
    });
  });

  test('resumeFromSnapshot with a paused snapshot restores as paused', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.elapse(const Duration(seconds: 3));
      ctrl.pause();

      final live = state(c)!;
      final snapshot = RunSnapshot(
        status: RunStatus.paused,
        startedAt: DateTime.utc(2026, 1, 1),
        movingSeconds: live.elapsed.seconds,
        distanceMeters: live.distance.meters,
        loopMeters: 4760.0,
        routeId: FakeEngineService.riverLoopId,
      );
      ctrl.dismissRun();

      await ctrl.resumeFromSnapshot(snapshot);
      async.flushMicrotasks();
      final restored = state(c)!;
      expect(restored.status, RunStatus.paused);
      expect(restored.elapsed.seconds, closeTo(3, 0.01));
    });
  });

  test('resumeFromSnapshot clears the persisted snapshot', () {
    fakeAsync((async) async {
      final store = MemoryPersistenceStore();
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      keepAlive(c);

      final ctrl = c.read(recordingControllerProvider.notifier);
      ctrl.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.elapse(const Duration(seconds: 2));
      ctrl.appBackgrounded();
      expect(store.read('run_snapshot'), isNotNull);

      final snap = parseRunSnapshot(store.read('run_snapshot')!);
      ctrl.dismissRun();
      await ctrl.resumeFromSnapshot(snap);
      async.flushMicrotasks();

      // The snapshot should have been cleared once resumed.
      expect(store.read('run_snapshot'), 'null');
    });
  });

  // ---------------------------------------------------------------------------
  // Widget: lifecycle observer triggers snapshot on backgrounding
  // ---------------------------------------------------------------------------
  testWidgets('app backgrounding triggers lifecycle snapshot', (tester) async {
    final store = MemoryPersistenceStore();
    await tester.pumpWidget(ProviderScope(
      overrides: [persistenceStoreProvider.overrideWithValue(store)],
      child: const AgainstYesterdayApp(),
    ));
    await tester.pumpAndSettle();

    // Open the Record tab and reach READY TO RUN.
    Finder tab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));
    await tester.tap(tab('Record'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('START'), findsOneWidget);

    // Start a run and let it accumulate a little distance (under the 5 s
    // snapshot throttle, so no snapshot exists yet).
    await tester.tap(find.text('START'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('PAUSE'), findsOneWidget);
    expect(store.read('run_snapshot'), isNull);

    // Simulate the app going to background: the AgainstYesterdayApp lifecycle observer
    // forwards this to the controller, which snapshots immediately.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump();

    final raw = store.read('run_snapshot');
    expect(raw, isNotNull);
    expect(raw, isNot('null'));
    final snap = parseRunSnapshot(raw!);
    expect(snap.movingSeconds, greaterThan(2.5));
    expect(snap.distanceMeters, greaterThan(0));
    expect(snap.routeId, FakeEngineService.riverLoopId);
  });
}