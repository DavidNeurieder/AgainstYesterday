// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared fixtures and seeding helpers for the hermetic app suites.
///
/// The app starts with an empty catalog (no pre-recorded routes or demo
/// history), so any test that needs routes on screen or a route to recognize
/// must seed them through this helper rather than relying on defaults.
library;

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/persistence/serialization.dart';

/// The River Loop fixture most route-dependent tests start from.
const Route riverLoopRoute = Route(
  id: FakeEngineService.riverLoopId,
  name: 'River Loop',
  distance: Distance.kilometers(4.76),
  geometry: FakeEngineService.riverLoop,
  attemptCount: 12,
  personalBest: Elapsed.seconds(1470),
);

/// Park 5K — a second catalog entry for library/Home tests.
const Route parkLoopRoute = Route(
  id: 'park-5k',
  name: 'Park 5K',
  distance: Distance.kilometers(5.0),
  geometry: <GeoPoint>[
    GeoPoint(latitude: 52.5200, longitude: 13.3800),
    GeoPoint(latitude: 52.5320, longitude: 13.3860),
    GeoPoint(latitude: 52.5200, longitude: 13.3920),
    GeoPoint(latitude: 52.5080, longitude: 13.3860),
    GeoPoint(latitude: 52.5200, longitude: 13.3800),
  ],
  attemptCount: 8,
  personalBest: Elapsed.seconds(1625),
);

/// Hügelrunde — the third demo-catalog entry.
const Route hillLoopRoute = Route(
  id: 'huegelrunde',
  name: 'Hügelrunde',
  distance: Distance.kilometers(8.2),
  geometry: <GeoPoint>[
    GeoPoint(latitude: 52.4900, longitude: 13.3000),
    GeoPoint(latitude: 52.5100, longitude: 13.3100),
    GeoPoint(latitude: 52.4900, longitude: 13.3200),
    GeoPoint(latitude: 52.4700, longitude: 13.3100),
    GeoPoint(latitude: 52.4900, longitude: 13.3000),
  ],
  attemptCount: 3,
  personalBest: Elapsed.seconds(2770),
);

/// A partial activity for tests that need recent history on Home.
Activity seedActivity({String id = 'act-001', String routeId = 'river-loop'}) =>
    Activity(
      id: id,
      routeId: routeId,
      startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      duration: const Elapsed.seconds(1502),
      distance: const Distance.kilometers(4.75),
      performance: '24:22 · 1st',
    );

/// The three-entry route catalog most library/home tests render.
const List<Route> demoRoutes = [riverLoopRoute, parkLoopRoute, hillLoopRoute];

/// The two-entry activity history those screens also expect.
List<Activity> demoActivities() => [
      seedActivity(id: 'act-003'),
      seedActivity(id: 'act-002', routeId: 'park-5k'),
    ];

/// A store pre-populated with [routes] and [activities], so a widget or a
/// [ProviderContainer] can be built against a non-empty catalog without disk.
MemoryPersistenceStore seededStore({
  List<Route> routes = const [],
  List<Activity> activities = const [],
}) {
  final store = MemoryPersistenceStore();
  store.write('routes', routeListToJson(routes));
  store.write('activities', activityListToJson(activities));
  return store;
}