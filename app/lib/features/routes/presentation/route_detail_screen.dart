// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route detail screen (§23, M12).
///
/// Route map, headline stats (PB / Average / Last), a performance chart of
/// every attempt, and the attempt history. Read-only projection of the two
/// repositories.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../widgets/route_map.dart';
import '../application/route_stats.dart';

class RouteDetailScreen extends ConsumerWidget {
  const RouteDetailScreen({super.key, required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final routes = ref.watch(routeRepositoryProvider);
    final route = routes.where((r) => r.id == routeId).firstOrNull;
    if (route == null) {
      return _NotFoundScreen(routeId: routeId);
    }

    final activities = ref.watch(activityRepositoryProvider);
    final attempts = <Activity>[
      for (final a in activities)
        if (a.routeId == route.id && a.duration != null) a,
    ];
    final stats = computeRouteStats(route: route, attempts: attempts);

    return Scaffold(
      appBar: AppBar(title: Text(route.name)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          SizedBox(
            height: 180,
            child: RouteMap(
              geometry: route.geometry,
              you: route.geometry.first,
              youProgress: 0,
              staticView: true,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '${route.distance.format()} · '
            '${stats.runs} ${stats.runs == 1 ? 'run' : 'runs'} · '
            '${stats.pb?.format() ?? 'no PB'} PB',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.lg),
          // M19: the detail page races this exact route, never another one.
          PrimaryButton(
            label: 'RACE YOUR BEST',
            icon: Icons.play_arrow_rounded,
            onPressed: () {
              HapticFeedback.mediumImpact();
              context.go('/race/${route.id}');
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          _StatRow(label: 'Personal Best', value: stats.pb),
          _StatRow(label: 'Average', value: stats.average),
          _StatRow(label: 'Last', value: stats.last),
          const SizedBox(height: AppSpacing.lg),
          if (attempts.isNotEmpty) ...[
            Text(
              'Performance',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PerformanceChart(
              attempts: attempts,
              pb: stats.pb,
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          Text(
            'Attempts',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (attempts.isEmpty)
            Text(
              'No attempts on this route yet.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textMuted,
                  ),
            )
          else
            for (final attempt in attempts) _AttemptRow(attempt: attempt),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final Elapsed? value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final value = this.value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            value?.format() ?? '—',
            style: textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bar chart of attempt times (lower is better) with the PB as a baseline.
class _PerformanceChart extends StatelessWidget {
  const _PerformanceChart({required this.attempts, required this.pb});

  final List<Activity> attempts;
  final Elapsed? pb;

  @override
  Widget build(BuildContext context) {
    final chronological = [...attempts]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final durations = <double>[
      for (final a in chronological) a.duration!.seconds,
    ];
    final baseline = pb?.seconds ?? durations.reduce(math.max);
    final maxV = math.max(
      durations.reduce(math.max),
      baseline,
    );
    final fastest = durations.isEmpty ? null : durations.reduce(math.min);

    return SizedBox(
      height: 120,
      child: CustomPaint(
        size: Size.infinite,
        painter: _ChartPainter(
          durations: durations,
          baseline: baseline,
          maxV: maxV,
          fastest: fastest,
          barColor: AppColors.pb,
          trackColor: AppColors.ghost,
          baselineColor: AppColors.you,
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.durations,
    required this.baseline,
    required this.maxV,
    required this.fastest,
    required this.barColor,
    required this.trackColor,
    required this.baselineColor,
  });

  final List<double> durations;
  final double baseline;
  final double maxV;
  final double? fastest;
  final Color barColor;
  final Color trackColor;
  final Color baselineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (durations.isEmpty || maxV <= 0) {
      return;
    }

    const padBottom = 12.0;
    final plotTop = 6.0;
    final plotHeight = size.height - plotTop - padBottom;
    final chartWidth = math.max(size.width, 1).toDouble();

    final n = durations.length;
    final slot = chartWidth / n;
    final barWidth = math.min(slot * 0.56, 26.0);

    // Bars, oldest → newest.
    for (var i = 0; i < n; i++) {
      final ratio = durations[i] / maxV;
      final height = ratio * plotHeight;
      final left = slot * i + (slot - barWidth) / 2;
      final top = plotTop + plotHeight - height;

      final color = durations[i] == fastest ? barColor : trackColor;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(left, top, barWidth, height),
          topLeft: const Radius.circular(4),
          topRight: const Radius.circular(4),
        ),
        Paint()..color = color,
      );
    }

    // PB baseline.
    final baselineY = plotTop + plotHeight - (baseline / maxV) * plotHeight;
    final line = Paint()
      ..color = baselineColor
      ..strokeWidth = 1.4;
    _drawDashedLine(
      canvas,
      Offset(0, baselineY),
      Offset(chartWidth, baselineY),
      line,
    );
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLen = 4.0;
    const gapLen = 3.0;
    final total = (b - a).distance;
    var dist = 0.0;
    var draw = true;
    while (dist < total) {
      final end = math.min(total, dist + (draw ? dashLen : gapLen));
      canvas.drawLine(
        Offset.lerp(a, b, dist / total)!,
        Offset.lerp(a, b, end / total)!,
        paint,
      );
      draw = !draw;
      dist = end;
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.durations != durations || old.baseline != baseline;
}

class _AttemptRow extends StatelessWidget {
  const _AttemptRow({required this.attempt});

  final Activity attempt;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final duration = attempt.duration!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            dateLabelFor(attempt.startedAt.toLocal()),
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          Text(
            duration.format(),
            style: textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// How many calendar days separate [from] and [to].
///
/// The comparison reads each input's own year/month/day fields and rebuilds
/// them as UTC dates before subtracting. That matters because a calendar day is
/// not always 24 hours long: across a daylight-saving transition the elapsed
/// time between two consecutive *local* midnights is 23 or 25 hours, and
/// [Duration.inDays] on that span would truncate to the wrong whole number —
/// giving "Today" for a date that is clearly yesterday. In UTC every day is
/// 24 hours, so the result depends only on the two calendar dates, never on the
/// machine's timezone or on a transition falling between them.
int calendarDayDifference(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day)
        .difference(DateTime.utc(from.year, from.month, from.day))
        .inDays;

/// Renders an attempt timestamp as a relative-or-absolute label.
///
/// [now] is injectable so the behaviour can be unit-tested instead of being
/// pinned to the wall clock — the seeded history sits a fixed 26 hours in the
/// past, so its label legitimately flips between "Yesterday" and an absolute
/// date depending on the time of day.
String dateLabelFor(DateTime d, {DateTime? now}) {
  final diff = calendarDayDifference(d, now ?? DateTime.now());
  if (diff == 0) {
    return 'Today';
  }
  if (diff == 1) {
    return 'Yesterday';
  }
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Route')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.route, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'Route not found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Back to Home'),
            ),
          ],
        ),
      ),
    );
  }
}