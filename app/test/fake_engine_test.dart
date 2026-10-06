// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';

void main() {
  group('FakeEngineService', () {
    test('generated recordings are deterministic', () {
      final a = FakeEngineService(seed: 7).generateRecording();
      final b = FakeEngineService(seed: 7).generateRecording();
      final c = FakeEngineService(seed: 8).generateRecording();

      expect(a.first.position, b.first.position);
      expect(a.length, b.length);
      // Different seed -> different jitter on the interior points.
      expect(a[150].position, isNot(c[150].position));
    });

    test('recording follows the river loop geometry', () {
      final engine = FakeEngineService();
      // Noise off: the track polyline matches the loop's geometry length.
      final points = engine.generateRecording(noiseMeters: 0);
      expect(points.length, greaterThan(200));
      final distance = polylineMeters(
        points.map((p) => p.position).toList(growable: false),
      );
      expect(distance, closeTo(4760, 300));
    });

    test('track order and timestamps are monotonic', () {
      final points = FakeEngineService().generateRecording();
      for (var i = 1; i < points.length; i++) {
        expect(
          points[i].timestamp.isAfter(points[i - 1].timestamp),
          isTrue,
        );
      }
    });

    test('processTrack summarizes deterministic', () async {
      final engine = FakeEngineService();
      final recording = engine.generateRecording();
      final first = await engine.processTrack(id: 'a', points: recording);
      final second = await engine.processTrack(id: 'b', points: recording);

      expect(first.inputPoints, recording.length);
      expect(first.outputPoints, lessThanOrEqualTo(first.inputPoints));
      expect(first.inputPoints, second.inputPoints);
      expect(first.processedDistance.meters, second.processedDistance.meters);
      expect(first.duration.format(), second.duration.format());
    });

    test('matching: same route matches, different geometry does not', () async {
      final engine = FakeEngineService();
      final a = engine.generateRecording();
      final b = engine.generateRecording(); // same route, later in sequence
      final result = await engine.matchRoutes(a: a, b: b);
      expect(result.sameRoute, isTrue);
      expect(result.score.spatialOverlap, greaterThan(0.9));

      // Different geometry: fixed points far from the loop.
      final far = [
        for (var i = 0; i < 100; i++)
          TrackPoint(
            position: GeoPoint(
              latitude: 52.2000 + i * 0.0001,
              longitude: 13.9000 + i * 0.0001,
            ),
            timestamp: DateTime.fromMillisecondsSinceEpoch(i * 1000),
          ),
      ];
      final other = await engine.matchRoutes(a: a, b: far);
      expect(other.sameRoute, isFalse);
      expect(other.score.spatialOverlap, lessThan(0.2));
    });

    test('attempt has monotonic samples', () async {
      final engine = FakeEngineService();
      final recording = engine.generateRecording();
      final attempt = await engine.createAttempt(
        activityId: 'act-1',
        routeId: FakeEngineService.riverLoopId,
        points: recording,
        routeGeometry: FakeEngineService.riverLoop,
      );

      expect(attempt.activityId, 'act-1');
      expect(attempt.samples.length, greaterThan(10));
      var lastDistance = -1.0;
      var lastElapsed = -1.0;
      for (final s in attempt.samples) {
        expect(s.distance.meters, greaterThan(lastDistance));
        expect(s.elapsed.seconds, greaterThanOrEqualTo(lastElapsed));
        lastDistance = s.distance.meters;
        lastElapsed = s.elapsed.seconds;
      }
    });

    test('ghost state: equal attempts are even', () async {
      final engine = FakeEngineService();
      final recording = engine.generateRecording();
      final attempt = await engine.createAttempt(
        activityId: 'a',
        routeId: FakeEngineService.riverLoopId,
        points: recording,
        routeGeometry: FakeEngineService.riverLoop,
      );
      final ghost = Ghost(attemptId: 'a', samples: attempt.samples);

      final state = engine.ghostStateAt(
        ghost: ghost,
        current: attempt,
        distance: Distance.meters(500),
      );
      expect(state.ahead, isTrue); // 0 or negative difference
      expect(state.timeDifference.seconds, lessThanOrEqualTo(0));
    });
  });
}