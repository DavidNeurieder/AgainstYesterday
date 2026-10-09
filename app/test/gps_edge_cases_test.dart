// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Device-GPS edge cases (test plan Phase 1).
///
/// The fixtures live in `gps_fixtures.dart`; this suite drives them through
/// the real recording controller in device mode and pins the behaviors the
/// plan calls out: no distance from a still phone, no phantom jump across an
/// outage or a date line, poor accuracy flagged but still recorded, and a
/// missing sensor field handled rather than crashing. Expected distances come
/// from the fixture (independently computed), never from the production
/// geometry helper.
library;

import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'gps_fixtures.dart';

/// A straight two-point route used to exercise the on-route / off-route axis.
const _line = [
  GeoPoint(latitude: 52.5000, longitude: 13.4000),
  GeoPoint(latitude: 52.5100, longitude: 13.4000),
];

final _lineRoute = Route(
  id: 'test-line',
  name: 'Test Line',
  distance: Distance.meters(1111.95),
  geometry: _line,
);

void main() {
  ({ProviderContainer container, ScriptedGpsSource source}) harness({
    String? acquisition,
  }) {
    final source = ScriptedGpsSource(acquisition: acquisition);
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

  LiveRunState live(ProviderContainer c) => c.read(recordingControllerProvider)!;

  RecordingController controller(ProviderContainer c) =>
      c.read(recordingControllerProvider.notifier);

  /// Boots to READY with [routes] preferred, then starts the run.
  void bootAndStart(
    ProviderContainer c,
    FakeAsync async, {
    List<Route> routes = const [],
  }) {
    controller(c).ensureSession(routes);
    async.flushMicrotasks();
    async.elapse(const Duration(milliseconds: 1000));
    expect(live(c).status, RunStatus.ready);
    controller(c).beginRun();
    async.flushMicrotasks();
    expect(live(c).status, RunStatus.running);
  }

  /// Replays one fixture and leaves the run running.
  void record(
    ({ProviderContainer container, ScriptedGpsSource source}) h,
    FakeAsync async,
    GpsScenario scenario, {
    List<Route> routes = const [],
  }) {
    bootAndStart(h.container, async, routes: routes);
    h.source.replay(async, scenario);
  }

  group('distance edge cases', () {
    test('a still phone adds no distance or moving time', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, stationary);
        final s = live(h.container);
        expect(s.distance.meters, 0);
        expect(s.elapsed.seconds, 0);
        // ...but the wall-clock stopwatch is alive regardless.
        expect(s.clockElapsed.seconds, greaterThan(0));
      });
    });

    test('sub-meter jitter stays below the motion floor', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, noisyStationary);
        expect(live(h.container).distance.meters, 0);
        expect(live(h.container).elapsed.seconds, 0);
      });
    });

    test('a duplicate coordinate adds nothing', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, duplicateFixes);
        expect(live(h.container).distance.meters, 0);
      });
    });

    test('a duplicate timestamp cannot prove motion', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, duplicateTimestamps);
        expect(live(h.container).distance.meters, 0);
      });
    });

    test('a straight walk accumulates its independently-known length', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, straightWalk);
        final s = live(h.container);
        expect(
          s.distance.meters,
          closeTo(straightWalk.expectedDistanceMeters!, 1.0),
        );
        // Four moving intervals of ten seconds each.
        expect(
          s.elapsed.seconds,
          closeTo(straightWalk.expectedAcceptedFixes! * 10, 1e-6),
        );
      });
    });

    test('a multi-segment walk sums meridional and zonal legs', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, multiSegment);
        expect(
          live(h.container).distance.meters,
          closeTo(multiSegment.expectedDistanceMeters!, 1.0),
        );
      });
    });

    test('a long straight session does not drift', () {
      fakeAsync((async) {
        final h = harness();
        final scenario = longSession();
        record(h, async, scenario);
        expect(
          live(h.container).distance.meters,
          closeTo(scenario.expectedDistanceMeters!, 1.0),
        );
      });
    });
  });

  group('outages and stale data', () {
    test('a GPS outage adds no movement until fixes resume', () {
      fakeAsync((async) {
        final h = harness();
        bootAndStart(h.container, async);

        final samples = gpsOutage.samples;
        async.elapse(samples[0].after);
        h.source.emit(samples[0].toFix(clock.now()));
        async.flushMicrotasks();
        async.elapse(samples[1].after);
        h.source.emit(samples[1].toFix(clock.now()));
        async.flushMicrotasks();

        final frozen = live(h.container).distance.meters;
        expect(frozen, greaterThan(0));

        // Thirty seconds with no fix at all: nothing may move the run.
        async.elapse(const Duration(seconds: 30));
        expect(live(h.container).distance.meters, frozen);

        // The first fix after the hole resumes movement from the last heard
        // position; the run does not fabricate the gap.
        h.source.emit(samples[2].toFix(clock.now()));
        async.flushMicrotasks();
        expect(live(h.container).distance.meters, greaterThan(frozen));

        final resumed = live(h.container).distance.meters;
        async.elapse(samples[3].after);
        h.source.emit(samples[3].toFix(clock.now()));
        async.flushMicrotasks();
        expect(live(h.container).distance.meters, greaterThan(resumed));
      });
    });

    test('a stale cached initial fix is not read as movement', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, staleInitialFix);
        final s = live(h.container);
        // The first two fixes (one stale, one repeated at the start line)
        // cannot prove motion; only the third, fresh fix moves the run.
        expect(s.distance.meters, greaterThan(0));
        expect(s.distance.meters, closeTo(111.19, 1.0));
      });
    });
  });

  group('GPS quality and missing fields', () {
    test('poor accuracy is flagged while the movement still counts', () {
      fakeAsync((async) {
        final h = harness();
        record(h, async, poorAccuracy);
        final s = live(h.container);
        expect(
          s.distance.meters,
          closeTo(poorAccuracy.expectedDistanceMeters!, 1.0),
        );
        expect(s.gpsQuality, 'poor');
      });
    });

    test('missing accuracy/speed/altitude are handled, not crashed', () {
      fakeAsync((async) {
        final h = harness();
        const scenario = GpsScenario(
          name: 'missing_fields',
          samples: [
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 52.5000, longitude: 13.4000),
              speedMetersPerSecond: null,
              accuracyMeters: null,
              altitudeMeters: null,
            ),
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 52.5010, longitude: 13.4000),
              speedMetersPerSecond: null,
              accuracyMeters: null,
              altitudeMeters: null,
            ),
          ],
        );
        record(h, async, scenario);
        final s = live(h.container);
        expect(s.distance.meters, greaterThan(0));
        // A missing accuracy counts as good (§17).
        expect(s.gpsQuality, 'good');
        final last = controller(h.container).currentFixes()!.last;
        expect(last.accuracyMeters, isNull);
        expect(last.altitudeMeters, isNull);
        expect(last.speedMetersPerSecond, isNull);
      });
    });
  });

  group('projection edge cases', () {
    test('a walk at high latitude keeps its true zonal length', () {
      fakeAsync((async) {
        final h = harness();
        const scenario = GpsScenario(
          name: 'high_latitude',
          samples: [
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 80.0000, longitude: 0.0000),
            ),
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 80.0000, longitude: 0.0100),
            ),
          ],
        );
        const earthRadiusM = 6371000.0;
        final expected = earthRadiusM *
            math.cos(80 * math.pi / 180.0) *
            (0.01 * math.pi / 180.0);
        record(h, async, scenario);
        expect(live(h.container).distance.meters, closeTo(expected, 2.0));
      });
    });

    test('crossing the date line does not fabricate a planet-sized jump', () {
      fakeAsync((async) {
        final h = harness();
        const scenario = GpsScenario(
          name: 'antimeridian',
          samples: [
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 0.0, longitude: 179.9990),
            ),
            GpsSample(
              after: Duration(seconds: 10),
              position: GeoPoint(latitude: 0.0, longitude: -179.9990),
            ),
          ],
        );
        record(h, async, scenario);
        final meters = live(h.container).distance.meters;
        expect(meters, greaterThan(100));
        expect(meters, lessThan(1000));
      });
    });

    test('leaving the route raises the off-route signal', () {
      fakeAsync((async) {
        final h = harness();
        const scenario = GpsScenario(
          name: 'route_deviation',
          samples: [
            GpsSample(after: Duration(seconds: 10), position: _line0),
            GpsSample(after: Duration(seconds: 10), position: _line1),
            GpsSample(after: Duration(seconds: 10), position: _offLine),
          ],
        );
        record(h, async, scenario, routes: [_lineRoute]);

        expect(live(h.container).route, _lineRoute);
        // A lateral step (~54 m east of the line) trips the 30 m signal.
        final off = live(h.container).offRoute;
        expect(off, isNotNull);
        expect(off!.meters, greaterThan(30));
      });
    });
  });

  group('run lifecycle edges', () {
    test('rapid start/pause/resume/finish persists exactly one run', () {
      fakeAsync((async) {
        final h = harness();
        final ctrl = controller(h.container);
        ctrl.ensureSession(const []);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1000));
        expect(live(h.container).status, RunStatus.ready);

        // Double START, double PAUSE: the redundant calls are inert.
        ctrl.beginRun();
        ctrl.beginRun();
        async.flushMicrotasks();
        expect(live(h.container).status, RunStatus.running);

        ctrl.pause();
        ctrl.pause();
        async.flushMicrotasks();
        expect(live(h.container).status, RunStatus.paused);

        ctrl.resume();
        async.flushMicrotasks();
        h.source.replay(async, straightWalk);
        expect(live(h.container).distance.meters, greaterThan(0));

        final before = h.container.read(activityRepositoryProvider).length;
        ctrl.finishRun();
        async.flushMicrotasks();
        expect(live(h.container).status, RunStatus.completed);
        expect(
          h.container.read(activityRepositoryProvider).length,
          before + 1,
        );
      });
    });
  });
}

const _line0 = GeoPoint(latitude: 52.5000, longitude: 13.4000);
const _line1 = GeoPoint(latitude: 52.5030, longitude: 13.4000);
const _offLine = GeoPoint(latitude: 52.5035, longitude: 13.4008);
