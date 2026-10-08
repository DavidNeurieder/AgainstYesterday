// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Month grouping and PB badges for the History tab (§24, §25).
///
/// Pure derivations over the two repositories so the screen stays a
/// projection: which calendar month a run landed in, which runs set a new
/// PB for their route, and how far every other attempt sits from the
/// route's current best.
library;

import '../../../engine/models.dart';

/// One calendar month of history, newest first.
class HistoryGroup {
  const HistoryGroup({required this.label, required this.activities});

  /// Header text — `'October'` within the reference year, `'October 2025'`
  /// otherwise, so groups from different years never blur together.
  final String label;

  /// The month's activities, newest first.
  final List<Activity> activities;
}

/// Groups [activities] into calendar months (by local date), newest month
/// and newest activity first. [now] is injectable for tests.
List<HistoryGroup> groupByMonth(List<Activity> activities, {DateTime? now}) {
  final ref = (now ?? DateTime.now()).toLocal();
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  final sorted = [...activities]
    ..sort((a, b) => b.startedAt.compareTo(a.startedAt));

  final groups = <HistoryGroup>[];
  for (final activity in sorted) {
    final local = activity.startedAt.toLocal();
    final label =
        local.year == ref.year ? months[local.month - 1] : '${months[local.month - 1]} ${local.year}';
    if (groups.isEmpty || groups.last.label != label) {
      groups.add(HistoryGroup(label: label, activities: [activity]));
    } else {
      groups.last.activities.add(activity);
    }
  }
  return groups;
}

/// The PB context the History rows annotate against (§24).
class HistoryPb {
  const HistoryPb({
    required this.pbSetters,
    required this.bestSeconds,
  });

  /// Activity ids that stood the route's best up when they finished — the
  /// chronological improvers, starting from the route's seeded PB as the
  /// standing best.
  final Set<String> pbSetters;

  /// routeId → the route's current best in seconds (seed or fastest
  /// attempt), for the `+0:44 vs PB` trailing delta.
  final Map<String, double> bestSeconds;
}

/// Derives [HistoryPb] from the activity history and the route catalog.
///
/// A run earns a trophy when it beat everything that came before it — its
/// seeded route PB included — so an early run keeps its badge even when a
/// later run takes the overall best.
HistoryPb computeHistoryPb(List<Activity> activities, List<Route> routes) {
  final seed = <String, double>{
    for (final route in routes)
      if (route.personalBest case final pb?) route.id: pb.seconds,
  };

  // The current best per route: the faster of the seed and all attempts.
  final best = <String, double>{...seed};
  final attemptsByRoute = <String, List<Activity>>{};
  for (final activity in activities) {
    final routeId = activity.routeId;
    final duration = activity.duration;
    if (routeId == null || duration == null) {
      continue;
    }
    (attemptsByRoute[routeId] ??= []).add(activity);
    final seconds = duration.seconds;
    if (best[routeId] case final current?) {
      if (seconds < current) {
        best[routeId] = seconds;
      }
    } else {
      best[routeId] = seconds;
    }
  }

  final setters = <String>{};
  for (final entry in attemptsByRoute.entries) {
    final attempts = [...entry.value]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    var standing = seed[entry.key] ?? double.infinity;
    for (final attempt in attempts) {
      final seconds = attempt.duration!.seconds;
      if (seconds < standing) {
        setters.add(attempt.id);
        standing = seconds;
      }
    }
  }

  return HistoryPb(pbSetters: setters, bestSeconds: best);
}
