// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// State-machine guard tests (test plan Phases 2 and 4).
///
/// Valid transitions are exercised in `recording_controller_test.dart`; this
/// suite pins the *invalid* transitions — the plan demands that a wrong
/// action "produce a predictable outcome rather than silently corrupting the
/// run". Every guard here is expected to be a strict no-op.
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

  /// Fresh container + session advanced all the way to READY.
  RecordingController boot(ProviderContainer c, FakeAsync async) {
    final ctrl = c.read(recordingControllerProvider.notifier);
    ctrl.ensureSession([_route]);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(state(c)!.status, RunStatus.ready);
    return ctrl;
  }

  group('invalid transitions are no-ops', () {
    test('pause, resume, and finish are ignored before running', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);

        ctrl.pause();
        ctrl.resume();
        ctrl.finishRun();

        expect(state(c)!.status, RunStatus.ready);
        expect(state(c)!.distance.meters, 0);
      });
    });

    test('resume while already running leaves the run untouched', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 2));
        final before = state(c)!.distance.meters;
        expect(before, greaterThan(0));

        ctrl.resume(); // not paused -> no-op
        expect(state(c)!.status, RunStatus.running);
        async.elapse(const Duration(seconds: 1));
        expect(state(c)!.distance.meters, greaterThan(before));
      });
    });

    test('a second beginRun re-anchors but never resets the clock', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 3));

        ctrl.beginRun(); // double-press START
        async.elapse(const Duration(seconds: 1));

        expect(state(c)!.status, RunStatus.running);
        // Elapsed keeps counting from the original start.
        expect(state(c)!.elapsed.seconds, greaterThan(3));
        expect(state(c)!.elapsed.seconds, lessThan(5));
      });
    });

    test('a double-pause is inert and a single resume un-pauses', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 2));
        ctrl.pause();
        final distance = state(c)!.distance.meters;
        final elapsed = state(c)!.elapsed.seconds;

        ctrl.pause(); // no-op: already paused
        expect(state(c)!.status, RunStatus.paused);
        async.elapse(const Duration(seconds: 5));
        expect(state(c)!.distance.meters, distance);
        expect(state(c)!.elapsed.seconds, elapsed);

        ctrl.resume();
        expect(state(c)!.status, RunStatus.running);
      });
    });

    test('finish twice persists exactly one activity', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 5));

        ctrl.finishRun();
        expect(state(c)!.status, RunStatus.completed);
        async.elapse(const Duration(milliseconds: 500));
        expect(state(c)!.status, RunStatus.completed);

        final saved = c.read(activityRepositoryProvider).length;
        ctrl.finishRun(); // no-op: already completed
        async.elapse(const Duration(milliseconds: 500));

        expect(state(c)!.status, RunStatus.completed);
        expect(c.read(activityRepositoryProvider).length, saved);
      });
    });

    test('resume after completion is a no-op', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 5));
        ctrl.finishRun();
        async.elapse(const Duration(milliseconds: 500));
        expect(state(c)!.status, RunStatus.completed);

        ctrl.resume();
        expect(state(c)!.status, RunStatus.completed);
      });
    });

    test('ensureSession is idempotent while a session is active', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);

        ctrl.ensureSession([_route]); // second "new run" request
        async.flushMicrotasks();

        // Still READY — no re-acquisition, no lost session.
        expect(state(c)!.status, RunStatus.ready);
        ctrl.beginRun();
        expect(state(c)!.status, RunStatus.running);
      });
    });
  });

  group('finish from a paused run', () {
    test('finishing while paused is allowed and completes the run', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();
        async.elapse(const Duration(seconds: 2));
        ctrl.pause();
        expect(state(c)!.status, RunStatus.paused);

        ctrl.finishRun();
        expect(state(c)!.status, RunStatus.completed);
        async.elapse(const Duration(milliseconds: 500));
        expect(state(c)!.status, RunStatus.completed);
        expect(state(c)!.ghostGap, isNotNull);
      });
    });
  });

  group('GPS quality during acquisition', () {
    test('reduced while acquiring, good once ready', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();

        expect(state(c)!.status, RunStatus.preparing);

        async.elapse(const Duration(milliseconds: 500));
        expect(state(c)!.status, RunStatus.gpsAcquiring);
        expect(state(c)!.gpsQuality, 'reduced');

        async.elapse(const Duration(milliseconds: 500));
        expect(state(c)!.status, RunStatus.ready);
        expect(state(c)!.gpsQuality, 'good');

        ctrl.beginRun();
        async.elapse(const Duration(seconds: 2));
        expect(state(c)!.status, RunStatus.running);
        expect(state(c)!.gpsQuality, 'good');
        // The demo runner tracks the geometry exactly, so §18 never fires.
        expect(state(c)!.offRoute, isNull);
      });
    });
  });

  group('loop seam — distance invariants', () {
    test('distance never exceeds or decreases below the loop length', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        final ctrl = boot(c, async);
        ctrl.beginRun();

        final loop = polylineMeters(FakeEngineService.riverLoop);

        // Run more than one full loop.
        async.elapse(const Duration(seconds: 5000));
        expect(state(c)!.distance.meters, closeTo(loop, 0.5));
        expect(state(c)!.routeProgress, lessThanOrEqualTo(1.0));

        // Further running neither grows past the loop nor shrinks.
        var previous = state(c)!.distance.meters;
        for (var i = 0; i < 10; i++) {
          async.elapse(const Duration(seconds: 5));
          final current = state(c)!.distance.meters;
          expect(current, greaterThanOrEqualTo(previous));
          expect(current, lessThanOrEqualTo(loop + 1e-9));
          previous = current;
        }
        expect(state(c)!.routeProgress, closeTo(1.0, 0.001));
      });
    });

    test('distance is zero before any movement', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);
        boot(c, async);
        expect(state(c)!.distance.meters, 0);
        expect(state(c)!.elapsed.seconds, 0);
      });
    });
  });
}