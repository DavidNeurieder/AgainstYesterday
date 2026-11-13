// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route statistics derivation (M12, §23).
///
/// Routed from the two repositories — the route's own PB plus the run
/// history — into the breakdown the statistics page shows, and the PB and run
/// count the route cards and detail headline reuse.
library;

import 'dart:math' as math;

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';

class RouteStats {
  const RouteStats({
    required this.pb,
    required this.average,
    required this.last,
    required this.runs,
    this.median,
    this.fastest,
    this.slowest,
    this.stdDev,
    this.range,
    this.trendSecondsPerRun,
    this.recentAverage,
    this.verdict,
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

  /// Median attempt time (lower half / upper half average for even counts).
  final Elapsed? median;

  /// Fastest recorded attempt (ignoring a seed PB that is not in history).
  final Elapsed? fastest;

  /// Slowest recorded attempt.
  final Elapsed? slowest;

  /// Population standard deviation of attempt times, in seconds.
  final Elapsed? stdDev;

  /// Spread between the slowest and fastest recorded attempt.
  final Elapsed? range;

  /// Linear trend of attempt times over chronological order, in seconds per
  /// run (negative means getting faster).
  final double? trendSecondsPerRun;

  /// Mean of the most recent up-to-5 timed attempts (newest first).
  final Elapsed? recentAverage;

  /// Short verdict derived from recent vs overall average.
  final String? verdict;
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
  final slowest = durations.isNotEmpty ? durations.last : null;
  final pb = _best(route.personalBest, fastest);

  final average = durations.isEmpty
      ? null
      : Elapsed.seconds(
          durations.fold<num>(0, (sum, e) => sum + e.seconds) /
              durations.length);

  // Median: average of the two middle values for an even count.
  final median = durations.isEmpty
      ? null
      : durations.length.isOdd
          ? durations[durations.length ~/ 2]
          : Elapsed.seconds(
              (durations[durations.length ~/ 2 - 1].seconds +
                      durations[durations.length ~/ 2].seconds) /
                  2,
            );

  // Population standard deviation.
  final stdDev = durations.length < 2
      ? null
      : Elapsed.seconds(
          math.sqrt(
            durations.fold<double>(
                  0,
                  (sum, e) => sum + math.pow(e.seconds - average!.seconds, 2),
                ) /
                durations.length,
          ),
        );

  final range = (fastest == null || slowest == null)
      ? null
      : Elapsed.seconds(slowest.seconds - fastest.seconds);

  // Trend: slope of duration over chronological run order (seconds per run).
  final trendSecondsPerRun = _trend(attempts);

  // Recent average: mean of the newest up to 5 timed attempts.
  final recentSorted = [...attempts]..sort(
      (a, b) => b.startedAt.compareTo(a.startedAt),
    );
  final recentTimed = [
    for (final a in recentSorted)
      if (a.duration != null) a.duration!,
  ].take(5).toList();
  final recentAverage = recentTimed.isEmpty
      ? null
      : Elapsed.seconds(
          recentTimed.fold<num>(0, (s, e) => s + e.seconds) /
              recentTimed.length,
        );
  String? verdict;
  if (recentAverage != null && average != null) {
    verdict = recentAverage.seconds < average.seconds
        ? 'improving'
        : (recentAverage.seconds > average.seconds ? 'slowing' : 'steady');
  }

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
    median: median,
    fastest: fastest,
    slowest: slowest,
    stdDev: stdDev,
    range: range,
    trendSecondsPerRun: trendSecondsPerRun,
    recentAverage: recentAverage,
    verdict: verdict,
  );
}

/// Slope (seconds per run) of attempt durations over chronological order,
/// or null with fewer than two timed attempts. Negative means improving.
double? _trend(List<Activity> attempts) {
  final timed = [
    for (final a in attempts)
      if (a.duration != null) a,
  ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  if (timed.length < 2) {
    return null;
  }
  final n = timed.length;
  final xs = List<double>.generate(n, (i) => i.toDouble());
  final ys = [for (final a in timed) a.duration!.seconds];
  final meanX = xs.reduce((a, b) => a + b) / n;
  final meanY = ys.reduce((a, b) => a + b) / n;
  var num = 0.0;
  var den = 0.0;
  for (var i = 0; i < n; i++) {
    num += (xs[i] - meanX) * (ys[i] - meanY);
    den += (xs[i] - meanX) * (xs[i] - meanX);
  }
  if (den == 0) {
    return null;
  }
  return num / den;
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