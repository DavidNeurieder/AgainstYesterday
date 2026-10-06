// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/core/units.dart';

void main() {
  group('Distance', () {
    test('conversions', () {
      expect(Distance.kilometers(1).meters, 1000);
      expect(Distance.meters(412).kilometers, closeTo(0.412, 1e-9));
    });

    test('arithmetic', () {
      final a = Distance.meters(300) + Distance.meters(112);
      expect(a.meters, 412);
      expect((Distance.meters(6) * 3).meters, 18);
      expect(
        (Distance.meters(500) - Distance.meters(150)).meters,
        350,
      );
    });

    test('equality uses tolerance', () {
      expect(Distance.meters(1.0), Distance.meters(1.00000000001));
      expect(Distance.meters(1), isNot(Distance.meters(1.01)));
    });

    test('formatting', () {
      expect(Distance.meters(412).format(), '412 m');
      expect(Distance.meters(4120).format(), '4.12 km');
      expect(Distance.zero().format(), '0 m');
    });
  });

  group('Elapsed', () {
    test('constructors', () {
      expect(Elapsed.seconds(90).seconds, 90);
      expect(Elapsed.minutes(2).seconds, 120);
      expect(Elapsed.hours(1).seconds, 3600);
    });

    test('format h:m:s', () {
      expect(Elapsed.seconds(20).format(), '0:20');
      expect(Elapsed.seconds(1940).format(), '32:20');
      expect(const Elapsed.seconds(3872).format(), '1:04:32');
    });

    test('format clock', () {
      expect(const Elapsed.seconds(3872).formatClock(), '01:04:32');
      expect(Elapsed.zero().formatClock(), '00:00:00');
    });

    test('addition', () {
      final sum = Elapsed.minutes(30) + Elapsed.minutes(2) + Elapsed.seconds(20);
      expect(sum.wholeSeconds, 1940);
    });
  });

  group('Speed', () {
    test('pace round trip', () {
      final s = Speed.fromPaceSecondsPerKm(300);
      expect(s.metersPerSecond, closeTo(3.333, 0.001));
      expect(s.paceSecondsPerKm, closeTo(300, 0.001));
      expect(s.formatPace(), '5:00 /km');
      expect(s.format(), '12.0 km/h');
    });

    test('stationary', () {
      final parked = Speed.zero();
      expect(parked.formatPace(), '— /km');
      expect(parked.format(), '0.0 km/h');
    });
  });
}