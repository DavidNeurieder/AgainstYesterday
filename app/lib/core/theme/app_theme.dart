// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App theme built from the [AppColors] palette and a small spacing scale.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Spacing scale used across the app.
abstract final class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

/// The single place that defines how Material looks in this app.
ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.pb,
      brightness: Brightness.dark,
      surface: AppColors.surface,
    ).copyWith(
      primary: AppColors.you,
      onPrimary: AppColors.background,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.error,
    ),
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: null, // system font; monospace handled per-widget (§44 timing)
  );

  return base.copyWith(
    textTheme: base.textTheme.copyWith(
      displayLarge: base.textTheme.displayLarge?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -1.5,
      ),
      displayMedium: base.textTheme.displayMedium?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(
        color: AppColors.textSecondary,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(20)),
        side: BorderSide(color: AppColors.outline),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: AppColors.surfaceHigh,
      height: 64,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.outline,
      thickness: 1,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: AppColors.surfaceHigh,
      side: const BorderSide(color: AppColors.outline),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
    ),
  );
}