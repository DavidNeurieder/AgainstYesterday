// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// GPS recovery around a mid-run receiver loss (test plan Phase 2.2).
///
/// The deterministic counterpart to the on-device feed: a scripted [GpsSource]
/// pushes real-shaped fixes into the *device* recording path, so the exact
/// distance arithmetic is pinned without an emulator. The sequence under test
/// is the one the plan names — valid fixes, a temporary loss, no phantom
/// distance while the gap is open, then a restored feed that must not double
/// count the ground it already recorded.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

/// A source whose fix stream is driven by hand, so a loss can be modelled as a
/// gap (no emissions) or as a hard stream error — both shapes a real receiver
/// produces when it drops out.
class _ManualGpsSource implements GpsSource {
  _ManualGpsSource();

  final _controller = StreamController<GpsFix>.broadcast();

  /// `null` accepts acquisition.
  String? acquisition;

  /// How many times [ensureAvailable] was entered — the acquisition gate ticks
  /// every 500 ms, so a request that is still awaiting the user's answer must
  /// not be re-entered on each tick.
  int acquisitionCalls = 0;

  /// When non-null, [ensureAvailable] waits on this instead of returning:
  /// stands in for Android's permission dialog, which only settles once the
  /// user answers it.
  Completer<String?>? pendingAcquisition;

  @override
  String get description => 'manual test GPS';

  @override
  Future<String?> ensureAvailable() {
    acquisitionCalls++;
    final pending = pendingAcquisition;
    if (pending != null) {
      return pending.future;
    }
    return Future<String?>.value(acquisition);
  }

  @override
  Future<bool> canAskPermission() async => false;

  @override
  Stream<GpsFix> fixes() => _controller.stream;

  @override
  Future<void> openSettings() async {}

  void emit(GpsFix fix) => _controller.add(fix);

  /// Simulates the receiver dropping out: the platform channel surfaces an
  /// error. The recording must survive it.
  void fail(Object error) => _controller.addError(error);

  Future<void> close() => _controller.close();
}

/// A fix at [lat]/[lon] timestamped by the fake clock.
GpsFix _fix(double lat, double lon) => GpsFix(
  timestamp: clock.now().toUtc(),
  latitude: lat,
  longitude: lon,
);

/// ~1.11 m per 0.00001° of latitude; a running stride is ~3 m/s, so
/// 0.000027° lands a realistic step that clears the 0.5 m/s motion floor.
const double _stepDegrees = 0.000027;

void main() {
  ({ProviderContainer container, _ManualGpsSource source}) harness() {
    final source = _ManualGpsSource();
    final container = ProviderContainer(
      overrides: [
        deviceGpsProvider.overrideWithValue(source),
        persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
      ],
    );
    final sub = container.listen(recordingControllerProvider, (_, _) {});
    addTearDown(() async {
      await source.close();
      sub.close();
      container.dispose();
    });
    return (container: container, source: source);
  }

  LiveRunState live(ProviderContainer c) =>
      c.read(recordingControllerProvider)!;

  RecordingController controller(ProviderContainer c) =>
      c.read(recordingControllerProvider.notifier);

  test('a lost feed freezes distance; a restored feed continues, not repeats',
      () {
    fakeAsync((async) {
      final h = harness();
      final ctrl = controller(h.container);
      ctrl.ensureSession(const []);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      expect(live(h.container).status, RunStatus.ready);

      ctrl.beginRun();
      async.flushMicrotasks();

      // 1. Valid fixes: five ~1.1 m strides north.
      var lat = 52.50000;
      for (var i = 0; i < 5; i++) {
        async.elapse(const Duration(seconds: 1));
        lat += _stepDegrees;
        h.source.emit(_fix(lat, 13.40000));
        async.flushMicrotasks();
      }
      final afterValid = live(h.container);
      expect(afterValid.distance.meters, greaterThan(4));
      final distanceAtLoss = afterValid.distance.meters;
      final movingAtLoss = afterValid.elapsed.seconds;
      expect(movingAtLoss, greaterThan(3));

      // 2. Temporary loss of location updates: the receiver goes quiet for a
      // long stretch. Nothing may accrue while the gap is open — no distance,
      // no moving time — but the wall clock keeps running.
      async.elapse(const Duration(seconds: 30));
      final duringLoss = live(h.container);
      expect(duringLoss.status, RunStatus.running);
      expect(duringLoss.distance.meters, distanceAtLoss,
          reason: 'distance must not grow while no fixes arrive');
      expect(duringLoss.elapsed.seconds, closeTo(movingAtLoss, 0.6),
          reason: 'moving time must not grow while no fixes arrive');
      expect(duringLoss.clockElapsed.seconds, greaterThan(movingAtLoss + 25),
          reason: 'the wall-clock stopwatch must keep counting');

      // 3. Restored feed. The first fix after a long gap spans the outage, so
      // its implied speed is negligible and the segment earns nothing — the
      // app must NOT bridge the gap. Two quick fixes then re-establish real
      // 1 Hz motion, and only the second stride is counted.
      async.elapse(const Duration(seconds: 1));
      lat += _stepDegrees;
      h.source.emit(_fix(lat, 13.40000));
      async.flushMicrotasks();

      final afterFirstFix = live(h.container);
      expect(afterFirstFix.distance.meters, distanceAtLoss,
          reason: 'a fix across the outage must not bridge it');

      // The next fix arrives one second later: now the pair implies real
      // running speed, so the stride lands — measured from the restored
      // anchor, never re-counting the ground before the outage.
      async.elapse(const Duration(seconds: 1));
      lat += _stepDegrees;
      h.source.emit(_fix(lat, 13.40000));
      async.flushMicrotasks();

      final afterRecovery = live(h.container);
      expect(afterRecovery.distance.meters, greaterThan(distanceAtLoss),
          reason: 'the restored feed must resume recording');
      // Exactly one more stride (~3 m) past the frozen distance.
      expect(afterRecovery.distance.meters - distanceAtLoss, closeTo(3, 0.5));
      expect(afterRecovery.elapsed.seconds, closeTo(movingAtLoss + 1, 0.6));
    });
  });

  test('a receiver stream error leaves a well-defined, live recording', () {
    fakeAsync((async) {
      final h = harness();
      final ctrl = controller(h.container);
      ctrl.ensureSession(const []);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.flushMicrotasks();

      var lat = 52.50000;
      for (var i = 0; i < 3; i++) {
        async.elapse(const Duration(seconds: 1));
        lat += _stepDegrees;
        h.source.emit(_fix(lat, 13.40000));
        async.flushMicrotasks();
      }
      final before = live(h.container);
      expect(before.distance.meters, greaterThan(2));

      // The platform channel throws (dongle unplugged, service flipped off).
      h.source.fail(StateError('receiver gone'));
      async.elapse(const Duration(seconds: 2));

      final after = live(h.container);
      // Well-defined: still running, previously recorded ground intact, no
      // crash, no bogus error screen.
      expect(after.status, RunStatus.running);
      expect(after.error, isNull);
      expect(after.distance.meters, before.distance.meters,
          reason: 'an error must not discard recorded distance');

      // The raw fixes already received are not thrown away either.
      final fixes = ctrl.currentFixes()!;
      expect(fixes, hasLength(3));

      // And the run can still be finished cleanly after the error.
      ctrl.finishRun();
      async.flushMicrotasks();
      expect(live(h.container).status, RunStatus.completed);
      final saved = h.container.read(activityRepositoryProvider).first;
      expect(saved.distance!.meters, closeTo(before.distance.meters, 0.6));
    });
  });

  test('an error before any fix still allows a clean finish at zero ground',
      () {
    fakeAsync((async) {
      final h = harness();
      final ctrl = controller(h.container);
      ctrl.ensureSession(const []);
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 1000));
      ctrl.beginRun();
      async.flushMicrotasks();

      h.source.fail(StateError('receiver never opened'));
      async.elapse(const Duration(seconds: 2));

      final live0 = live(h.container);
      expect(live0.status, RunStatus.running);
      expect(live0.distance.meters, 0);

      ctrl.finishRun();
      async.flushMicrotasks();
      expect(live(h.container).status, RunStatus.completed);
      final saved = h.container.read(activityRepositoryProvider).first;
      expect(saved.distance!.meters, 0);
    });
  });

  test('an unanswered permission request is not re-issued on every tick', () {
    fakeAsync((async) {
      final h = harness();
      final ctrl = controller(h.container);

      // Android's dialog is open: the request is outstanding until the user
      // answers, which the test models with a completer it controls.
      h.source.pendingAcquisition = Completer<String?>();
      ctrl.ensureSession(const []);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(live(h.container).status, RunStatus.gpsAcquiring);
      expect(h.source.acquisitionCalls, 1);

      // The gate keeps ticking while the dialog is up. Each tick must NOT
      // start another request: on Android that re-shows the dialog forever and
      // collides with "can request only one set of permissions at a time".
      async.elapse(const Duration(seconds: 10));
      expect(h.source.acquisitionCalls, 1,
          reason: 'the acquisition gate must not stack permission requests');
      expect(live(h.container).status, RunStatus.gpsAcquiring);

      // The user finally answers: the outstanding request resolves to a
      // denial and the one request already made surfaces the error screen.
      h.source.pendingAcquisition!.complete('Location permission is denied.');
      async.flushMicrotasks();
      expect(h.source.acquisitionCalls, 1);
      expect(live(h.container).status, RunStatus.error);
      expect(live(h.container).error!.gpsSettingsAction, isTrue);

      // And a genuine RETRY is allowed to ask again (the gate re-enters with
      // no request in flight).
      h.source.pendingAcquisition = null;
      h.source.acquisition = null;
      ctrl.retry();
      async.elapse(const Duration(milliseconds: 700));
      async.elapse(const Duration(milliseconds: 700));
      expect(h.source.acquisitionCalls, 2);
      expect(live(h.container).status, RunStatus.ready);
    });
  });
}
