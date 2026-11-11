// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/routes/application/example_routes.dart';
import 'package:against_yesterday/persistence/persistence.dart';

void main() {
  testWidgets('empty library offers example routes and installs them',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
        ],
        child: const AgainstYesterdayApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Welcome to Against Yesterday'), findsOneWidget);
    expect(find.byKey(const ValueKey('explore-examples')), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await tester.runAsync(() => installExampleRoutes(container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(container.read(routeRepositoryProvider).length, 1);
    expect(
      container.read(routeRepositoryProvider).every((r) => r.isExample),
      isTrue,
    );
    expect(container.read(activityRepositoryProvider).length, 4);
    expect(find.text('Welcome to Against Yesterday'), findsNothing);
    expect(find.text('Cycling Finland'), findsWidgets);
    expect(find.text('Example'), findsWidgets);
  });

  testWidgets('example routes are removable and restorable',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(MemoryPersistenceStore()),
        ],
        child: const AgainstYesterdayApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    await tester.runAsync(() => installExampleRoutes(container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(routeRepositoryProvider).length, 1);
    expect(container.read(activityRepositoryProvider).length, 4);

    await tester.runAsync(() => removeExampleRoutes(container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(routeRepositoryProvider).length, 0);
    expect(container.read(activityRepositoryProvider).length, 0);

    await tester.runAsync(() => installExampleRoutes(container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(container.read(routeRepositoryProvider).length, 1);
    expect(container.read(activityRepositoryProvider).length, 4);
  });
}
