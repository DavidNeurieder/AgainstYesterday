// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Eligibility and shared derivations for route attempt statistics.
///
/// Centralizes which activities count as route attempts for personal
/// aggregates and provides spec-aligned helpers used by stats, history and
/// result screens so Dart-side calculations do not drift.
library;

import '../../../core/units.dart';
import '../../../engine/models.dart';

/// Whether [activity] is an eligible timed attempt on [routeId].
///
/// Personal aggregates exclude example/demo activities and require a positive
/// recorded duration. Distance/quality gates can be tightened later without
/// scattering the predicate.
bool isEligibleRouteAttempt(Activity activity, String routeId) {
  if (activity.isExample) return false;
  if (activity.routeId != routeId) return false;
  final duration = activity.duration;
  return duration != null && duration.seconds > 0;
}

/// Eligible timed attempts for [route], unordered.
List<Activity> eligibleAttemptsForRoute(
  Iterable<Activity> activities,
  Route route,
) {
  if (route.isExample) return const [];
  return [
    for (final a in activities)
      if (isEligibleRouteAttempt(a, route.id)) a,
  ];
}

/// Chronologically sorted eligible attempts for [route].
List<Activity> chronologicalEligibleAttemptsForRoute(
  Iterable<Activity> activities,
  Route route,
) {
  final attempts = eligibleAttemptsForRoute(activities, route);
  attempts.sort((a, b) => a.startedAt.compareTo(b.startedAt));
  return attempts;
}

/// One PB progression event: [activity] set a new best, improving on
/// [previous] (null for the first recorded best).
typedef PbProgressionEvent = ({Activity activity, Elapsed? previous});

/// Computes PB progression events from [attempts] (any order), using each
/// attempt's duration as the performance time. Only attempts with positive
/// duration that strictly improve the standing best emit an event.
List<PbProgressionEvent> computePbProgression(
  Iterable<Activity> attempts, {
  double? seedBestSeconds,
}) {
  final timed = [
    for (final a in attempts)
      if (a.duration != null && a.duration!.seconds > 0) a,
  ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  final events = <PbProgressionEvent>[];
  var standing = seedBestSeconds ?? double.infinity;
  Elapsed? standingElapsed;
  for (final a in timed) {
    final seconds = a.duration!.seconds;
    if (seconds < standing) {
      events.add((activity: a, previous: standingElapsed));
      standing = seconds;
      standingElapsed = a.duration;
    }
  }
  return events;
}

/// 1-based rank of [activityId] among eligible attempts on [route], ordered
/// by fastest duration first (ties keep stable input order via id tiebreak),
/// or null when the activity is not a ranked eligible attempt.
int? routeAttemptRank({
  required Iterable<Activity> activities,
  required Route route,
  required String activityId,
}) {
  final ranked = eligibleAttemptsForRoute(activities, route)
    ..sort((a, b) {
      final cmp = a.duration!.seconds.compareTo(b.duration!.seconds);
      if (cmp != 0) return cmp;
      final t = a.startedAt.compareTo(b.startedAt);
      if (t != 0) return t;
      return a.id.compareTo(b.id);
    });
  for (var i = 0; i < ranked.length; i++) {
    if (ranked[i].id == activityId) return i + 1;
  }
  return null;
}

/// Human-readable ordinal ranking label, e.g. "Your 2nd fastest run on this
/// route", or null when [activityId] is not ranked.
String? routeAttemptRankLabel({
  required Iterable<Activity> activities,
  required Route route,
  required String activityId,
}) {
  final rank = routeAttemptRank(
    activities: activities,
    route: route,
    activityId: activityId,
  );
  if (rank == null) return null;
  final suffix = switch (rank % 100) {
    11 || 12 || 13 => 'th',
    _ => switch (rank % 10) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' },
  };
  return 'Your $rank$suffix fastest run on this route';
}

/// Current best (seconds) over eligible attempts and optional seed PB for a
/// non-example route.
double? currentBestSeconds({
  required Route route,
  required Iterable<Activity> activities,
}) {
  if (route.isExample) return null;
  double? best = route.personalBest?.seconds;
  for (final a in activities) {
    if (!isEligibleRouteAttempt(a, route.id)) continue;
    final s = a.duration!.seconds;
    if (best == null || s < best) best = s;
  }
  return best;
}
