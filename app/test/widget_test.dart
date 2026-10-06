// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';

void main() {
  testWidgets('home shows the primary start action and catalogs', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    // Primary action per §43.
    expect(find.widgetWithText(FilledButton, 'Start a run'), findsOneWidget);

    // Section content from the seeded home directory.
    expect(find.text('River Loop'), findsWidgets);
    expect(find.text('Park 5K'), findsWidgets);
    await tester.scrollUntilVisible(find.text('Hügelrunde'), 200);
    expect(find.text('Hügelrunde'), findsWidgets);
  });

  testWidgets('shell navigates between tabs', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    Finder tab(String label) =>
        find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

    await tester.tap(tab('Routes'));
    await tester.pumpAndSettle();
    expect(find.text('River Loop'), findsWidgets);

    await tester.tap(tab('Record'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);

    await tester.tap(tab('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Start a run'), findsOneWidget);
  });

  testWidgets('start a run routes to pre-run screen', (tester) async {
    await tester.pumpWidget(const AgainstYesterdayApp());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Start a run'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('READY TO RUN'), findsOneWidget);
  });
}