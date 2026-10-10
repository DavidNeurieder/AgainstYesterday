// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The Android recording foreground service tracks the device GPS stream.
///
/// Screen-off recording only works if the platform keeps delivering fixes to
/// a backgrounded app, which on Android 12+ requires a foreground location
/// service. These tests drive the recording controller with a fake
/// [GpsSource] and a recording fake of [RunForegroundLifespan], and assert:
///
///  * the service is elevated exactly when the receiver streams and dropped
///    when it stops (start → pause → resume → finish);
///  * a failed startup is surfaced as [BackgroundProtection.unavailable] and
///    never leaves a false active state, while the run itself keeps working
///    (screen-on recording does not need the service);
///  * a finish while startup is still pending leaves no orphaned service;
///  * repeated stop and disposal are idempotent;
///  * scenario runs (no device source) never touch the platform channel.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/features/recording/application/run_foreground_lifespan.dart';
import 'package:against_yesterday/persistence/persistence.dart';

const _route = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

/// A deterministic [GpsSource]: canned fixes on demand.
class _FakeGpsSource implements GpsSource {
  _FakeGpsSource(this.stream);

  final Stream<GpsFix> stream;

  @override
  String get description => 'test device GPS';

  @override
  Future<String?> ensureAvailable() async => null;

  @override
  Stream<GpsFix> fixes() => stream;

  @override
  Future<void> openSettings() async {}
}

/// Records each elevation/drop the controller asks for, and can script a
/// startup failure or hold a start pending through [gate].
class _RecordingLifespan implements RunForegroundLifespan {
  int started = 0;
  int stopped = 0;

  /// When set, every start fails with this reason.
  ForegroundStartFailure? failure;

  /// When set, a start does not settle until the test completes [gate].
  Completer<ForegroundStartFailure?>? gate;

  @override
  Future<ForegroundStartFailure?> start() {
    started++;
    final pending = gate;
    if (pending != null) {
      return pending.future;
    }
    return Future.value(failure);
  }

  @override
  Future<void> stop() async => stopped++;
}

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) => c.read(recordingControllerProvider);

  void bootToReady(ProviderContainer c, FakeAsync async,
      {List<Route> routes = const [_route]}) {
    c.read(recordingControllerProvider.notifier).ensureSession(routes);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(state(c)!.status, RunStatus.ready);
  }

  group('recording foreground service lifespan', () {
    test('elevated while the device stream is up, dropped when it stops', () {
      fakeAsync((async) {
        final lifespan = _RecordingLifespan();
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(_FakeGpsSource(stream.stream)),
            runForegroundLifespanProvider.overrideWithValue(lifespan),
            persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        // No session yet: nothing is up, and there is no state to consult.
        expect(lifespan.started, 0);
        expect(lifespan.stopped, 0);

        // START elevates the process for the whole streaming window.
        bootToReady(c, async);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );
        ctrl.beginRun();
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(lifespan.stopped, 0);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.active,
        );

        // Pausing cancels the stream, so the elevation drops with it.
        ctrl.pause();
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(lifespan.stopped, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );

        // RESUME starts a fresh stream; idempotent start stays at one call.
        ctrl.resume();
        async.flushMicrotasks();
        expect(lifespan.started, 2);
        expect(lifespan.stopped, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.active,
        );

        // FINISH seals the run and drops the elevation for good.
        ctrl.finishRun();
        async.flushMicrotasks();
        expect(lifespan.started, 2);
        expect(lifespan.stopped, 2);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );
      });
    });

    test('startup failure is surfaced, not silently assumed', () {
      fakeAsync((async) {
        final lifespan = _RecordingLifespan()
          ..failure = ForegroundStartFailure.notAllowed;
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(_FakeGpsSource(stream.stream)),
            runForegroundLifespanProvider.overrideWithValue(lifespan),
            persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        // No route: fixes accumulate plain ground distance, proving the run
        // keeps recording even though protection failed.
        bootToReady(c, async, routes: const []);
        ctrl.beginRun();
        async.flushMicrotasks();

        // No false protection: the state says unavailable.
        expect(lifespan.started, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.unavailable,
        );

        // And the run itself keeps recording — GNSS with the screen on does
        // not need the service — so fixes still advance distance.
        const a = GeoPoint(latitude: 52.5000, longitude: 13.3700);
        const b = GeoPoint(latitude: 52.5025, longitude: 13.3700);
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(
          GpsFix(
            timestamp: clock.now().toUtc(),
            latitude: a.latitude,
            longitude: a.longitude,
            accuracyMeters: 3.0,
            speedMetersPerSecond: 3.0,
          ),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(
          GpsFix(
            timestamp: clock.now().toUtc(),
            latitude: b.latitude,
            longitude: b.longitude,
            accuracyMeters: 3.0,
            speedMetersPerSecond: 3.0,
          ),
        );
        async.flushMicrotasks();

        final live = state(c)!;
        expect(live.status, RunStatus.running);
        expect(
          live.distance.meters,
          closeTo(haversineMeters(a, b), 1e-6),
        );
        expect(
          live.backgroundProtection,
          BackgroundProtection.unavailable,
        );
      });
    });

    test('finish while startup is pending leaves no orphaned service', () {
      fakeAsync((async) {
        final lifespan = _RecordingLifespan();
        final gate = Completer<ForegroundStartFailure?>();
        lifespan.gate = gate;
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(_FakeGpsSource(stream.stream)),
            runForegroundLifespanProvider.overrideWithValue(lifespan),
            persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        bootToReady(c, async);
        ctrl.beginRun();
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.starting,
        );

        // The run finishes while the platform call is still in flight.
        ctrl.finishRun();
        async.flushMicrotasks();
        expect(lifespan.stopped, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );

        // The late start settles *after* the stop: it must not resurrect
        // protection for a finished run, and no extra stop is requested.
        gate.complete(null);
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(lifespan.stopped, 1);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );
      });
    });

    test('repeated stop and disposal are idempotent', () {
      fakeAsync((async) {
        final lifespan = _RecordingLifespan();
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(_FakeGpsSource(stream.stream)),
            runForegroundLifespanProvider.overrideWithValue(lifespan),
            persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        bootToReady(c, async);
        ctrl.beginRun();
        async.flushMicrotasks();
        expect(lifespan.started, 1);

        // Pausing twice is a no-op the second time, so exactly one stop —
        // idempotency means a repeated stop is *not* a second request.
        ctrl.pause();
        ctrl.pause();
        async.flushMicrotasks();
        expect(lifespan.stopped, 1);

        // Finishing again after PAUSE (no resumed stream to stop) must not
        // issue a second stop either; the teardown dispose is a no-op too.
        ctrl.finishRun();
        ctrl.finishRun();
        async.flushMicrotasks();
        expect(lifespan.stopped, 1);
        expect(lifespan.started, 1);
      });
    });

    test('scenario runs never touch the platform channel', () {
      fakeAsync((async) {
        final lifespan = _RecordingLifespan();
        final c = ProviderContainer(
          overrides: [
            runForegroundLifespanProvider.overrideWithValue(lifespan),
            persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        bootToReady(c, async);
        ctrl.beginRun();
        async.flushMicrotasks();
        ctrl.finishRun();
        async.flushMicrotasks();

        expect(lifespan.started, 0);
        expect(lifespan.stopped, 0);
        expect(
          state(c)!.backgroundProtection,
          BackgroundProtection.inactive,
        );
      });
    });
  });
}