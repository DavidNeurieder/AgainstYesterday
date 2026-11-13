// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App-wide statistics (M34): aggregates across routes and runs.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../core/theme/app_colors.dart';
import '../../../persistence/persistence.dart';
import 'package:go_router/go_router.dart';
import '../../routes/application/route_stats.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';

enum _StatsPeriod { week, month, year, all }

class StatisticsScreen extends ConsumerStatefulWidget {
  const StatisticsScreen({super.key});

  @override
  ConsumerState<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends ConsumerState<StatisticsScreen> {
  _StatsPeriod _period = _StatsPeriod.all;

  DateTime _periodStart(_StatsPeriod p, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    switch (p) {
      case _StatsPeriod.week:
        return today.subtract(const Duration(days: 7));
      case _StatsPeriod.month:
        final prevMonth = now.month == 1 ? 12 : now.month - 1;
        final prevYear = now.month == 1 ? now.year - 1 : now.year;
        final lastDay = DateTime(prevYear, prevMonth + 1, 0).day;
        final day = now.day > lastDay ? lastDay : now.day;
        return DateTime(prevYear, prevMonth, day);
      case _StatsPeriod.year:
        return DateTime(now.year - 1, now.month, now.day);
      case _StatsPeriod.all:
        return DateTime(1970);
    }
  }

  List<double> _weeklyBuckets(List<Activity> acts, double Function(Activity) value) {
    final now = DateTime.now();
    final buckets = List<double>.filled(8, 0);
    final counts = List<int>.filled(8, 0);
    for (final a in acts) {
      final weeksAgo = now.difference(a.startedAt).inDays ~/ 7;
      if (weeksAgo < 0 || weeksAgo >= 8) continue;
      final idx = 7 - weeksAgo;
      buckets[idx] += value(a);
      counts[idx] += 1;
    }
    return buckets;
  }

  List<Widget> _pbTimeline(BuildContext context, List<Route> routes, List<Activity> activities) {
    final textTheme = Theme.of(context).textTheme;
    final routeNames = {for (final r in routes) r.id: r.name};
    final events = <Activity>[];
    for (final r in routes) {
      final attempts = [
        for (final a in activities)
          if (a.routeId == r.id && a.duration != null) a,
      ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      Elapsed? best;
      for (final a in attempts) {
        if (best == null || a.duration!.seconds < best.seconds) {
          best = a.duration;
          events.add(a);
        }
      }
    }
    events.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (events.isEmpty) {
      return [
        Text(
          'No personal bests yet.',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      ];
    }
    return [
      for (final a in events.take(5))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.emoji_events, size: 16, color: AppColors.pb),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '${routeNames[a.routeId] ?? 'Route'} · ${a.duration!.format()}',
                  style: textTheme.bodyMedium,
                ),
              ),
              Text(
                '${a.startedAt.toLocal().day}/${a.startedAt.toLocal().month}',
                style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final routes = ref.watch(routeRepositoryProvider);
    final activities = ref.watch(activityRepositoryProvider);
    final units = ref.watch(displayUnitProvider);
    final textTheme = Theme.of(context).textTheme;

    final now = DateTime.now();
    final start = _periodStart(_period, now);
    final prevStart = _periodStart(_period, start);
    final filtered = <Activity>[
      for (final a in activities) if (!a.startedAt.isBefore(start)) a,
    ];
    final previous = <Activity>[
      for (final a in activities)
        if (!a.startedAt.isBefore(prevStart) && a.startedAt.isBefore(start)) a,
    ];

    double totalDistanceM = 0;
    int totalSeconds = 0;
    int timedRuns = 0;
    for (final a in filtered) {
      if (a.distance != null) totalDistanceM += a.distance!.meters;
      if (a.duration != null) {
        totalSeconds += a.duration!.seconds.round();
        timedRuns++;
      }
    }
    double prevDistanceM = 0;
    for (final a in previous) {
      if (a.distance != null) prevDistanceM += a.distance!.meters;
    }

    int pbCount = 0;
    for (final r in routes) {
      final attempts = [
        for (final a in filtered) if (a.routeId == r.id && a.duration != null) a,
      ];
      final stats = computeRouteStats(route: r, attempts: attempts);
      if (stats.pb != null) pbCount++;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          SegmentedButton<_StatsPeriod>(
            segments: const [
              ButtonSegment(value: _StatsPeriod.week, label: Text('Week')),
              ButtonSegment(value: _StatsPeriod.month, label: Text('Month')),
              ButtonSegment(value: _StatsPeriod.year, label: Text('Year')),
              ButtonSegment(value: _StatsPeriod.all, label: Text('All')),
            ],
            selected: {_period},
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
          const SizedBox(height: AppSpacing.md),
          if (routes.isEmpty)
            const EmptyStatePlaceholder()
          else ...[
            _SummaryGrid(
              totalDistance: Distance.meters(totalDistanceM),
              totalSeconds: totalSeconds,
              runs: timedRuns,
              pbCount: pbCount,
              units: units,
            ),
            if (_period != _StatsPeriod.all && previous.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'vs previous: ${Distance.meters(prevDistanceM).formatWith(units)} '
                  '(${totalDistanceM >= prevDistanceM ? '+' : ''}'
                  '${(totalDistanceM - prevDistanceM).toStringAsFixed(0)} m)',
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
            Text('Distance trend', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _WeeklyBarChart(
              buckets: _weeklyBuckets(filtered, (a) => a.distance?.meters ?? 0),
              unit: 'm',
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Pace trend', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _WeeklyBarChart(
              buckets: _weeklyBuckets(
                filtered.where((a) => a.duration != null && a.distance != null && a.distance!.meters > 0).toList(),
                (a) => (a.duration!.seconds / (a.distance!.meters / 1000.0)),
              ),
              unit: 'min/km',
              lowerIsBetter: true,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Consistency (last 4 weeks)', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            _ConsistencyCalendar(activities: filtered),
            const SizedBox(height: AppSpacing.lg),
            Text('Recent achievements', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            ..._pbTimeline(context, routes, activities),
            const SizedBox(height: AppSpacing.lg),
            Text('Routes', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final r in routes) ...[
              _RouteStatCard(route: r, activities: activities, units: units),
              const SizedBox(height: AppSpacing.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class EmptyStatePlaceholder extends StatelessWidget {
  const EmptyStatePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(AppSpacing.xl),
        child: Text('No routes yet. Record a run to see statistics.'),
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.totalDistance,
    required this.totalSeconds,
    required this.runs,
    required this.pbCount,
    required this.units,
  });

  final Distance totalDistance;
  final int totalSeconds;
  final int runs;
  final int pbCount;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    Widget card(String label, String value) => Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(value, style: textTheme.titleLarge),
              ],
            ),
          ),
        );
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        SizedBox(width: 160, child: card('Total distance', totalDistance.formatWith(units))),
        SizedBox(width: 160, child: card('Total time', Elapsed.seconds(totalSeconds.toDouble()).formatClock())),
        SizedBox(width: 160, child: card('Timed runs', '$runs')),
        SizedBox(width: 160, child: card('Personal bests', '$pbCount')),
      ],
    );
  }
}


class _WeeklyBarChart extends StatelessWidget {
  const _WeeklyBarChart({
    required this.buckets,
    required this.unit,
    this.lowerIsBetter = false,
  });

  final List<double> buckets;
  final String unit;
  final bool lowerIsBetter;

  @override
  Widget build(BuildContext context) {
    final maxV = buckets.isEmpty
        ? 1.0
        : buckets.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);
    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in buckets)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: (v / maxV * 90).clamp(2.0, 90.0),
                      decoration: BoxDecoration(
                        color: AppColors.you,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      v == 0 ? '' : v.toStringAsFixed(unit == 'm' ? 0 : 1),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.textMuted,
                          ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}


class _ConsistencyCalendar extends StatelessWidget {
  const _ConsistencyCalendar({required this.activities});

  final List<Activity> activities;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final days = <DateTime>[];
    for (var i = 27; i >= 0; i--) {
      days.add(DateTime(now.year, now.month, now.day).subtract(Duration(days: i)));
    }
    final active = <String>{};
    for (final a in activities) {
      final d = a.startedAt.toLocal();
      active.add('${d.year}-${d.month}-${d.day}');
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: days.length,
      itemBuilder: (context, i) {
        final d = days[i];
        final key = '${d.year}-${d.month}-${d.day}';
        final isActive = active.contains(key);
        return Container(
          decoration: BoxDecoration(
            color: isActive ? AppColors.you : AppColors.surfaceHigh,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      },
    );
  }
}

class _RouteStatCard extends ConsumerWidget {
  const _RouteStatCard({
    required this.route,
    required this.activities,
    required this.units,
  });

  final Route route;
  final List<Activity> activities;
  final Units units;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final attempts = [
      for (final a in activities) if (a.routeId == route.id && a.duration != null) a,
    ];
    final stats = computeRouteStats(route: route, attempts: attempts);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          AppHaptics.selection(ref);
          context.push('/route/${route.id}');
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(route.name, style: textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              '${route.distance.formatWith(units)} · ${stats.runs} runs',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(child: _kv(context, 'PB', stats.pb?.format() ?? '—')),
                Expanded(child: _kv(context, 'Average', stats.average?.format() ?? '—')),
                Expanded(child: _kv(context, 'Last', stats.last?.format() ?? '—')),
              ],
            ),
            if (stats.verdict != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Trend: ${stats.verdict}',
                  style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _kv(BuildContext context, String k, String v) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(k, style: textTheme.labelSmall?.copyWith(color: AppColors.textMuted)),
        Text(v, style: textTheme.titleSmall),
      ],
    );
  }
}