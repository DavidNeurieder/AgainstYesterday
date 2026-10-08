// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/widgets/performance_gap.dart';

void main() {
  Future<void> pumpGap(
    WidgetTester tester, {
    required AheadBehind state,
    Elapsed difference = const Elapsed.seconds(12),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
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
      ),
    );
  }

  /// Seconds currently rendered by the hero label (`0:41` / `+0:41`).
  double labelSeconds(WidgetTester tester) {
    final data = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .firstWhere(RegExp(r'^\+?\d+:\d\d$').hasMatch);
    final match = RegExp(r'^\+?(\d+):(\d\d)$').firstMatch(data)!;
    return (int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!))
        .toDouble();
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

  testWidgets('the gap digits tween between values (§30)', (tester) async {
    await pumpGap(tester, state: AheadBehind.ahead);
    expect(find.text('0:12'), findsOneWidget);

    // A tick pushes the gap out to 1:00 — the digits glide, then land.
    await pumpGap(
      tester,
      state: AheadBehind.ahead,
      difference: const Elapsed.seconds(60),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final mid = labelSeconds(tester);
    expect(mid, greaterThan(12));
    expect(mid, lessThan(60));

    await tester.pumpAndSettle();
    expect(find.text('1:00'), findsOneWidget);
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