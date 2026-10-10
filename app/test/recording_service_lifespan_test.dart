// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The Android recording foreground service tracks the device GPS stream.
///
/// Screen-off recording only works if the platform keeps delivering fixes to
/// a backgrounded app, which on Android 12+ requires a foreground location
/// service. These tests drive the recording controller with a fake
/// [GpsSource] and a recording fake of [RunForegroundLifespan], and assert
/// the service is elevated exactly when the receiver streams and dropped when
/// it stops. Scenario runs (no device source) never touch the platform
/// channel at all.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
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

/// Records each elevation/drop the controller asks for.
class _RecordingLifespan implements RunForegroundLifespan {
  int started = 0;
  int stopped = 0;

  @override
  Future<void> start() async => started++;

  @override
  Future<void> stop() async => stopped++;
}

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  void bootToReady(ProviderContainer c, FakeAsync async) {
    c.read(recordingControllerProvider.notifier).ensureSession([_route]);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(c.read(recordingControllerProvider)!.status, RunStatus.ready);
  }

  group('recording foreground service lifespan', () {
    test('elevated while the device stream is up, dropped when it stops',
        () {
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
        // Idle and ready: the service is not up yet.
        expect(lifespan.started, 0);
        expect(lifespan.stopped, 0);

        // START elevates the process for the whole streaming window.
        bootToReady(c, async);
        ctrl.beginRun();
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(lifespan.stopped, 0);

        // Pausing cancels the stream, so the elevation drops with it.
        ctrl.pause();
        async.flushMicrotasks();
        expect(lifespan.started, 1);
        expect(lifespan.stopped, 1);

        // RESUME starts a fresh stream; idempotent start stays at one call.
        ctrl.resume();
        async.flushMicrotasks();
        expect(lifespan.started, 2);
        expect(lifespan.stopped, 1);

        // FINISH seals the run and drops the elevation for good.
        ctrl.finishRun();
        async.flushMicrotasks();
        expect(lifespan.started, 2);
        expect(lifespan.stopped, 2);
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
      });
    });
  });
}