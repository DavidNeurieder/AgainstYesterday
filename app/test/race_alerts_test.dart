// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// M25: race feedback overlays — the §17 weak-GPS banner, the §18
/// off-route state, and the pure signals that drive both.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';

import 'test_catalog.dart';

LiveRunState live({
  RunStatus status = RunStatus.running,
  String gpsQuality = 'good',
  Distance? offRoute,
}) =>
    LiveRunState(
      status: status,
      elapsed: Elapsed.seconds(61),
      distance: Distance.meters(800),
      pace: Speed.metersPerSecond(3.2),
      routeProgress: 0.16,
      gpsQuality: gpsQuality,
      offRoute: offRoute,
      route: demoRoutes.first,
    );

Future<void> pumpLive(WidgetTester tester, LiveRunState state) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildAppTheme(),
        home: LiveRunScreen(state: state),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('qualityForGpsAccuracy (§17)', () {
    test('buckets the fix accuracy into good/reduced/poor', () {
      expect(qualityForGpsAccuracy(null), 'good');
      expect(qualityForGpsAccuracy(5), 'good');
      expect(qualityForGpsAccuracy(14.9), 'good');
      expect(qualityForGpsAccuracy(15), 'reduced');
      expect(qualityForGpsAccuracy(39.9), 'reduced');
      expect(qualityForGpsAccuracy(40), 'poor');
      expect(qualityForGpsAccuracy(120), 'poor');
    });
  });

  group('offRouteDistance (§18)', () {
    // A ~3.5 km east-west segment at 51°N.
    final geometry = [
      const GeoPoint(latitude: 51.0, longitude: 7.0),
      const GeoPoint(latitude: 51.0, longitude: 7.05),
    ];

    test('is null without a position or real geometry', () {
      expect(offRouteDistance(geometry: geometry, position: null), isNull);
      expect(
        offRouteDistance(
          geometry: const [GeoPoint(latitude: 51.0, longitude: 7.0)],
          position: const GeoPoint(latitude: 51.0, longitude: 7.0),
        ),
        isNull,
      );
    });

    test('is null while on or close to the line', () {
      expect(
        offRouteDistance(
          geometry: geometry,
          position: const GeoPoint(latitude: 51.0, longitude: 7.02),
        ),
        isNull,
      );
      // ~20 m north of the line: inside the 30 m threshold.
      expect(
        offRouteDistance(
          geometry: geometry,
          position: const GeoPoint(latitude: 51.00018, longitude: 7.02),
        ),
        isNull,
      );
    });

    test('measures the lateral distance once beyond the threshold', () {
      // ~42 m north of the line.
      final off = offRouteDistance(
        geometry: geometry,
        position: const GeoPoint(latitude: 51.0003773, longitude: 7.02),
      );
      expect(off, isNotNull);
      expect(off!.meters, closeTo(42, 1));

      // The same 42 m passes a raised threshold.
      expect(
        offRouteDistance(
          geometry: geometry,
          position: const GeoPoint(latitude: 51.0003773, longitude: 7.02),
          thresholdMeters: 50,
        ),
        isNull,
      );
    });
  });

  group('weak GPS banner (§17)', () {
    testWidgets('appears for reduced or poor quality', (tester) async {
      await pumpLive(tester, live(gpsQuality: 'poor'));
      expect(find.text('GPS SIGNAL WEAK'), findsOneWidget);
      expect(
        find.text('Your position may be temporarily inaccurate.'),
        findsOneWidget,
      );

      await pumpLive(tester, live(gpsQuality: 'reduced'));
      expect(find.text('GPS SIGNAL WEAK'), findsOneWidget);
    });

    testWidgets('stays hidden while quality is good', (tester) async {
      await pumpLive(tester, live());
      expect(find.text('GPS SIGNAL WEAK'), findsNothing);
      expect(
        find.text('Your position may be temporarily inaccurate.'),
        findsNothing,
      );
    });
  });

  group('off-route overlay (§18)', () {
    testWidgets('shows the distance with the race screen underneath',
        (tester) async {
      await pumpLive(tester, live(offRoute: Distance.meters(42)));
      expect(find.text('OFF ROUTE'), findsOneWidget);
      expect(find.text('42 m away'), findsOneWidget);
      expect(
        find.text('Return to the route\nto continue your race.'),
        findsOneWidget,
      );
      // The race screen stays visible underneath.
      expect(find.text('PAUSE'), findsOneWidget);
      expect(find.text('FINISH'), findsOneWidget);
    });

    testWidgets('is hidden while on the route', (tester) async {
      await pumpLive(tester, live());
      expect(find.text('OFF ROUTE'), findsNothing);
      expect(find.textContaining('away'), findsNothing);
    });
  });
}
