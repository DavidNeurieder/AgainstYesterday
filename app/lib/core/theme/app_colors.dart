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

  /// Tertiary / disabled text. Raised for WCAG AA contrast on both surfaces
  /// (M14): 5.0:1 on `background`, 4.6:1 on `surface`.
  static const Color textMuted = Color(0xFF7A8493);

  /// YOU — the live run (white primary, like the plan's "Primary white").
  static const Color you = Color(0xFFF2F4F8);

  /// GHOST — the reference attempt.
  static const Color ghost = Color(0xFF7C8A9E);

  /// Ahead of the ghost.
  static const Color ahead = Color(0xFF34C77B);

  /// Behind the ghost.
  static const Color behind = Color(0xFFE0A83B);

  /// Personal best accent.
  static const Color pb = Color(0xFF4F8CFF);

  /// GPS warning.
  static const Color gpsWarning = Color(0xFFF08A3C);

  /// Error state.
  static const Color error = Color(0xFFE0453F);
}