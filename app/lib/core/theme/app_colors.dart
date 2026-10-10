// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Color tokens for the app (§44).
///
/// The visual language opposes **YOU** against **GHOST** on a dark neutral
/// background, with a restrained semantic palette.
library;

import 'package:flutter/material.dart';

/// Semantic colors used across the design system.
@immutable
abstract final class AppColors {
  const AppColors._();

  /// Dark neutral background.
  static const Color background = Color(0xFF0E1116);

  /// Slightly lighter surface for cards.
  static const Color surface = Color(0xFF171B22);

  /// Elevated surface (sheets, dialogs).
  static const Color surfaceHigh = Color(0xFF202530);

  /// Hairlines and borders.
  static const Color outline = Color(0xFF2A303B);

  /// Primary text (white).
  static const Color textPrimary = Color(0xFFF2F4F8);

  /// Secondary text.
  static const Color textSecondary = Color(0xFF9AA3B2);

  /// Tertiary / disabled text. Keeps WCAG AA (≥4.5:1) on every surface
  /// (M14, audited M28): 6.0:1 on `background`, 5.5:1 on `surface`,
  /// 4.9:1 on `surfaceHigh`.
  static const Color textMuted = Color(0xFF8792A1);

  /// YOU — the live run (white primary, like the plan's "Primary white").
  static const Color you = Color(0xFFF2F4F8);

  /// The travelled part of the route on a map — the GPS path you have actually
  /// run. A saturated green (the same hue family as [ahead]) so it stays
  /// legible over both the dark painter surface and the light MapLibre style;
  /// the full route behind it remains the faint [ghost] trace.
  static const Color track = Color(0xFF34C77B);

  /// GHOST — the reference attempt. AA on every surface (M28).
  static const Color ghost = Color(0xFF8593A7);

  /// Ahead of the ghost.
  static const Color ahead = Color(0xFF34C77B);

  /// Behind the ghost.
  static const Color behind = Color(0xFFE0A83B);

  /// Personal best accent.
  static const Color pb = Color(0xFF4F8CFF);

  /// GPS warning.
  static const Color gpsWarning = Color(0xFFF08A3C);

  /// Error text and icons — AA on every surface (M28 audit).
  static const Color error = Color(0xFFEE5A53);

  /// Destructive button fill: `textPrimary` reads at 4.6:1 over it, where
  /// the lighter [error] text token would not (M28).
  static const Color errorFill = Color(0xFFC93B34);
}