// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gps_app/core/units.dart';
import 'package:gps_app/engine/models.dart';
import 'package:gps_app/widgets/performance_gap.dart';

void main() {
  Future<void> pumpGap(
    WidgetTester tester, {
    required AheadBehind state,
    Elapsed difference = const Elapsed.seconds(12),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Center(
            child: PerformanceGap(
              difference: difference,
              distance: const Distance.meters(500),
              state: state,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('ahead state shows a signed label', (tester) async {
    await pumpGap(tester, state: AheadBehind.ahead);
    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('AHEAD · at 500 m'), findsOneWidget);
  });

  testWidgets('behind state shows an explicit plus', (tester) async {
    await pumpGap(tester, state: AheadBehind.behind);
    expect(find.text('+0:12'), findsOneWidget);
    expect(find.text('BEHIND · at 500 m'), findsOneWidget);
  });

  testWidgets('tied and unknown states', (tester) async {
    await pumpGap(
      tester,
      state: AheadBehind.tied,
      difference: const Elapsed.seconds(0),
    );
    expect(find.text('0:00'), findsOneWidget);

    await pumpGap(tester, state: AheadBehind.unknown);
    expect(find.text('—'), findsOneWidget);
  });

  test('AheadBehind.fromGap maps a GhostState', () {
    GhostState gap({
      required bool ahead,
      double seconds = 5,
    }) => GhostState(
      distance: const Distance.meters(100),
      timeDifference: Elapsed.seconds(seconds),
      ahead: ahead,
    );

    expect(AheadBehind.fromGap(gap(ahead: true, seconds: -5)), AheadBehind.ahead);
    expect(AheadBehind.fromGap(gap(ahead: false, seconds: 5)), AheadBehind.behind);
    expect(AheadBehind.fromGap(gap(ahead: true, seconds: 0)), AheadBehind.tied);
  });
}