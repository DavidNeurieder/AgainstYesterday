// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// A failed foreground-service start is surfaced on the live run screen —
/// the UI must never claim screen-off protection it does not have.
library;

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/presentation/live_run_screen.dart';

void main() {
  testWidgets('unavailable protection shows the banner', (tester) async {
    await _pump(
      tester,
      const LiveRunState(
        status: RunStatus.running,
        elapsed: Elapsed.zero(),
        distance: Distance.meters(0),
        pace: Speed.metersPerSecond(3.2),
        routeProgress: 0,
        backgroundProtection: BackgroundProtection.unavailable,
      ),
    );

    expect(
      find.text('SCREEN-OFF RECORDING NOT PROTECTED'),
      findsOneWidget,
    );
    expect(
      find.text('The run is still recording while the screen is on.'),
      findsOneWidget,
    );
  });

  testWidgets('active protection shows no banner', (tester) async {
    await _pump(
      tester,
      const LiveRunState(
        status: RunStatus.running,
        elapsed: Elapsed.zero(),
        distance: Distance.meters(0),
        pace: Speed.metersPerSecond(3.2),
        routeProgress: 0,
        backgroundProtection: BackgroundProtection.active,
      ),
    );

    expect(
      find.text('SCREEN-OFF RECORDING NOT PROTECTED'),
      findsNothing,
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