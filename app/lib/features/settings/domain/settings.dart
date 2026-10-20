// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App settings model (M21, §26).
///
/// A small flat value object; everything defaults to the shipped behavior so
/// a fresh install (or a deleted store) behaves exactly like earlier
/// milestones — the one exception is [`onboardingSeen`], which the first
/// launch deliberately detects from a missing settings document (§34).
library;

import 'package:flutter/material.dart';

import '../../../core/units.dart';

/// Which theme the app should follow (§6).
enum AppThemeMode {
  system,
  light,
  dark;

  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  String get label => switch (this) {
        AppThemeMode.system => 'System',
        AppThemeMode.light => 'Light',
        AppThemeMode.dark => 'Dark',
      };
}

class AppSettings {
  const AppSettings({
    required this.hapticsEnabled,
    required this.countdownEnabled,
    required this.units,
    required this.onboardingSeen,
    required this.locationRationaleSeen,
    this.themeMode = AppThemeMode.dark,
  });

  /// Vibrate on interactions (start, finish, phase changes, …).
  final bool hapticsEnabled;

  /// Play the 3-2-1-GO countdown before a route race starts.
  final bool countdownEnabled;

  /// How distance, pace and speed are displayed.
  final Units units;

  /// Whether the first-launch intro (§34) has been dismissed.
  ///
  /// The gate (`onboardingSeenProvider`) watches the settings repository:
  /// [`SettingsRepository.build`] reports `false` while no settings document
  /// exists (a fresh install), so [`defaults`] itself keeps `true` — a
  /// corrupt store or a settings reset never re-shows the intro.
  final bool onboardingSeen;

  /// Whether the one-time explanation of *why* the app needs location (§33)
  /// has been given.
  ///
  /// Shown once per install, right before Android's own permission dialog can
  /// appear (`locationRationaleSeenProvider`). Like [`onboardingSeen`], the
  /// default keeps `true` so a corrupt store or a settings reset never shows
  /// it again — only a store with no document at all (a fresh install) trips
  /// it.
  final bool locationRationaleSeen;

  /// Light/dark/system theme (§6). Defaults to dark to preserve the shipped
  /// look.
  final AppThemeMode themeMode;

  static const AppSettings defaults = AppSettings(
    hapticsEnabled: true,
    countdownEnabled: true,
    units: Units.kilometers,
    onboardingSeen: true,
    locationRationaleSeen: true,
    themeMode: AppThemeMode.dark,
  );

  AppSettings copyWith({
    bool? hapticsEnabled,
    bool? countdownEnabled,
    Units? units,
    bool? onboardingSeen,
    bool? locationRationaleSeen,
    AppThemeMode? themeMode,
  }) =>
      AppSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        countdownEnabled: countdownEnabled ?? this.countdownEnabled,
        units: units ?? this.units,
        onboardingSeen: onboardingSeen ?? this.onboardingSeen,
        locationRationaleSeen: locationRationaleSeen ?? this.locationRationaleSeen,
        themeMode: themeMode ?? this.themeMode,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.countdownEnabled == countdownEnabled &&
      other.units == units &&
      other.onboardingSeen == onboardingSeen &&
      other.locationRationaleSeen == locationRationaleSeen &&
      other.themeMode == themeMode;

  @override
  int get hashCode => Object.hash(
        hapticsEnabled,
        countdownEnabled,
        units,
        onboardingSeen,
        locationRationaleSeen,
        themeMode,
      );
}
