// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// §33: the app explains why it needs location *before* Android's own
/// permission dialog can appear — once per install, on a real store, and only
/// while that dialog would actually be shown.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/engine/device_gps_source.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/features/settings/application/settings_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

/// A device receiver with a scripted permission state.
class _ScriptedGpsSource implements GpsSource {
  _ScriptedGpsSource({this.askable = true});

  /// Whether Android would still show its own permission dialog.
  final bool askable;

  @override
  String get description => 'scripted test GPS';

  @override
  Future<String?> ensureAvailable() async => null;

  @override
  Future<bool> canAskPermission() async => askable;

  @override
  Stream<GpsFix> fixes() => const Stream<GpsFix>.empty();

  @override
  Future<void> openSettings() async {}
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('location-rationale');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Widget storeApp({GpsSource? source, bool? rationaleSeen}) => ProviderScope(
    overrides: [
      // A real store: the gate only trips on an install with no settings
      // document yet, exactly like the first-launch intro.
      persistenceStoreProvider.overrideWithValue(JsonFileStore(dir)),
      if (source != null) deviceGpsProvider.overrideWithValue(source),
      if (rationaleSeen != null)
        locationRationaleSeenProvider.overrideWithValue(rationaleSeen),
    ],
    child: const AgainstYesterdayApp(),
  );

  /// Walks the first-launch intro and lands in record-a-route, the shortest
  /// path from a fresh install to a run flow.
  Future<void> startRecording(WidgetTester tester, Widget app) async {
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pumpAndSettle();
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
    await tester.pumpAndSettle();
    await tester.tap(find.text('GET STARTED'));
    // Explicit pumps, not pumpAndSettle: the prep screen keeps an acquiring
    // animation running, which would never settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  /// Reads the app's own provider container out of the pumped widget tree.
  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  testWidgets('a fresh install explains location before the run flow starts',
      (tester) async {
    await startRecording(tester, storeApp(source: _ScriptedGpsSource()));

    // The explanation precedes preparation: no session exists behind it yet.
    expect(find.text('Why location?'), findsOneWidget);
    expect(
      containerOf(tester).read(recordingControllerProvider),
      isNull,
      reason: 'the explanation comes before the session asks for permission',
    );

    await tester.tap(find.byKey(const ValueKey('location-rationale-continue')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));

    // Dismissed, the flow prepares exactly as it would have without the gate.
    expect(find.text('Why location?'), findsNothing);
    expect(find.text('START RECORDING'), findsOneWidget);
    expect(containerOf(tester).read(recordingControllerProvider), isNotNull);

    // …and the explanation is recorded as given, so it never repeats.
    expect(
      containerOf(tester).read(settingsRepositoryProvider).locationRationaleSeen,
      isTrue,
    );
  });

  testWidgets('an explanation already given opens the flow straight away',
      (tester) async {
    await startRecording(
      tester,
      storeApp(source: _ScriptedGpsSource(), rationaleSeen: true),
    );

    expect(find.text('Why location?'), findsNothing);
    expect(containerOf(tester).read(recordingControllerProvider), isNotNull);
  });

  testWidgets('no explanation when Android has no dialog left to show',
      (tester) async {
    // Permission already granted (or permanently denied): there is no system
    // dialog to introduce, so the app stays quiet.
    await startRecording(
      tester,
      storeApp(source: _ScriptedGpsSource(askable: false)),
    );

    expect(find.text('Why location?'), findsNothing);
    expect(containerOf(tester).read(recordingControllerProvider), isNotNull);
  });

  testWidgets('the demo timeline is never interrupted by the explanation',
      (tester) async {
    // No device receiver wired in (host, widget tests, the E2E default), so
    // there is no permission to explain.
    await startRecording(tester, storeApp());

    expect(find.text('Why location?'), findsNothing);
    expect(containerOf(tester).read(recordingControllerProvider), isNotNull);
  });
}
