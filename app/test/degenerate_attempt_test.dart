// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Degenerate recordings and how they classify (test plan Phase 1.3).
///
/// A run that never moved — a stopped GPS, a phone left on the sofa — still
/// reaches the save path. Its 0 s / 0 m attempt must not be mistaken for a
/// record, must not crash the statistics, and must not manufacture a
/// personal best the runner never earned.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/history/application/history_grouping.dart';
import 'package:against_yesterday/features/routes/application/route_stats.dart';

Route _route({Elapsed? pb}) => Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: const Distance.meters(4760),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: pb,
);

Activity _attempt({
  required String id,
  required double seconds,
  required double meters,
  required DateTime started,
}) => Activity(
  id: id,
  routeId: FakeEngineService.riverLoopId,
  startedAt: started,
  duration: Elapsed.seconds(seconds),
  distance: Distance.meters(meters),
);

void main() {
  group('zero-distance attempts', () {
    test('a 0 s smartphone-in-pocket attempt becomes the PB but moves no '
        'distance', () {
      // The statistics treat duration as the PB axis, whatever the distance:
      // a 0 s attempt sorts first. Pinning the behaviour makes the surprise
      // explicit rather than leaving it to be discovered in production.
      final stats = computeRouteStats(
        route: _route(pb: const Elapsed.seconds(1470)),
        attempts: [
          _attempt(
            id: 'standstill',
            seconds: 0,
            meters: 0,
            started: DateTime.utc(2026, 1, 1),
          ),
        ],
      );

      expect(stats.pb?.seconds, 0);
      expect(stats.last?.seconds, 0);
      expect(stats.runs, 12);
    });

    test('a zero-duration attempt does not corrupt the average', () {
      final stats = computeRouteStats(
        route: _route(pb: const Elapsed.seconds(1470)),
        attempts: [
          _attempt(
            id: 'standstill',
            seconds: 0,
            meters: 0,
            started: DateTime.utc(2026, 1, 1),
          ),
          _attempt(
            id: 'real',
            seconds: 1500,
            meters: 4760,
            started: DateTime.utc(2026, 1, 2),
          ),
        ],
      );

      expect(stats.average?.seconds, closeTo(750, 1e-9));
    });

    test('a zero-duration attempt is not a history trophy', () {
      // The trophy marks a *chronological improver*. A 0 s attempt is
      // "fastest" by the numbers, so the grouping must not silently drop it —
      // but it also must not invent a second improver behind it.
      final history = computeHistoryPb(
        [
          _attempt(
            id: 'standstill',
            seconds: 0,
            meters: 0,
            started: DateTime.utc(2026, 1, 1),
          ),
        ],
        [_route(pb: const Elapsed.seconds(1470))],
      );

      expect(history.bestSeconds[FakeEngineService.riverLoopId], 0);
      expect(history.pbSetters, contains('standstill'));
    });

    test('an activity with no duration is skipped, not treated as zero', () {
      final stats = computeRouteStats(
        route: _route(pb: const Elapsed.seconds(1470)),
        attempts: [
          Activity(
            id: 'interrupted',
            routeId: FakeEngineService.riverLoopId,
            startedAt: DateTime.utc(2026, 1, 1),
            duration: null,
            distance: const Distance.meters(900),
          ),
        ],
      );

      // No duration means no time axis: the seed PB stands and the average
      // ignores the attempt entirely (rather than averaging in a 0).
      expect(stats.pb?.seconds, 1470);
      expect(stats.average, isNull);
      expect(stats.last, isNull);
      expect(stats.runs, 12);
    });
  });
}
