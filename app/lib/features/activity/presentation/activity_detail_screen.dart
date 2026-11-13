// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Activity detail screen (§24, M11).
///
/// Reached by tapping an activity in History. Shows the same
/// layout as [ResultScreen] but reads persisted data from the repositories.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../app/dependencies.dart';
import '../../../core/ui/split_row.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../map/map_surface.dart';
import '../../map/route_map_autosave.dart';
import 'elevation_profile.dart';
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
    // The route, not this run's track, frames the activity map: all runs of
    // the course share the same saved map. The recorded track is overlaid when
    // there is one; a run without a track still shows the course.
    final routeGeometry = route?.geometry ?? const <GeoPoint>[];
    final runTrack = activity.track;
    final trackPositions = runTrack != null && runTrack.length >= 2
        ? [for (final p in runTrack) p.position]
        : const <GeoPoint>[];
    final useRouteBase = routeGeometry.length >= 2;
    final mapGeometry = useRouteBase ? routeGeometry : trackPositions;
    final overlayTrack =
        useRouteBase && trackPositions.length >= 2 ? trackPositions : const <GeoPoint>[];

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
        actions: [
          IconButton(
            key: const ValueKey('replay-activity'),
            icon: const Icon(Icons.replay_rounded),
            tooltip: 'Replay',
            onPressed: () => context.push('/activity/$activityId/replay'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        children: [
          if (route != null) RouteMapAutosave(route: route),
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
          // The recorded track on the map. Every run of a route draws the same
          // route geometry — the shared course map — with this run's track on
          // top, so switching between runs keeps the same ground underfoot.
          if (mapGeometry.length >= 2) ...[
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              height: 240,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: mapSurface.build(
                  context,
                  MapScene(
                    geometry: mapGeometry,
                    track: overlayTrack,
                    you: trackPositions.isNotEmpty
                        ? trackPositions.first
                        : mapGeometry.first,
                    youProgress: trackPositions.isEmpty ? 0 : 1,
                    staticView: true,
                  ),
                ),
              ),
            ),
          ],
          if (activity.track case final track? when track.any((p) => p.altitudeMeters != null)) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Elevation',
              style: textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            RepaintBoundary(child: ElevationProfile(track: track)),
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
          if (activity.track case final track? when track.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            TrackAnalyticsSection(track: track),
          ],
          // The raw recorded fixes, for anyone who wants the exact GPS output
          // behind the track: coordinates, local time and altitude when the
          // receiver reported it.
          if (activity.track case final track? when track.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            _RawGpsSection(points: track),
          ],
          const SizedBox(height: AppSpacing.lg),
          OutlinedButton.icon(
            key: const ValueKey('export-analysis'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(
                ClipboardData(
                  text: 'Distance: ${activity.distance?.formatWith(ref.read(displayUnitProvider)) ?? '—'}\n'
                      'Duration: ${activity.duration?.formatClock() ?? '—'}\n'
                      'Fixes: ${activity.track?.length ?? 0}',
                ),
              );
              messenger.showSnackBar(
                const SnackBar(content: Text('Analysis copied to clipboard.')),
              );
            },
            icon: const Icon(Icons.download_rounded),
            label: const Text('Export analysis'),
          ),
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

/// Engine-computed track analytics (M30): distance, time breakdown, pace,
/// speed, elevation and GPS quality. Rendered from `EngineService.analyzeTrack`
/// so fake and Rust engines agree.
class TrackAnalyticsSection extends ConsumerStatefulWidget {
  const TrackAnalyticsSection({super.key, required this.track});

  final List<TrackPoint> track;

  @override
  ConsumerState<TrackAnalyticsSection> createState() =>
      _TrackAnalyticsSectionState();
}

class _TrackAnalyticsSectionState
    extends ConsumerState<TrackAnalyticsSection> {
  late Future<TrackAnalytics> _future;

  @override
  void initState() {
    super.initState();
    _future = _analyze();
  }

  @override
  void didUpdateWidget(covariant TrackAnalyticsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track != widget.track) {
      _future = _analyze();
    }
  }

  Future<TrackAnalytics> _analyze() =>
      ref.read(engineServiceProvider).analyzeTrack(points: widget.track);

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Track analytics',
          style: textTheme.titleMedium?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        FutureBuilder<TrackAnalytics>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (snapshot.hasError || !snapshot.hasData) {
              return Text(
                'Analytics unavailable.',
                style: textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                ),
              );
            }
            final a = snapshot.data!;
            final units = ref.watch(displayUnitProvider);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _AnalyticsRow(
                  key: const ValueKey('analytics-distance'),
                  label: 'Distance',
                  value: Distance.meters(a.distanceMeters).formatWith(units),
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-elapsed'),
                  label: 'Elapsed time',
                  value: Elapsed.seconds(a.elapsedTimeMs / 1000.0).formatClock(),
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-moving'),
                  label: 'Moving time',
                  value: Elapsed.seconds(a.movingTimeMs / 1000.0).formatClock(),
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-paused'),
                  label: 'Paused time',
                  value: Elapsed.seconds(a.pausedTimeMs / 1000.0).formatClock(),
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-stopped'),
                  label: 'Stopped time',
                  value: Elapsed.seconds(a.stoppedTimeMs / 1000.0).formatClock(),
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-avg-pace'),
                  label: 'Average pace',
                  value: a.averagePaceMsPerKm == null
                      ? '—'
                      : '${Elapsed.seconds(a.averagePaceMsPerKm! / 1000.0).format()} /km',
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-best-pace'),
                  label: 'Best pace',
                  value: a.bestPaceMsPerKm == null
                      ? '—'
                      : '${Elapsed.seconds(a.bestPaceMsPerKm! / 1000.0).format()} /km',
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-avg-speed'),
                  label: 'Average speed',
                  value: a.averageSpeedMps == null
                      ? '—'
                      : '${(a.averageSpeedMps! * 3.6).toStringAsFixed(2)} km/h',
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-moving-speed'),
                  label: 'Moving speed',
                  value: a.movingSpeedMps == null
                      ? '—'
                      : '${(a.movingSpeedMps! * 3.6).toStringAsFixed(2)} km/h',
                ),
                _AnalyticsRow(
                  key: const ValueKey('analytics-max-speed'),
                  label: 'Max speed',
                  value: a.maxSpeedMps == null
                      ? '—'
                      : '${(a.maxSpeedMps! * 3.6).toStringAsFixed(2)} km/h',
                ),
                if (a.elevationGainMeters != null)
                  _AnalyticsRow(
                    key: const ValueKey('analytics-elev-gain'),
                    label: 'Elevation gain',
                    value: '${a.elevationGainMeters!.toStringAsFixed(1)} m',
                  ),
                if (a.elevationLossMeters != null)
                  _AnalyticsRow(
                    key: const ValueKey('analytics-elev-loss'),
                    label: 'Elevation loss',
                    value: '${a.elevationLossMeters!.toStringAsFixed(1)} m',
                  ),
                if (a.elevationMinMeters != null)
                  _AnalyticsRow(
                    key: const ValueKey('analytics-elev-min'),
                    label: 'Min elevation',
                    value: '${a.elevationMinMeters!.toStringAsFixed(1)} m',
                  ),
                if (a.elevationMaxMeters != null)
                  _AnalyticsRow(
                    key: const ValueKey('analytics-elev-max'),
                    label: 'Max elevation',
                    value: '${a.elevationMaxMeters!.toStringAsFixed(1)} m',
                  ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'GPS quality: ${a.quality.acceptedSamples} accepted, '
                  '${a.quality.rejectedSamples} rejected, '
                  '${(a.quality.coverageRatio * 100).toStringAsFixed(0)}% coverage, '
                  '${a.quality.gpsGapCount} gaps'
                  '${a.quality.hasSufficientDistance ? '' : ' (insufficient distance)'}'
                  '${a.quality.hasElevationData ? '' : ' (no elevation)'}',
                  style: textTheme.bodySmall?.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _AnalyticsRow extends StatelessWidget {
  const _AnalyticsRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
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
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              'GPS quality: ${points.length} fixes retained (raw fixes unchanged).',
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ),
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
              child: const Text('Back to Routes'),
            ),
          ],
        ),
      ),
    );
  }
}