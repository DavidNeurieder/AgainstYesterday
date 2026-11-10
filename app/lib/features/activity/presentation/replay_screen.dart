// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Activity replay screen — feels like a real recording.
///
/// Rust owns replay time and derived state (fed through the engine, including
/// the ghost/ahead-behind comparison); Flutter owns presentation and user
/// interaction (ticker, map, controls). The HUD reuses the same race widgets as
/// the live run.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/units.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import '../../map/map_surface.dart';
import '../../recording/application/ghost_profile.dart';
import '../../recording/presentation/race_hud.dart';
import '../../settings/application/settings_controller.dart';

class ReplayScreen extends ConsumerStatefulWidget {
  const ReplayScreen({super.key, required this.activityId});

  final String activityId;

  @override
  ConsumerState<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends ConsumerState<ReplayScreen>
    with SingleTickerProviderStateMixin {
  ReplayHandle? _handle;
  ReplaySnapshot? _snapshot;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  String? _error;
  bool _loading = true;
  bool _seeking = false;
  bool _showAnalysis = false;

  Route? _route;
  List<GeoPoint> _geometry = const [];
  List<TrackPoint>? _activityTrack;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _init();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _handle?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final activities = ref.read(activityRepositoryProvider);
      final match = activities.where((a) => a.id == widget.activityId);
      if (match.isEmpty) {
        setState(() {
          _error = 'Activity not found.';
          _loading = false;
        });
        return;
      }
      final activity = match.first;

      var fixes = activity.rawFixes;
      if (fixes == null || fixes.isEmpty) {
        final track = activity.track;
        if (track != null && track.isNotEmpty) {
          fixes = [
            for (final p in track)
              GpsFix(
                timestamp: p.timestamp,
                latitude: p.position.latitude,
                longitude: p.position.longitude,
                altitudeMeters: p.altitudeMeters,
              ),
          ];
        }
      }
      if (fixes == null || fixes.length < 2) {
        setState(() {
          _error = 'This activity has no replayable GPS data.';
          _loading = false;
        });
        return;
      }

      Route? route;
      List<GeoPoint>? routeGeometry;
      final routeId = activity.routeId;
      if (routeId != null) {
        final routes = ref.read(routeRepositoryProvider);
        final routeMatch = routes.where((r) => r.id == routeId);
        if (routeMatch.isNotEmpty) {
          route = routeMatch.first;
          routeGeometry = route.geometry;
        }
      }

      // Prefer the route's geometry for the race view; fall back to the
      // recorded track so free runs still draw a course.
      var geometry = routeGeometry ?? const <GeoPoint>[];
      if (geometry.length < 2) {
        if (activity.track case final track? when track.length >= 2) {
          geometry = [for (final p in track) p.position];
        } else {
          geometry = [
            for (final f in fixes)
              GeoPoint(latitude: f.latitude, longitude: f.longitude),
          ];
        }
      }

      final engine = ref.read(engineServiceProvider);

      List<AttemptSample>? ghostSamples;
      if (route?.personalBest case final pb?) {
        final fastest = fastestActivityForRoute(activities, route!.id);
        try {
          ghostSamples = await buildGhostSamples(
            engine: engine,
            route: route,
            pb: pb,
            fastestActivity: fastest,
          );
        } catch (_) {
          ghostSamples = null;
        }
      }

      final handle = await engine.createReplay(
        fixes: fixes,
        routeGeometry: routeGeometry,
        ghostSamples: ghostSamples,
      );
      if (!mounted) {
        handle.dispose();
        return;
      }
      final persistedSpeed = ref.read(replaySpeedProvider);
      handle.setSpeed(persistedSpeed);
      final snap = handle.snapshot();
      setState(() {
        _route = route;
        _geometry = geometry;
        _activityTrack = activity.track;
        _handle = handle;
        _snapshot = snap;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Replay could not start: $e';
          _loading = false;
        });
      }
    }
  }

  void _onTick(Duration elapsed) {
    final handle = _handle;
    if (handle == null || _seeking) return;
    final delta = (elapsed - _lastTick).inMicroseconds / 1000000.0;
    _lastTick = elapsed;
    if (delta <= 0 || delta > 1.0) {
      // Drop jumps (background/resume, ticker restart) without accumulating.
      return;
    }
    final snap = handle.advance(delta);
    if (mounted) {
      setState(() => _snapshot = snap);
      if (snap.finished) _ticker?.stop();
    }
  }

  void _togglePlay() {
    final handle = _handle;
    final snap = _snapshot;
    if (handle == null || snap == null) return;
    if (snap.state == ReplayState.playing) {
      handle.pause();
      _ticker?.stop();
      setState(() => _snapshot = handle.snapshot());
    } else {
      handle.play();
      _lastTick = Duration.zero;
      _ticker?.start();
      setState(() => _snapshot = handle.snapshot());
    }
  }

  void _seek(double seconds) {
    final handle = _handle;
    if (handle == null) return;
    handle.seek(seconds);
    setState(() => _snapshot = handle.snapshot());
  }

  void _setSpeed(double speed) {
    final handle = _handle;
    if (handle == null) return;
    handle.setSpeed(speed);
    final repo = ref.read(settingsRepositoryProvider.notifier);
    final current = ref.read(settingsRepositoryProvider);
    repo.save(current.copyWith(replaySpeed: speed));
    setState(() => _snapshot = handle.snapshot());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title()),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back',
          onPressed: () => context.pop(),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: AppSpacing.md),
            child: _ReplayPill(),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  String _title() {
    if (_route case final route?) return route.name;
    final activities = ref.watch(activityRepositoryProvider);
    final match = activities.where((a) => a.id == widget.activityId);
    if (match.isEmpty) return 'Replay';
    final routeId = match.first.routeId;
    if (routeId == null) return 'Replay';
    final routes = ref.watch(routeRepositoryProvider);
    final r = routes.where((x) => x.id == routeId);
    return r.isEmpty ? 'Replay' : r.first.name;
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error case final err?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            err,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyLarge
                ?.copyWith(color: AppColors.textSecondary),
          ),
        ),
      );
    }
    final snap = _snapshot;
    if (snap == null) return const Center(child: Text('No replay data.'));
    return _buildRace(context, snap);
  }

  Widget _buildRace(BuildContext context, ReplaySnapshot snap) {
    final units = ref.watch(displayUnitProvider);
    final mapSurface = ref.watch(mapSurfaceProvider);
    final textTheme = Theme.of(context).textTheme;
    final distance = Distance.meters(snap.distanceMeters);
    final pace = Speed.metersPerSecond(snap.paceMps);
    final moving = Elapsed.seconds(snap.movingSeconds);

    // The engine orients the route to the recorded direction and reports it;
    // draw and place the ghost along the same axis.
    final geometry = snap.reversed
        ? _geometry.reversed.toList(growable: false)
        : _geometry;

    // The actual recorded path, revealed up to the current replay point so a
    // run that diverged from the planned course is still visible.
    List<GeoPoint> trackGeometry = const [];
    final trackPoints = _activityTrack;
    if (_route != null && trackPoints != null && trackPoints.length >= 2) {
      final n = snap.appliedFixes.clamp(0, trackPoints.length);
      trackGeometry = [for (final p in trackPoints.take(n)) p.position];
      if (trackGeometry.length < 2) trackGeometry = const [];
    }

    GeoPoint? ghostPosition;
    final ghost = snap.ghost;
    if (ghost != null && geometry.length >= 2) {
      ghostPosition = pointAlongPolyline(geometry, ghost.ghostDistanceMeters);
    }
    final you = snap.position ??
        ghostPosition ??
        (geometry.isNotEmpty ? geometry.first : null);

    final offRoute = snap.offRouteMeters == null
        ? null
        : Distance.meters(snap.offRouteMeters!);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RaceHeroRow(
              distance: distance,
              units: units,
              ghostGap: snap.ghostGap,
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  (you != null && geometry.isNotEmpty)
                      ? mapSurface.build(
                          context,
                          MapScene(
                            geometry: geometry,
                            you: you,
                            youProgress: snap.routeProgress,
                            ghost: ghostPosition,
                            name: _route?.name,
                            courseColor: AppColors.pb,
                            track: trackGeometry,
                          ),
                        )
                      : const Center(child: Text('No map data.')),
                  if (offRoute case final Distance d)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHigh.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            'OFF ROUTE · ${d.format()} away',
                            style: textTheme.labelSmall?.copyWith(
                              color: AppColors.gpsWarning,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: HudMetric(
                      label: 'PACE',
                      value: pace.formatPaceWith(units),
                    ),
                  ),
                  Expanded(
                    child: HudMetric(
                      label: 'TIME',
                      value: moving.format(),
                      prominent: true,
                    ),
                  ),
                  Expanded(
                    child: HudMetric(
                      key: const ValueKey('replay-fixes'),
                      label: 'FIXES',
                      value: '${snap.appliedFixes}',
                    ),
                  ),
                ],
              ),
            ),
            _ReplayControls(
              snapshot: snap,
              showAnalysis: _showAnalysis,
              onToggle: _togglePlay,
              onToggleAnalysis: () => setState(() => _showAnalysis = !_showAnalysis),
              onSeekStart: () => _seeking = true,
              onSeekEnd: (v) {
                _seeking = false;
                _seek(v);
              },
              onSpeed: _setSpeed,
            ),
            if (_showAnalysis)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Analysis: ${snap.elapsedSeconds.toStringAsFixed(1)} s / '
                  '${snap.distanceMeters.toStringAsFixed(1)} m',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReplayPill extends StatelessWidget {
  const _ReplayPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.you.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.replay_rounded, size: 14, color: AppColors.you),
          const SizedBox(width: 4),
          Text(
            'REPLAY',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: AppColors.you,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _ReplayControls extends StatelessWidget {
  const _ReplayControls({
    required this.snapshot,
    required this.showAnalysis,
    required this.onToggle,
    required this.onToggleAnalysis,
    required this.onSeekStart,
    required this.onSeekEnd,
    required this.onSpeed,
  });

  final ReplaySnapshot snapshot;
  final bool showAnalysis;
  final VoidCallback onToggle;
  final VoidCallback onToggleAnalysis;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onSpeed;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final playing = snapshot.state == ReplayState.playing;
    final total = snapshot.totalSeconds.isFinite ? snapshot.totalSeconds : 0.0;
    final elapsed =
        snapshot.elapsedSeconds.clamp(0.0, total > 0 ? total : 0.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${Elapsed.seconds(elapsed).formatClock()} / ${Elapsed.seconds(total).formatClock()}',
              style: textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              '${snapshot.appliedFixes}/${snapshot.totalFixes} fixes',
              style: textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ),
        Slider(
          key: const ValueKey('replay-seek'),
          value: elapsed,
          min: 0,
          max: total > 0 ? total : 1,
          onChangeStart: (_) => onSeekStart(),
          onChanged: total > 0 ? (_) {} : null,
          onChangeEnd: total > 0 ? onSeekEnd : null,
        ),
        Row(
          children: [
            IconButton.filledTonal(
              key: const ValueKey('replay-toggle'),
              onPressed: onToggle,
              tooltip: playing ? 'Pause' : 'Play',
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'Speed',
              style:
                  textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(width: AppSpacing.xs),
            IconButton.filledTonal(
              key: const ValueKey('replay-analysis'),
              onPressed: onToggleAnalysis,
              tooltip: 'Analysis',
              icon: Icon(
                showAnalysis ? Icons.analytics : Icons.analytics_outlined,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            DropdownButton<double>(
              key: const ValueKey('replay-speed'),
              value: _nearestSpeed(snapshot.speed),
              underline: const SizedBox.shrink(),
              items: const [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
                  .map(
                    (s) => DropdownMenuItem<double>(
                      value: s,
                      child: Text('${s}x'),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) onSpeed(v);
              },
            ),
          ],
        ),
      ],
    );
  }

  double _nearestSpeed(double speed) {
    const opts = [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0];
    var best = opts[1];
    var bestD = (speed - best).abs();
    for (final o in opts) {
      final d = (speed - o).abs();
      if (d < bestD) {
        best = o;
        bestD = d;
      }
    }
    return best;
  }
}
