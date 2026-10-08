// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Widget-level checks for the shared design system (`lib/core/ui/`) so the
/// building blocks themselves are pinned before screens consume them (§27).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:against_yesterday/core/units.dart';
import 'package:against_yesterday/core/ui/app_buttons.dart';
import 'package:against_yesterday/core/ui/app_states.dart';
import 'package:against_yesterday/core/ui/gap_line.dart';
import 'package:against_yesterday/core/ui/split_row.dart';
import 'package:against_yesterday/engine/models.dart';
import 'package:against_yesterday/features/result/application/splits.dart';

void main() {
  Widget frame(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('PrimaryButton', () {
    testWidgets('renders a full-width FilledButton with the label',
        (tester) async {
      await tester.pumpWidget(frame(
        const PrimaryButton(label: 'GO', onPressed: _noop),
      ));
      final button =
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'GO'));
      expect(button.onPressed, isNotNull);
      expect(tester.getSize(find.byType(FilledButton)).width,
          tester.getSize(find.byType(Scaffold)).width);
      expect(tester.getSize(find.byType(FilledButton)).height, 56);
    });

    testWidgets('honours the custom height', (tester) async {
      await tester.pumpWidget(frame(
        const PrimaryButton(
          label: 'Start a run',
          height: 64,
          onPressed: _noop,
        ),
      ));
      expect(tester.getSize(find.byType(FilledButton)).height, 64);
    });

    testWidgets('disables when no callback is given', (tester) async {
      await tester.pumpWidget(frame(
        const PrimaryButton(label: 'WAIT'),
      ));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'WAIT')),
        isA<FilledButton>(),
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'WAIT'))
            .enabled,
        isFalse,
      );
    });
  });

  group('GapLine', () {
    testWidgets('says first-time without a PB reference', (tester) async {
      await tester.pumpWidget(frame(const GapLine(gap: null)));
      expect(find.text('First time on this route'), findsOneWidget);
    });

    testWidgets('renders ahead-of-PB offset green', (tester) async {
      await tester.pumpWidget(frame(GapLine(
        gap: const GhostState(
          distance: Distance.meters(1000),
          timeDifference: Elapsed.seconds(-20),
          ahead: true,
        ),
      )));
      expect(find.text('0:20 ahead of PB'), findsOneWidget);
    });

    testWidgets('renders behind-of-PB offset and the tie case', (tester) async {
      await tester.pumpWidget(frame(GapLine(
        gap: const GhostState(
          distance: Distance.meters(1000),
          timeDifference: Elapsed.seconds(30),
          ahead: false,
        ),
      )));
      expect(find.text('0:30 behind PB'), findsOneWidget);

      await tester.pumpWidget(frame(GapLine(
        gap: const GhostState(
          distance: Distance.meters(1000),
          timeDifference: Elapsed.zero(),
          ahead: true,
        ),
      )));
      expect(find.text('Tied with PB'), findsOneWidget);
    });
  });

  group('SplitRow', () {
    testWidgets('signs the split delta by direction', (tester) async {
      await tester.pumpWidget(frame(SplitRow(
        split: const SplitDelta(
          kilometer: 3,
          elapsedSeconds: 900,
          deltaSeconds: -5,
        ),
      )));
      expect(find.text('3 km'), findsOneWidget);
      expect(find.text('-0:05'), findsOneWidget);
      expect(find.text('ahead'), findsOneWidget);

      await tester.pumpWidget(frame(SplitRow(
        split: const SplitDelta(
          kilometer: 4,
          elapsedSeconds: 1200,
          deltaSeconds: 8,
        ),
      )));
      expect(find.text('+0:08'), findsOneWidget);
      expect(find.text('behind'), findsOneWidget);
    });
  });

  group('EmptyState', () {
    testWidgets('full variant centres the message', (tester) async {
      await tester.pumpWidget(frame(
        const EmptyState(
          icon: Icons.route,
          message: 'No routes yet.',
        ),
      ));
      expect(find.byIcon(Icons.route), findsOneWidget);
      expect(find.text('No routes yet.'), findsOneWidget);
    });

    testWidgets('compact variant renders the inline row', (tester) async {
      await tester.pumpWidget(frame(
        const EmptyState(
          compact: true,
          icon: Icons.directions_run,
          message: 'No runs yet.',
        ),
      ));
      expect(find.byIcon(Icons.directions_run), findsOneWidget);
      expect(find.text('No runs yet.'), findsOneWidget);
    });
  });

  group('LoadingState', () {
    testWidgets('is an icon-based cue, never an animated spinner',
        (tester) async {
      await tester.pumpWidget(frame(
        const LoadingState(message: 'Getting GPS…'),
      ));
      expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
      expect(find.text('Getting GPS…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('ErrorState', () {
    testWidgets('renders the §33 block with spaced, tappable actions',
        (tester) async {
      var retried = 0;
      await tester.pumpWidget(frame(
        ErrorState(
          title: 'COULDN\'T LOAD ROUTE',
          message: 'Try again.',
          actions: [
            OutlinedButton(onPressed: _noop, child: const Text('SECOND')),
            FilledButton(onPressed: () => retried++, child: const Text('RETRY')),
          ],
        ),
      ));
      expect(find.text('COULDN\'T LOAD ROUTE'), findsOneWidget);
      expect(find.text('Try again.'), findsOneWidget);

      // Actions are stacked with a gap, not jammed together.
      final second = tester.getTopLeft(find.text('SECOND'));
      final retry = tester.getTopLeft(find.text('RETRY'));
      expect(retry.dy, greaterThan(second.dy));

      await tester.tap(find.text('RETRY'));
      expect(retried, 1);
    });
  });
}

void _noop() {}