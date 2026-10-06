// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/core/units.dart';
import 'package:gps_app/engine/models.dart';

void main() {
  group('GeoPoint', () {
    test('equality', () {
      expect(
        const GeoPoint(latitude: 1.0, longitude: 2.0),
        const GeoPoint(latitude: 1.0, longitude: 2.0),
      );
      expect(
        const GeoPoint(latitude: 1.0, longitude: 2.0),
        isNot(const GeoPoint(latitude: 1.0, longitude: 2.1)),
      );
    });
  });

  group('haversine', () {
    test('zero distance', () {
      const p = GeoPoint(latitude: 52.0, longitude: 13.0);
      expect(haversineMeters(p, p), 0);
    });

    test('known reference: 1 deg latitude ≈ 111.19 km', () {
      const a = GeoPoint(latitude: 0.0, longitude: 0.0);
      const b = GeoPoint(latitude: 1.0, longitude: 0.0);
      expect(haversineMeters(a, b), closeTo(111_195, 50));
    });

    test('polyline length', () {
      const a = GeoPoint(latitude: 0.0, longitude: 0.0);
      const b = GeoPoint(latitude: 0.0, longitude: 0.01);
      const c = GeoPoint(latitude: 0.0, longitude: 0.02);
      expect(polylineMeters(const [a, b, c]), closeTo(haversineMeters(a, c), 1));
    });
  });

  group('Models', () {
    test('route with personal best', () {
      final route = Route(
        id: 'r1',
        name: 'River Loop',
        distance: Distance.kilometers(2.1),
        geometry: const [GeoPoint(latitude: 52.0, longitude: 13.0)],
        attemptCount: 3,
        personalBest: Elapsed.minutes(10),
      );
      expect(route.personalBest!.format(), '10:00');
      expect(route.distance.format(), '2.10 km');
    });

    test('ghost state convention', () {
      // positive timeDifference == behind (ahead == false).
      final behind = GhostState(
        distance: Distance.meters(500),
        timeDifference: Elapsed.seconds(12),
        ahead: false,
      );
      expect(behind.ahead, isFalse);
    });

    test('live run state carries route progress', () {
      final live = LiveRunState(
        status: RunStatus.running,
        elapsed: Elapsed.minutes(8),
        distance: Distance.meters(1240),
        currentPosition: const GeoPoint(latitude: 52.5, longitude: 13.3),
        pace: Speed.fromPaceSecondsPerKm(320),
        ghostGap: const GhostState(
          distance: Distance.meters(1240),
          timeDifference: Elapsed.seconds(-5),
          ahead: true,
        ),
        routeProgress: 0.59,
        gpsQuality: 'good',
      );
      expect(live.routeProgress, 0.59);
      expect(live.ghostGap!.ahead, isTrue);
      expect(live.pace.formatPace(), '5:20 /km');
    });
  });
}