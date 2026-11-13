// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route statistics (M12, §23).
///
/// The numbers themselves are computed by the engine
/// (`EngineService.computeRouteStats`) and cached in
/// `route_stats_provider.dart`. Flutter only renders the result; this file
/// keeps the shared type and the display fallback used before the engine
/// future resolves.
library;

import 'package:against_yesterday/engine/models.dart';

export 'package:against_yesterday/engine/models.dart' show RouteStats;

/// The stats a card can show synchronously while the engine future is still
/// pending: the route's seeded run count and PB, with no derived metrics.
RouteStats fallbackRouteStats(Route route) => RouteStats(
      pb: route.personalBest,
      average: null,
      last: null,
      runs: route.attemptCount,
    );
