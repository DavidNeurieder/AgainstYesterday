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

import '../../../app/dependencies.dart';
import '../../../core/date_labels.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../map/map_surface.dart';
import '../../map/offline_region_repository.dart';
import '../../map/offline_regions.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';
import '../application/route_stats.dart';
import '../../../widgets/route_map.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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
          // The course on the map: through the same seam as the activity track
          // and the live run, so device builds (MAP_VIEW=true) render it with
          // MapLibre and host/test builds keep the hermetic painter.
          SizedBox(
            height: 180,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ref
                      .watch(mapSurfaceProvider)
                      .build(
                        context,
                        MapScene(
                          geometry: route.geometry,
                          you: route.geometry.first,
                          youProgress: 0,
                          staticView: true,
                        ),
                      ),
                  Positioned.fill(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _showExpandedMap(context, route, attempts),
                        splashColor: Colors.white10,
                        highlightColor: Colors.white10,
                      ),
                    ),
                  ),
                ],
              ),
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
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          // M19: the detail page races this exact route, never another one.
          PrimaryButton(
            label: 'RACE YOUR BEST',
            icon: Icons.play_arrow_rounded,
            onPressed: () {
              AppHaptics.medium(ref);
              // Pushed over the shell so back returns to this detail page.
              context.push('/race/${route.id}');
            },
          ),
          const SizedBox(height: AppSpacing.lg),
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
          if (stats.trendSecondsPerRun != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Trend (s/run)',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '${stats.trendSecondsPerRun! >= 0 ? '+' : ''}'
                    '${stats.trendSecondsPerRun!.toStringAsFixed(1)}'
                    ' (${stats.trendSecondsPerRun! < 0 ? 'improving' : 'slowing'})',
                    textAlign: TextAlign.right,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          if (attempts.isNotEmpty) ...[
            Text(
              'Performance',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            _PerformanceChart(attempts: attempts, pb: stats.pb),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (attempts.isNotEmpty) ...[
            SegmentComparisonSection(route: route, attempts: attempts),
            const SizedBox(height: AppSpacing.lg),
          ],
          Text(
            'Attempts',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (attempts.isEmpty)
            Text(
              'No attempts on this route yet.',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
            )
          else
            for (final attempt in attempts)
              _AttemptRow(attempt: attempt, pb: stats.pb),
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
    final maxV = math.max(durations.reduce(math.max), baseline);
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
  const _AttemptRow({required this.attempt, this.pb});

  final Activity attempt;
  final Elapsed? pb;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final duration = attempt.duration!;
    final delta = pb == null ? null : duration.seconds - pb!.seconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      // §7: the date wraps instead of pushing the duration off the row at a
      // large system font scale.
      child: Row(
        children: [
          Expanded(
            child: Text(
              dateLabelFor(attempt.startedAt.toLocal()),
              style: textTheme.bodyMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            duration.format(),
            textAlign: TextAlign.right,
            style: textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (delta != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Text(
              delta == 0
                  ? 'PB'
                  : (delta > 0
                        ? '+${Elapsed.seconds(delta).format()}'
                        : '-${Elapsed.seconds(-delta).format()}'),
              textAlign: TextAlign.right,
              style: textTheme.bodySmall?.copyWith(
                color: delta <= 0 ? AppColors.ahead : AppColors.behind,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
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
    final region = ref.watch(
      offlineRegionRepositoryProvider.select(
        (regions) => regions.where((r) => r.routeId == routeId).firstOrNull,
      ),
    );
    final textTheme = Theme.of(context).textTheme;

    final Widget content = switch (region?.status) {
      OfflineRegionStatus.ready => Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            size: 18,
            color: AppColors.ahead,
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Offline map ready — works without a connection.',
            style: textTheme.bodySmall,
          ),
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

Future<void> _showExpandedMap(
  BuildContext context,
  Route route,
  List<Activity> attempts,
) async {
  final tracks = <List<GeoPoint>>[
    for (final a in attempts)
      if (a.track != null && a.track!.length >= 2)
        [for (final t in a.track!) t.position],
  ];
  await showDialog<void>(
    context: context,
    builder: (context) {
      final size = MediaQuery.of(context).size;
      return Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: SizedBox(
          width: size.width * 0.92,
          height: size.height * 0.78,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${route.name} — attempts',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter:
                            tracks.isNotEmpty && tracks.first.isNotEmpty
                            ? LatLng(
                                tracks.first.first.latitude,
                                tracks.first.first.longitude,
                              )
                            : (route.geometry.isNotEmpty
                                  ? LatLng(
                                      route.geometry.first.latitude,
                                      route.geometry.first.longitude,
                                    )
                                  : const LatLng(0, 0)),
                        initialZoom: 14,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName:
                              'dev.neurieder.against_yesterday',
                        ),
                        PolylineLayer(
                          polylines: [
                            Polyline(
                              points: [
                                for (final p in route.geometry)
                                  LatLng(p.latitude, p.longitude),
                              ],
                              strokeWidth: 3,
                              color: AppColors.ghost.withValues(alpha: 0.45),
                            ),
                          ],
                        ),
                        for (var i = 0; i < tracks.length; i++)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: [
                                  for (final p in tracks[i])
                                    LatLng(p.latitude, p.longitude),
                                ],
                                strokeWidth: 3,
                                color: attemptColor(i),
                              ),
                            ],
                          ),
                        const SimpleAttributionWidget(
                          source: Text('© OpenStreetMap contributors'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('Legend', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: AppSpacing.xs),
                Expanded(
                  flex: 0,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _LegendRow(
                            color: AppColors.ghost.withValues(alpha: 0.6),
                            label: 'Route',
                          ),
                          for (var i = 0; i < attempts.length; i++)
                            if (attempts[i].track != null &&
                                attempts[i].track!.length >= 2)
                              _LegendRow(
                                color: attemptColor(i),
                                label:
                                    '${dateLabelFor(attempts[i].startedAt.toLocal())}'
                                    ' · ${attempts[i].duration?.format() ?? '—'}',
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }
}

class SegmentComparisonSection extends ConsumerStatefulWidget {
  const SegmentComparisonSection({
    super.key,
    required this.route,
    required this.attempts,
  });

  final Route route;
  final List<Activity> attempts;

  @override
  ConsumerState<SegmentComparisonSection> createState() =>
      _SegmentComparisonSectionState();
}

class _SegmentComparisonSectionState
    extends ConsumerState<SegmentComparisonSection> {
  double _segmentDistance = 1000;
  bool _loading = false;
  List<RouteSegmentComparison>? _comparison;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void didUpdateWidget(covariant SegmentComparisonSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.route.id != widget.route.id ||
        oldWidget.attempts.length != widget.attempts.length) {
      _run();
    }
  }

  Future<void> _run() async {
    final engine = ref.read(engineServiceProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selected = widget.attempts.take(5).toList();
      final attempts = <Attempt>[];
      for (final a in selected) {
        if (a.track == null || a.track!.length < 2) continue;
        final att = await engine.createAttempt(
          activityId: a.id,
          routeId: widget.route.id,
          points: a.track!,
          routeGeometry: widget.route.geometry,
        );
        attempts.add(att);
      }
      if (attempts.length < 2) {
        setState(() {
          _comparison = null;
          _loading = false;
        });
        return;
      }
      final result = await engine.compareRouteSegments(
        attempts: attempts,
        segmentDistanceMeters: _segmentDistance,
        routeDistanceMeters: widget.route.distance.meters,
      );
      setState(() {
        _comparison = result;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Segment comparison',
          style: textTheme.titleMedium?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          children: [
            for (final d in const [500.0, 1000.0, 2000.0, 5000.0])
              ChoiceChip(
                label: Text(
                  d >= 1000
                      ? '${(d / 1000).toStringAsFixed(0)} km'
                      : '${d.toStringAsFixed(0)} m',
                ),
                selected: _segmentDistance == d,
                onSelected: (_) {
                  setState(() => _segmentDistance = d);
                  _run();
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(
            _error!,
            style: textTheme.bodySmall?.copyWith(color: AppColors.error),
          )
        else if (_comparison == null || _comparison!.isEmpty)
          Text(
            'Need at least two activities with tracks to compare.',
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
          )
        else
          _SegmentTable(comparison: _comparison!),
      ],
    );
  }
}

class _SegmentTable extends StatelessWidget {
  const _SegmentTable({required this.comparison});

  final List<RouteSegmentComparison> comparison;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: [
          const DataColumn(label: Text('Seg')),
          const DataColumn(label: Text('Start')),
          const DataColumn(label: Text('End')),
          for (var i = 0; i < comparison.first.segments.length; i++)
            DataColumn(label: Text('Run ${i + 1}')),
          const DataColumn(label: Text('Best')),
          const DataColumn(label: Text('Spread')),
        ],
        rows: [
          for (final c in comparison)
            DataRow(
              cells: [
                DataCell(Text('${c.index + 1}')),
                DataCell(Text('${c.startDistanceM.toStringAsFixed(0)}m')),
                DataCell(Text('${c.endDistanceM.toStringAsFixed(0)}m')),
                for (final s in c.segments)
                  DataCell(
                    Text(
                      s.durationSeconds > 0
                          ? '${(s.averageSpeedMps * 3.6).toStringAsFixed(1)} km/h'
                          : '—',
                    ),
                  ),
                DataCell(Text((c.maxSpeedMps * 3.6).toStringAsFixed(1))),
                DataCell(Text((c.speedSpreadMps * 3.6).toStringAsFixed(1))),
              ],
            ),
        ],
      ),
    );
  }
}
