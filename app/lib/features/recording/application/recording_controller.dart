// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Recording state machine — M6 (§8, §9).
///
/// Runs the whole flow on a fake GPS timeline:
///
/// ```text
/// preparing → gpsAcquiring → ready → running ⇄ paused → finishing → completed
/// ```
///
/// The controller owns time and points; the UI is a pure projection of the
/// emitted [`LiveRunState`]. Live state is published at ~2 Hz (§7).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/units.dart';
import '../../../engine/fake_engine.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';

/// Null until a run session exists; otherwise the current live state.
final recordingControllerProvider =
    NotifierProvider.autoDispose<RecordingController, LiveRunState?>(
      RecordingController.new,
    );

class RecordingController extends Notifier<LiveRunState?> {
  static const Duration _tick = Duration(milliseconds: 500);

  /// Demo cruise speed: 4:57/km.
  static const double _baseSpeedMps = 1000.0 / 297.0;

  Timer? _timer;
  _RecSession? _session;
  final math.Random _random = math.Random(7);

  /// Wall-clock anchor for the last tick (M13): elapsed time is derived from
  /// the real clock rather than assuming each timer tick is exactly 500 ms,
  /// so throttled/suspended background timers never corrupt the pace.
  DateTime _lastTick = clock.now();

  /// Throttles background snapshot writes (at most every 5 seconds).
  static const Duration _snapshotEvery = Duration(seconds: 5);
  DateTime _throttleAnchor = clock.now();

  @override
  LiveRunState? build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return null;
  }

  /// Starts (or keeps) a run session for [preferredRoutes]. Idempotent.
  void ensureSession(List<Route> preferredRoutes) {
    if (_session != null) {
      return;
    }
    final preferred = preferredRoutes.isNotEmpty
        ? preferredRoutes.firstWhere(
            (r) => r.id == FakeEngineService.riverLoopId,
            orElse: () => preferredRoutes.first,
          )
        : null;
    _session = _RecSession(preferred, 0);
    _beginAcquisition();
  }

  /// Dropping the detected route (`Continue without route`, §11).
  void continueWithoutRoute() {
    final session = _requireSession();
    session.route = null;
    session.ghost = null;
    _emit(status: RunStatus.ready);
  }

  /// START on the pre-run screen: begin moving time.
  void beginRun() {
    final session = _requireSession();
    if (session.route == null) {
      session.loopLength = session.geometry.isEmpty
          ? 0
          : polylineMeters(session.geometry);
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _emit(status: RunStatus.running);
  }

  void pause() {
    if (state?.status != RunStatus.running) {
      return;
    }
    _emit(status: RunStatus.paused);
  }

  void resume() {
    if (state?.status != RunStatus.paused) {
      return;
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _emit(status: RunStatus.running);
  }

  /// App lifecycle M13, §28: the run left the foreground. Sync the wall clock
  /// so a suspended background timer doesn't inflate elapsed time, and write
  /// a snapshot immediately in case the process is killed.
  void appBackgrounded() {
    _lastTick = clock.now();
    if (_isActiveRun) {
      _snapshot();
    }
  }

  /// App lifecycle M13, §28: back in the foreground. Same clock sync; the
  /// recording resumes where the wall clock left it.
  void appForegrounded() {
    _lastTick = clock.now();
  }

  /// True while a run is actually in progress (running or paused), so
  /// lifecycle snapshots only capture real sessions.
  bool get _isActiveRun {
    final status = state?.status;
    return status == RunStatus.running || status == RunStatus.paused;
  }

  /// FINISH: one final "finishing" tick then a completed summary.
  void finishRun() {
    if (state?.status != RunStatus.running &&
        state?.status != RunStatus.paused) {
      return;
    }
    _emit(status: RunStatus.finishing);
  }

  /// Dismiss the completed run and reset the session.
  void dismissRun() {
    _timer?.cancel();
    _timer = null;
    _session = null;
    state = null;
    ref.read(runSnapshotProvider.notifier).save(null);
  }

  Future<void> _beginAcquisition() async {
    try {
      await _prepareGhost();
    } catch (_) {
      // M14: surface engine/preparation failures instead of hanging forever.
      if (_session != null) {
        _emit(status: RunStatus.error);
      }
      return;
    }
    if (_session == null) {
      return; // dismissed while preparing
    }
    _emit(status: RunStatus.preparing);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
  }

  /// M14: retry after an [RunStatus.error] — re-runs the acquisition pipeline.
  void retry() {
    if (_session != null) {
      _beginAcquisition();
    }
  }

  void _onTick() {
    switch (state?.status) {
      case RunStatus.preparing:
        _emit(status: RunStatus.gpsAcquiring);
      case RunStatus.gpsAcquiring:
        _emit(status: RunStatus.ready);
      case RunStatus.running:
        _advance();
      case RunStatus.finishing:
        _complete();
      default:
        break;
    }
  }

  void _advance() {
    final session = _requireSession();
    final now = clock.now();
    final deltaSeconds = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;

    // Slightly variable, deterministic pace.
    final speed = _baseSpeedMps * (0.97 + _random.nextDouble() * 0.06);
    final step = speed * deltaSeconds;
    session.distanceM = _clampMeters(
      session.distanceM + step,
      session.loopLength,
    );
    session.moving = session.moving + Elapsed.seconds(deltaSeconds);

    final position = pointAlongPolyline(session.geometry, session.distanceM);
    if (position != null) {
      _recordFix(session, now, position, speed);
    }

    GhostState? gap;
    GeoPoint? ghostPosition;
    if (session.ghost != null) {
      gap = _gapAt(session, session.distanceM);
      final ghostDistance = _ghostDistanceAt(session, session.moving.seconds);
      ghostPosition = pointAlongPolyline(session.geometry, ghostDistance);
    }

    _emit(
      status: RunStatus.running,
      position: position,
      gap: gap,
      ghostPosition: ghostPosition,
    );
    _snapshotThrottled();
  }

  /// Retains one raw GPS observation for [position] (M15 Phase 12).
  ///
  /// The fake receiver reports a constant 5 m accuracy and 60 m altitude; the
  /// speed and bearing are derived from the movement just like the Rust
  /// fixture generator does. Crucially these are the *fix's own* sensor
  /// fields, captured before any track processing — never re-derived later.
  void _recordFix(
    _RecSession session,
    DateTime timestamp,
    GeoPoint position,
    double speedMps,
  ) {
    final previous = session.rawFixes.isEmpty ? null : session.rawFixes.last;
    session.rawFixes.add(
      GpsFix(
        timestamp: timestamp.toUtc(),
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: 5.0,
        altitudeMeters: 60.0,
        speedMetersPerSecond: speedMps,
        bearingDegrees: previous == null
            ? null
            : _forwardBearing(
                previous.latitude,
                previous.longitude,
                position.latitude,
                position.longitude,
              ),
      ),
    );
  }

  /// Initial forward azimuth in degrees 0..360 (WGS84 great-circle).
  double _forwardBearing(double lat1, double lon1, double lat2, double lon2) {
    final phi1 = _radians(lat1);
    final phi2 = _radians(lat2);
    final dLon = _radians(lon2 - lon1);
    final x = math.sin(dLon) * math.cos(phi2);
    final y =
        math.cos(phi1) * math.sin(phi2) -
        math.sin(phi1) * math.cos(phi2) * math.cos(dLon);
    var degrees = math.atan2(x, y) * (180.0 / math.pi);
    if (degrees < 0) {
      degrees += 360.0;
    }
    return degrees;
  }

  double _radians(double degrees) => degrees * (math.pi / 180.0);

  /// Persists a snapshot at most every ~5 s of wall time so a backgrounded or
  /// killed process can resume close to where it left off (§28).
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
    if (session == null || live == null) {
      return null;
    }
    final snapshot = RunSnapshot(
      status: live.status,
      startedAt: session.startedAt,
      movingSeconds: session.moving.seconds,
      distanceMeters: session.distanceM,
      loopMeters: session.loopLength,
      routeId: session.route?.id,
    );
    ref.read(runSnapshotProvider.notifier).save(snapshot);
    return snapshot;
  }

  /// Resumes an interrupted session from its persisted snapshot (§28).
  /// Mirrors [ensureSession]: recover geometry/ghost then re-enter
  /// `running`/`paused` with a fresh timer.
  Future<void> resumeFromSnapshot(RunSnapshot snapshot) async {
    if (_session != null) {
      return;
    }
    final routes = ref.read(routeRepositoryProvider);
    final route = snapshot.routeId == null
        ? null
        : routes.where((r) => r.id == snapshot.routeId).firstOrNull;
    _session = _RecSession(
      route,
      snapshot.distanceMeters,
      startedAt: snapshot.startedAt,
      movingSeconds: snapshot.movingSeconds,
      loopLength: snapshot.loopMeters,
    );
    try {
      await _prepareGhost();
    } catch (_) {
      _emit(status: RunStatus.error);
      return;
    }
    if (_session == null) {
      return;
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _emit(status: snapshot.status);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
  }

  /// Distance the PB ghost has covered by [liveSeconds] of live moving time.
  double _ghostDistanceAt(_RecSession session, double liveSeconds) {
    final samples = session.ghost!.samples;
    if (samples.isEmpty) {
      return 0;
    }
    if (liveSeconds <= samples.first.elapsed.seconds) {
      return samples.first.distance.meters;
    }
    for (var i = 1; i < samples.length; i++) {
      if (liveSeconds <= samples[i].elapsed.seconds) {
        final a = samples[i - 1];
        final b = samples[i];
        final span = b.elapsed.seconds - a.elapsed.seconds;
        final fraction = span <= 0
            ? 0
            : (liveSeconds - a.elapsed.seconds) / span;
        return a.distance.meters +
            (b.distance.meters - a.distance.meters) * fraction;
      }
    }
    return samples.last.distance.meters;
  }

  GhostState _gapAt(_RecSession session, double distanceM) {
    final reference = session.ghost!.samples;
    // Live time at this distance: constant cruise pace.
    final liveTime =
        session.moving.seconds *
        (distanceM / (session.loopLength <= 0 ? 1 : session.loopLength));
    final referenceTime = _referenceTimeAt(reference, distanceM);
    final difference = Elapsed.seconds(liveTime - referenceTime);
    return GhostState(
      distance: Distance.meters(distanceM),
      timeDifference: difference,
      ahead: difference.seconds <= 0,
    );
  }

  /// Interpolates the reference (ghost/PB) time at [distanceM].
  double _referenceTimeAt(List<AttemptSample> samples, double distanceM) {
    if (samples.isEmpty) {
      return 0;
    }
    if (distanceM <= samples.first.distance.meters) {
      return samples.first.elapsed.seconds;
    }
    for (var i = 1; i < samples.length; i++) {
      if (distanceM <= samples[i].distance.meters) {
        final a = samples[i - 1];
        final b = samples[i];
        final span = b.distance.meters - a.distance.meters;
        final fraction = span <= 0 ? 0 : (distanceM - a.distance.meters) / span;
        return a.elapsed.seconds +
            (b.elapsed.seconds - a.elapsed.seconds) * fraction;
      }
    }
    return samples.last.elapsed.seconds;
  }

  void _complete() {
    final session = _requireSession();
    final gap = session.ghost != null
        ? _gapAt(session, session.distanceM)
        : null;
    _emit(status: RunStatus.completed, gap: gap, hasUnsavedData: true);
    _timer?.cancel();
    _timer = null;
    // Persist in the background; the flag clears when the save lands.
    _persistCompletedRun();
  }

  /// Saves the finished run into the activity repository (M10, §27).
  Future<void> _persistCompletedRun() async {
    final session = _requireSession();
    final gap = session.ghost != null
        ? _gapAt(session, session.distanceM)
        : null;
    var saved = true;
    try {
      final track = _synthesizeTrack(session);
      final routeId = session.route?.id ?? await _recognizeRoute(track);
      final activity = Activity(
        id: 'act-${session.startedAt.millisecondsSinceEpoch}',
        routeId: routeId,
        startedAt: session.startedAt,
        duration: session.moving,
        distance: Distance.meters(session.distanceM),
        performance: session.moving.format(),
        track: track,
        rawFixes: List.unmodifiable(session.rawFixes),
      );
      await ref
          .read(activityRepositoryProvider.notifier)
          .saveActivity(activity);
      // M13 §28: the run is safely stored — clear the interrupted-run snapshot.
      await ref.read(runSnapshotProvider.notifier).save(null);
    } catch (_) {
      // Best-effort persistence: degraded storage or a failed route match must
      // keep the completed summary visible, not crash the app (Phase 13).
      saved = false;
    }
    if (_session == session) {
      _emit(status: RunStatus.completed, gap: gap, hasUnsavedData: !saved);
    }
  }

  /// Reconstructs a deterministic GPS timeline from the recorded session:
  /// points along the geometry every 25 m, timed to match the moving clock.
  List<TrackPoint> _synthesizeTrack(_RecSession session) {
    final track = <TrackPoint>[];
    if (session.geometry.length < 2 || session.distanceM <= 0) {
      return track;
    }
    const stepMeters = 25.0;
    final durationMs = (session.moving.seconds * 1000).round();
    for (var d = 0.0; d < session.distanceM; d += stepMeters) {
      final position = pointAlongPolyline(session.geometry, d);
      if (position == null) {
        break;
      }
      final elapsedMs = (durationMs * (d / session.distanceM)).round();
      track.add(
        TrackPoint(
          position: position,
          timestamp: session.startedAt.add(Duration(milliseconds: elapsedMs)),
        ),
      );
    }
    final finalPosition = pointAlongPolyline(
      session.geometry,
      session.distanceM,
    );
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

  /// Tries to match an unrecognized run against the catalog so the saved
  /// activity carries a `routeId`. Returns `null` for a genuinely new route.
  Future<String?> _recognizeRoute(List<TrackPoint> track) async {
    if (track.length < 2) {
      return null;
    }
    final engine = ref.read(engineServiceProvider);
    for (final route in ref.read(routeRepositoryProvider)) {
      final result = await engine.matchRoutes(
        a: track,
        b: _geometryTrack(route.geometry),
      );
      if (result.sameRoute) {
        return route.id;
      }
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

  Future<void> _prepareGhost() async {
    final session = _requireSession();
    final route = session.route;
    if (route == null) {
      session.geometry = FakeEngineService.riverLoop;
      session.loopLength = polylineMeters(session.geometry);
      return;
    }
    session.geometry = route.geometry;
    session.loopLength = polylineMeters(session.geometry);

    if (route.personalBest case final pb?) {
      // Ghost = the PB attempt run at constant PB speed. M9: generated by
      // whichever engine is wired in (fake or Rust).
      final engine = ref.read(engineServiceProvider);
      final speed = session.loopLength / pb.seconds;
      final recording = engine.generateRecording(
        noiseMeters: 1.0,
        speedMetersPerSecond: speed,
        sampleEverySeconds: 1.0,
      );
      final attempt = await engine.createAttempt(
        activityId: 'ghost-${route.id}',
        routeId: route.id,
        points: recording,
        routeGeometry: route.geometry,
      );
      session.ghost = Ghost(
        attemptId: attempt.activityId,
        samples: attempt.samples,
      );
    }
  }

  void _emit({
    required RunStatus status,
    GeoPoint? position,
    GhostState? gap,
    GeoPoint? ghostPosition,
    bool hasUnsavedData = true,
  }) {
    final session = _requireSession();
    final keepGap = gap ?? state?.ghostGap;
    state = LiveRunState(
      status: status,
      elapsed: session.moving,
      distance: Distance.meters(session.distanceM),
      currentPosition: position ?? state?.currentPosition,
      pace: Speed.metersPerSecond(_baseSpeedMps),
      ghostGap: keepGap,
      routeProgress: session.loopLength <= 0
          ? 0
          : session.distanceM / session.loopLength,
      gpsQuality: status == RunStatus.gpsAcquiring ? 'reduced' : 'good',
      hasUnsavedData: hasUnsavedData,
      route: session.route,
      ghostPosition: ghostPosition ?? state?.ghostPosition,
      startedAt: session.startedAt,
    );
  }

  /// Read-only diagnostic view of the in-flight track (M15 Phase 10): the
  /// same 25 m-synthesized timeline the run would be persisted with, or
  /// `null` when no session exists.
  List<TrackPoint>? currentTrack() {
    final session = _session;
    return session == null ? null : _synthesizeTrack(session);
  }

  /// Read-only view of the raw GPS observations retained this session
  /// (M15 Phase 12): the complete, unprocessed receiver output, or `null`
  /// when no session exists.
  List<GpsFix>? currentFixes() {
    final session = _session;
    return session == null ? null : List.unmodifiable(session.rawFixes);
  }

  _RecSession _requireSession() {
    final session = _session;
    assert(session != null, 'RecordingController has no active session');
    return session!;
  }

  double _clampMeters(double value, double max) {
    if (max <= 0) {
      return value;
    }
    return value > max ? max : value;
  }
}

/// Internal mutable recording session.
class _RecSession {
  _RecSession(
    this.route,
    this.distanceM, {
    DateTime? startedAt,
    double movingSeconds = 0,
    this.loopLength = 0,
  }) : startedAt = startedAt ?? DateTime.now().toUtc(),
       moving = Elapsed.seconds(movingSeconds);

  final DateTime startedAt;
  Route? route;
  List<GeoPoint> geometry = FakeEngineService.riverLoop;
  double loopLength = 0;
  Ghost? ghost;
  Elapsed moving = Elapsed.zero();
  double distanceM;

  /// Every raw GPS observation received this session (M15 Phase 12), in
  /// arrival order. Unlike `_synthesizeTrack` (25 m display/persist samples),
  /// this is the complete pre-processing trace.
  final List<GpsFix> rawFixes = [];
}
