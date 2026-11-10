// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Recording state machine — live calculations are owned by the engine.
///
/// The controller drives a stateful [LiveRunHandle]: raw GPS fixes (from the
/// device receiver, or a deterministic scenario timeline) are pushed into the
/// engine, and the emitted [LiveRunState] is a projection of the engine's
/// snapshot plus wall-clock timekeeping and persistence. No filtering,
/// distance, moving time, pace, route projection, off-route or ghost math lives
/// here.
///
/// ```text
/// preparing → gpsAcquiring → ready → running ⇄ paused → finishing → completed
/// ```
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/units.dart';
import '../../../engine/device_gps_source.dart';
import '../../../engine/engine_service.dart';
import '../../../engine/fake_engine.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import 'ghost_profile.dart';
import 'run_foreground_lifespan.dart';

final recordingControllerProvider =
    NotifierProvider.autoDispose<RecordingController, LiveRunState?>(
      RecordingController.new,
    );

final saveProgressProvider = NotifierProvider<SaveProgressReporter, String?>(
  SaveProgressReporter.new,
);

class SaveProgressReporter extends Notifier<String?> {
  @override
  String? build() => null;

  void report(String phase) => state = phase;
}

class RecordingController extends Notifier<LiveRunState?> {
  static const Duration _tick = Duration(milliseconds: 500);

  /// Demo cruise speed: 4:57/km.
  static const double _baseSpeedMps = 1000.0 / 297.0;

  static const Duration _snapshotEvery = Duration(seconds: 5);

  Timer? _timer;
  _RecSession? _session;
  GpsSource? _gpsSource;
  StreamSubscription<GpsFix>? _gpsSub;
  bool _acquiring = false;
  bool _foregroundActive = false;
  RunForegroundLifespan? _foregroundLifespan;
  BackgroundProtection _protection = BackgroundProtection.inactive;
  Activity? _lastFinishedActivity;

  /// Wall-clock anchor for the scenario tick.
  DateTime _lastTick = clock.now();
  DateTime _throttleAnchor = clock.now();

  /// When the current running stretch began (wall clock), or `null` while
  /// paused/before START. The stopwatch counts wall time, not motion.
  DateTime? _runningSince;

  /// Scenario-mode progress along [ _session.geometry] (meters). The engine
  /// handle owns the authoritative distance; this drives where the next
  /// synthetic fix is placed.
  double _scenarioDistanceM = 0;

  @override
  LiveRunState? build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _stopDeviceStream();
      _disposeHandle();
    });
    return null;
  }

  void ensureSession(List<Route> preferredRoutes) {
    if (_session != null) return;
    _session = _RecSession(
      preferredRoutes.isNotEmpty ? preferredRoutes.first : null,
    );
    _gpsSource = ref.read(deviceGpsProvider);
    _scenarioDistanceM = 0;
    _beginAcquisition();
  }

  void continueWithoutRoute() {
    final session = _requireSession();
    session.route = null;
    session.ghostSamples = null;
    session.geometry = _gpsSource == null
        ? FakeEngineService.riverLoop
        : const [];
    session.loopLength = 0;
    session.handle?.setGhost(null);
    _emit(status: RunStatus.ready);
    unawaited(_recreateHandle());
  }

  void beginRun() {
    final session = _requireSession();
    if (session.route == null) {
      session.loopLength = session.geometry.isEmpty
          ? 0
          : polylineMeters(session.geometry);
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _runningSince = clock.now();
    _pushScenarioAnchor(session);
    _emit(status: RunStatus.running);
    _startDeviceStream();
  }

  /// Seeds the scenario timeline with an initial fix so the engine's first
  /// tick forms a complete segment (moving time counts from the first step).
  void _pushScenarioAnchor(_RecSession session) {
    if (_gpsSource != null || session.geometry.length < 2) return;
    final now = clock.now();
    final position = pointAlongPolyline(session.geometry, _scenarioDistanceM);
    if (position == null) return;
    final fix = GpsFix(
      timestamp: now.toUtc(),
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: 5.0,
      altitudeMeters: 60.0,
      speedMetersPerSecond: _baseSpeedMps,
      bearingDegrees: _bearingAt(session.geometry, _scenarioDistanceM),
    );
    session.rawFixes.add(fix);
    session.handle?.push(fix);
  }

  void pause() {
    if (state?.status != RunStatus.running) return;
    _flushClock();
    _stopDeviceStream();
    _session?.handle?.pause();
    _emit(status: RunStatus.paused);
  }

  void resume() {
    if (state?.status != RunStatus.paused) return;
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _runningSince = clock.now();
    _session?.handle?.resume();
    if (_gpsSource == null && _session != null) {
      _pushScenarioAnchor(_session!);
    }
    _emit(status: RunStatus.running);
    _startDeviceStream();
  }

  void appBackgrounded() {
    _lastTick = clock.now();
    if (_isActiveRun) _snapshot();
  }

  void appForegrounded() {
    _lastTick = clock.now();
  }

  bool get _isActiveRun {
    final status = state?.status;
    return status == RunStatus.running || status == RunStatus.paused;
  }

  void finishRun() {
    if (state?.status != RunStatus.running &&
        state?.status != RunStatus.paused) {
      return;
    }
    _flushClock();
    _session?.handle?.finish();
    _emit(status: RunStatus.finishing);
    _complete();
  }

  void dismissRun() {
    _timer?.cancel();
    _timer = null;
    _stopDeviceStream();
    _disposeHandle();
    _runningSince = null;
    _session = null;
    _scenarioDistanceM = 0;
    state = null;
    _lastFinishedActivity = null;
    ref.read(runSnapshotProvider.notifier).save(null);
  }

  Future<void> _beginAcquisition() async {
    try {
      await _prepareSession();
    } catch (e, st) {
      debugPrint('Ghost/session preparation failed: $e\n$st');
      if (_session != null) {
        _emit(
          status: RunStatus.error,
          error: RunError(
            message: 'The engine failed to prepare the ghost. Try again. ($e)',
          ),
        );
      }
      return;
    }
    if (_session == null) return;
    _emit(status: RunStatus.preparing);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
  }

  void retry() {
    if (_session != null) _beginAcquisition();
  }

  void _onTick() {
    switch (state?.status) {
      case RunStatus.preparing:
        _emit(status: RunStatus.gpsAcquiring);
      case RunStatus.gpsAcquiring:
        if (_gpsSource != null) {
          _acquireDeviceGps();
        } else {
          _emit(status: RunStatus.ready);
        }
      case RunStatus.running:
        if (_gpsSource == null) {
          _advanceScenario();
        } else {
          // Fixes drive the engine; refresh the wall-clock readout between them.
          _emit(status: RunStatus.running, keepPace: true);
          _snapshotThrottled();
        }
      case RunStatus.finishing:
        _complete();
      default:
        break;
    }
  }

  Future<void> _acquireDeviceGps() async {
    final source = _gpsSource;
    if (source == null) return;
    if (_acquiring) return;
    _acquiring = true;
    String? problem;
    try {
      problem = await source.ensureAvailable();
    } catch (e) {
      problem = 'The GPS receiver did not answer: $e';
    } finally {
      _acquiring = false;
    }
    if (_session == null) return;
    if (problem != null) {
      _emit(
        status: RunStatus.error,
        error: RunError(message: problem, gpsSettingsAction: true),
      );
      return;
    }
    _emit(status: RunStatus.ready);
  }

  Future<void> openSettings() =>
      _gpsSource?.openSettings() ?? Future<void>.value();

  void _startDeviceStream() {
    final source = _gpsSource;
    if (source == null) return;
    if (!_foregroundActive) {
      _foregroundActive = true;
      _foregroundLifespan = ref.read(runForegroundLifespanProvider);
      _protection = BackgroundProtection.starting;
      _refreshState();
      unawaited(_ensureForegroundService());
    }
    _gpsSub?.cancel();
    _gpsSub = source.fixes().listen(
      _onDeviceFix,
      onError: (Object e) {
        debugPrint('GPS source stream failed: $e');
      },
    );
  }

  Future<void> _ensureForegroundService() async {
    final lifespan = _foregroundLifespan;
    if (lifespan == null) return;
    ForegroundStartFailure? failure;
    try {
      failure = await lifespan.start();
    } catch (error, stack) {
      debugPrint('Foreground recording service start threw: $error\n$stack');
      failure = ForegroundStartFailure.unknown;
    }
    if (lifespan != _foregroundLifespan) return;
    if (failure == null) {
      _protection = BackgroundProtection.active;
    } else {
      debugPrint(
        'Foreground recording service could not start: ${failure.message}',
      );
      _foregroundActive = false;
      _foregroundLifespan = null;
      _protection = BackgroundProtection.unavailable;
    }
    _refreshState();
  }

  void _refreshState() {
    final current = state;
    if (current != null) _emit(status: current.status, keepPace: true);
  }

  void _stopDeviceStream() {
    _gpsSub?.cancel();
    _gpsSub = null;
    if (_foregroundActive) {
      _foregroundActive = false;
      final lifespan = _foregroundLifespan;
      _foregroundLifespan = null;
      _protection = BackgroundProtection.inactive;
      unawaited(lifespan?.stop() ?? Future<void>.value());
    }
  }

  void _onDeviceFix(GpsFix fix) {
    if (state?.status != RunStatus.running) return;
    final session = _requireSession();
    _recordDeviceFix(fix);
    session.handle?.push(fix);
    _emit(status: RunStatus.running);
    _snapshotThrottled();
  }

  void _recordDeviceFix(GpsFix fix) {
    final session = _requireSession();
    final previous = session.rawFixes.isEmpty ? null : session.rawFixes.last;
    final bearing =
        fix.bearingDegrees ??
        (previous == null
            ? null
            : _forwardBearing(
                previous.latitude,
                previous.longitude,
                fix.latitude,
                fix.longitude,
              ));
    session.rawFixes.add(
      GpsFix(
        timestamp: fix.timestamp,
        latitude: fix.latitude,
        longitude: fix.longitude,
        accuracyMeters: fix.accuracyMeters,
        altitudeMeters: fix.altitudeMeters,
        speedMetersPerSecond: fix.speedMetersPerSecond,
        bearingDegrees: bearing,
      ),
    );
  }

  void _advanceScenario() {
    final session = _requireSession();
    final now = clock.now();
    final deltaSeconds = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;

    if (session.geometry.length < 2) return;
    _scenarioDistanceM += _baseSpeedMps * deltaSeconds;
    if (session.loopLength > 0 && _scenarioDistanceM >= session.loopLength) {
      // Stop just before the closed-loop vertex so its projection is
      // unambiguous; the engine snaps coverage to the full route length.
      _scenarioDistanceM = session.loopLength - 0.05;
    }

    final position = pointAlongPolyline(session.geometry, _scenarioDistanceM);
    if (position == null) return;

    final fix = GpsFix(
      timestamp: now.toUtc(),
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyMeters: 5.0,
      altitudeMeters: 60.0,
      speedMetersPerSecond: _baseSpeedMps,
      bearingDegrees: _bearingAt(session.geometry, _scenarioDistanceM),
    );
    session.rawFixes.add(fix);
    session.handle?.push(fix);
    _emit(status: RunStatus.running);
    _snapshotThrottled();
  }

  double? _bearingAt(List<GeoPoint> geometry, double distanceM) {
    if (geometry.length < 2) return null;
    // Approximate bearing from a short step ahead along the polyline.
    final a = pointAlongPolyline(geometry, distanceM);
    final b = pointAlongPolyline(geometry, distanceM + 1.0);
    if (a == null || b == null) return null;
    return _forwardBearing(a.latitude, a.longitude, b.latitude, b.longitude);
  }

  double _forwardBearing(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = lat1 * (3.141592653589793 / 180.0);
    final phi2 = lat2 * (3.141592653589793 / 180.0);
    final dLon = (lon2 - lon1) * (3.141592653589793 / 180.0);
    final x = math.sin(dLon) * math.cos(phi2);
    final y =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    var degrees = math.atan2(x, y) * (180.0 / 3.141592653589793);
    if (degrees < 0) degrees += 360.0;
    return degrees;
  }

  double _clockSeconds(_RecSession session) {
    final since = _runningSince;
    if (since == null) return session.clockSeconds;
    final delta = clock.now().difference(since).inMilliseconds / 1000.0;
    return session.clockSeconds + (delta > 0 ? delta : 0);
  }

  void _flushClock() {
    final session = _session;
    if (session == null || _runningSince == null) return;
    session.clockSeconds = _clockSeconds(session);
    _runningSince = null;
  }

  void _snapshotThrottled() {
    final now = clock.now();
    if (now.difference(_throttleAnchor) >= _snapshotEvery) {
      _throttleAnchor = now;
      _snapshot();
    }
  }

  RunSnapshot? _snapshot() {
    final session = _session;
    final live = state;
    final handle = session?.handle;
    if (session == null || live == null || handle == null) return null;
    final snap = handle.snapshot();
    final snapshot = RunSnapshot(
      status: live.status,
      startedAt: session.startedAt,
      movingSeconds: snap.movingSeconds,
      clockSeconds: _clockSeconds(session),
      distanceMeters: snap.distanceMeters,
      loopMeters: session.loopLength,
      routeId: session.route?.id,
    );
    ref.read(runSnapshotProvider.notifier).save(snapshot);
    return snapshot;
  }

  Future<void> resumeFromSnapshot(RunSnapshot snapshot) async {
    if (_session != null) return;
    final routes = ref.read(routeRepositoryProvider);
    final route = snapshot.routeId == null
        ? null
        : routes.where((r) => r.id == snapshot.routeId).firstOrNull;
    _session = _RecSession(
      route,
      startedAt: snapshot.startedAt,
      clockSeconds: snapshot.clockSeconds,
      loopLength: snapshot.loopMeters,
    );
    _gpsSource = ref.read(deviceGpsProvider);
    _scenarioDistanceM = snapshot.distanceMeters;
    try {
      await _prepareSession();
      _session?.handle?.seed(
        distanceMeters: snapshot.distanceMeters,
        movingSeconds: snapshot.movingSeconds,
      );
      // Anchor the scenario chain at the resumed position so the first
      // tick after resume accrues distance instead of only re-anchoring.
      if (_gpsSource == null) {
        final anchorPos = pointAlongPolyline(
          _session!.geometry,
          snapshot.distanceMeters,
        );
        if (anchorPos != null) {
          final now = clock.now();
          _session!.handle?.push(
            GpsFix(
              timestamp: now.toUtc(),
              latitude: anchorPos.latitude,
              longitude: anchorPos.longitude,
              accuracyMeters: 5.0,
              altitudeMeters: 60.0,
              speedMetersPerSecond: _baseSpeedMps,
              bearingDegrees: _bearingAt(
                _session!.geometry,
                snapshot.distanceMeters,
              ),
            ),
          );
        }
      }
    } catch (e, st) {
      debugPrint('Resume preparation failed: $e\n$st');
      _emit(
        status: RunStatus.error,
        error: RunError(
          message: 'The engine failed to prepare the ghost. Try again. ($e)',
        ),
      );
      return;
    }
    if (_session == null) return;
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    if (snapshot.status == RunStatus.running) _runningSince = clock.now();
    _emit(status: snapshot.status);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
    if (snapshot.status == RunStatus.running) _startDeviceStream();
  }

  void _complete() {
    _emit(status: RunStatus.completed, hasUnsavedData: false);
    _timer?.cancel();
    _timer = null;
    _stopDeviceStream();
    _persistCompletedRun();
  }

  Future<void> _persistCompletedRun() async {
    final session = _requireSession();
    final snap = session.handle?.snapshot();
    final progress = ref.read(saveProgressProvider.notifier);
    try {
      progress.report(
        'synthesize d=${(snap?.distanceMeters ?? 0).toStringAsFixed(1)} '
        'geom=${session.geometry.length} route=${session.route?.id}',
      );
      final track = _synthesizeTrack(session, snap?.distanceMeters ?? 0);
      progress.report('synthesized ${track.length} pts');
      String? routeId = session.route?.id;
      if (routeId == null) {
        try {
          routeId = await _recognizeRoute(track);
        } catch (e) {
          progress.report('route match failed: $e');
        }
      }
      progress.report('route=$routeId');
      final activity = Activity(
        id: 'act-${session.startedAt.millisecondsSinceEpoch}',
        routeId: routeId,
        startedAt: session.startedAt,
        duration: Elapsed.seconds(snap?.movingSeconds ?? 0),
        distance: Distance.meters(snap?.distanceMeters ?? 0),
        performance: Elapsed.seconds(snap?.movingSeconds ?? 0).format(),
        track: track,
        rawFixes: List.unmodifiable(session.rawFixes),
      );
      progress.report('activity built (${activity.rawFixes?.length} fixes)');
      final saved = await _saveRunToDisk(activity);
      progress.report(saved ? 'run saved' : 'disk save failed');
      if (_session == session) {
        _emit(status: RunStatus.completed, hasUnsavedData: !saved);
      }
    } catch (e, st) {
      debugPrint('Failed to persist completed run: $e\n$st');
      progress.report('error: ${e.runtimeType}: $e');
      if (_session == session) {
        _emit(status: RunStatus.completed, hasUnsavedData: true);
      }
    }
  }

  Future<bool> _saveRunToDisk(Activity activity) async {
    _lastFinishedActivity = activity;
    final inHistory = await ref
        .read(activityRepositoryProvider.notifier)
        .saveActivity(activity);
    final snapshotCleared = await ref
        .read(runSnapshotProvider.notifier)
        .save(null);
    final saved = inHistory && snapshotCleared;
    if (saved) _lastFinishedActivity = null;
    return saved;
  }

  Future<void> retrySave() async {
    final activity = _lastFinishedActivity;
    if (activity == null ||
        state?.status != RunStatus.completed ||
        state?.hasUnsavedData != true) {
      return;
    }
    final progress = ref.read(saveProgressProvider.notifier);
    progress.report('retry save');
    final saved = await _saveRunToDisk(activity);
    progress.report(saved ? 'retry saved' : 'retry failed');
    if (saved && state?.status == RunStatus.completed) {
      _emit(status: RunStatus.completed, hasUnsavedData: false);
    }
  }

  List<TrackPoint> _synthesizeTrack(_RecSession session, double distanceM) {
    if (_gpsSource != null) {
      return [
        for (final fix in session.rawFixes)
          TrackPoint(
            position: GeoPoint(
              latitude: fix.latitude,
              longitude: fix.longitude,
            ),
            altitudeMeters: fix.altitudeMeters,
            timestamp: fix.timestamp,
          ),
      ];
    }
    final track = <TrackPoint>[];
    if (session.geometry.length < 2 || distanceM <= 0) return track;
    const stepMeters = 25.0;
    final movingSeconds =
        session.handle?.snapshot().movingSeconds ?? session.clockSeconds;
    final durationMs = (movingSeconds * 1000).round();
    for (var d = 0.0; d < distanceM; d += stepMeters) {
      final position = pointAlongPolyline(session.geometry, d);
      if (position == null) break;
      final elapsedMs = (durationMs * (d / distanceM)).round();
      track.add(
        TrackPoint(
          position: position,
          timestamp: session.startedAt.add(Duration(milliseconds: elapsedMs)),
        ),
      );
    }
    final finalPosition = pointAlongPolyline(session.geometry, distanceM);
    if (finalPosition != null) {
      track.add(
        TrackPoint(
          position: finalPosition,
          timestamp: session.startedAt.add(Duration(milliseconds: durationMs)),
        ),
      );
    }
    return track;
  }

  Future<String?> _recognizeRoute(List<TrackPoint> track) async {
    if (track.length < 2) return null;
    final engine = ref.read(engineServiceProvider);
    for (final route in ref.read(routeRepositoryProvider)) {
      final result = await engine.matchRoutes(
        a: track,
        b: _geometryTrack(route.geometry),
      );
      if (result.sameRoute) return route.id;
    }
    return null;
  }

  List<TrackPoint> _geometryTrack(List<GeoPoint> geometry) => [
    for (var i = 0; i < geometry.length; i++)
      TrackPoint(
        position: geometry[i],
        timestamp: DateTime.fromMillisecondsSinceEpoch(i * 1000, isUtc: true),
      ),
  ];

  Future<void> _prepareSession() async {
    final session = _requireSession();
    final route = session.route;
    final engine = ref.read(engineServiceProvider);

    if (route == null) {
      session.geometry = _gpsSource == null
          ? FakeEngineService.riverLoop
          : const [];
      // Preserve a pre-set loop length (e.g. a headless resume snapshot) so
      // scenario advancement stays bounded; a fresh free run has no cap.
      if (session.loopLength <= 0) session.loopLength = 0;
      session.ghostSamples = null;
      await _recreateHandle();
      return;
    }

    session.geometry = route.geometry;
    session.loopLength = polylineMeters(session.geometry);

    if (route.personalBest case final pb?) {
      session.ghostSamples = await _buildGhostSamples(engine, route, pb);
    } else {
      session.ghostSamples = null;
    }
    await _recreateHandle();
  }

  /// Real PB profile from the fastest activity (moving-time axis), falling
  /// back to a constant-pace analytic ghost. Delegates to [buildGhostSamples]
  /// (shared with replay) so the engine is exercised identically.
  Future<List<AttemptSample>> _buildGhostSamples(
    EngineService engine,
    Route route,
    Elapsed pb,
  ) {
    return buildGhostSamples(
      engine: engine,
      route: route,
      pb: pb,
      fastestActivity: _fastestActivityFor(route.id),
      baseSpeedMps: _baseSpeedMps,
    );
  }

  double sessionLoopLength(Route route) => polylineMeters(route.geometry);

  Activity? _fastestActivityFor(String routeId) {
    final activities = ref.read(activityRepositoryProvider);
    Activity? best;
    for (final a in activities) {
      if (a.routeId != routeId) continue;
      if (a.duration == null) continue;
      if (best == null || a.duration!.seconds < best.duration!.seconds) {
        best = a;
      }
    }
    return best;
  }

  Future<void> _recreateHandle() async {
    final session = _requireSession();
    _disposeHandle();
    final engine = ref.read(engineServiceProvider);
    final routeGeometry = session.route != null ? session.geometry : null;
    session.handle = await engine.createLiveRun(
      route: routeGeometry,
      ghostSamples: session.ghostSamples,
    );
  }

  void _disposeHandle() {
    _session?.handle?.dispose();
    _session?.handle = null;
  }

  double _routeProgressFor(_RecSession session, LiveEngineSnapshot? snap) {
    final reported = snap?.routeProgress ?? 0.0;
    if (reported > 0) return reported.clamp(0.0, 1.0);
    final route = session.route;
    final distance = snap?.distanceMeters ?? 0.0;
    if (route != null && route.distance.meters > 0 && distance > 0) {
      return (distance / route.distance.meters).clamp(0.0, 1.0);
    }
    return 0.0;
  }

  void _emit({
    required RunStatus status,
    bool keepPace = false,
    RunError? error,
    bool hasUnsavedData = true,
  }) {
    final session = _requireSession();
    final snap = session.handle?.snapshot();
    final ghost = snap?.ghost;

    GeoPoint? ghostPosition;
    if (ghost != null && session.geometry.length >= 2) {
      ghostPosition = pointAlongPolyline(
        session.geometry,
        ghost.ghostDistanceMeters,
      );
    }

    final paceMps = snap?.paceMps ?? 0;
    final pace = (keepPace && paceMps <= 0 && state != null)
        ? state!.pace
        : Speed.metersPerSecond(paceMps);

    state = LiveRunState(
      status: status,
      elapsed: Elapsed.seconds(snap?.movingSeconds ?? 0),
      clockElapsed: Elapsed.seconds(_clockSeconds(session)),
      distance: Distance.meters(snap?.distanceMeters ?? 0),
      currentPosition: snap?.position ?? state?.currentPosition,
      pace: pace,
      error: status == RunStatus.error ? (error ?? state?.error) : null,
      ghostGap: ghost?.toGhostState(),
      routeProgress: _routeProgressFor(session, snap),
      gpsQuality: status == RunStatus.gpsAcquiring
          ? 'reduced'
          : qualityForGpsAccuracy(snap?.accuracyMeters),
      offRoute: snap?.offRouteMeters == null
          ? null
          : Distance.meters(snap!.offRouteMeters!),
      hasUnsavedData: hasUnsavedData,
      route: session.route,
      ghostPosition: ghostPosition ?? state?.ghostPosition,
      startedAt: session.startedAt,
      rawFixCount: session.rawFixes.length,
      backgroundProtection: _protection,
      track: [
        for (final f in session.rawFixes)
          GeoPoint(latitude: f.latitude, longitude: f.longitude),
      ],
    );
  }

  List<TrackPoint>? currentTrack() {
    final session = _session;
    if (session == null) return null;
    final dist = session.handle?.snapshot().distanceMeters ?? 0;
    return _synthesizeTrack(session, dist);
  }

  List<GpsFix>? currentFixes() {
    final session = _session;
    return session == null ? null : List.unmodifiable(session.rawFixes);
  }

  _RecSession _requireSession() {
    final session = _session;
    assert(session != null, 'RecordingController has no active session');
    return session!;
  }
}

class _RecSession {
  _RecSession(
    this.route, {
    DateTime? startedAt,
    this.clockSeconds = 0,
    this.loopLength = 0,
  }) : startedAt = startedAt ?? DateTime.now().toUtc();

  final DateTime startedAt;
  Route? route;
  List<GeoPoint> geometry = const [];
  double loopLength = 0;
  List<AttemptSample>? ghostSamples;
  double clockSeconds = 0;
  LiveRunHandle? handle;
  final List<GpsFix> rawFixes = [];
}
