// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Statistics for one route (§23).
///
/// A hub of cards — overview, performance, segment comparison — each opening
/// its own page. Everything here is scoped to the route you came from, never
/// another course. Reached from that route's detail app bar so the run list
/// stays front and centre.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/date_labels.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_sections.dart';
import '../../../core/ui/app_states.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../app/dependencies.dart';
import '../application/route_attempts.dart';
import '../../../widgets/route_silhouette.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/route_stats.dart';
import '../application/route_stats_provider.dart';
import 'pb_progression.dart';
import 'route_segment_comparison.dart';
import 'route_stats_view.dart';

/// The statistics sections of one route; each hub card opens one.
enum RouteStatsSection {
  overview('overview', 'Overview'),
  performance('performance', 'Performance'),
  segments('segments', 'Segment comparison');

  const RouteStatsSection(this.slug, this.title);

  /// Path segment used by the router.
  final String slug;

  /// App bar and card title.
  final String title;

  static RouteStatsSection? fromSlug(String slug) {
    for (final section in values) {
      if (section.slug == slug) return section;
    }
    return null;
  }
}

/// The per-route statistics hub: one card per section.
class RouteStatisticsScreen extends ConsumerWidget {
  const RouteStatisticsScreen({super.key, required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref
        .watch(routeRepositoryProvider)
        .where((r) => r.id == routeId)
        .firstOrNull;
    if (route == null) {
      return _NotFoundScaffold(title: 'Statistics');
    }

    final attempts = _timedAttempts(ref, route);
    final stats =
        statsFor(ref.watch(routeStatsIndexProvider), routeId) ??
        fallbackRouteStats(route);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Statistics')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _RouteHeader(
            route: route,
            runs: stats.runs,
            units: ref.watch(displayUnitProvider),
          ),
          const SizedBox(height: AppSpacing.lg),
          _StatsCard(
            key: const ValueKey('stats-card-overview'),
            icon: Icons.insights_outlined,
            title: RouteStatsSection.overview.title,
            subtitle: 'Personal best, average, median and trend',
            onTap: () =>
                _openSection(context, ref, route, RouteStatsSection.overview),
            preview: Row(
              children: [
                Expanded(
                  child: MetricDisplay(
                    label: 'PB',
                    value: stats.pb?.format() ?? '—',
                  ),
                ),
                Expanded(
                  child: MetricDisplay(
                    label: 'Average',
                    value: stats.average?.format() ?? '—',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _StatsCard(
            key: const ValueKey('stats-card-performance'),
            icon: Icons.bar_chart,
            title: RouteStatsSection.performance.title,
            subtitle: 'Chart and times of every timed run',
            onTap: () => _openSection(
              context,
              ref,
              route,
              RouteStatsSection.performance,
            ),
            preview: attempts.isEmpty
                ? Text(
                    'No timed runs on this route yet.',
                    style: textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  )
                : PerformanceChart(
                    attempts: attempts,
                    pb: stats.pb,
                    height: 64,
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          _StatsCard(
            key: const ValueKey('stats-card-segments'),
            icon: Icons.linear_scale,
            title: RouteStatsSection.segments.title,
            subtitle: 'Equal-distance splits across your recent runs',
            onTap: () =>
                _openSection(context, ref, route, RouteStatsSection.segments),
            preview: Text(
              '500 m · 1 km · 2 km · 5 km splits',
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One statistics section for one route.
class RouteStatisticsSectionScreen extends ConsumerWidget {
  const RouteStatisticsSectionScreen({
    super.key,
    required this.routeId,
    required this.section,
  });

  final String routeId;
  final RouteStatsSection section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref
        .watch(routeRepositoryProvider)
        .where((r) => r.id == routeId)
        .firstOrNull;
    if (route == null) {
      return _NotFoundScaffold(title: section.title);
    }

    final attempts = _timedAttempts(ref, route);
    final stats =
        statsFor(ref.watch(routeStatsIndexProvider), route.id) ??
        fallbackRouteStats(route);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(section.title)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _RouteHeader(
            route: route,
            runs: stats.runs,
            units: ref.watch(displayUnitProvider),
          ),
          const SizedBox(height: AppSpacing.lg),
          switch (section) {
            RouteStatsSection.overview => RouteStatsView(stats: stats),
            RouteStatsSection.performance => _PerformanceSection(
              attempts: attempts,
              pb: stats.pb,
            ),
            RouteStatsSection.segments => SegmentComparisonSection(
              route: route,
              attempts: attempts,
            ),
          },
          if (section == RouteStatsSection.overview) ...[
            const SizedBox(height: AppSpacing.lg),
            _ElevationSummarySection(attempts: attempts),
            const SizedBox(height: AppSpacing.lg),
            PbProgressionSection(route: route, attempts: attempts),
          ],
          if (section == RouteStatsSection.performance &&
              attempts.length >= 2) ...[
            const SizedBox(height: AppSpacing.lg),
            HeadToHeadSection(route: route, attempts: attempts),
          ],
          if (attempts.isEmpty && section != RouteStatsSection.segments) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'No timed runs on this route yet, so there is nothing to '
              'compare.',
              style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

/// Timed, eligible runs recorded on [route] for statistics presentation.
List<Activity> _timedAttempts(WidgetRef ref, Route route) =>
    eligibleAttemptsForRoute(ref.watch(activityRepositoryProvider), route);

void _openSection(
  BuildContext context,
  WidgetRef ref,
  Route route,
  RouteStatsSection section,
) {
  AppHaptics.selection(ref);
  context.push('/route/${route.id}/statistics/${section.slug}');
}

/// Route identity shown above the cards and on every section page.
class _RouteHeader extends StatelessWidget {
  const _RouteHeader({
    required this.route,
    required this.runs,
    required this.units,
  });

  final Route route;
  final int runs;
  final Units units;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        SizedBox(
          width: 56,
          height: 44,
          child: Center(child: RouteSilhouette(geometry: route.geometry)),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(route.name, style: textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                '${route.distance.formatWith(units)} · '
                '$runs ${runs == 1 ? 'run' : 'runs'}',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One tappable statistics card on the hub.
class _StatsCard extends StatelessWidget {
  const _StatsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.preview,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? preview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: AppColors.you),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: Text(title, style: textTheme.titleMedium)),
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              if (preview case final preview?) ...[
                const SizedBox(height: AppSpacing.sm),
                preview,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _PerformanceRange { all, days7, days30, days90, last5, last10 }

/// Performance page: the chart plus its timed runs in chronological order.
class _PerformanceSection extends StatefulWidget {
  const _PerformanceSection({required this.attempts, this.pb});

  final List<Activity> attempts;
  final Elapsed? pb;

  @override
  State<_PerformanceSection> createState() => _PerformanceSectionState();
}

class _PerformanceSectionState extends State<_PerformanceSection> {
  _PerformanceRange _range = _PerformanceRange.all;

  List<Activity> get _filtered {
    final chronological = [...widget.attempts]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final now = DateTime.now().toUtc();
    return switch (_range) {
      _PerformanceRange.all => chronological,
      _PerformanceRange.days7 =>
        chronological.where((a) => now.difference(a.startedAt).inDays < 7).toList(),
      _PerformanceRange.days30 =>
        chronological.where((a) => now.difference(a.startedAt).inDays < 30).toList(),
      _PerformanceRange.days90 =>
        chronological.where((a) => now.difference(a.startedAt).inDays < 90).toList(),
      _PerformanceRange.last5 => chronological.length <= 5
          ? chronological
          : chronological.sublist(chronological.length - 5),
      _PerformanceRange.last10 => chronological.length <= 10
          ? chronological
          : chronological.sublist(chronological.length - 10),
    };
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    if (widget.attempts.isEmpty) {
      return const SizedBox.shrink();
    }
    final chronological = _filtered;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in const [
              (_PerformanceRange.all, 'All'),
              (_PerformanceRange.days30, '30 days'),
              (_PerformanceRange.days90, '90 days'),
              (_PerformanceRange.days7, '7 days'),
              (_PerformanceRange.last5, 'Last 5'),
              (_PerformanceRange.last10, 'Last 10'),
            ])
              ChoiceChip(
                label: Text(entry.$2),
                selected: _range == entry.$1,
                onSelected: (_) => setState(() => _range = entry.$1),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (chronological.isEmpty)
          Text(
            'No runs in this range.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          )
        else ...[
          PerformanceChart(attempts: chronological, pb: widget.pb),
          const SizedBox(height: AppSpacing.lg),
          SectionHeader(title: 'Runs'),
          const SizedBox(height: AppSpacing.sm),
          for (final run in chronological)
            Padding(
              key: ValueKey('performance-run-${run.id}'),
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      dateLabelFor(run.startedAt.toLocal()),
                      style: textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    run.duration!.format(),
                    textAlign: TextAlign.right,
                    style: textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (widget.pb case final pb?) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      _deltaLabel(run.duration!.seconds - pb.seconds),
                      textAlign: TextAlign.right,
                      style: textTheme.bodySmall?.copyWith(
                        color: run.duration!.seconds <= pb.seconds
                            ? AppColors.ahead
                            : AppColors.behind,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ],
    );
  }
}

String _deltaLabel(double delta) {
  if (delta == 0) return 'PB';
  return delta > 0
      ? '+${Elapsed.seconds(delta).format()}'
      : '-${Elapsed.seconds(-delta).format()}';
}

class _ElevationSummarySection extends ConsumerStatefulWidget {
  const _ElevationSummarySection({required this.attempts});

  final List<Activity> attempts;

  @override
  ConsumerState<_ElevationSummarySection> createState() =>
      _ElevationSummarySectionState();
}

class _ElevationSummarySectionState
    extends ConsumerState<_ElevationSummarySection> {
  Future<_ElevationAggregate?>? _future;
  String _key = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant _ElevationSummarySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refresh();
  }

  void _refresh() {
    final ids = widget.attempts.map((a) => a.id).join(',');
    if (ids == _key) return;
    _key = ids;
    _future = _load();
  }

  Future<_ElevationAggregate?> _load() async {
    final withTrack = [
      for (final a in widget.attempts)
        if (a.track != null && a.track!.length >= 2) a,
    ];
    if (withTrack.isEmpty) return null;
    final engine = ref.read(engineServiceProvider);
    final samples = <TrackAnalytics>[];
    for (final a in withTrack.take(8)) {
      try {
        final analytics = await engine.analyzeTrack(points: a.track!);
        if (analytics.quality.hasElevationData) samples.add(analytics);
      } catch (_) {}
    }
    if (samples.isEmpty) return null;
    double? minV;
    double? maxV;
    var gainSum = 0.0;
    var lossSum = 0.0;
    var gainCount = 0;
    var lossCount = 0;
    for (final s in samples) {
      if (s.elevationMinMeters case final v?) {
        minV = minV == null ? v : (v < minV ? v : minV);
      }
      if (s.elevationMaxMeters case final v?) {
        maxV = maxV == null ? v : (v > maxV ? v : maxV);
      }
      if (s.elevationGainMeters case final v?) {
        gainSum += v;
        gainCount++;
      }
      if (s.elevationLossMeters case final v?) {
        lossSum += v;
        lossCount++;
      }
    }
    return _ElevationAggregate(
      attempts: samples.length,
      avgGain: gainCount == 0 ? null : gainSum / gainCount,
      avgLoss: lossCount == 0 ? null : lossSum / lossCount,
      minElevation: minV,
      maxElevation: maxV,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return FutureBuilder<_ElevationAggregate?>(
      future: _future,
      builder: (context, snapshot) {
        final agg = snapshot.data;
        if (agg == null) return const SizedBox.shrink();
        String fmt(double? v) =>
            v == null ? '—' : '${v.toStringAsFixed(0)} m';
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(title: 'Elevation'),
            const SizedBox(height: AppSpacing.sm),
            _ElevationRow(label: 'Avg ascent', value: fmt(agg.avgGain)),
            _ElevationRow(label: 'Avg descent', value: fmt(agg.avgLoss)),
            _ElevationRow(label: 'Min elevation', value: fmt(agg.minElevation)),
            _ElevationRow(label: 'Max elevation', value: fmt(agg.maxElevation)),
            Text(
              'Aggregated from ${agg.attempts} attempt(s) with elevation data (engine-analyzed).',
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ElevationAggregate {
  const _ElevationAggregate({
    required this.attempts,
    required this.avgGain,
    required this.avgLoss,
    required this.minElevation,
    required this.maxElevation,
  });
  final int attempts;
  final double? avgGain;
  final double? avgLoss;
  final double? minElevation;
  final double? maxElevation;
}

class _ElevationRow extends StatelessWidget {
  const _ElevationRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            value,
            textAlign: TextAlign.right,
            style: textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotFoundScaffold extends StatelessWidget {
  const _NotFoundScaffold({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: const EmptyState(icon: Icons.route, message: 'Route not found.'),
    );
  }
}
