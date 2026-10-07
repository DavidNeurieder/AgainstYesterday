// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/core/theme/app_theme.dart';
import 'package:against_yesterday/persistence/persistence.dart';
import 'package:against_yesterday/app/router.dart';
import 'package:against_yesterday/engine/rust_engine_service.dart';
import 'package:against_yesterday/widgets/route_map.dart';

import 'test_catalog.dart';

/// M9 end-to-end check: the *record flow UI* against the real Rust engine
/// over FFI — the "swap the implementation, keep the UI unchanged" promise.
void main() {
  const envPath = String.fromEnvironment('GPS_ENGINE_LIB');
  // See rust_engine_test.dart: skip locally when the cdylib is unbuilt, but
  // fail in CI, where building it first is part of the job's own contract.
  const requireEngine = bool.fromEnvironment('REQUIRE_RUST_ENGINE');
  final candidates = envPath.isNotEmpty
      ? [envPath]
      : [
          '../target/release/libgps_engine.so',
          'build/libgps_engine.so',
          'target/release/libgps_engine.so',
        ];

  testWidgets('record flow runs on the Rust engine', (tester) async {
    final path = candidates.where(FileSystemEntity.isFileSync).firstOrNull;
    if (path == null) {
      if (requireEngine) {
        fail(
            'REQUIRE_RUST_ENGINE is set but no cdylib was found (searched: '
            '${candidates.join(', ')}). Build it first: '
            'cargo build --release -p gps-engine');
      }
      markTestSkipped(
        'libgps_engine.so not found (searched: ${candidates.join(', ')}). '
        'Run `cargo build --release` in the workspace root.',
      );
      return;
    }

    final engine = RustEngineService.open(path);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          engineServiceProvider.overrideWithValue(engine),
          // Seed a route so the race flow has a PB ghost for the Rust engine
          // to prepare: the shipped app starts with an empty catalog, and an
          // empty Home leads into the record-route flow (M18), not a race.
          persistenceStoreProvider.overrideWithValue(
            seededStore(routes: [riverLoopRoute]),
          ),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          routerConfig: buildRouter(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'RACE YOUR BEST'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('READY TO RUN'), findsOneWidget);
    await tester.tap(find.text('START'));
    // The 3-2-1-GO race countdown (§11) reaches the live phase.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 400));

    // Live phase with the map and its markers.
    expect(find.text('PAUSE'), findsOneWidget);
    expect(find.text('FINISH'), findsOneWidget);
    expect(find.byType(RouteMap), findsOneWidget);
    expect(find.byKey(const ValueKey('you-marker')), findsOneWidget);

    await tester.tap(find.text('FINISH'));
    await tester.pump();
    expect(find.text('RUN COMPLETE'), findsOneWidget);
  });
}