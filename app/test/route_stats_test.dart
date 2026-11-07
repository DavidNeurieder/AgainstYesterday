// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
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
  required DateTime started,
}) =>
    Activity(
      id: id,
      routeId: FakeEngineService.riverLoopId,
      startedAt: started,
      duration: Elapsed.seconds(seconds),
      distance: const Distance.meters(4760),
    );

void main() {
  test('empty history falls back to the route seed', () {
    final stats = computeRouteStats(
      route: _route(pb: const Elapsed.seconds(1470)),
      attempts: const [],
    );
    expect(stats.runs, 12);
    expect(stats.pb?.seconds, 1470);
    expect(stats.average, isNull);
    expect(stats.last, isNull);
  });

  test('history wins over the seed for runs; PB stays the best time', () {
    final stats = computeRouteStats(
      route: _route(pb: const Elapsed.seconds(1470)),
      attempts: [
        _attempt(
          id: 'a1',
          seconds: 1502,
          started: DateTime.utc(2026, 1, 1),
        ),
        _attempt(
          id: 'a2',
          seconds: 1588,
          started: DateTime.utc(2026, 1, 2),
        ),
      ],
    );
    // Real attempts never shrink the route's lifetime counter.
    expect(stats.runs, 12);
    expect(stats.pb?.seconds, 1470); // seed is still the fastets ever.
    expect(stats.average?.seconds, closeTo(1545, 0.1));
    // Newest attempt is a2.
    expect(stats.last?.seconds, 1588);
  });

  test('a route with no seed counter grows with each attempt', () {
    final route = Route(
      id: 'x',
      name: 'New route',
      distance: const Distance.meters(4760),
      geometry: FakeEngineService.riverLoop,
      attemptCount: 0,
    );
    final stats = computeRouteStats(
      route: route,
      attempts: [
        _attempt(id: 'a1', seconds: 1502, started: DateTime.utc(2026, 1, 1)),
        _attempt(id: 'a2', seconds: 1588, started: DateTime.utc(2026, 1, 2)),
      ],
    );
    expect(stats.runs, 2);
    expect(stats.pb?.seconds, 1502);
  });

  test('history PB beats the seed when it is faster', () {
    final stats = computeRouteStats(
      route: _route(pb: const Elapsed.seconds(1470)),
      attempts: [
        _attempt(
          id: 'a1',
          seconds: 1455,
          started: DateTime.utc(2026, 1, 1),
        ),
      ],
    );
    expect(stats.pb?.seconds, 1455);
    expect(stats.average?.seconds, 1455);
    expect(stats.last?.seconds, 1455);
  });

  test('median and spread are computed from attempt times', () {
    final stats = computeRouteStats(
      route: Route(
        id: 'x',
        name: 'New route',
        distance: const Distance.meters(4760),
        geometry: FakeEngineService.riverLoop,
        attemptCount: 0,
      ),
      attempts: [
        _attempt(id: 'a1', seconds: 100, started: DateTime.utc(2026, 1, 1)),
        _attempt(id: 'a2', seconds: 200, started: DateTime.utc(2026, 1, 2)),
        _attempt(id: 'a3', seconds: 300, started: DateTime.utc(2026, 1, 3)),
        _attempt(id: 'a4', seconds: 400, started: DateTime.utc(2026, 1, 4)),
      ],
    );
    expect(stats.median?.seconds, closeTo(250, 0.1));
    expect(stats.fastest?.seconds, 100);
    expect(stats.slowest?.seconds, 400);
    expect(stats.range?.seconds, 300);
    expect(stats.stdDev?.seconds, closeTo(111.8, 0.2));
  });

  test('trend is negative when runs get faster', () {
    final stats = computeRouteStats(
      route: Route(
        id: 'x',
        name: 'New route',
        distance: const Distance.meters(4760),
        geometry: FakeEngineService.riverLoop,
        attemptCount: 0,
      ),
      attempts: [
        _attempt(id: 'a1', seconds: 400, started: DateTime.utc(2026, 1, 1)),
        _attempt(id: 'a2', seconds: 300, started: DateTime.utc(2026, 1, 2)),
        _attempt(id: 'a3', seconds: 200, started: DateTime.utc(2026, 1, 3)),
      ],
    );
    expect(stats.trendSecondsPerRun, isNotNull);
    expect(stats.trendSecondsPerRun!, lessThan(0));
  });
}