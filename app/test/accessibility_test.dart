// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// §32 accessibility: WCAG AA contrast for the palette, text alternatives
/// to colour, screen-reader labels, and 48 px touch targets.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/core/theme/app_colors.dart';
import 'package:against_yesterday/core/ui/split_row.dart';
import 'package:against_yesterday/features/activity/presentation/activity_detail_screen.dart';
import 'package:against_yesterday/features/result/application/splits.dart';
import 'package:against_yesterday/persistence/persistence.dart';

import 'test_catalog.dart';

double _linearize(double channel) => channel <= 0.04045
    ? channel / 12.92
    : math.pow((channel + 0.055) / 1.055, 2.4).toDouble();

double _luminance(Color color) =>
    0.2126 * _linearize(color.r) +
    0.7152 * _linearize(color.g) +
    0.0722 * _linearize(color.b);

/// WCAG contrast ratio (1..21) between two colours.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Whether the semantics tree speaks [name] anywhere — screen readers read
/// `label` and `tooltip` (icon buttons name themselves via the tooltip).
bool _spoken(WidgetTester tester, String name) {
  var found = false;
  void visit(SemanticsNode node) {
    if (node.label == name || node.tooltip == name) {
      found = true;
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  for (final view in tester.binding.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) {
      visit(root);
    }
  }
  return found;
}

void main() {
  group('colour contrast (§32)', () {
    test('every text token reaches WCAG AA on every surface', () {
      const surfaces = <String, Color>{
        'background': AppColors.background,
        'surface': AppColors.surface,
        'surfaceHigh': AppColors.surfaceHigh,
      };
      const tokens = <String, Color>{
        'textPrimary': AppColors.textPrimary,
        'textSecondary': AppColors.textSecondary,
        'textMuted': AppColors.textMuted,
        'you': AppColors.you,
        'ghost': AppColors.ghost,
        'ahead': AppColors.ahead,
        'behind': AppColors.behind,
        'pb': AppColors.pb,
        'gpsWarning': AppColors.gpsWarning,
        'error': AppColors.error,
      };
      for (final token in tokens.entries) {
        for (final surface in surfaces.entries) {
          final ratio = _contrast(token.value, surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${token.key} on ${surface.key} is '
                '${ratio.toStringAsFixed(2)}:1, below WCAG AA 4.5:1',
          );
        }
      }
    });

    test('the destructive fill carries textPrimary at AA', () {
      final ratio = _contrast(AppColors.textPrimary, AppColors.errorFill);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason: 'Delete button label is ${ratio.toStringAsFixed(2)}:1',
      );
    });
  });

  group('text alternatives to colour (§32)', () {
    testWidgets('a split names ahead or behind, not just green or amber',
        (tester) async {
      Widget row(double deltaSeconds) => MaterialApp(
            home: Scaffold(
              body: SplitRow(
                split: SplitDelta(
                  kilometer: 1,
                  elapsedSeconds: 300,
                  deltaSeconds: deltaSeconds,
                ),
              ),
            ),
          );

      await tester.pumpWidget(row(-5));
      expect(find.text('-0:05'), findsOneWidget);
      expect(find.text('ahead'), findsOneWidget);

      await tester.pumpWidget(row(8));
      expect(find.text('+0:08'), findsOneWidget);
      expect(find.text('behind'), findsOneWidget);
    });
  });

  group('screen reader labels (§32)', () {
    testWidgets('the home settings button is labelled for screen readers',
        semanticsEnabled: true, (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(seededStore()),
        ],
        child: const AgainstYesterdayApp(),
      ));
      await tester.pumpAndSettle();

      expect(_spoken(tester, 'Settings'), isTrue);
    });

    testWidgets('the activity detail back button is labelled',
        semanticsEnabled: true, (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(activities: [seedActivity()]),
          ),
        ],
        child: const MaterialApp(
          home: ActivityDetailScreen(activityId: 'act-001'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(_spoken(tester, 'Back'), isTrue);
    });
  });

  group('touch targets (§32)', () {
    testWidgets('icon buttons keep the 48 px minimum on home', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(seededStore()),
        ],
        child: const AgainstYesterdayApp(),
      ));
      await tester.pumpAndSettle();

      final icons = find.byType(IconButton);
      expect(icons, findsWidgets);
      for (final element in icons.evaluate()) {
        final size = tester.getSize(find.byWidget(element.widget));
        expect(
          size.width,
          greaterThanOrEqualTo(48),
          reason: 'IconButton ${element.widget} is ${size.width} px wide',
        );
        expect(
          size.height,
          greaterThanOrEqualTo(48),
          reason: 'IconButton ${element.widget} is ${size.height} px tall',
        );
      }
    });

    testWidgets('the back button keeps the 48 px minimum', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          persistenceStoreProvider.overrideWithValue(
            seededStore(activities: [seedActivity()]),
          ),
        ],
        child: const MaterialApp(
          home: ActivityDetailScreen(activityId: 'act-001'),
        ),
      ));
      await tester.pumpAndSettle();

      final back = tester.getSize(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.byType(IconButton),
        ),
      );
      expect(back.width, greaterThanOrEqualTo(48));
      expect(back.height, greaterThanOrEqualTo(48));
    });
  });
}
