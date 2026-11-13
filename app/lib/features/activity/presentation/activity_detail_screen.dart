// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Activity detail screen (§24, M11).
///
/// Reached by tapping an activity in History. Shows the same
/// layout as [ResultScreen] but reads persisted data from the repositories.
library;

import 'dart:convert';

import 'package:flutter/material.dart' hide Route;
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
import '../application/activity_analytics.dart';
import '../../result/application/gap_curve.dart';
import '../../result/application/splits.dart';
import '../../result/presentation/gap_chart.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/application/track_export.dart';

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
            _PaceMapSection(
              mapSurface: mapSurface,
              mapGeometry: mapGeometry,
              overlayTrack: overlayTrack,
              runTrack: runTrack,
              trackPositions: trackPositions,
              route: route,
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
          if (route != null && route.personalBest != null && trackMeters >= gapChartMinimumMeters) ...[
            const SizedBox(height: AppSpacing.xl),
            Text(
              'Gap to PB',
              style: textTheme.titleMedium?.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            GapChart(
              curve: computeGapCurve(
                activity: activity,
                route: route,
                trackMeters: trackMeters,
              ),
              units: units,
            ),
          ],
          if (activity.track case final track? when track.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            TrackAnalyticsSection(activityId: activity.id),
            const SizedBox(height: AppSpacing.xl),
            PaceDistributionSection(activityId: activity.id),
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
              final engine = ref.read(engineServiceProvider);
              final track = activity.track ?? const <TrackPoint>[];
              TrackAnalytics? analytics;
              try {
                analytics = await engine.analyzeTrack(points: track);
              } catch (_) {
                analytics = null;
              }
              final payload = <String, Object?>{
                'activityId': activity.id,
                'routeId': activity.routeId,
                'startedAt': activity.startedAt.toUtc().toIso8601String(),
                'distanceMeters': activity.distance?.meters,
                'durationSeconds': activity.duration?.seconds,
                'performance': activity.performance,
                'fixCount': track.length,
                'splits': [
                  for (final s in splits)
                    <String, Object?>{
                      'index': s.index,
                      'startDistanceM': s.startDistanceM,
                      'endDistanceM': s.endDistanceM,
                      'durationSeconds': s.durationSeconds,
                      'averageSpeedMps': s.averageSpeedMps,
                    },
                ],
                if (analytics != null)
                  'analytics': <String, Object?>{
                    'distanceMeters': analytics.distanceMeters,
                    'elapsedTimeMs': analytics.elapsedTimeMs,
                    'movingTimeMs': analytics.movingTimeMs,
                    'pausedTimeMs': analytics.pausedTimeMs,
                    'stoppedTimeMs': analytics.stoppedTimeMs,
                    'averagePaceMsPerKm': analytics.averagePaceMsPerKm,
                    'averageSpeedMps': analytics.averageSpeedMps,
                    'movingSpeedMps': analytics.movingSpeedMps,
                    'maxSpeedMps': analytics.maxSpeedMps,
                    'bestPaceMsPerKm': analytics.bestPaceMsPerKm,
                    'elevationGainMeters': analytics.elevationGainMeters,
                    'elevationLossMeters': analytics.elevationLossMeters,
                    'elevationMinMeters': analytics.elevationMinMeters,
                    'elevationMaxMeters': analytics.elevationMaxMeters,
                    'quality': <String, Object?>{
                      'acceptedSamples': analytics.quality.acceptedSamples,
                      'rejectedSamples': analytics.quality.rejectedSamples,
                      'coverageRatio': analytics.quality.coverageRatio,
                      'gpsGapCount': analytics.quality.gpsGapCount,
                      'hasSufficientDistance':
                          analytics.quality.hasSufficientDistance,
                      'hasElevationData': analytics.quality.hasElevationData,
                    },
                  },
                'exportedAt': DateTime.now().toUtc().toIso8601String(),
              };
              final contents =
                  const JsonEncoder.withIndent('  ').convert(payload);
              final fileName =
                  'against-yesterday-analysis-${activity.id}.json';
              try {
                await ref.read(trackExporterProvider).saveToDownloads(
                      fileName: fileName,
                      contents: contents,
                    );
                messenger.showSnackBar(
                  SnackBar(content: Text('Saved $fileName to Downloads.')),
                );
              } on TrackExportException catch (error) {
                await Clipboard.setData(ClipboardData(text: contents));
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      'Exported to clipboard (Downloads unavailable: '
                      '${error.message}).',
                    ),
                  ),
                );
              }
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
/// speed, elevation and GPS quality. Rendered from the cached
/// `trackAnalyticsProvider` so fake and Rust engines agree and repeated views
/// reuse one result.
class TrackAnalyticsSection extends ConsumerWidget {
  const TrackAnalyticsSection({super.key, required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final async = ref.watch(trackAnalyticsProvider(activityId));
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
        async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Text(
            'Analytics unavailable.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          data: (a) {
            if (a == null) {
              return Text(
                'Analytics unavailable.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              );
            }
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
                  key: const ValueKey('analytics-smoothed-pace'),
                  label: 'Smoothed pace (engine)',
                  value: a.smoothedBestPaceMsPerKm == null
                      ? (a.paceSamples.length < 5
                          ? '—'
                          : '${Elapsed.seconds(_smoothedPace(a.paceSamples) / 1000.0).format()} /km')
                      : '${Elapsed.seconds(a.smoothedBestPaceMsPerKm! / 1000.0).format()} /km',
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

/// Pace distribution derived from the engine's pace samples.
class PaceDistributionSection extends ConsumerWidget {
  const PaceDistributionSection({super.key, required this.activityId});

  final String activityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final textTheme = Theme.of(context).textTheme;
    final async = ref.watch(trackAnalyticsProvider(activityId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Pace distribution',
          style: textTheme.titleMedium?.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        async.when(
          loading: () => const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: CircularProgressIndicator(),
            ),
          ),
          error: (e, _) => Text(
            'Pace distribution unavailable.',
            style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          data: (analytics) {
            if (analytics == null) {
              return Text(
                'Pace distribution unavailable.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              );
            }
            final samples = analytics.paceSamples;
            if (samples.isEmpty) {
              return Text(
                'No pace samples.',
                style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              );
            }
            // Buckets in min/km: <5, 5-6, 6-7, 7-8, >8
            final buckets = <String, int>{
              '<5:00': 0,
              '5-6:00': 0,
              '6-7:00': 0,
              '7-8:00': 0,
              '>8:00': 0,
            };
            for (final s in samples) {
              final minPerKm = s.paceMsPerKm / 60000.0;
              if (minPerKm < 5) {
                buckets['<5:00'] = buckets['<5:00']! + 1;
              } else if (minPerKm < 6) {
                buckets['5-6:00'] = buckets['5-6:00']! + 1;
              } else if (minPerKm < 7) {
                buckets['6-7:00'] = buckets['6-7:00']! + 1;
              } else if (minPerKm < 8) {
                buckets['7-8:00'] = buckets['7-8:00']! + 1;
              } else {
                buckets['>8:00'] = buckets['>8:00']! + 1;
              }
            }
            final maxCount = buckets.values.reduce((a, b) => a > b ? a : b);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final entry in buckets.entries)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            height: maxCount == 0
                                ? 4
                                : (entry.value / maxCount * 80).clamp(4.0, 80.0),
                            decoration: BoxDecoration(
                              color: AppColors.you,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.key,
                            style: textTheme.labelSmall?.copyWith(
                              color: AppColors.textMuted,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          Text(
                            '${entry.value}',
                            style: textTheme.labelSmall,
                          ),
                        ],
                      ),
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

List<Color> _paceTrackColors(List<TrackPoint> track) {
  if (track.length < 2) return const [];
  final colors = <Color>[];
  for (var i = 0; i < track.length - 1; i++) {
    final a = track[i];
    final b = track[i + 1];
    final dist = haversineMeters(a.position, b.position);
    final secs = b.timestamp.difference(a.timestamp).inMilliseconds / 1000.0;
    double paceMinPerKm = double.infinity;
    if (dist > 0 && secs > 0) {
      paceMinPerKm = (secs / dist) * 1000.0 / 60.0;
    }
    Color c;
    if (paceMinPerKm < 5) {
      c = AppColors.ahead;
    } else if (paceMinPerKm < 6) {
      c = AppColors.track;
    } else if (paceMinPerKm < 7) {
      c = AppColors.behind;
    } else {
      c = AppColors.gpsWarning;
    }
    colors.add(c);
  }
  return colors;
}
class _PaceMapSection extends StatefulWidget {
  const _PaceMapSection({
    required this.mapSurface,
    required this.mapGeometry,
    required this.overlayTrack,
    required this.runTrack,
    required this.trackPositions,
    required this.route,
  });

  final MapSurface mapSurface;
  final List<GeoPoint> mapGeometry;
  final List<GeoPoint> overlayTrack;
  final List<TrackPoint>? runTrack;
  final List<GeoPoint> trackPositions;
  final Route? route;

  @override
  State<_PaceMapSection> createState() => _PaceMapSectionState();
}

class _PaceMapSectionState extends State<_PaceMapSection> {
  bool _showGap = false;

  List<Color>? _colors() {
    final track = widget.runTrack;
    if (track == null || track.length < 2 || widget.overlayTrack.length < 2) {
      return null;
    }
    if (_showGap) {
      final pb = widget.route?.personalBest;
      if (pb == null || widget.route == null) return _paceTrackColors(track);
      final totalDist = widget.route!.distance.meters;
      if (totalDist <= 0) return _paceTrackColors(track);
      final colors = <Color>[];
      double cumDist = 0;
      for (var i = 0; i < track.length - 1; i++) {
        final a = track[i];
        final b = track[i + 1];
        final segDist = haversineMeters(a.position, b.position);
        final midDist = cumDist + segDist / 2;
        cumDist += segDist;
        final curElapsed =
            b.timestamp.difference(track.first.timestamp).inMilliseconds /
                1000.0;
        final pbElapsed = pb.seconds * (midDist / totalDist);
        colors.add(curElapsed <= pbElapsed ? AppColors.ahead : AppColors.behind);
      }
      return colors;
    }
    return _paceTrackColors(track);
  }

  @override
  Widget build(BuildContext context) {
    final hasPb = widget.route?.personalBest != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasPb)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Pace')),
                ButtonSegment(value: true, label: Text('vs PB')),
              ],
              selected: {_showGap},
              onSelectionChanged: (s) => setState(() => _showGap = s.first),
            ),
          ),
        SizedBox(
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: widget.mapSurface.build(
              context,
              MapScene(
                geometry: widget.mapGeometry,
                track: widget.overlayTrack,
                trackColors: _colors(),
                you: widget.trackPositions.isNotEmpty
                    ? widget.trackPositions.first
                    : widget.mapGeometry.first,
                youProgress: widget.trackPositions.isEmpty ? 0 : 1,
                staticView: true,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

double _smoothedPace(List<({double distanceMeters, int paceMsPerKm})> samples) {
  final window = 5;
  var best = double.infinity;
  for (var i = window - 1; i < samples.length; i++) {
    var sum = 0.0;
    for (var j = i - window + 1; j <= i; j++) {
      sum += samples[j].paceMsPerKm;
    }
    final avg = sum / window;
    if (avg < best) best = avg;
  }
  return best.isFinite ? best : samples.map((s) => s.paceMsPerKm.toDouble()).reduce((a, b) => a < b ? a : b);
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