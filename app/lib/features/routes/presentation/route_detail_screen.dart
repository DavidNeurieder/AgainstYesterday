// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route detail screen (§23, M12).
///
/// Route map, headline summary, RACE YOUR BEST, and every run recorded on
/// this course — sortable by date or performance time. The numeric
/// breakdown and the performance chart live on the statistics page so this
/// screen stays about choosing a run. Read-only projection of the two
/// repositories.
library;

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
import '../../map/map_surface.dart';
import '../../map/offline_region_repository.dart';
import '../../map/offline_regions.dart';
import '../../map/route_map_autosave.dart';
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
      appBar: AppBar(
        title: Text(route.name),
        actions: [
          IconButton(
            key: const ValueKey('route-statistics'),
            tooltip: 'Statistics',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () {
              AppHaptics.selection(ref);
              context.push('/route/${route.id}/statistics');
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          // Opening the route saves its map locally; every run of the course
          // then shares it. The offline card below reports/retries the state.
          RouteMapAutosave(route: route),
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
          // The run history replaces the old stats block: the start button
          // leads straight into the runs you can inspect or replay.
          RunsSection(attempts: attempts, pb: stats.pb),
        ],
      ),
    );
  }
}

/// How the run list is ordered.
enum RunSort {
  /// Most recent run first.
  date,

  /// Fastest run first.
  time,
}

/// Every timed run recorded on this route — the list that replaced the
/// aggregate stats block under the start button.
class RunsSection extends StatefulWidget {
  const RunsSection({super.key, required this.attempts, this.pb});

  final List<Activity> attempts;
  final Elapsed? pb;

  @override
  State<RunsSection> createState() => _RunsSectionState();
}

class _RunsSectionState extends State<RunsSection> {
  RunSort _sort = RunSort.date;

  List<Activity> get _sorted {
    final runs = [...widget.attempts];
    if (_sort == RunSort.time) {
      runs.sort((a, b) {
        final byTime = (a.duration?.seconds ?? double.infinity).compareTo(
          b.duration?.seconds ?? double.infinity,
        );
        return byTime != 0 ? byTime : b.startedAt.compareTo(a.startedAt);
      });
    } else {
      runs.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    }
    return runs;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final runs = _sorted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // §7: at a large font scale the sort control wraps under the header
        // instead of squeezing the two segments.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            Text(
              'Runs',
              style: textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            SegmentedButton<RunSort>(
              key: const ValueKey('runs-sort'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                  value: RunSort.date,
                  label: Text('Date'),
                  icon: Icon(Icons.calendar_today_outlined, size: 16),
                ),
                ButtonSegment(
                  value: RunSort.time,
                  label: Text('Time'),
                  icon: Icon(Icons.timer_outlined, size: 16),
                ),
              ],
              selected: {_sort},
              onSelectionChanged: (selection) {
                setState(() => _sort = selection.first);
              },
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (runs.isEmpty)
          Text(
            'No runs on this route yet.',
            style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
          )
        else
          for (final run in runs)
            _RunRow(
              key: ValueKey('run-${run.id}'),
              attempt: run,
              pb: widget.pb,
            ),
      ],
    );
  }
}

class _RunRow extends ConsumerWidget {
  const _RunRow({super.key, required this.attempt, this.pb});

  final Activity attempt;
  final Elapsed? pb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final duration = attempt.duration!;
    final delta = pb == null ? null : duration.seconds - pb!.seconds;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        AppHaptics.light(ref);
        context.push('/activity/${attempt.id}');
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
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
            const SizedBox(width: AppSpacing.xs),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
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
      label: const Text('Save offline map'),
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
      key: ValueKey('retry-offline-$routeId'),
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
              child: const Text('Back to Routes'),
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
