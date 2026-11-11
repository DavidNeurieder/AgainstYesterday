// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App settings model (M21, §26).
///
/// A small flat value object; everything defaults to the shipped behavior so
/// a fresh install (or a deleted store) behaves exactly like earlier
/// milestones — the one exception is [`locationRationaleSeen`], which a first
/// launch deliberately detects from a missing settings document (§33).
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
    required this.locationRationaleSeen,
    this.themeMode = AppThemeMode.dark,
    this.replaySpeed = 1.0,
    this.mapsEnabled = true,
  });

  /// Vibrate on interactions (start, finish, phase changes, …).
  final bool hapticsEnabled;

  /// Play the 3-2-1-GO countdown before a route race starts.
  final bool countdownEnabled;

  /// How distance, pace and speed are displayed.
  final Units units;

  /// Whether the one-time explanation of *why* the app needs location (§33)
  /// has been given.
  ///
  /// Shown once per install, right before Android's own permission dialog can
  /// appear (`locationRationaleSeenProvider`). The default keeps `true` so a
  /// corrupt store or a settings reset never shows it again — only a store
  /// with no document at all (a fresh install) trips it.
  final bool locationRationaleSeen;

  /// Light/dark/system theme (§6). Defaults to dark to preserve the shipped
  /// look.
  final AppThemeMode themeMode;

  /// Last-used replay playback speed (§replay). Defaults to 1x.
  final double replaySpeed;

  /// Whether the app may talk to map servers for tiles and styles.
  ///
  /// Defaults to on. Turning it off makes the app fully offline: every screen
  /// draws with the self-contained painter, no tile/style request is made and
  /// no offline region is downloaded. Saved regions are kept for later.
  final bool mapsEnabled;

  static const AppSettings defaults = AppSettings(
    hapticsEnabled: true,
    countdownEnabled: true,
    units: Units.kilometers,
    locationRationaleSeen: true,
    themeMode: AppThemeMode.dark,
    mapsEnabled: true,
  );

  AppSettings copyWith({
    bool? hapticsEnabled,
    bool? countdownEnabled,
    Units? units,
    bool? locationRationaleSeen,
    AppThemeMode? themeMode,
    double? replaySpeed,
    bool? mapsEnabled,
  }) =>
      AppSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        countdownEnabled: countdownEnabled ?? this.countdownEnabled,
        units: units ?? this.units,
        locationRationaleSeen: locationRationaleSeen ?? this.locationRationaleSeen,
        themeMode: themeMode ?? this.themeMode,
        replaySpeed: replaySpeed ?? this.replaySpeed,
        mapsEnabled: mapsEnabled ?? this.mapsEnabled,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.countdownEnabled == countdownEnabled &&
      other.units == units &&
      other.locationRationaleSeen == locationRationaleSeen &&
      other.themeMode == themeMode &&
      other.replaySpeed == replaySpeed &&
      other.mapsEnabled == mapsEnabled;

  @override
  int get hashCode => Object.hash(
        hapticsEnabled,
        countdownEnabled,
        units,
        locationRationaleSeen,
        themeMode,
        replaySpeed,
        mapsEnabled,
      );
}
