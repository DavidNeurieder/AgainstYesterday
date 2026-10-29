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
import 'package:flutter_test/flutter_test.dart';

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

/// Dismisses the first-launch intro (§34) when it is showing.
///
/// A fresh install (the harness uninstalls before each suite) lands on the
/// three-screen intro before Home, so a suite that pumps the app directly must
/// walk it. A no-op when the intro is not present — a warm install or a
/// pre-seeded settings document never trips the gate.
Future<void> dismissOnboardingIfPresent(WidgetTester tester) async {
  // The GET STARTED button only exists on the last page; the page dots carry
  // a spoken count, so jump to the last one deterministically.
  final lastDot = find.bySemanticsLabel('Screen 3 of 3');
  if (!tester.any(find.text('GET STARTED')) && tester.any(lastDot)) {
    await tester.tap(lastDot);
    await tester.pumpAndSettle();
  }
  if (tester.any(find.text('GET STARTED'))) {
    await tester.tap(find.text('GET STARTED'));
    await tester.pumpAndSettle();
  }
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
