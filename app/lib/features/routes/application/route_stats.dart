// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route statistics derivation (M12, §23).
///
/// Routed from the two repositories — the route's own PB plus the attempt
/// history — into the compact set the route detail screen shows.
library;

import 'dart:math' as math;

import 'package:gps_app/core/units.dart';
import 'package:gps_app/engine/models.dart';

class RouteStats {
  const RouteStats({
    required this.pb,
    required this.average,
    required this.last,
    required this.runs,
  });

  /// Fastest ever on this route (seed PB when no history beats it).
  final Elapsed? pb;

  /// Mean of all recorded attempts.
  final Elapsed? average;

  /// Most recent attempt.
  final Elapsed? last;

  /// Number of known runs (at least the route's own counter when history
  /// is empty, so seeded demo routes read naturally).
  final int runs;
}

/// Computes [RouteStats] for [route] from its [attempts] (activities that
/// recognised it). Sources may arrive in any order; they are normalised here.
RouteStats computeRouteStats({
  required Route route,
  required List<Activity> attempts,
}) {
  final durations = <Elapsed>[
    for (final a in attempts)
      if (a.duration != null) a.duration!,
  ];
  durations.sort((a, b) => a.seconds.compareTo(b.seconds));

  final fastest = durations.isNotEmpty ? durations.first : null;
  final pb = _best(route.personalBest, fastest);

  final average = durations.isEmpty
      ? null
      : Elapsed.seconds(
          durations.fold<num>(0, (sum, e) => sum + e.seconds) /
              durations.length);

  final recent = [...attempts]..sort(
      (a, b) => b.startedAt.compareTo(a.startedAt),
    );
  final last = recent.isNotEmpty && recent.first.duration != null
      ? recent.first.duration
      : null;

  return RouteStats(
    pb: pb,
    average: average,
    last: last,
    runs: attempts.isEmpty
        ? route.attemptCount
        : math.max(route.attemptCount, attempts.length),
  );
}

/// The faster of [a] and [b]; either may be null.
Elapsed? _best(Elapsed? a, Elapsed? b) {
  if (a == null) {
    return b;
  }
  if (b == null) {
    return a;
  }
  return a.seconds <= b.seconds ? a : b;
}