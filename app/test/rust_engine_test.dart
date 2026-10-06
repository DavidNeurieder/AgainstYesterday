import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/core/units.dart';
import 'package:gps_app/engine/fake_engine.dart';
import 'package:gps_app/engine/models.dart';
import 'package:gps_app/engine/rust_engine_service.dart';

/// M9 host-side integration test: drives the real Rust engine over FFI.
///
/// Skipped when the cdylib isn't available — build it with
/// `cargo build --release -p gps-engine` at the workspace root (produces
/// `target/release/libgps_engine.so`), or point at a build via
/// `GPS_ENGINE_LIB`. CI additionally passes
/// `--dart-define=REQUIRE_RUST_ENGINE=true` so that a missing cdylib fails
/// the job rather than quietly skipping.
void main() {
  const envPath = String.fromEnvironment('GPS_ENGINE_LIB');
  // Locally, an unbuilt cdylib is normal — the tests skip with an explanation.
  // In CI the library is built first, so a missing one means the build
  // misconfigured itself; skipping would turn that into a green job with less
  // coverage than advertised. CI passes --dart-define=REQUIRE_RUST_ENGINE=true.
  const requireEngine = bool.fromEnvironment('REQUIRE_RUST_ENGINE');

  group('RustEngineService (FFI)', () {
    // Deliberately not `late`: reading an unassigned `late` local throws
    // LateInitializationError, which would turn "library absent" into a
    // failure instead of the skip below.
    RustEngineService? engine;

    setUpAll(() {
      final candidates = envPath.isNotEmpty
          ? [envPath]
          : [
              '../target/release/libgps_engine.so',
              'build/libgps_engine.so',
              'target/release/libgps_engine.so',
            ];
      final path = candidates.where(FileSystemEntity.isFileSync).firstOrNull;
      if (path == null) {
        if (requireEngine) {
          fail(
              'REQUIRE_RUST_ENGINE is set but no cdylib was found (searched: '
              '${candidates.join(', ')}). Build it first: '
              'cargo build --release -p gps-engine');
        }
        markTestSkipped(
          'libgps_engine.so not found (searched: ${candidates.join(', ')}). '
          'Run `cargo build --release` in the workspace root.',
        );
        return;
      }
      engine = RustEngineService.open(path);
    });

    test('reports its own version', () {
      final e = engine;
      if (e == null) return;
      final version = e.version;
      expect(version, isNotEmpty);
      expect(version.split('.').length, 3);
    });

    test('generates a deterministic recording of the demo loop', () {
      final e = engine;
      if (e == null) return;
      final a = e.generateRecording(
        speedMetersPerSecond: 15,
        sampleEverySeconds: 1,
        noiseMeters: 0,
      );
      final b = e.generateRecording(
        speedMetersPerSecond: 15,
        sampleEverySeconds: 1,
        noiseMeters: 0,
      );
      expect(a.length, greaterThan(2));
      expect(a.first.position, b.first.position);
      expect(a.last.position, b.last.position);
      expect(a.length, b.length);
      // Monotonic timestamps.
      for (var i = 1; i < a.length; i++) {
        expect(
          a[i].timestamp.isAfter(a[i - 1].timestamp),
          isTrue,
          reason: 'point $i must come after point ${i - 1}',
        );
      }
    });

    test('reduces a recording to an attempt on the route axis', () async {
      final e = engine;
      if (e == null) return;
      final recording = e.generateRecording(
        speedMetersPerSecond: 15,
        sampleEverySeconds: 1,
        noiseMeters: 0,
      );
      final attempt = await e.createAttempt(
        activityId: 'perf-1',
        routeId: FakeEngineService.riverLoopId,
        points: recording,
        routeGeometry: FakeEngineService.riverLoop,
      );
      expect(attempt.samples, isNotEmpty);
      expect(attempt.elapsed.seconds, greaterThan(0));
      final loop = polylineMeters(FakeEngineService.riverLoop);
      final covered = attempt.samples.last.distance.meters;
      // Coverage clamps at the closing vertex (~8 m short of full loop).
      expect(covered, closeTo(loop, 20), reason: 'coverage must approach the loop length');
      // Monotonic sample series.
      for (var i = 1; i < attempt.samples.length; i++) {
        expect(attempt.samples[i].distance.meters,
            greaterThanOrEqualTo(attempt.samples[i - 1].distance.meters));
      }
    });

    test('matches a recording against itself', () async {
      final e = engine;
      if (e == null) return;
      final recording = e.generateRecording(
        speedMetersPerSecond: 15,
        sampleEverySeconds: 1,
        noiseMeters: 0,
      );
      final result = await e.matchRoutes(a: recording, b: recording);
      expect(result.sameRoute, isTrue);
      expect(result.score.spatialOverlap, closeTo(1.0, 1e-6));
    });

    test('ghost state reports being ahead or behind', () {
      final e = engine;
      if (e == null) return;
      final ghost = Ghost(
        attemptId: 'pb',
        samples: const [
          AttemptSample(
              distance: Distance.meters(0), elapsed: Elapsed.seconds(0)),
          AttemptSample(
              distance: Distance.meters(5000), elapsed: Elapsed.seconds(1500)),
        ],
      );
      // Current run: 5 km in 1200 s -> faster than the PB.
      final current = Attempt(
        activityId: 'now',
        routeId: 'x',
        elapsed: const Elapsed.seconds(1200),
        samples: const [
          AttemptSample(
              distance: Distance.meters(0), elapsed: Elapsed.seconds(0)),
          AttemptSample(
              distance: Distance.meters(5000), elapsed: Elapsed.seconds(1200)),
        ],
      );
      final ahead = e.ghostStateAt(
        ghost: ghost,
        current: current,
        distance: const Distance.meters(5000),
      );
      expect(ahead.ahead, isTrue); // 1200 < 1500
      expect(ahead.timeDifference.seconds, closeTo(-300, 1e-6));
    });

    test('processes a track into a summary', () async {
      final e = engine;
      if (e == null) return;
      final recording = e.generateRecording(
        speedMetersPerSecond: 15,
        sampleEverySeconds: 1,
        noiseMeters: 0,
      );
      final track = await e.processTrack(id: 't1', points: recording);
      expect(track.inputPoints, recording.length);
      expect(track.outputPoints, greaterThan(0));
      expect(track.originalDistance.meters, closeTo(
          polylineMeters(FakeEngineService.riverLoop), 40));
    });
  });
}