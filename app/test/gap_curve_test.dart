// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// M26 (§23): the gap-to-PB curve and the performance graph built from it.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/fake_engine.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/result/application/gap_curve.dart';
import 'package:against_yesterday/features/result/presentation/gap_chart.dart';

Route _route({double? pbSeconds = 1500}) => Route(
      id: FakeEngineService.riverLoopId,
      name: 'River Loop',
      distance: const Distance.meters(5000),
      geometry: FakeEngineService.riverLoop,
      attemptCount: 3,
      personalBest: pbSeconds == null ? null : Elapsed.seconds(pbSeconds),
    );

/// A flat track: 25 m-spaced points covering `meters`, timed so the last
/// point is at `totalSeconds` (mirrors [splits_test]'s fixture).
List<TrackPoint> _track(double meters, double totalSeconds) {
  final start = DateTime.utc(2026, 1, 1);
  final points = <TrackPoint>[];
  for (var d = 0.0; d <= meters; d += 25.0) {
    final fraction = meters <= 0 ? 0.0 : d / meters;
    points.add(TrackPoint(
      position: GeoPoint(latitude: 52.5 + fraction, longitude: 13.36),
      timestamp: start.add(Duration(
        milliseconds: (totalSeconds * 1000 * fraction).round(),
      )),
    ));
  }
  return points;
}

Activity _activity({List<TrackPoint>? track}) => Activity(
      id: 'a',
      routeId: FakeEngineService.riverLoopId,
      startedAt: DateTime.utc(2026, 1, 1),
      duration: Elapsed.seconds(1700),
      distance: Distance.meters(5000),
      track: track,
    );

List<GapPoint> _curve({
  required double meters,
  required double seconds,
  double? pbSeconds = 1500,
  double? trackMeters,
}) =>
    computeGapCurve(
      activity: _activity(track: _track(meters, seconds)),
      route: _route(pbSeconds: pbSeconds),
      trackMeters: trackMeters ?? meters,
    );

void main() {
  group('computeGapCurve', () {
    test('is empty without a PB, a track, or enough distance', () {
      expect(
        _curve(meters: 5000, seconds: 1700, pbSeconds: null),
        isEmpty,
        reason: 'no PB → no curve',
      );
      expect(
        computeGapCurve(
          activity: _activity(),
          route: _route(),
          trackMeters: 5000,
        ),
        isEmpty,
        reason: 'no track → no curve',
      );
      expect(
        _curve(meters: 120, seconds: 45, trackMeters: 120),
        isEmpty,
        reason: 'under gapChartMinimumMeters → no curve',
      );
    });

    test('starts at the origin and samples every 100 m to the finish', () {
      final curve = _curve(meters: 5000, seconds: 1700);
      expect(curve.first.distanceMeters, 0);
      expect(curve.first.aheadSeconds, 0);
      expect(curve, hasLength(51)); // origin + 100…4900 + finish
      expect(curve[1].distanceMeters, gapSampleStepMeters);
      expect(curve.last.distanceMeters, 5000);
      for (var i = 1; i < curve.length; i++) {
        expect(curve[i].distanceMeters, greaterThan(curve[i - 1].distanceMeters),
            reason: 'samples must be strictly increasing');
      }
    });

    test('a PB-matched run stays at zero along the whole curve', () {
      final curve = _curve(meters: 5000, seconds: 1500);
      expect(curve, hasLength(51));
      for (final point in curve) {
        expect(point.aheadSeconds.abs(), lessThan(0.05),
            reason: 'at ${point.distanceMeters} m');
      }
    });

    test('a slower run falls behind linearly (positive = ahead)', () {
      // 5 km in 1700 s vs a 1500 s PB: −0.04 s per meter.
      final curve = _curve(meters: 5000, seconds: 1700);
      for (final point in curve) {
        expect(point.aheadSeconds, lessThan(0.01),
            reason: 'at ${point.distanceMeters} m');
      }
      expect(curve[10].aheadSeconds, closeTo(-40, 2)); // 1000 m
      expect(curve.last.aheadSeconds, closeTo(-200, 3));
    });

    test('a faster run pulls ahead linearly', () {
      // 5 km in 1300 s vs a 1500 s PB: +0.04 s per meter.
      final curve = _curve(meters: 5000, seconds: 1300);
      for (final point in curve) {
        expect(point.aheadSeconds, greaterThan(-0.01),
            reason: 'at ${point.distanceMeters} m');
      }
      expect(curve[10].aheadSeconds, closeTo(40, 2));
      expect(curve.last.aheadSeconds, closeTo(200, 3));
    });

    test('includes the exact end of a partial run', () {
      final curve = _curve(meters: 950, seconds: 300, trackMeters: 950);
      expect(curve.first.distanceMeters, 0);
      expect(curve.last.distanceMeters, 950);
      expect(curve, hasLength(11)); // origin + 100…900 + 950
    });
  });

  group('GapChart', () {
    Future<GapChart> pumpChart(
      WidgetTester tester,
      List<GapPoint> curve, {
      Units units = Units.kilometers,
    }) async {
      final chart = GapChart(curve: curve, units: units);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: chart)),
        ),
      );
      await tester.pumpAndSettle();
      return chart;
    }

    testWidgets(
        'titles the graph and summarises the finish for semantics',
        semanticsEnabled: true,
        (tester) async {
      await pumpChart(tester, const [
        GapPoint(distanceMeters: 0, aheadSeconds: 0),
        GapPoint(distanceMeters: 800, aheadSeconds: -5),
        GapPoint(distanceMeters: 1500, aheadSeconds: 12),
      ]);
      expect(find.text('GAP TO YOUR BEST'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Gap to your best: ahead 0:12 at the finish.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'summarises a behind finish',
        semanticsEnabled: true,
        (tester) async {
      await pumpChart(tester, const [
        GapPoint(distanceMeters: 0, aheadSeconds: 0),
        GapPoint(distanceMeters: 1500, aheadSeconds: -31),
      ]);
      expect(
        find.bySemanticsLabel(
          'Gap to your best: behind 0:31 at the finish.',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
        'summarises a dead heat',
        semanticsEnabled: true,
        (tester) async {
      await pumpChart(tester, const [
        GapPoint(distanceMeters: 0, aheadSeconds: 0),
        GapPoint(distanceMeters: 1500, aheadSeconds: 0),
      ]);
      expect(
        find.bySemanticsLabel(
          'Gap to your best: even with your best at the finish.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders nothing for a degenerate curve', (tester) async {
      await pumpChart(tester, const [
        GapPoint(distanceMeters: 0, aheadSeconds: 0),
      ]);
      expect(find.text('GAP TO YOUR BEST'), findsNothing);
    });
  });
}
