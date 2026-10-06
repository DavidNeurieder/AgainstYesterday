// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

void main() {
  /// Keeps the autoDispose provider alive while a fake-async test runs.
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) =>
      c.read(recordingControllerProvider);

  test('pre-run flow: preparing → gpsAcquiring → ready', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      c.read(recordingControllerProvider.notifier).ensureSession([_route]);
      async.flushMicrotasks();

      expect(state(c)!.status, RunStatus.preparing);

      async.elapse(const Duration(milliseconds: 500));
      expect(state(c)!.status, RunStatus.gpsAcquiring);

      async.elapse(const Duration(milliseconds: 500));
      expect(state(c)!.status, RunStatus.ready);
      expect(state(c)!.route?.name, 'River Loop');
    });
  });

  test('running advances distance and moving time', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000)); // ready
      expect(state(c)!.status, RunStatus.ready);

      notifier.beginRun();
      expect(state(c)!.status, RunStatus.running);
      async.elapse(const Duration(seconds: 2));

      final running = state(c)!;
      expect(running.status, RunStatus.running);
      expect(running.distance.meters, greaterThan(0));
      expect(running.elapsed.seconds, closeTo(2, 0.01));
      expect(running.hasUnsavedData, isTrue);
    });
  });

  test('paused time does not count toward performance', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.beginRun();
      async.elapse(const Duration(milliseconds: 1000));

      notifier.pause();
      final distanceAtPause = state(c)!.distance.meters;
      final elapsedAtPause = state(c)!.elapsed.seconds;

      async.elapse(const Duration(seconds: 3));
      expect(state(c)!.status, RunStatus.paused);
      expect(state(c)!.distance.meters, distanceAtPause);
      expect(state(c)!.elapsed.seconds, elapsedAtPause);

      notifier.resume();
      async.elapse(const Duration(milliseconds: 500));
      expect(state(c)!.distance.meters, greaterThan(distanceAtPause));
    });
  });

  test('finish completes the run and leaves a gap vs PB', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.beginRun();
      async.elapse(const Duration(seconds: 30));

      notifier.finishRun();
      expect(state(c)!.status, RunStatus.completed);
      async.elapse(const Duration(milliseconds: 500));

      final done = state(c)!;
      expect(done.status, RunStatus.completed);
      expect(done.hasUnsavedData, isFalse);
      expect(done.ghostGap, isNotNull);

      // M10: the finished run was saved into the activity history.
      final history = c.read(activityRepositoryProvider);
      expect(history.length, 3); // 2 seeded demo activities + this run
      final saved = history.first;
      expect(saved.duration?.seconds, closeTo(30, 1));
      expect(saved.track, isNotEmpty);
      // The session knew the route, so the activity is tagged with it.
      expect(saved.routeId, FakeEngineService.riverLoopId);
    });
  });

  test('a full loop saved without a route is recognized and tagged', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.continueWithoutRoute();
      notifier.beginRun();
      // ~4.9 km at ~3.37 m/s completes the ~4.76 km loop.
      async.elapse(const Duration(seconds: 1500));
      notifier.finishRun();
      async.elapse(const Duration(milliseconds: 500));

      final saved = c.read(activityRepositoryProvider).first;
      expect(saved.distance?.meters, greaterThan(4700));
      expect(saved.routeId, FakeEngineService.riverLoopId);
    });
  });

  test('dismissing resets the session', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.dismissRun();
      expect(state(c), isNull);
      // A fresh session can be started again.
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      expect(state(c)!.status, RunStatus.preparing);
    });
  });

  test('ghost marks the PB distance at the live elapsed time', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.beginRun();

      async.elapse(const Duration(seconds: 30));
      final a = state(c)!;
      expect(a.currentPosition, isNotNull);
      expect(a.ghostPosition, isNotNull);

      async.elapse(const Duration(seconds: 30));
      final b = state(c)!;
      expect(b.ghostPosition, isNotNull);
      // The ghost advances along the route while the run goes on.
      expect(
        haversineMeters(a.ghostPosition!, b.ghostPosition!),
        greaterThan(0),
      );

      // Ghost runs at a PB pace different from ours, so positions differ.
      expect(
        haversineMeters(b.ghostPosition!, b.currentPosition!),
        greaterThan(0),
      );
    });
  });

  test('continue without route clears the ghost', () {
    fakeAsync((async) {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      keepAlive(c);
      final notifier = c.read(recordingControllerProvider.notifier);
      notifier.ensureSession([_route]);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      notifier.continueWithoutRoute();
      final ready = state(c)!;
      expect(ready.status, RunStatus.ready);
      expect(ready.route, isNull);
      expect(ready.ghostGap, isNull);
    });
  });
}