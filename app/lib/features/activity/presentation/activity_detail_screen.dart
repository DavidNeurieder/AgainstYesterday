// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Activity detail screen (§24, M11).
///
/// Reached by tapping an activity in Home's recent list. Shows the same
/// layout as [ResultScreen] but reads persisted data from the repositories.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/split_row.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../map/map_surface.dart';
import '../../result/application/splits.dart';
import '../../settings/application/settings_controller.dart';

class ActivityDetailScreen extends ConsumerWidget {
  const ActivityDetailScreen({super.key, required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activities = ref.watch(activityRepositoryProvider);
    final matches = activities.where((a) => a.id == activityId);
    if (matches.isEmpty) {
      return _NotFoundScreen(activityId: activityId);
    }
    final activity = matches.first;

    final textTheme = Theme.of(context).textTheme;
    final units = ref.watch(displayUnitProvider);
    final mapSurface = ref.watch(mapSurfaceProvider);
    final routeId = activity.routeId;
    final routes = ref.watch(routeRepositoryProvider);
    final route = routeId != null
        ? routes.where((r) => r.id == routeId).firstOrNull
        : null;
    final routeName = route?.name ?? 'New route';

    final distance = activity.distance;
    final duration = activity.duration;
    final trackMeters = distance?.meters ?? 0;

    final splits = (route != null && trackMeters > 0)
        ? computeSplits(
            activity: activity,
            route: route,
            trackMeters: trackMeters,
          )
        : [];

    return Scaffold(
      appBar: AppBar(
        title: Text(routeName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        children: [
          Text(
            routeName,
            textAlign: TextAlign.center,
            style: textTheme.titleLarge?.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            duration?.formatClock() ?? '—',
            textAlign: TextAlign.center,
            style: textTheme.displayMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            distance?.formatWith(units) ?? '—',
            textAlign: TextAlign.center,
            style: textTheme.headlineSmall?.copyWith(
              color: AppColors.textSecondary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (activity.performance case final perf?)
            Text(
              perf,
              textAlign: TextAlign.center,
              style: textTheme.bodyLarge?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          // The recorded track on the map: the whole run shown static, fitted
          // to the viewport, through whichever renderer the build selected
          // (painter fallback on host/tests, MapLibre on device).
          if (activity.track case final track? when track.length >= 2) ...[
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              height: 240,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: mapSurface.build(
                  context,
                  MapScene(
                    geometry: [for (final p in track) p.position],
                    you: track.first.position,
                    youProgress: 1,
                    staticView: true,
                  ),
                ),
              ),
            ),
          ],
          if (splits.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Splits',
              style: textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final split in splits)
              SplitRow(split: split),
          ],
          // The raw recorded fixes, for anyone who wants the exact GPS output
          // behind the track: coordinates, local time and altitude when the
          // receiver reported it.
          if (activity.track case final track? when track.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            _RawGpsSection(points: track),
          ],
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Run on ${_formatDate(activity.startedAt)}',
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _formatDate(DateTime dt) {
  final d = dt.toLocal();
  return '${d.day}/${d.month}/${d.year}';
}

/// One persisted raw GPS fix, formatted as a plain coordinate line.
String _fixToLine(TrackPoint p) {
  final position = p.position;
  final altitude = p.altitudeMeters;
  return '${position.latitude.toStringAsFixed(6)}, '
      '${position.longitude.toStringAsFixed(6)}, '
      '${p.timestamp.toUtc().toIso8601String()}'
      '${altitude == null ? '' : ', ${altitude.toStringAsFixed(1)} m'}';
}

/// Collapsible raw GPS readout on the activity detail screen.
///
/// Lists every recorded fix (lat/lon, local time, altitude when the receiver
/// reported it) in a bounded scroller so a multi-thousand-point run stays
/// cheap, and offers the whole track as copied text — one comma-separated
/// line per fix, UTC timestamps — for pasting into a map tool or tracker.
class _RawGpsSection extends StatefulWidget {
  const _RawGpsSection({required this.points});

  final List<TrackPoint> points;

  @override
  State<_RawGpsSection> createState() => _RawGpsSectionState();
}

class _RawGpsSectionState extends State<_RawGpsSection> {
  Future<void> _copyCoordinates() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(
      ClipboardData(
        text: [for (final p in widget.points) _fixToLine(p)].join('\n'),
      ),
    );
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Raw coordinates copied to clipboard.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final points = widget.points;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: const ValueKey('raw-gps-section'),
        title: Text(
          'Raw GPS',
          style: textTheme.titleMedium,
        ),
        subtitle: Text(
          '${points.length} ${points.length == 1 ? 'fix' : 'fixes'}',
          style: textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
        ),
        childrenPadding: const EdgeInsets.only(bottom: AppSpacing.sm),
        children: [
          SizedBox(
            height: 260,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: points.length,
              itemBuilder: (context, index) {
                final p = points[index];
                final position = p.position;
                final altitude = p.altitudeMeters;
                final time = p.timestamp.toLocal();
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 4,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 40,
                        child: Text(
                          '${index + 1}.',
                          style: textTheme.bodySmall?.copyWith(
                            color: AppColors.textMuted,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${position.latitude.toStringAsFixed(6)}, '
                              '${position.longitude.toStringAsFixed(6)}',
                              style: textTheme.bodyMedium?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            Text(
                              '${time.hour.toString().padLeft(2, '0')}:'
                              '${time.minute.toString().padLeft(2, '0')}:'
                              '${time.second.toString().padLeft(2, '0')}'
                              '${altitude == null ? '' : ' · ${altitude.toStringAsFixed(1)} m'}',
                              style: textTheme.bodySmall?.copyWith(
                                color: AppColors.textSecondary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const ValueKey('copy-raw-gps'),
                onPressed: _copyCoordinates,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: const Text('Copy coordinates'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen({required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Activity')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              'Activity not found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              activityId,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
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