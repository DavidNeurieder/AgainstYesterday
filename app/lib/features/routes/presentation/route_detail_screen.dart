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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/date_labels.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../../widgets/route_map.dart';
import '../../map/offline_region_repository.dart';
import '../../map/offline_regions.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
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
    final units = ref.watch(displayUnitProvider);
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
          if (ref.watch(offlineMapsAvailableProvider)) ...[
            _OfflineDownloadCard(routeId: route.id),
            const SizedBox(height: AppSpacing.md),
          ],
          Text(
            '${route.distance.formatWith(units)} · '
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
              AppHaptics.medium(ref);
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

/// Download/status card for this route's offline region (§23, offline map
/// Phase 3). Only rendered when this build can download regions (device
/// MapLibre builds); manage or delete downloads in Settings → Map.
class _OfflineDownloadCard extends ConsumerWidget {
  const _OfflineDownloadCard({required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final region = ref.watch(offlineRegionRepositoryProvider
        .select((regions) => regions.where((r) => r.routeId == routeId).firstOrNull));
    final textTheme = Theme.of(context).textTheme;

    final Widget content = switch (region?.status) {
      OfflineRegionStatus.ready => Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 18, color: AppColors.ahead),
            const SizedBox(width: AppSpacing.sm),
            Text('Offline map ready — works without a connection.',
                style: textTheme.bodySmall),
          ],
        ),
      OfflineRegionStatus.downloading => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Downloading ${(region!.progress * 100).round()}%',
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            LinearProgressIndicator(
              key: ValueKey('route-offline-progress-$routeId'),
              value: region.progress,
              color: AppColors.you,
              backgroundColor: AppColors.outline,
              minHeight: 4,
            ),
          ],
        ),
      OfflineRegionStatus.failed => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              region!.errorText ?? 'Download failed.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.error),
            ),
            const SizedBox(height: AppSpacing.sm),
            _RetryButton(routeId: routeId),
          ],
        ),
      _ => _DownloadButton(routeId: routeId),
    };

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: content,
      ),
    );
  }
}

class _DownloadButton extends ConsumerWidget {
  const _DownloadButton({required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref
        .watch(routeRepositoryProvider)
        .where((r) => r.id == routeId)
        .firstOrNull;
    return OutlinedButton.icon(
      key: ValueKey('download-offline-$routeId'),
      onPressed: route == null
          ? null
          : () => ref
              .read(offlineRegionRepositoryProvider.notifier)
              .downloadRoute(route),
      icon: const Icon(Icons.download_for_offline_outlined),
      label: const Text('Download offline map'),
    );
  }
}

class _RetryButton extends ConsumerWidget {
  const _RetryButton({required this.routeId});

  final String routeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref
        .watch(routeRepositoryProvider)
        .where((r) => r.id == routeId)
        .firstOrNull;
    return TextButton.icon(
      onPressed: route == null
          ? null
          : () => ref
              .read(offlineRegionRepositoryProvider.notifier)
              .downloadRoute(route),
      icon: const Icon(Icons.refresh),
      label: const Text('Try again'),
    );
  }
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