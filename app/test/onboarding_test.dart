// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/features/settings/application/settings_controller.dart';
import 'package:against_yesterday/features/settings/domain/settings.dart';
import 'package:against_yesterday/persistence/persistence.dart';

/// M29: first-launch onboarding (§34) — three screens, GET STARTED landing
/// in record-a-route, and a gate that only a real install (a [JsonFileStore])
/// ever trips: hermetic test stores skip the intro outright.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('onboarding');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Widget storeApp() => ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
        ],
        child: const AgainstYesterdayApp(),
      );

  testWidgets(
      'a fresh install walks the three screens and starts recording',
      (tester) async {
    await tester.pumpWidget(storeApp());
    await tester.pumpAndSettle();

    // Screen 1 per §34: title + tagline, no exit yet.
    expect(find.text('Against Yesterday'), findsOneWidget);
    expect(find.text('Race your best.'), findsOneWidget);
    expect(find.text('GET STARTED'), findsNothing);

    // Screen 2: the route promise.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('Choose a route.'), findsOneWidget);
    expect(
      find.text('Your previous best becomes your opponent.'),
      findsOneWidget,
    );
    expect(find.text('GET STARTED'), findsNothing);

    // Screen 3: the gap promise plus the only exit action.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pumpAndSettle();
    expect(find.text('See the gap.'), findsOneWidget);
    expect(
      find.text('Know exactly when you\'re winning or losing.'),
      findsOneWidget,
    );
    expect(find.text('GET STARTED'), findsOneWidget);

    // GET STARTED marks the flag seen and drops into record-a-route (§34:
    // "immediately take the user to Record your first route").
    await tester.tap(find.text('GET STARTED'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('GET STARTED'), findsNothing);
    expect(find.text('Record Route'), findsOneWidget);

    // The gate flipped in memory the moment the button was pressed…
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    expect(container.read(settingsRepositoryProvider).onboardingSeen, isTrue);

    // …and the background write reaches the document, so a relaunch over
    // the same store skips the intro (real file IO needs real event-loop
    // turns, which pump() alone does not provide).
    for (var i = 0;
        i < 10 && !File('${dir.path}/settings.json').existsSync();
        i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(File('${dir.path}/settings.json').existsSync(), isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(storeApp());
    await tester.pumpAndSettle();
    expect(find.text('Against Yesterday'), findsNothing);
    expect(find.text('GET STARTED'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Your first race awaits.'), findsOneWidget);
  });

  testWidgets('an already-seen install never enters the intro',
      (tester) async {
    File('${dir.path}/settings.json').writeAsStringSync(
      appSettingsToJson(AppSettings.defaults),
    );
    await tester.pumpWidget(storeApp());
    await tester.pumpAndSettle();
    expect(find.text('Against Yesterday'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Your first race awaits.'), findsOneWidget);
  });

  group('the gate', () {
    test('hermetic stores are always seen', () {
      final container = ProviderContainer(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            const NoopPersistenceStore(),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(onboardingSeenProvider), isTrue);
    });

    test('a missing settings document means a fresh install', () {
      final container = ProviderContainer(
        overrides: [
          persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(onboardingSeenProvider), isFalse);
    });

    test('the persisted flag decides once the document exists', () async {
      await JsonFileStore(dir).write('settings', '{"onboarding":false}');
      final container = ProviderContainer(
        overrides: [
          persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(onboardingSeenProvider), isFalse);
    });

    test('documents written before M29 count as already seen', () async {
      await JsonFileStore(dir).write('settings', '{"haptics":false}');
      final container = ProviderContainer(
        overrides: [
          persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(onboardingSeenProvider), isTrue);
    });
  });
}
