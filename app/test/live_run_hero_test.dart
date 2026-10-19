// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// §2: the gap is the hero metric of the live screen.
///
/// The race readout must out-rank distance — biggest type, the semantic
/// ahead/behind colour, and the rest of the row to itself instead of a
/// squeezed fixed box — because it is the one number that answers "am I
/// winning?". Without a ghost to race there is no gap, and distance is the
/// hero by default.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_colors.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';

/// A live race state with a scripted gap.
LiveRunState racing({
  double gapSeconds = 12,
  bool ahead = false,
  double meters = 800,
}) => LiveRunState(
  status: RunStatus.running,
  elapsed: const Elapsed.seconds(61),
  distance: Distance.meters(meters),
  pace: const Speed.metersPerSecond(3.2),
  routeProgress: 0.16,
  ghostGap: GhostState(
    distance: Distance.meters(meters),
    timeDifference: Elapsed.seconds(gapSeconds),
    ahead: ahead,
  ),
);

/// The Text rendering the gap's own digits, not its state label.
Text gapDigits(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('live-gap')),
        matching: find.byType(Text),
      ),
    )
    .firstWhere((t) => RegExp(r'^\+?\d+:\d\d(:\d\d)?$').hasMatch(t.data ?? ''));

void main() {
  testWidgets('the gap outranks distance as the hero readout', (tester) async {
    await _pump(tester, racing());

    final gap = find.byKey(const ValueKey('live-gap'));
    expect(gap, findsOneWidget);
    // The gap block is no longer squeezed into a fixed 168 px box.
    expect(tester.getSize(gap).width, greaterThan(168));

    // Its seconds are the biggest digits in the hero row.
    final distance = tester.widget<Text>(
      find.byKey(const ValueKey('live-distance')),
    );
    expect(
      gapDigits(tester).style!.fontSize!,
      greaterThan(distance.style!.fontSize!),
    );

    // The racing distance is the supporting read: muted beside the coloured
    // ahead/behind digits.
    expect(distance.style!.color, AppColors.textSecondary);
    expect(gapDigits(tester).style!.color, isNot(AppColors.textSecondary));
  });

  testWidgets('without a ghost, distance stays the hero', (tester) async {
    await _pump(
      tester,
      const LiveRunState(
        status: RunStatus.running,
        elapsed: Elapsed.seconds(61),
        distance: Distance.meters(800),
        pace: Speed.metersPerSecond(3.2),
        routeProgress: 0.16,
      ),
    );

    expect(find.byKey(const ValueKey('live-gap')), findsNothing);
    final distance = tester.widget<Text>(
      find.byKey(const ValueKey('live-distance')),
    );
    final theme = Theme.of(
      tester.element(find.byKey(const ValueKey('live-distance'))),
    );
    expect(distance.style!.fontSize, theme.textTheme.displayMedium!.fontSize);
    expect(distance.style!.color, isNot(AppColors.textSecondary));
  });

  testWidgets('an hour-long gap still fits on a 320 px phone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // "+1:08:21" — the widest a gap can get (an hour or more). A layout
    // overflow here would fail the test outright; the scale-down keeps it in.
    await _pump(tester, racing(gapSeconds: 4101, meters: 2410));

    expect(find.text('+1:08:21'), findsOneWidget);
    expect(
      gapDigits(tester).style!.fontSize!,
      greaterThan(
        tester
            .widget<Text>(find.byKey(const ValueKey('live-distance')))
            .style!
            .fontSize!,
      ),
    );
  });
}

Future<void> _pump(WidgetTester tester, LiveRunState state) async {
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
