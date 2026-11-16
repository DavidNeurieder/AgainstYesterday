// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared polling helpers for the on-device suites (§45).
///
/// The live binding runs on the wall clock — acquisition, GPS fixes and async
/// saves land whenever they land — so every "must happen" assertion polls
/// with a timeout instead of sleeping for a fixed duration. [waitForCondition]
/// takes an optional [diagnostics] dump so a red run shows the state that
/// never arrived.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/app/dependencies.dart';
import 'package:against_yesterday/engine/rust_engine_service.dart';
import 'package:against_yesterday/features/recording/application/recording_controller.dart';
import 'package:against_yesterday/persistence/persistence.dart';

/// Parses a distance label like `1.23 km` or `456 m` into meters.
///
/// Fails on an unreadable label instead of returning a sentinel: a present
/// but malformed value is a defect, and a silent 0 would hide it behind an
/// opaque timeout or turn an assertion into a vacuous pass (the testing
/// plan's "no silent zeros" rule).
int parseDistanceLabel(String text) {
  final match = RegExp(r'^(\d+(?:\.\d+)?)\s*(km|m)$').firstMatch(text.trim());
  if (match == null) {
    fail('unparsable distance label: "$text"');
  }
  final value = double.parse(match.group(1)!);
  return match.group(2) == 'km' ? (value * 1000).round() : value.round();
}

/// The distance shown for [key], or null when the widget is not mounted.
///
/// Not mounted is a normal polling state (the countdown before the live
/// screen, the recorder before START), so it maps to null; a mounted but
/// unreadable label still fails through [parseDistanceLabel].
///
/// [key] is a plain [Key] on purpose: a parameter typed `ValueKey` would give
/// the const at each call site the static context `ValueKey<dynamic>`, and
/// `ValueKey.operator==` rejects a mismatched type argument, so the lookup
/// would never match and every caller would silently read 0.
int? _metersOrNull(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  if (!tester.any(finder)) {
    return null;
  }
  return parseDistanceLabel(tester.widget<Text>(finder).data!);
}

Never _metersMissing(String what) => fail('$what is not on screen');

/// The distance value currently shown on the live race screen, in meters.
///
/// Returns 0 with the live screen not yet mounted (e.g. still on the 3-2-1-GO
/// countdown), so polling probes just keep waiting.
int displayedMeters(WidgetTester tester) =>
    _metersOrNull(tester, const ValueKey('live-distance')) ?? 0;

/// The distance value currently shown on the record-a-route recorder, in
/// meters. Returns 0 while the recorder is not mounted.
int recordDistanceMeters(WidgetTester tester) =>
    _metersOrNull(tester, const ValueKey('record-distance')) ?? 0;

/// Like [displayedMeters] but fails when the live screen is not mounted: for
/// assertions where a missing widget is the defect, not a wait.
int requireDisplayedMeters(WidgetTester tester) =>
    _metersOrNull(tester, const ValueKey('live-distance')) ??
    _metersMissing('live-distance');

/// Like [recordDistanceMeters] but fails when the recorder is not mounted.
int requireRecordDistanceMeters(WidgetTester tester) =>
    _metersOrNull(tester, const ValueKey('record-distance')) ??
    _metersMissing('record-distance');

/// Pumps while wall-clock time elapses (the live binding can't pump for a
/// duration), so real periodic timers fire and re-render.
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// Polls until [text] is onscreen. On-device GPS acquisition and async
/// saves happen on real timers, so a fixed await would be flaky.
Future<void> waitForText(WidgetTester tester, String text,
    {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    if (tester.any(find.text(text))) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for "$text"');
}

/// Polls until [probe] holds. Ticks and GPS fixes arrive on the wall clock,
/// and the CI emulator runs without hardware acceleration, so a fixed sleep
/// can end before the first fix does — every "must advance" assertion polls
/// instead of sleeping. [diagnostics] (when given) is appended to the
/// timeout failure so a red CI run shows the state that never arrived.
Future<void> waitForCondition(
  WidgetTester tester,
  bool Function() probe,
  String description, {
  Duration timeout = const Duration(seconds: 30),
  String Function()? diagnostics,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump();
    if (probe()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $description'
      '${diagnostics == null ? '' : '\n${diagnostics()}'}');
}

/// Polls until any on-screen text contains [text]. On-device saves and engine
/// replies are asynchronous, so a plain `expect` right after `pumpAndSettle`
/// can look at a tree that has not rebuilt yet; the poll also fails with the
/// widget tree's text (when [diagnostics] is omitted) so a missing label is
/// immediately attributable.
Future<void> waitForTextContaining(
  WidgetTester tester,
  String text, {
  Duration timeout = const Duration(seconds: 15),
  String Function()? diagnostics,
}) async {
  await waitForCondition(
    tester,
    () => tester.any(find.textContaining(text)),
    'text containing "$text"',
    timeout: timeout,
    diagnostics: diagnostics ??
        () => 'texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
  );
}

/// Fails when the suite was launched with `USE_RUST_ENGINE=true` but the app
/// is not actually running the native engine.
///
/// `connected-test-engine` exists to exercise the Rust cdylib on the device.
/// Dependencies already make a missing library a startup error, but asserting
/// the concrete implementation here names the mismatch at the test instead of
/// letting a future dependency change silently run the fake under the engine
/// target.
void expectRequestedEngine(ProviderContainer container) {
  if (!const bool.fromEnvironment('USE_RUST_ENGINE')) return;
  expect(
    container.read(engineServiceProvider),
    isA<RustEngineService>(),
    reason: 'USE_RUST_ENGINE=true must run the native Rust engine',
  );
}

/// What was on screen and in the stores when a result assertion timed out.
///
/// Kept next to the polling helpers so a red connected run names the state
/// that never arrived instead of only the widget that was missing.
String resultDiagnostics(
  WidgetTester tester,
  ProviderContainer container,
) {
  final activities = container.read(activityRepositoryProvider);
  final status = container.read(recordingControllerProvider)?.status.name;
  final snapshot = container.read(runSnapshotProvider);
  return 'texts=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}, '
      'activities=${activities.map((a) => '${a.id}:${a.routeId}:${a.duration?.seconds}').toList()}, '
      'run_status=$status, run_snapshot=${snapshot == null ? 'null' : 'present'}';
}

/// Ends a live run the way a user does: taps FINISH, then confirms the §12
/// dialog that follows. The confirm is polled for because the dialog mounts on
/// the next real frame on the live binding.
Future<void> finishAndConfirm(WidgetTester tester) async {
  await tester.tap(find.text('FINISH'));
  await waitForCondition(
    tester,
    () => tester.any(find.byKey(const ValueKey('confirm-finish'))),
    'the finish confirmation dialog',
  );
  await tester.tap(find.byKey(const ValueKey('confirm-finish')));
  await tester.pump();
}

/// Accepts the §33 location explanation when the flow opens with one.
///
/// The explanation, when it comes at all, precedes preparation — so this
/// settles for whichever lands first: the dialog itself, or [nextScreenText],
/// the screen the flow shows once it is past the gate. The device harness
/// grants location in a retry loop, so on a warm run there is no dialog and
/// this returns as soon as the flow reaches [nextScreenText].
Future<void> acceptLocationRationaleIfShown(
  WidgetTester tester,
  String nextScreenText,
) async {
  final continueButton = find.byKey(
    const ValueKey('location-rationale-continue'),
  );
  await waitForCondition(
    tester,
    () => tester.any(continueButton) || tester.any(find.text(nextScreenText)),
    'the location explanation or "$nextScreenText"',
  );
  if (tester.any(continueButton)) {
    await tester.tap(continueButton);
    await tester.pump();
  }
}
