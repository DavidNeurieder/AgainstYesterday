// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Failure injection & regression tests (test plan Phases 13 and 14).
///
/// The contract: dependency failures (storage, engine route matching, broken
/// documents) must yield a *safe, recoverable state* — never an unhandled
/// async exception or a provider that explodes — so the runner keeps a valid
/// summary and history instead of a crash.
library;

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

/// Storage whose reads and writes always throw. Simulates a device whose
/// flash/database is dead or a sandbox that denies I/O (Phase 13).
class _ThrowingStore implements PersistenceStore {
  const _ThrowingStore();

  @override
  String? read(String key) => throw StateError('storage read failed');

  @override
  Future<void> write(String key, String value) async =>
      throw StateError('storage write failed');

  @override
  void remove(String key) => throw StateError('storage write failed');
}

/// Engine whose route matching always fails (and so would `_recognizeRoute`).
class _MismatchingEngine extends FakeEngineService {
  _MismatchingEngine() : super();

  @override
  Future<RouteMatchResult> matchRoutes({
    required List<TrackPoint> a,
    required List<TrackPoint> b,
  }) async {
    throw StateError('route matching failed');
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

  // -------------------------------------------------------------------------
  // Storage reads fail → degrade to the empty defaults (never crash).
  // -------------------------------------------------------------------------
  group('failed storage reads degrade to the empty defaults', () {
    test('a throwing routes read degrades to an empty catalog', () async {
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
      ]);
      addTearDown(c.dispose);
      expect(c.read(routeRepositoryProvider), isEmpty);
    });

    test('a throwing activities read degrades to an empty history', () async {
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
      ]);
      addTearDown(c.dispose);
      expect(c.read(activityRepositoryProvider), isEmpty);
    });

    test('a throwing snapshot read yields no interrupted run', () async {
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
      ]);
      addTearDown(c.dispose);
      expect(c.read(runSnapshotProvider), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Storage writes fail → repositories keep working in memory, no crash.
  // -------------------------------------------------------------------------
  group('failed storage writes stay safe', () {
    test('saving an activity under a failing store does not throw', () async {
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
      ]);
      addTearDown(c.dispose);

      await c.read(activityRepositoryProvider.notifier).saveActivity(
            Activity(
              id: 'a1',
              startedAt: DateTime.utc(2026, 1, 1),
              duration: const Elapsed.seconds(100),
              distance: const Distance.meters(500),
            ),
          );
      // In-memory history is authoritative even when the disk failed.
      expect(c.read(activityRepositoryProvider).first.id, 'a1');
    });

    test('saving and clearing a snapshot under a failing store is a no-op-safe',
        () async {
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
      ]);
      addTearDown(c.dispose);

      final snapshot = RunSnapshot(
        status: RunStatus.running,
        startedAt: DateTime.utc(2026, 1, 1),
        movingSeconds: 60,
        distanceMeters: 200,
        loopMeters: 4760,
      );
      await c.read(runSnapshotProvider.notifier).save(snapshot);
      expect(c.read(runSnapshotProvider), snapshot);

      await c.read(runSnapshotProvider.notifier).save(null);
      expect(c.read(runSnapshotProvider), isNull);
    });

    test('finishing a run under a failing store completes without crashing',
        () {
      fakeAsync((async) async {
        final c = ProviderContainer(overrides: [
          persistenceStoreProvider
              .overrideWithValue(const _ThrowingStore()),
        ]);
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 5));
        ctrl.finishRun();
        async.elapse(const Duration(milliseconds: 500));

        // The completed summary stays visible and the in-memory history holds
        // the run, but the disk write flag reports that nothing landed.
        expect(state(c)!.status, RunStatus.completed);
        expect(state(c)!.hasUnsavedData, isTrue);
        expect(c.read(activityRepositoryProvider), hasLength(1));
        // Snapshot was cleared in memory.
        expect(c.read(runSnapshotProvider), isNull);
      });
    });

    test('backgrounded snapshot under a failing store never throws', () {
      fakeAsync((async) {
        final c = ProviderContainer(overrides: [
          persistenceStoreProvider
              .overrideWithValue(const _ThrowingStore()),
        ]);
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 7));

        ctrl.appBackgrounded(); // triggers a throttled snapshot
        async.flushMicrotasks();

        // The run keeps recording regardless of the failed snapshot write.
        expect(state(c)!.status, RunStatus.running);
        async.elapse(const Duration(seconds: 1));
        expect(state(c)!.distance.meters, greaterThan(0));
      });
    });
  });

  // -------------------------------------------------------------------------
  // Engine failures on the way OUT (route recognition) are safe too.
  // -------------------------------------------------------------------------
  group('route recognition failure on finish', () {
    test('a route-less run finishing with a failing matcher still completes', () {
      fakeAsync((async) {
        // Start on a known route, then drop it, so the finish runs route
        // recognition against a seeded catalog whose matcher throws.
        final c = ProviderContainer(overrides: [
          engineServiceProvider.overrideWithValue(_MismatchingEngine()),
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: [riverLoopRoute]),
          ),
        ]);
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([riverLoopRoute]);
        async.flushMicrotasks();
        expect(state(c)!.status, RunStatus.preparing);
        ctrl.continueWithoutRoute();
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 5));
        ctrl.finishRun();
        async.elapse(const Duration(milliseconds: 500));

        expect(state(c)!.status, RunStatus.completed);
        expect(state(c)!.hasUnsavedData, isTrue);
      });
    });
  });

  // -------------------------------------------------------------------------
  // Structurally valid JSON, wrong shape → safe defaults (Phase 6/14).
  // -------------------------------------------------------------------------
  group('valid JSON with the wrong shape', () {
    test('routes document of the wrong shape degrades to an empty catalog', () async {
      final dir = await Directory.systemTemp.createTemp('against_yesterday_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonFileStore(dir);
      File('${dir.path}/routes.json').writeAsStringSync('{}'); // object, not list
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      expect(c.read(routeRepositoryProvider), isEmpty);
    });

    test('activities document of the wrong shape degrades to an empty history',
        () async {
      final dir = await Directory.systemTemp.createTemp('against_yesterday_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonFileStore(dir);
      File('${dir.path}/activities.json').writeAsStringSync('"just-a-string"');
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      expect(c.read(activityRepositoryProvider), isEmpty);
    });

    test('snapshot document of the wrong shape yields no interrupted run',
        () async {
      final dir = await Directory.systemTemp.createTemp('against_yesterday_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = JsonFileStore(dir);
      File('${dir.path}/run_snapshot.json').writeAsStringSync('[]');
      final c = ProviderContainer(overrides: [
        persistenceStoreProvider.overrideWithValue(store),
      ]);
      addTearDown(c.dispose);
      expect(c.read(runSnapshotProvider), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Lifecycle hygiene (Phase 14): an active run must not leak its 2 Hz ticker
  // into a disposed provider (the on-device relaunch test exercises this).
  // -------------------------------------------------------------------------
  group('lifecycle hygiene', () {
    test('disposing an active session cancels its ticker', () {
      fakeAsync((async) {
        final c = ProviderContainer(overrides: [
          persistenceStoreProvider.overrideWithValue(const _ThrowingStore()),
        ]);
        final sub = c.listen(recordingControllerProvider, (_, _) {});

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 2));
        expect(state(c)!.distance.meters, greaterThan(0));

        sub.close();
        c.dispose();

        // If the ticker survived disposal it would keep firing into a disposed
        // provider and throw here.
        async.elapse(const Duration(seconds: 10));
      });
    });
  });
}