// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Recording controller — device-GPS mode (M15 Phase 12).
///
/// The scenario timeline stays the default for host runs; these tests wire a
/// deterministic fake [GpsSource] in through [deviceGpsProvider] and assert
/// the live run is driven by *real* fixes: position, distance, the raw-fix
/// buffer and the persisted track all reflect the receiver's own output.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clock/clock.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';
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

/// A deterministic [GpsSource]: canned fixes plus scripted acquisition.
class _FakeGpsSource implements GpsSource {
  _FakeGpsSource(this.stream, {this.acquisition});

  final Stream<GpsFix> stream;
  final String? acquisition;
  int settingsOpened = 0;

  @override
  String get description => 'test device GPS';

  @override
  Future<String?> ensureAvailable() async => acquisition;

  @override
  Stream<GpsFix> fixes() => stream;

  @override
  Future<void> openSettings() async {
    settingsOpened++;
  }
}

GpsFix _fix(double latitude, double longitude, {double? speed}) => GpsFix(
  timestamp: clock.now().toUtc(),
  latitude: latitude,
  longitude: longitude,
  accuracyMeters: 3.0,
  altitudeMeters: 55.0,
  speedMetersPerSecond: speed,
  bearingDegrees: 90.0,
);

void main() {
  ProviderSubscription<LiveRunState?> keepAlive(ProviderContainer c) {
    final sub = c.listen(recordingControllerProvider, (_, _) {});
    addTearDown(sub.close);
    return sub;
  }

  LiveRunState? state(ProviderContainer c) => c.read(recordingControllerProvider);

  void bootToReady(ProviderContainer c, FakeAsync async) {
    final ctrl = c.read(recordingControllerProvider.notifier);
    ctrl.ensureSession([_route]);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(state(c)!.status, RunStatus.ready);
  }

  group('device GPS mode', () {
    test('free-running: fixes drive distance, fixes buffer and track', () {
      fakeAsync((async) {
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(
              _FakeGpsSource(stream.stream),
            ),
            persistenceStoreProvider.overrideWithValue(
              MemoryPersistenceStore(),
            ),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        // No routes preferred -> a genuinely new line: nothing to snap to, so
        // distance accumulates from the ground travelled between fixes.
        c.read(recordingControllerProvider.notifier).ensureSession(const []);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(state(c)!.status, RunStatus.ready);

        c.read(recordingControllerProvider.notifier).beginRun();
        async.flushMicrotasks();

        const a = GeoPoint(latitude: 52.5000, longitude: 13.3700);
        const b = GeoPoint(latitude: 52.5025, longitude: 13.3700);
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(a.latitude, a.longitude));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(
          _fix(b.latitude, b.longitude, speed: 3.0),
        );
        async.flushMicrotasks();

        final live = state(c)!;
        expect(live.status, RunStatus.running);
        expect(live.distance.meters, closeTo(haversineMeters(a, b), 1e-6));
        // Only the second fix can prove motion (the first is the anchor), so
        // exactly the one 1.2 s interval counts as moving time.
        expect(live.elapsed.seconds, closeTo(1.2, 1e-9));
        expect(live.currentPosition, b);

        // The raw-fix buffer keeps the receiver's own sensor fields.
        final fixes = c
            .read(recordingControllerProvider.notifier)
            .currentFixes()!;
        expect(fixes, hasLength(2));
        expect(fixes.first.accuracyMeters, 3.0);
        expect(fixes.first.altitudeMeters, 55.0);
        expect(fixes.last.speedMetersPerSecond, 3.0);
        expect(fixes.last.bearingDegrees, 90.0);

        // The persisted track is the real fix timeline, not a geometry synth.
        final track = c
            .read(recordingControllerProvider.notifier)
            .currentTrack()!;
        expect(track, hasLength(2));
        expect(track.last.position, b);
        expect(track.last.altitudeMeters, 55.0);

        c.read(recordingControllerProvider.notifier).finishRun();
        async.flushMicrotasks();

        expect(state(c)!.status, RunStatus.completed);
        // The repo is seeded with demo history; find the run we just saved.
        final saved = c
            .read(activityRepositoryProvider)
            .firstWhere((a) => a.id.startsWith('act-'));
        expect(saved.rawFixes, hasLength(2));
        expect(saved.track, hasLength(2));
        expect(saved.track!.last.position, b);
      });
    });

    test('stationary fixes do not move the run, distance or pace', () {
      fakeAsync((async) {
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(
              _FakeGpsSource(stream.stream),
            ),
            persistenceStoreProvider.overrideWithValue(
              MemoryPersistenceStore(),
            ),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        c.read(recordingControllerProvider.notifier).ensureSession(const []);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(state(c)!.status, RunStatus.ready);

        c.read(recordingControllerProvider.notifier).beginRun();
        async.flushMicrotasks();

        // A parked phone: identical fixes that keep quiet while the receiver
        // insists on a stale cached running speed — the phantom 4:47/km pace.
        const still = GeoPoint(latitude: 52.5000, longitude: 13.3700);
        for (var i = 0; i < 3; i++) {
          async.elapse(const Duration(milliseconds: 1200));
          stream.add(_fix(still.latitude, still.longitude, speed: 3.5));
          async.flushMicrotasks();
        }

        final live = state(c)!;
        expect(live.status, RunStatus.running);
        expect(live.distance.meters, 0);
        // Moving time never starts on a still phone.
        expect(live.elapsed.seconds, 0);
        // The cached speed must not surface as a cruise pace.
        expect(live.pace.metersPerSecond, 0);
        expect(live.pace.formatPace(), '— /km');

        // The still fixes still reach the raw buffer, so the persisted track
        // keeps the receiver's full output even while standing.
        final fixes = c
            .read(recordingControllerProvider.notifier)
            .currentFixes()!;
        expect(fixes, hasLength(3));

        // A genuine step afterwards resumes the run from the last heard fix.
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(52.5003, 13.3700));
        async.flushMicrotasks();

        final moved = state(c)!;
        expect(moved.distance.meters, greaterThan(0));
        expect(moved.elapsed.seconds, greaterThan(0));
      });
    });

    test('on a recognised route, distance follows the geometry', () {
      fakeAsync((async) {
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(
              _FakeGpsSource(stream.stream),
            ),
            persistenceStoreProvider.overrideWithValue(
              MemoryPersistenceStore(),
            ),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);
        bootToReady(c, async);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.beginRun();
        async.flushMicrotasks();

        final geo = FakeEngineService.riverLoop;
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(geo[0].latitude, geo[0].longitude));
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(geo[1].latitude, geo[1].longitude));
        async.flushMicrotasks();

        final live = state(c)!;
        // Snapped onto the route: distance is the arc length to geometry[1].
        expect(
          live.distance.meters,
          closeTo(haversineMeters(geo[0], geo[1]), 1e-6),
        );
        // The emitted position is the runner's real fix, not the snapped one.
        expect(live.currentPosition, geo[1]);
        // River Loop carries a PB, so the live run races its ghost.
        expect(live.ghostGap, isNotNull);
        expect(live.routeProgress, greaterThan(0));
      });
    });

    test('paused runs ignore late fixes; resuming keeps recording', () {
      fakeAsync((async) {
        final stream = StreamController<GpsFix>.broadcast();
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(
              _FakeGpsSource(stream.stream),
            ),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);
        bootToReady(c, async);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.beginRun();
        async.flushMicrotasks();

        final geo = FakeEngineService.riverLoop;
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(geo[0].latitude, geo[0].longitude));
        async.flushMicrotasks();
        final distanceBefore = state(c)!.distance.meters;
        expect(distanceBefore, 0);

        ctrl.pause();
        async.flushMicrotasks();
        // A fix arriving while paused must not move the run.
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(geo[4].latitude, geo[4].longitude));
        async.flushMicrotasks();
        expect(state(c)!.status, RunStatus.paused);
        expect(state(c)!.distance.meters, distanceBefore);

        ctrl.resume();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1200));
        stream.add(_fix(geo[2].latitude, geo[2].longitude));
        async.flushMicrotasks();
        expect(state(c)!.status, RunStatus.running);
        expect(state(c)!.distance.meters, greaterThan(distanceBefore));
      });
    });

test('acquisition refusal lands ERROR with the GPS reason surfaced', () {
      fakeAsync((async) {
        final stream = StreamController<GpsFix>.broadcast();
        final source = _FakeGpsSource(
          stream.stream,
          acquisition: 'Location services are off. Turn on GPS, then try '
              'again.',
        );
        final c = ProviderContainer(
          overrides: [
            deviceGpsProvider.overrideWithValue(source),
          ],
        );
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));

        expect(state(c)!.status, RunStatus.error);
        // The error screen shows the GPS activation problem, not an engine
        // excuse, and offers to open the matching settings.
        expect(
          state(c)!.error?.message,
          startsWith('Location services are off.'),
        );
        expect(state(c)!.error?.gpsSettingsAction, isTrue);

        ctrl.openSettings();
        async.flushMicrotasks();
        expect(source.settingsOpened, 1);

        // M14: retry re-runs acquisition; the refusal persists.
        ctrl.retry();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(state(c)!.status, RunStatus.error);
      });
    });

    test('no device source keeps the deterministic scenario timeline', () {
      fakeAsync((async) {
        final c = ProviderContainer();
        addTearDown(c.dispose);
        keepAlive(c);

        final ctrl = c.read(recordingControllerProvider.notifier);
        ctrl.ensureSession([_route]);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(state(c)!.status, RunStatus.ready);

        ctrl.beginRun();
        async.elapse(const Duration(seconds: 3));
        final live = state(c)!;
        expect(live.status, RunStatus.running);
        expect(live.distance.meters, greaterThan(0));
        // Scenario fixes carry the demo receiver's synthetic fields.
        final fixes = ctrl.currentFixes()!;
        expect(fixes, isNotEmpty);
        expect(fixes.first.accuracyMeters, 5.0);
        expect(fixes.first.altitudeMeters, 60.0);
        expect(fixes.first.latitude, closeTo(52.5, 0.02));
      });
    });
  });
}