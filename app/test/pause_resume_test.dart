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

  test('resuming after several pauses never duplicates the track', () {
    fakeAsync((async) {
      final c = container(async);
      final ctrl = c.read(recordingControllerProvider.notifier);

      // Pause/resume is documented to *close* a track and open a fresh one on
      // resume (the free-run reset). Whatever the internals, the sealed
      // activity must carry each second of movement exactly once: the track
      // length has to match the moving time, not the wall-clock span.
      ctrl.beginRun();
      var runningSeconds = 0;
      for (var i = 0; i < 4; i++) {
        async.elapse(const Duration(seconds: 1));
        runningSeconds++;
        final running = state(c)!;
        // Movement was recorded while running.
        expect(running.distance.meters, greaterThan(0));
        expect(running.status, RunStatus.running);

        ctrl.pause();
        final frozen = state(c)!.distance.meters;

        // A long pause holds the distance exactly where the pause left it —
        // no sample is appended, no segment is reopened.
        async.elapse(const Duration(seconds: 5));
        expect(state(c)!.distance.meters, frozen);
        expect(state(c)!.status, RunStatus.paused);

        // The first tick after a resume must move on from the frozen point,
        // never re-add the metre the pause froze on.
        ctrl.resume();
        async.elapse(const Duration(seconds: 1));
        runningSeconds++;
        expect(state(c)!.distance.meters, greaterThan(frozen));
      }
      ctrl.finishRun();
      async.elapse(const Duration(milliseconds: 500));

      final saved = c.read(activityRepositoryProvider).first;
      // Eight 1 s running stretches, with every 5 s pause excluded.
      expect(saved.duration!.seconds, closeTo(runningSeconds, 0.6));

      final track = saved.track!;
      // The decisive check: the saved track holds roughly one sample per
      // moving second — a duplicated resume segment would leave many more.
      expect(track.length, lessThanOrEqualTo(runningSeconds + 3));
      expect(track.length, greaterThanOrEqualTo(2));

      // And no two consecutive samples may repeat the same position *and*
      // timestamp: a duplicated resume would leave exactly that pair.
      for (var i = 1; i < track.length; i++) {
        final prev = track[i - 1];
        final next = track[i];
        final samePoint =
            prev.position.latitude == next.position.latitude &&
            prev.position.longitude == next.position.longitude;
        final sameStamp = prev.timestamp == next.timestamp;
        expect(samePoint && sameStamp, isFalse,
            reason: 'track has a duplicated sample at index $i');
      }
    });
  });
}