// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App theme built from the [AppColors] palette and a small spacing scale.
library;

import 'package:flutter/material.dart';

import 'app_colors.dart';

const _kLightBackground = Color(0xFFF7F8FA);
const _kLightSurface = Color(0xFFFFFFFF);
const _kLightSurfaceHigh = Color(0xFFF1F3F6);
const _kLightOutline = Color(0xFFD8DEE8);
const _kLightTextPrimary = Color(0xFF101318);
const _kLightTextSecondary = Color(0xFF4B5565);

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
ThemeData buildAppTheme([Brightness brightness = Brightness.dark]) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.pb,
      brightness: brightness,
      surface: brightness == Brightness.dark ? AppColors.surface : const Color(0xFFF7F8FA),
    ).copyWith(
      primary: AppColors.you,
      onPrimary: AppColors.background,
      surface: brightness == Brightness.dark ? AppColors.surface : _kLightSurface,
      onSurface: brightness == Brightness.dark ? AppColors.textPrimary : _kLightTextPrimary,
      error: brightness == Brightness.dark ? AppColors.error : const Color(0xFFB42318),
    ),
    scaffoldBackgroundColor: brightness == Brightness.dark ? AppColors.background : _kLightBackground,
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
        color: brightness == Brightness.dark ? AppColors.textSecondary : _kLightTextSecondary,
      ),
      labelLarge: base.textTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: brightness == Brightness.dark ? AppColors.surface : _kLightSurface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        side: BorderSide(color: brightness == Brightness.dark ? AppColors.outline : _kLightOutline),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: brightness == Brightness.dark ? AppColors.background : _kLightBackground,
      foregroundColor: brightness == Brightness.dark ? AppColors.textPrimary : _kLightTextPrimary,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: brightness == Brightness.dark ? AppColors.surface : _kLightSurface,
      indicatorColor: brightness == Brightness.dark ? AppColors.surfaceHigh : _kLightSurfaceHigh,
      height: 64,
    ),
    dividerTheme: DividerThemeData(
      color: brightness == Brightness.dark ? AppColors.outline : _kLightOutline,
      thickness: 1,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: brightness == Brightness.dark ? AppColors.surfaceHigh : _kLightSurfaceHigh,
      side: BorderSide(color: brightness == Brightness.dark ? AppColors.outline : _kLightOutline),
      labelStyle: TextStyle(color: brightness == Brightness.dark ? AppColors.textSecondary : _kLightTextSecondary),
    ),
  );
}