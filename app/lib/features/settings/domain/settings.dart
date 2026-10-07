// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App settings model (M21, §26).
///
/// A small flat value object; everything defaults to the shipped behavior so
/// a fresh install (or a deleted store) behaves exactly like earlier
/// milestones.
library;

import '../../../core/units.dart';

class AppSettings {
  const AppSettings({
    required this.hapticsEnabled,
    required this.countdownEnabled,
    required this.units,
  });

  /// Vibrate on interactions (start, finish, phase changes, …).
  final bool hapticsEnabled;

  /// Play the 3-2-1-GO countdown before a route race starts.
  final bool countdownEnabled;

  /// How distance, pace and speed are displayed.
  final Units units;

  static const AppSettings defaults = AppSettings(
    hapticsEnabled: true,
    countdownEnabled: true,
    units: Units.kilometers,
  );

  AppSettings copyWith({
    bool? hapticsEnabled,
    bool? countdownEnabled,
    Units? units,
  }) =>
      AppSettings(
        hapticsEnabled: hapticsEnabled ?? this.hapticsEnabled,
        countdownEnabled: countdownEnabled ?? this.countdownEnabled,
        units: units ?? this.units,
      );

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.hapticsEnabled == hapticsEnabled &&
      other.countdownEnabled == countdownEnabled &&
      other.units == units;

  @override
  int get hashCode => Object.hash(hapticsEnabled, countdownEnabled, units);
}