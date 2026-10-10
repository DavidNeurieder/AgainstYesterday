// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The live run screen shows a FIXES readout fed by the raw-fix count the
/// controller emits in [LiveRunState.rawFixCount] — a live check that the
/// phone receiver is actually streaming fixes during a run.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';

void main() {
  testWidgets('shows the raw fix count while running', (tester) async {
    await _pump(
      tester,
      const LiveRunState(
        status: RunStatus.running,
        elapsed: Elapsed.seconds(61),
        distance: Distance.meters(800),
        pace: Speed.metersPerSecond(3.2),
        routeProgress: 0.16,
        rawFixCount: 4,
      ),
    );

    expect(find.text('FIXES'), findsOneWidget);
    final metric = find.byKey(const ValueKey('live-fixes'));
    expect(
      tester.widget<Text>(find.descendant(of: metric, matching: find.byType(Text)).last).data,
      '4',
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