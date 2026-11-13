// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared route statistics treatment (§23).
///
/// The full numeric breakdown of one route — PB, average, median, spread,
/// trend — plus an optional performance chart of its timed runs. Kept out of
/// the route detail screen so the statistics page can render the same view
/// for every route without duplicating the layout.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';

/// The complete statistics block for one route.
///
/// [attempts] is only read when [showChart] is true; the numeric rows come
/// from [stats] either way.
class RouteStatsView extends StatelessWidget {
  const RouteStatsView({
    super.key,
    required this.stats,
    this.attempts = const [],
    this.showChart = false,
  });

  final RouteStats stats;
  final List<Activity> attempts;
  final bool showChart;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatRow(label: 'Personal Best', value: stats.pb),
        _StatRow(label: 'Average', value: stats.average),
        _StatRow(label: 'Median', value: stats.median),
        _StatRow(label: 'Last', value: stats.last),
        if (stats.fastest != null && stats.slowest != null) ...[
          _StatRow(label: 'Fastest', value: stats.fastest),
          _StatRow(label: 'Slowest', value: stats.slowest),
          _StatRow(label: 'Range', value: stats.range),
        ],
        if (stats.stdDev != null)
          _StatRow(label: 'Std. deviation', value: stats.stdDev),
        if (stats.trendSecondsPerRun case final trend?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Trend (s/run)',
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '${trend >= 0 ? '+' : ''}'
                  '${trend.toStringAsFixed(1)}'
                  ' (${trend < 0 ? 'improving' : 'slowing'})',
                  textAlign: TextAlign.right,
                  style: textTheme.titleSmall?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        if (stats.recentAverage != null && stats.runs >= 2)
          _StatRow(label: 'Recent (last 5)', value: stats.recentAverage),
        if (stats.verdict != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Verdict',
                    style: textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  stats.verdict!,
                  textAlign: TextAlign.right,
                  style: textTheme.titleSmall?.copyWith(
                    color: stats.verdict == 'improving'
                        ? AppColors.ahead
                        : (stats.verdict == 'slowing'
                            ? AppColors.behind
                            : AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (showChart && attempts.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Text(
            'Performance',
            style: textTheme.titleMedium?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          PerformanceChart(attempts: attempts, pb: stats.pb),
        ],
      ],
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
      // §7: a large system font scale must not clip either end of the row —
      // the label takes the slack and wraps, the value keeps its own width.
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
            value?.format() ?? '—',
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

/// Bar chart of attempt times (lower is better) with the PB as a baseline.
class PerformanceChart extends StatelessWidget {
  const PerformanceChart({
    super.key,
    required this.attempts,
    required this.pb,
    this.height = 120,
  });

  final List<Activity> attempts;
  final Elapsed? pb;

  /// Chart height in logical pixels — shorter for compact card previews.
  final double height;

  @override
  Widget build(BuildContext context) {
    final chronological = [
      for (final a in attempts)
        if (a.duration != null) a,
    ]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    if (chronological.isEmpty) {
      return const SizedBox.shrink();
    }
    final durations = <double>[
      for (final a in chronological) a.duration!.seconds,
    ];
    final baseline = pb?.seconds ?? durations.reduce(math.max);
    final maxV = math.max(durations.reduce(math.max), baseline);
    final fastest = durations.isEmpty ? null : durations.reduce(math.min);

    return SizedBox(
      height: height,
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
