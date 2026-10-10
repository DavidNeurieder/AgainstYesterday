// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Recording state machine — M6 (§8, §9).
///
/// Runs the whole flow on a GPS timeline:
///
/// ```text
/// preparing → gpsAcquiring → ready → running ⇄ paused → finishing → completed
/// ```
///
/// The timeline is *either* the deterministic scenario the fixture engine
/// drives (the default on hosts and in the E2E), *or* the real device
/// receiver when a [GpsSource] is wired in (`USE_DEVICE_GPS=true`, see
/// `app/dependencies.dart`). In device mode each fix comes straight from the
/// phone: position, distance, speed and the raw-fix buffer all reflect the
/// receiver's own output.
///
/// The controller owns time and points; the UI is a pure projection of the
/// emitted [`LiveRunState`]. Live state is published at ~2 Hz (§7).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/units.dart';
import '../../../engine/device_gps_source.dart';
import '../../../engine/fake_engine.dart';
import '../../../engine/models.dart';
import '../../../persistence/persistence.dart';
import 'run_foreground_lifespan.dart';

/// Null until a run session exists; otherwise the current live state.
final recordingControllerProvider =
    NotifierProvider.autoDispose<RecordingController, LiveRunState?>(
      RecordingController.new,
    );

/// Last step reached by the background save of a finished run. On-device
/// tests read this so a red run can tell a hang (phase never advances) from a
/// throw (phase becomes `error: …`) — the run itself never blocks on storage.
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

  /// Slowest true motion (m/s) that advances a device-mode run. A fix must
  /// clear this floor on the ground it actually covered: a stopped phone's
  /// jitter — or a receiver serving a stale cached speed — never moves the
  /// run, adds moving time, or shows a phantom pace.
  static const double _motionFloorMps = 0.5;

  Timer? _timer;
  _RecSession? _session;
  final math.Random _random = math.Random(7);

  /// The active device GPS source when the run consumes real fixes, else
  /// `null` (deterministic scenario timeline). Resolved once per session from
  /// [deviceGpsProvider].
  GpsSource? _gpsSource;
  StreamSubscription<GpsFix>? _gpsSub;

  /// While the Android recording foreground service is up (see
  /// `run_foreground_lifespan.dart`). Only flips on when a device source
  /// actually streams, so scenario runs never touch the platform channel.
  /// The instance is captured at start (a plain method call) because stop can
  /// run from `ref.onDispose`, where reading providers is forbidden.
  bool _foregroundActive = false;
  RunForegroundLifespan? _foregroundLifespan;

  /// Foreground-service protection, separate from the recorded run state so a
  /// failed start can never masquerade as a GPS or run failure.
  BackgroundProtection _protection = BackgroundProtection.inactive;

  /// The completed run whose disk write failed (§33) — held so TRY AGAIN on
  /// the save-error block can rewrite it. `null` once the save has landed.
  Activity? _lastFinishedActivity;

  /// Previous raw position, used to measure the ground travelled between
  /// consecutive fixes. Anchored on every observation so a later move always
  /// measures from the last heard fix; free-run distance accumulates only for
  /// fixes that clear the motion floor.
  GeoPoint? _prevRawPosition;

  /// Wall-clock anchor for the last tick (M13): elapsed time is derived from
  /// the real clock rather than assuming each timer tick is exactly 500 ms,
  /// so throttled/suspended background timers never corrupt the pace.
  DateTime _lastTick = clock.now();

  /// When the current running stretch began (wall clock), or `null` while
  /// paused/before START. The recorder's stopwatch is the session's
  /// `clockSeconds` plus this live stretch; it keeps counting across a
  /// backgrounding because the recorder is still running, while
  /// `session.moving` stays fix-gated.
  DateTime? _runningSince;

  /// Throttles background snapshot writes (at most every 5 seconds).
  static const Duration _snapshotEvery = Duration(seconds: 5);
  DateTime _throttleAnchor = clock.now();

  @override
  LiveRunState? build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
      _stopDeviceStream();
    });
    return null;
  }

  /// Starts (or keeps) a run session for [preferredRoutes]. Idempotent.
  void ensureSession(List<Route> preferredRoutes) {
    if (_session != null) {
      return;
    }
    _session = _RecSession(
      preferredRoutes.isNotEmpty ? preferredRoutes.first : null,
      0,
    );
    _gpsSource = ref.read(deviceGpsProvider);
    _prevRawPosition = null;
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
    _runningSince = clock.now();
    _emit(status: RunStatus.running);
    _startDeviceStream();
  }

  void pause() {
    if (state?.status != RunStatus.running) {
      return;
    }
    _flushClock();
    _stopDeviceStream();
    _emit(status: RunStatus.paused);
  }

  void resume() {
    if (state?.status != RunStatus.paused) {
      return;
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    _runningSince = clock.now();
    _emit(status: RunStatus.running);
    _startDeviceStream();
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
    // Freeze the stopwatch at the finish line before sealing the run.
    _flushClock();
    _emit(status: RunStatus.finishing);
    // Seal the run now, not on the next 500 ms tick: pressing FINISH is a
    // commitment, and a dismissal in the finishing→complete gap used to cancel
    // the timer before _complete() ran — silently dropping the save.
    _complete();
  }

  /// Dismiss the completed run and reset the session.
  void dismissRun() {
    _timer?.cancel();
    _timer = null;
    _stopDeviceStream();
    _runningSince = null;
    _session = null;
    state = null;
    _lastFinishedActivity = null;
    ref.read(runSnapshotProvider.notifier).save(null);
  }

  Future<void> _beginAcquisition() async {
    try {
      await _prepareGhost();
    } catch (_) {
      // M14: surface engine/preparation failures instead of hanging forever.
      if (_session != null) {
        _emit(
          status: RunStatus.error,
          error: const RunError(
            message: 'The engine failed to prepare the ghost. Try again.',
          ),
        );
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
        if (_gpsSource != null) {
          // Device mode: real acquisition gate — permission/service checks are
          // async, so this returns before the next tick lands the READY.
          _acquireDeviceGps();
        } else {
          _emit(status: RunStatus.ready);
        }
      case RunStatus.running:
        if (_gpsSource == null) {
          // Scenario timeline: the world advances on the clock.
          _advance();
        } else {
          // Device mode: fixes drive moving time/distance, but the wall-clock
          // stopwatch must still tick between them — otherwise a standing
          // runner watches TIME sit at 0:00. The last pace/position is kept so
          // this refresh never invents a phantom pace.
          _emit(status: RunStatus.running, pace: state?.pace);
          _snapshotThrottled();
        }
      case RunStatus.finishing:
        _complete();
      default:
        break;
    }
  }

  /// Device-mode acquisition: confirm the receiver is usable before READY.
  ///
  /// Surfaces a refusal as the recoverable ERROR state (M14) — naming the
  /// activation problem (services off / permission denied) instead of blaming
  /// the engine, and offering to open the matching system settings.
  Future<void> _acquireDeviceGps() async {
    final source = _gpsSource;
    if (source == null) {
      return;
    }
    String? problem;
    try {
      problem = await source.ensureAvailable();
    } catch (e) {
      problem = 'The GPS receiver did not answer: $e';
    }
    if (_session == null) {
      return; // dismissed while acquiring
    }
    if (problem != null) {
      _emit(
        status: RunStatus.error,
        error: RunError(message: problem, gpsSettingsAction: true),
      );
      return;
    }
    _emit(status: RunStatus.ready);
  }

  /// Opens the system screen that can put the receiver back in service
  /// (location settings, or app settings for a denied permission).
  Future<void> openSettings() =>
      _gpsSource?.openSettings() ?? Future<void>.value();

  /// Subscribes the live receiver while the run is moving. No-op unless a
  /// device [GpsSource] is wired in.
  void _startDeviceStream() {
    final source = _gpsSource;
    if (source == null) {
      return;
    }
    // Screen-off recording: keep the Android location foreground service up
    // for exactly as long as the receiver streams fixes (§28), so Android
    // 12+ keeps delivering GPS once the activity is stopped. Startup is
    // observable: the outcome lands in [BackgroundProtection] instead of being
    // assumed.
    if (!_foregroundActive) {
      _foregroundActive = true;
      _foregroundLifespan = ref.read(runForegroundLifespanProvider);
      _protection = BackgroundProtection.starting;
      _refreshState();
      unawaited(_ensureForegroundService());
    }
    _gpsSub?.cancel();
    _gpsSub = source.fixes().listen(_onDeviceFix, onError: (Object e) {
      // A dropped receiver (service flipped off mid-run, dongle unplugged)
      // must not take the recording down: keep the last emitted state.
      debugPrint('GPS source stream failed: $e');
    });
  }

  /// Asks the platform to elevate the recording, then records the outcome in
  /// [_protection]. A failure is logged and surfaced, never silently assumed
  /// away — but it is also deliberately *not* fatal: GNSS recording with the
  /// screen on works without the service, so the run continues and simply
  /// reports that screen-off protection is off.
  Future<void> _ensureForegroundService() async {
    final lifespan = _foregroundLifespan;
    if (lifespan == null) {
      return;
    }
    ForegroundStartFailure? failure;
    try {
      failure = await lifespan.start();
    } catch (error, stack) {
      // A buggy seam must not hang the run, but it must be loud.
      debugPrint('Foreground recording service start threw: $error\n$stack');
      failure = ForegroundStartFailure.unknown;
    }
    if (lifespan != _foregroundLifespan) {
      // A stop (or a newer start) superseded this request while it was in
      // flight, so the outcome no longer describes the current state.
      return;
    }
    if (failure == null) {
      _protection = BackgroundProtection.active;
    } else {
      debugPrint('Foreground recording service could not start: '
          '${failure.message}');
      // Allow a later resume to try again; nothing is up to stop.
      _foregroundActive = false;
      _foregroundLifespan = null;
      _protection = BackgroundProtection.unavailable;
    }
    _refreshState();
  }

  /// Re-emits the current status so protection changes reach the UI between
  /// the regular ~2 Hz ticks, preserving the live pace. No-op when no state
  /// has been emitted yet.
  void _refreshState() {
    final current = state;
    if (current != null) {
      _emit(status: current.status, pace: current.pace);
    }
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

  /// Real-GPS driver: one receiver fix advances the session.
  ///
  /// Only fixes that actually clear the motion floor move the run: while a
  /// phone sits still — even when the receiver serves a stale cached speed —
  /// the fix lands in the raw buffer and tracks the map position, but never
  /// adds moving time, distance, or a phantom cruise pace.
  void _onDeviceFix(GpsFix fix) {
    if (state?.status != RunStatus.running) {
      return; // paused / finishing ignore late fixes
    }
    final session = _requireSession();
    final now = fix.timestamp;
    final deltaSeconds = now.difference(_lastTick).inMilliseconds / 1000.0;
    _lastTick = now;

    final position = GeoPoint(
      latitude: fix.latitude,
      longitude: fix.longitude,
    );
    final projected = projectOnPolyline(session.geometry, position);
    final onRoute = projected != null && session.route != null;

    // Ground covered since the previous fix (0 for the very first).
    final groundMeters = _prevRawPosition == null
        ? 0.0
        : haversineMeters(_prevRawPosition!, position);
    _prevRawPosition = position;

    if (!_isMoving(fix, groundMeters, deltaSeconds)) {
      _recordDeviceFix(fix);
      _emit(status: RunStatus.running, position: position, pace: Speed.zero());
      _snapshotThrottled();
      return;
    }

    if (onRoute) {
      // On a recognised route: the distance axis follows the geometry — the
      // runner never loses ground to receiver jump, and a loop crossing must
      // not rewind accumulated progress.
      if (projected.distanceM > session.distanceM) {
        session.distanceM = projected.distanceM;
      }
    } else {
      // Free-running (no route, or off the geometry): accumulate the travelled
      // ground distance between consecutive raw fixes.
      session.distanceM += groundMeters;
    }

    if (deltaSeconds > 0) {
      session.moving = session.moving + Elapsed.seconds(deltaSeconds);
    }

    _recordDeviceFix(fix);

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
      pace: _fixPace(fix, groundMeters, deltaSeconds),
    );
    _snapshotThrottled();
  }

  /// Whether a fix plausibly moved the runner. The ground covered between
  /// fixes must clear [_motionFloorMps]; a receiver-reported speed only counts
  /// when the ground corroborates it — a stopped phone keeps a stale cached
  /// speed, but its fixes barely displace.
  bool _isMoving(GpsFix fix, double groundMeters, double deltaSeconds) {
    if (deltaSeconds <= 0) {
      return false;
    }
    final speed = fix.speedMetersPerSecond;
    if (speed != null) {
      return speed >= _motionFloorMps &&
          groundMeters >= _motionFloorMps * deltaSeconds * 0.5;
    }
    return groundMeters / deltaSeconds >= _motionFloorMps;
  }

  /// Pace for a device fix: the receiver's own speed when reported, else the
  /// ground covered since the previous fix. Only invoked for moving fixes, so
  /// "— /km" is never manufactured out of a still correction.
  Speed _fixPace(GpsFix fix, double groundMeters, double deltaSeconds) {
    final speed = fix.speedMetersPerSecond;
    if (speed != null && speed > 0) {
      return Speed.metersPerSecond(speed);
    }
    if (deltaSeconds > 0 && groundMeters > 0) {
      return Speed.metersPerSecond(groundMeters / deltaSeconds);
    }
    return Speed.zero();
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

  /// Retains one raw observation from the device receiver verbatim (M15
  /// Phase 12): the fix keeps its own timestamp, accuracy, altitude, speed and
  /// bearing. Only a missing bearing is derived from the previous fix — the
  /// receiver usually reports none for the first sample.
  void _recordDeviceFix(GpsFix fix) {
    final session = _requireSession();
    final previous = session.rawFixes.isEmpty ? null : session.rawFixes.last;
    final bearing = fix.bearingDegrees ??
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

  /// Seconds the wall-clock stopwatch reads right now: everything flushed so
  /// far plus the current running stretch. Derived from the real clock, so a
  /// throttled background timer never freezes or inflates it.
  double _clockSeconds(_RecSession session) {
    final since = _runningSince;
    if (since == null) {
      return session.clockSeconds;
    }
    final delta = clock.now().difference(since).inMilliseconds / 1000.0;
    return session.clockSeconds + (delta > 0 ? delta : 0);
  }

  /// Banks the current running stretch into the session and stops the
  /// stopwatch — on pause, finish or teardown.
  void _flushClock() {
    final session = _session;
    if (session == null || _runningSince == null) {
      return;
    }
    session.clockSeconds = _clockSeconds(session);
    _runningSince = null;
  }

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
      clockSeconds: _clockSeconds(session),
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
      clockSeconds: snapshot.clockSeconds,
      loopLength: snapshot.loopMeters,
    );
    _gpsSource = ref.read(deviceGpsProvider);
    _prevRawPosition = null;
    try {
      await _prepareGhost();
    } catch (_) {
      _emit(
        status: RunStatus.error,
        error: const RunError(
          message: 'The engine failed to prepare the ghost. Try again.',
        ),
      );
      return;
    }
    if (_session == null) {
      return;
    }
    _lastTick = clock.now();
    _throttleAnchor = clock.now();
    if (snapshot.status == RunStatus.running) {
      _runningSince = clock.now();
    }
    _emit(status: snapshot.status);
    _timer?.cancel();
    _timer = Timer.periodic(_tick, (_) => _onTick());
    if (snapshot.status == RunStatus.running) {
      _startDeviceStream();
    }
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
    // The save runs in the background; the unsaved flag only turns on if it
    // fails (§33), so the finish screen never flashes a false alarm.
    _emit(status: RunStatus.completed, gap: gap, hasUnsavedData: false);
    _timer?.cancel();
    _timer = null;
    _stopDeviceStream();
    _persistCompletedRun();
  }

  /// Saves the finished run into the activity repository (M10, §27).
  ///
  /// A failed route match no longer costs the run: the activity is saved
  /// without a route instead (§33), so the unsaved flag — and the save-error
  /// block — only ever mean "the disk write failed, retry it".
  Future<void> _persistCompletedRun() async {
    final session = _requireSession();
    final gap = session.ghost != null
        ? _gapAt(session, session.distanceM)
        : null;
    final progress = ref.read(saveProgressProvider.notifier);
    try {
      progress.report(
        'synthesize d=${session.distanceM.toStringAsFixed(1)} '
        'geom=${session.geometry.length} route=${session.route?.id}',
      );
      final track = _synthesizeTrack(session);
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
        duration: session.moving,
        distance: Distance.meters(session.distanceM),
        performance: session.moving.format(),
        track: track,
        rawFixes: List.unmodifiable(session.rawFixes),
      );
      progress.report('activity built (${activity.rawFixes?.length} fixes)');
      final saved = await _saveRunToDisk(activity);
      progress.report(saved ? 'run saved' : 'disk save failed');
      if (_session == session) {
        _emit(status: RunStatus.completed, gap: gap, hasUnsavedData: !saved);
      }
    } catch (e, st) {
      // Keep the completed summary visible rather than crashing the app
      // (Phase 13); the §33 block offers the retry.
      debugPrint('Failed to persist completed run: $e\n$st');
      progress.report('error: ${e.runtimeType}: $e');
      if (_session == session) {
        _emit(status: RunStatus.completed, gap: gap, hasUnsavedData: true);
      }
    }
  }

  /// Writes the finished run to storage: history first (the in-memory list
  /// holds it either way), then the interrupted-run snapshot. Both writes must
  /// land for the run to count as saved; the activity is kept for §33's
  /// retry until they do.
  Future<bool> _saveRunToDisk(Activity activity) async {
    _lastFinishedActivity = activity;
    final inHistory = await ref
        .read(activityRepositoryProvider.notifier)
        .saveActivity(activity);
    final snapshotCleared =
        await ref.read(runSnapshotProvider.notifier).save(null);
    final saved = inHistory && snapshotCleared;
    if (saved) {
      _lastFinishedActivity = null;
    }
    return saved;
  }

  /// §33 TRY AGAIN: rewrites the disk from the activity already held in
  /// memory and clears the save-error block once both writes land.
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
      _emit(
        status: RunStatus.completed,
        gap: state?.ghostGap,
        hasUnsavedData: false,
      );
    }
  }

  /// Reconstructs the recorded GPS timeline.
  ///
  /// Scenario runs resample the geometry every 25 m (deterministic demo data);
  /// device runs persist the fixes the receiver actually produced, verbatim.
  List<TrackPoint> _synthesizeTrack(_RecSession session) {
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
      // No route in any mode: a genuinely new line — no synthetic rug to race
      // on. Distance accumulates from the fixes (device) or the scenario
      // clock (host/E2E) without a route to walk along. A loop length
      // recovered from a resume snapshot is preserved so a restarted run
      // keeps clamping to its recorded loop; fresh free runs stay unbounded.
      //
      // Scenario timeline only: a route-less session still walks the demo
      // loop so position and fixes exist (M18) — that is how a fresh install
      // records River Loop in the deterministic demo instead of standing on
      // the start line with no data to save. A real receiver (device mode)
      // supplies its own line, so such sessions keep no geometry.
      session.geometry = _gpsSource == null
          ? FakeEngineService.riverLoop
          : const [];
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
    Speed? pace,
    RunError? error,
    bool hasUnsavedData = true,
  }) {
    final session = _requireSession();
    final keepGap = gap ?? state?.ghostGap;
    // §17: quality follows the latest fix's accuracy; acquiring has no fix
    // yet and reads as reduced. §18: only a recognised route can be left.
    final accuracy = session.rawFixes.isEmpty
        ? null
        : session.rawFixes.last.accuracyMeters;
    final offRoute = status == RunStatus.running && session.route != null
        ? offRouteDistance(geometry: session.geometry, position: position)
        : null;
    state = LiveRunState(
      status: status,
      elapsed: session.moving,
      clockElapsed: Elapsed.seconds(_clockSeconds(session)),
      distance: Distance.meters(session.distanceM),
      currentPosition: position ?? state?.currentPosition,
      pace: pace ?? Speed.metersPerSecond(_baseSpeedMps),
      // The error reason lives only while the run sits in ERROR: as soon as
      // it moves on, the readout must not keep a stale "why it failed".
      error: status == RunStatus.error ? (error ?? state?.error) : null,
      ghostGap: keepGap,
      routeProgress: session.loopLength <= 0
          ? 0
          : session.distanceM / session.loopLength,
      gpsQuality: status == RunStatus.gpsAcquiring
          ? 'reduced'
          : qualityForGpsAccuracy(accuracy),
      offRoute: offRoute,
      hasUnsavedData: hasUnsavedData,
      route: session.route,
      ghostPosition: ghostPosition ?? state?.ghostPosition,
      startedAt: session.startedAt,
      rawFixCount: session.rawFixes.length,
      backgroundProtection: _protection,
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
    this.clockSeconds = 0,
    this.loopLength = 0,
  }) : startedAt = startedAt ?? DateTime.now().toUtc(),
       moving = Elapsed.seconds(movingSeconds);

  final DateTime startedAt;
  Route? route;
  List<GeoPoint> geometry = const [];
  double loopLength = 0;
  Ghost? ghost;
  Elapsed moving = Elapsed.zero();

  /// Wall-clock seconds run so far, excluding paused stretches (the recorder's
  /// stopwatch). Separate from [moving]: a parked phone still sees the clock
  /// tick while its motion-gated distance and PB stay at zero.
  double clockSeconds = 0;
  double distanceM;

  /// Every raw GPS observation received this session (M15 Phase 12), in
  /// arrival order. Unlike `_synthesizeTrack` (25 m display/persist samples),
  /// this is the complete pre-processing trace.
  final List<GpsFix> rawFixes = [];
}
