// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Guards the on-device distance helpers in `integration_test/support.dart`.
///
/// They cannot be exercised by the host suites otherwise, and a raw `ValueKey`
/// parameter is a silent trap: it gives the const at each call site the
/// static context `ValueKey<dynamic>`, `ValueKey.operator==` rejects a
/// mismatched type argument, the lookup never matches and every caller reads
/// 0 — a green-looking probe that waits forever on the device.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support.dart';

void main() {
  testWidgets('displayedMeters reads the mounted live distance',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Text('1.23 km', key: ValueKey('live-distance')),
      ),
    );
    expect(displayedMeters(tester), 1230);
  });

  testWidgets('displayedMeters is 0 while the live screen is unmounted',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('no distance')));
    expect(displayedMeters(tester), 0);
  });

  testWidgets('recordDistanceMeters reads the mounted recorder distance',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Text('456 m', key: ValueKey('record-distance')),
      ),
    );
    expect(recordDistanceMeters(tester), 456);
  });

  testWidgets('requireDisplayedMeters fails when the live screen is unmounted',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('no distance')));
    expect(() => requireDisplayedMeters(tester), throwsA(isA<TestFailure>()));
  });

  test('parseDistanceLabel reads both units and rejects garbage', () {
    expect(parseDistanceLabel('1.23 km'), 1230);
    expect(parseDistanceLabel('456 m'), 456);
    expect(() => parseDistanceLabel('oops'), throwsA(isA<TestFailure>()));
  });
}
