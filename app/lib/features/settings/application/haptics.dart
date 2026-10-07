// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Haptic feedback routed through the settings master switch (M21, §26).
///
/// Every `HapticFeedback.*` call in the app goes through one of these helpers
/// so "Haptics" in Settings genuinely turns them off.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'settings_controller.dart';

class AppHaptics {
  AppHaptics._();

  static void light(WidgetRef ref) => _gate(ref, HapticFeedback.lightImpact);
  static void medium(WidgetRef ref) => _gate(ref, HapticFeedback.mediumImpact);
  static void heavy(WidgetRef ref) => _gate(ref, HapticFeedback.heavyImpact);
  static void selection(WidgetRef ref) =>
      _gate(ref, HapticFeedback.selectionClick);

  static void _gate(WidgetRef ref, Future<void> Function() impact) {
    if (ref.read(hapticsEnabledProvider)) {
      impact();
    }
  }
}