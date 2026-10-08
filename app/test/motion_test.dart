// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/core/ui/app_motion.dart';

void main() {
  Finder opacityOf() => find.descendant(
        of: find.byType(StaggeredIn),
        matching: find.byType(Opacity),
      );

  testWidgets('StaggeredIn honors its delay, then settles fully visible',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StaggeredIn(
            delay: const Duration(milliseconds: 100),
            duration: const Duration(milliseconds: 200),
            child: const Text('In'),
          ),
        ),
      ),
    );

    // First frame: the reveal has not started.
    await tester.pump();
    expect(tester.widget<Opacity>(opacityOf()).opacity, 0);

    // Still inside the delay window.
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.widget<Opacity>(opacityOf()).opacity, 0);

    // One-shot: it ends opaque and no frames are left for pumpAndSettle.
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(opacityOf()).opacity, 1);
    expect(find.text('In'), findsOneWidget);
  });

  testWidgets('disabled animations reveal the child immediately',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: const StaggeredIn(child: Text('In')),
          ),
        ),
      ),
    );

    await tester.pump();
    // No wrapper at all — the child renders directly (§32).
    expect(find.byType(Opacity), findsNothing);
    expect(find.text('In'), findsOneWidget);
  });
}
