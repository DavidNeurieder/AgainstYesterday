// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Engine-backed route statistics (M30).
///
/// All numbers are computed by `EngineService.computeRouteStats`; Flutter
/// caches the results and renders them. `routeStatsIndexProvider` computes
/// every route once, and `statsFor` selects one route's entry.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';

/// Stats for every route in the catalog, keyed by route id.
final routeStatsIndexProvider = FutureProvider<Map<String, RouteStats>>((
  ref,
) async {
  final routes = ref.watch(routeRepositoryProvider);
  final activities = ref.watch(activityRepositoryProvider);
  final engine = ref.read(engineServiceProvider);
  final out = <String, RouteStats>{};
  for (final route in routes) {
    final attempts = <Activity>[
      for (final a in activities)
        if (a.routeId == route.id && a.duration != null) a,
    ];
    out[route.id] = await engine.computeRouteStats(
      route: route,
      attempts: attempts,
    );
  }
  return out;
});

/// Stats for a single route's entry in [index], or null while unavailable.
RouteStats? statsFor(
  AsyncValue<Map<String, RouteStats>> index,
  String routeId,
) => index.asData?.value[routeId];
