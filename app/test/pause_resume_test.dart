// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Dedicated pause/resume suite (test plan Phase 5).
///
/// The central invariant: **paused time never counts toward moving time or
/// distance** — the saved activity's duration must reflect only running time.
library;

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
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) =>
      c.read(recordingControllerProvider);

  ProviderContainer container(FakeAsync async) {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    keepAlive(c);
    final ctrl = c.read(recordingControllerProvider.notifier);
    ctrl.ensureSession([_route]);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000)); // ready
    return c;
  }

  test('explicit pauses never count toward moving time or distance', () {
    fakeAsync((async) {
      final c = container(async);
      final ctrl = c.read(recordingControllerProvider.notifier);

      ctrl.beginRun();
      async.elapse(const Duration(seconds: 5)); // run 5
      ctrl.pause();
      async.elapse(const Duration(seconds: 10)); // pause 10
      ctrl.resume();
      async.elapse(const Duration(seconds: 3)); // run 8
      ctrl.pause();
      async.elapse(const Duration(seconds: 4)); // pause 4
      ctrl.resume();
      async.elapse(const Duration(seconds: 2)); // run 10
      ctrl.pause();

      final live = state(c)!;
      expect(live.status, RunStatus.paused);
      // Only the 5+3+2 = 10 running seconds count.
      expect(live.elapsed.seconds, closeTo(10, 0.6));
      final distance = live.distance.meters;
      expect(distance, greaterThan(0));

      // A long pause adds nothing.
      async.elapse(const Duration(seconds: 30));
      expect(state(c)!.distance.meters, distance);
      expect(state(c)!.elapsed.seconds, closeTo(10, 0.6));

      // Finish from the pause: the saved run keeps the same clock.
      ctrl.finishRun();
      async.elapse(const Duration(milliseconds: 500));
      final saved = c.read(activityRepositoryProvider).first;
      expect(saved.duration!.seconds, closeTo(10, 0.6));
      expect(saved.distance!.meters, closeTo(distance, 0.1));
    });
  });

  test('pause immediately after start; finish right after resume', () {
    fakeAsync((async) {
      final c = container(async);
      final ctrl = c.read(recordingControllerProvider.notifier);

      ctrl.beginRun();
      async.elapse(const Duration(milliseconds: 500)); // one tick
      ctrl.pause();
      async.elapse(const Duration(seconds: 30)); // nothing happens
      ctrl.resume();
      async.elapse(const Duration(milliseconds: 500)); // one tick
      ctrl.finishRun();
      async.elapse(const Duration(milliseconds: 500));

      expect(state(c)!.status, RunStatus.completed);
      final saved = c.read(activityRepositoryProvider).first;
      // ~1 second of actual movement across the two ticks.
      expect(saved.duration!.seconds, greaterThan(0));
      expect(saved.duration!.seconds, lessThan(3));
      expect(saved.distance!.meters, greaterThan(0));
      expect(saved.distance!.meters, lessThan(20));
    });
  });

  test('a one-second run records about one second of moving time', () {
    fakeAsync((async) {
      final c = container(async);
      final ctrl = c.read(recordingControllerProvider.notifier);

      ctrl.beginRun();
      async.elapse(const Duration(seconds: 1));
      ctrl.finishRun();
      async.elapse(const Duration(milliseconds: 500));

      final saved = c.read(activityRepositoryProvider).first;
      expect(saved.duration!.seconds, closeTo(1, 0.05));
    });
  });

  test('resume then pause again cycles cleanly more than once', () {
    fakeAsync((async) {
      final c = container(async);
      final ctrl = c.read(recordingControllerProvider.notifier);

      ctrl.beginRun();
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 1));
        ctrl.pause();
        expect(state(c)!.status, RunStatus.paused);
        async.elapse(const Duration(seconds: 1)); // idle
        ctrl.resume();
        expect(state(c)!.status, RunStatus.running);
      }
      async.elapse(const Duration(seconds: 1));
      ctrl.finishRun();
      async.elapse(const Duration(milliseconds: 500));

      final saved = c.read(activityRepositoryProvider).first;
      // 3 runs × 1 s + a trailing second = 4 s of moving time; each 1 s
      // pause between them is excluded.
      expect(saved.duration!.seconds, closeTo(4, 0.6));
    });
  });
}