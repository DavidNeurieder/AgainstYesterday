// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App settings model (M21, §26).
///
/// A small flat value object; everything defaults to the shipped behavior so
/// a fresh install (or a deleted store) behaves exactly like earlier
/// milestones — the one exception is [`onboardingSeen`], which the first
/// launch deliberately detects from a missing settings document (§34).
library;

import '../../../core/units.dart';

class AppSettings {
  const AppSettings({
    required this.hapticsEnabled,
    required this.countdownEnabled,
    required this.units,
    required this.onboardingSeen,
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

  static const AppSettings defaults = AppSettings(
    hapticsEnabled: true,
    countdownEnabled: true,
    units: Units.kilometers,
    onboardingSeen: true,
  );

  AppSettings copyWith({
    bool? hapticsEnabled,
    bool? countdownEnabled,
    Units? units,
    bool? onboardingSeen,
  }) =>
      AppSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        countdownEnabled: countdownEnabled ?? this.countdownEnabled,
        units: units ?? this.units,
        onboardingSeen: onboardingSeen ?? this.onboardingSeen,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.countdownEnabled == countdownEnabled &&
      other.units == units &&
      other.onboardingSeen == onboardingSeen;

  @override
  int get hashCode =>
      Object.hash(hapticsEnabled, countdownEnabled, units, onboardingSeen);
}