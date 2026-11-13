// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Per-segment comparison of the recent runs on one route (§23).
///
/// Live only on the route statistics page now: it asks the engine to reduce
/// each attempt to the route axis, then compares equal-distance splits.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../engine/engine_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../engine/models.dart';

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
      String? firstError;
      for (final a in selected) {
        if (a.track == null || a.track!.length < 2) continue;
        final sanitized = _monotonicTrack(a.track!);
        try {
          final att = await engine.createAttempt(
            activityId: a.id,
            routeId: widget.route.id,
            points: sanitized,
            routeGeometry: widget.route.geometry,
          );
          attempts.add(att);
          continue;
        } catch (_) {
          // Fall through to synthetic timeline.
        }
        final synthetic = [
          for (var i = 0; i < sanitized.length; i++)
            TrackPoint(
              position: sanitized[i].position,
              altitudeMeters: sanitized[i].altitudeMeters,
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                i * 1000,
                isUtc: true,
              ),
            ),
        ];
        try {
          final att = await engine.createAttempt(
            activityId: a.id,
            routeId: widget.route.id,
            points: synthetic,
            routeGeometry: widget.route.geometry,
          );
          attempts.add(att);
        } catch (e) {
          firstError ??= '${a.id}: $e';
        }
      }
      if (attempts.length < 2) {
        setState(() {
          _comparison = null;
          _loading = false;
          _error = firstError;
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

/// Ensures a track's timestamps are non-decreasing so the Rust engine's
/// `Track` validation accepts them. Non-monotonic (or sentinel) timestamps
/// are replaced with a synthetic one-second cadence, preserving positions.
List<TrackPoint> _monotonicTrack(List<TrackPoint> points) {
  var monotonic = true;
  for (var i = 1; i < points.length; i++) {
    if (points[i].timestamp.isBefore(points[i - 1].timestamp)) {
      monotonic = false;
      break;
    }
  }
  if (monotonic) return points;
  final start = points.first.timestamp;
  return [
    for (var i = 0; i < points.length; i++)
      TrackPoint(
        position: points[i].position,
        altitudeMeters: points[i].altitudeMeters,
        timestamp: start.add(Duration(seconds: i)),
      ),
  ];
}

/// Builds engine [Attempt]s from a selection of activities on [route], using the
/// same monotonic-timestamp sanitising as the segment comparison. Returns an
/// empty list when fewer than two usable attempts exist.
Future<List<Attempt>> buildRouteAttempts({
  required EngineService engine,
  required Route route,
  required List<Activity> selected,
}) async {
  final attempts = <Attempt>[];
  for (final a in selected) {
    if (a.track == null || a.track!.length < 2) continue;
    final sanitized = _monotonicTrack(a.track!);
    try {
      final att = await engine.createAttempt(
        activityId: a.id,
        routeId: route.id,
        points: sanitized,
        routeGeometry: route.geometry,
      );
      attempts.add(att);
      continue;
    } catch (_) {}
    final synthetic = [
      for (var i = 0; i < sanitized.length; i++)
        TrackPoint(
          position: sanitized[i].position,
          altitudeMeters: sanitized[i].altitudeMeters,
          timestamp: sanitized.first.timestamp.add(Duration(seconds: i)),
        ),
    ];
    try {
      final att = await engine.createAttempt(
        activityId: a.id,
        routeId: route.id,
        points: synthetic,
        routeGeometry: route.geometry,
      );
      attempts.add(att);
    } catch (_) {}
  }
  return attempts;
}

/// Head-to-head comparison of two attempts on one route.
class HeadToHeadSection extends ConsumerStatefulWidget {
  const HeadToHeadSection({
    super.key,
    required this.route,
    required this.attempts,
  });

  final Route route;
  final List<Activity> attempts;

  @override
  ConsumerState<HeadToHeadSection> createState() =>
      _HeadToHeadSectionState();
}

class _HeadToHeadSectionState extends ConsumerState<HeadToHeadSection> {
  Activity? _a;
  Activity? _b;
  bool _loading = false;
  List<RouteSegmentComparison>? _comparison;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.attempts.length >= 2) {
      _a = widget.attempts.first;
      _b = widget.attempts[1];
    }
    _run();
  }

  @override
  void didUpdateWidget(covariant HeadToHeadSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attempts.length != widget.attempts.length) {
      if (widget.attempts.length >= 2) {
        _a = widget.attempts.first;
        _b = widget.attempts.length > 1 ? widget.attempts[1] : null;
      }
      _run();
    }
  }

  Future<void> _run() async {
    if (_a == null || _b == null) return;
    final engine = ref.read(engineServiceProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final atts = await buildRouteAttempts(
        engine: engine,
        route: widget.route,
        selected: [_a!, _b!],
      );
      if (atts.length < 2) {
        setState(() {
          _comparison = null;
          _loading = false;
          _error = 'Need two usable attempts.';
        });
        return;
      }
      final result = await engine.compareRouteSegments(
        attempts: atts,
        segmentDistanceMeters: 1000,
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
    if (widget.attempts.length < 2) {
      return Text(
        'Need at least two attempts to compare.',
        style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Head to head', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: DropdownButton<Activity>(
                value: _a,
                isExpanded: true,
                items: [
                  for (final a in widget.attempts)
                    DropdownMenuItem(value: a, child: Text(_label(a))),
                ],
                onChanged: (v) {
                  setState(() => _a = v);
                  _run();
                },
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: DropdownButton<Activity>(
                value: _b,
                isExpanded: true,
                items: [
                  for (final a in widget.attempts)
                    DropdownMenuItem(value: a, child: Text(_label(a))),
                ],
                onChanged: (v) {
                  setState(() => _b = v);
                  _run();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_loading)
          const Center(child: CircularProgressIndicator())
        else if (_error != null)
          Text(_error!, style: textTheme.bodySmall?.copyWith(color: AppColors.error))
        else if (_comparison == null || _comparison!.isEmpty)
          Text('No comparison available.',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted))
        else
          _SegmentTable(comparison: _comparison!),
      ],
    );
  }

  String _label(Activity a) {
    final d = a.startedAt.toLocal();
    return '${d.day}/${d.month} ${a.duration?.format() ?? ''}'.trim();
  }
}
