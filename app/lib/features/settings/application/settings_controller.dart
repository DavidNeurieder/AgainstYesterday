// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings persistence and the derived read-model providers (M21, §26).
///
/// [`SettingsRepository`] is backed by the same [`PersistenceStore`] as routes
/// and activities (key `settings`), so the toggles survive restarts. Downstream
/// reads go through the small convenience providers — [`hapticsEnabledProvider`],
/// [`countdownEnabledProvider`], [`displayUnitProvider`],
/// [`onboardingSeenProvider`] — keeping call sites dependent on just the one
/// flag they need.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/units.dart';
import '../../../persistence/persistence.dart';
import '../domain/settings.dart';

String appSettingsToJson(AppSettings settings) => const JsonEncoder().convert({
  'haptics': settings.hapticsEnabled,
  'countdown': settings.countdownEnabled,
  'units': settings.units.name,
  'onboarding': settings.onboardingSeen,
});

AppSettings parseAppSettings(String json) {
  final map = (jsonDecode(json) as Map).cast<String, Object?>();
  return AppSettings(
    hapticsEnabled: map['haptics'] as bool? ?? true,
    countdownEnabled: map['countdown'] as bool? ?? true,
    units: Units.values.firstWhere(
      (u) => u.name == map['units'],
      orElse: () => AppSettings.defaults.units,
    ),
    // Documents written before M29 lack the key; their installs predate
    // the intro, so they count as already seen.
    onboardingSeen: map['onboarding'] as bool? ?? true,
  );
}

/// The persisted settings; defaults until the user changes something.
final settingsRepositoryProvider =
    NotifierProvider<SettingsRepository, AppSettings>(SettingsRepository.new);

/// Haptics master switch (M21, §26) — read by [`AppHaptics`].
final hapticsEnabledProvider = Provider<bool>((ref) =>
    ref.watch(settingsRepositoryProvider).hapticsEnabled);

/// Whether a route race plays the 3-2-1-GO countdown before starting.
final countdownEnabledProvider = Provider<bool>((ref) =>
    ref.watch(settingsRepositoryProvider).countdownEnabled);

/// The unit used to format distance, pace and speed across the app.
final displayUnitProvider = Provider<Units>(
  (ref) => ref.watch(settingsRepositoryProvider).units,
);

/// Whether the first-launch intro (§34) still has to be shown.
///
/// Hermetic stores (widget tests, demo mode) never onboard. On a real
/// [JsonFileStore] the settings repository reports `false` while no
/// settings document exists — a fresh install — and afterwards decides
/// through [`AppSettings.onboardingSeen`].
final onboardingSeenProvider = Provider<bool>((ref) {
  final store = ref.watch(persistenceStoreProvider);
  if (store is! JsonFileStore) {
    return true;
  }
  return ref.watch(settingsRepositoryProvider).onboardingSeen;
});

class SettingsRepository extends Notifier<AppSettings> {
  @override
  AppSettings build() {
    ref.watch(persistenceStoreProvider);
    final raw = readBestEffort(ref.read(persistenceStoreProvider), _key);
    if (raw == null) {
      // No document at all: a fresh install has not met the intro yet (§34).
      return AppSettings.defaults.copyWith(onboardingSeen: false);
    }
    try {
      return parseAppSettings(raw);
    } on FormatException {
      // Corrupt store: fall back to defaults.
    } on TypeError {
      // Structurally valid JSON with the wrong shape.
    }
    return AppSettings.defaults;
  }

  /// Persists [next] and makes it the live setting.
  Future<void> save(AppSettings next) async {
    state = next;
    await _persist();
  }

  Future<void> resetToDefaults() async {
    state = AppSettings.defaults;
    await _persist();
  }

  Future<void> _persist() async {
    final store = ref.read(persistenceStoreProvider);
    if (store is NoopPersistenceStore) {
      return;
    }
    await writeBestEffort(store, _key, appSettingsToJson(state));
  }

  static const _key = 'settings';
}