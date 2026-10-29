// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Personal-best classification and post-reload consistency (test plan
/// Phase 1.3).
///
/// The route statistics are a projection over two repositories, so the two
/// things worth pinning are the *tie-break* (an equally fast run must not
/// steal a PB it did not beat) and the *reload* (what survives a round trip
/// through the store codec must classify identically to what was written).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/history/application/history_grouping.dart';
import 'package:against_yesterday/features/routes/application/route_stats.dart';
import 'package:against_yesterday/persistence/serialization.dart';

const _routeId = FakeEngineService.riverLoopId;

Route _route({Elapsed? pb, int attemptCount = 12}) => Route(
  id: _routeId,
  name: 'River Loop',
  distance: const Distance.meters(4760),
  geometry: FakeEngineService.riverLoop,
  attemptCount: attemptCount,
  personalBest: pb,
);

Activity _attempt({
  required String id,
  required double seconds,
  required DateTime started,
  String? performance,
}) => Activity(
  id: id,
  routeId: _routeId,
  startedAt: started,
  duration: Elapsed.seconds(seconds),
  distance: const Distance.meters(4760),
  performance: performance,
);

void main() {
  group('tie-breaking', () {
    test('an equally fast run does not replace the standing PB', () {
      final stats = computeRouteStats(
        route: _route(pb: const Elapsed.seconds(1470)),
        attempts: [
          _attempt(id: 'equal', seconds: 1470, started: DateTime.utc(2026, 1, 1)),
        ],
      );
      // The seed already holds 1470, so a matching attempt is not an
      // improvement and the PB is unchanged.
      expect(stats.pb?.seconds, 1470);
    });

    test('history decides the PB by the fastest attempt, not the latest', () {
      final stats = computeRouteStats(
        route: _route(pb: const Elapsed.seconds(1470)),
        attempts: [
          _attempt(id: 'slow', seconds: 1600, started: DateTime.utc(2026, 1, 2)),
          _attempt(id: 'fast', seconds: 1440, started: DateTime.utc(2026, 1, 1)),
          _attempt(id: 'mid', seconds: 1500, started: DateTime.utc(2026, 1, 3)),
        ],
      );
      expect(stats.pb?.seconds, 1440);
      // `last` is chronological, not the fastest.
      expect(stats.last?.seconds, 1500);
      expect(stats.average?.seconds, closeTo((1600 + 1440 + 1500) / 3, 0.1));
    });

    test('only the first run of equal times earns the history trophy', () {
      final history = computeHistoryPb(
        [
          _attempt(id: 'first', seconds: 1450, started: DateTime.utc(2026, 1, 1)),
          _attempt(id: 'equal', seconds: 1450, started: DateTime.utc(2026, 1, 2)),
        ],
        [_route(pb: const Elapsed.seconds(1470))],
      );

      // The improver is whoever *strictly* beat the standing best: the first
      // run. The equal one comes after the best already stands at 1450.
      expect(history.pbSetters, contains('first'));
      expect(history.pbSetters, isNot(contains('equal')));
      expect(history.bestSeconds[_routeId], 1450);
    });

    test('a run that ties the previous improver is not a second trophy', () {
      final history = computeHistoryPb(
        [
          _attempt(id: 'a', seconds: 1450, started: DateTime.utc(2026, 1, 1)),
          _attempt(id: 'b', seconds: 1440, started: DateTime.utc(2026, 1, 2)),
          _attempt(id: 'c', seconds: 1440, started: DateTime.utc(2026, 1, 3)),
        ],
        [_route(pb: const Elapsed.seconds(1470))],
      );

      expect(history.pbSetters, {'a', 'b'});
      expect(history.bestSeconds[_routeId], 1440);
    });
  });

  group('round-trip consistency', () {
    test('distance, duration and performance survive the codec unchanged', () {
      final written = [
        _attempt(
          id: 'saved',
          seconds: 1432.5,
          started: DateTime.utc(2026, 2, 14, 9, 30),
          performance: 'ahead',
        ),
      ];

      final reloaded = parseActivityList(activityListToJson(written));
      expect(reloaded, hasLength(1));

      final before = computeRouteStats(route: _route(), attempts: written);
      final after = computeRouteStats(route: _route(), attempts: reloaded);

      // The classification is identical before and after the round trip — a
      // silently truncated field would show up here.
      expect(after.pb?.seconds, before.pb?.seconds);
      expect(after.average?.seconds, before.average?.seconds);
      expect(after.last?.seconds, before.last?.seconds);
      expect(after.runs, before.runs);

      // And the raw values are bit-for-bit the same.
      final reloadedAttempt = reloaded.single;
      expect(reloadedAttempt.duration!.seconds, 1432.5);
      expect(reloadedAttempt.distance!.meters, 4760);
      expect(reloadedAttempt.performance, 'ahead');
      expect(reloadedAttempt.startedAt, DateTime.utc(2026, 2, 14, 9, 30));
    });

    test('a sub-second duration keeps its fraction through the codec', () {
      // The codec stores seconds as a double; a run under one second must not
      // round to zero and vanish from the PB axis.
      final written = [
        _attempt(
          id: 'blink',
          seconds: 0.4,
          started: DateTime.utc(2026, 1, 1),
        ),
      ];

      final reloaded = parseActivityList(activityListToJson(written));
      expect(reloaded.single.duration!.seconds, closeTo(0.4, 1e-9));

      final stats = computeRouteStats(route: _route(), attempts: reloaded);
      expect(stats.pb?.seconds, closeTo(0.4, 1e-9));
    });

    test('the trophy classification is stable across the codec', () {
      final written = [
        _attempt(id: 'a', seconds: 1450, started: DateTime.utc(2026, 1, 1)),
        _attempt(id: 'b', seconds: 1440, started: DateTime.utc(2026, 1, 2)),
        _attempt(id: 'c', seconds: 1460, started: DateTime.utc(2026, 1, 3)),
      ];
      final route = _route(pb: const Elapsed.seconds(1470));

      final before = computeHistoryPb(written, [route]);
      final after = computeHistoryPb(
        parseActivityList(activityListToJson(written)),
        [route],
      );

      expect(after.pbSetters, before.pbSetters);
      expect(after.bestSeconds, before.bestSeconds);
    });
  });
}
