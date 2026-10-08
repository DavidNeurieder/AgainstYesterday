// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The shared run-start error screen (M14, §33) for the race and record
/// flows: the reason (when known), an optional jump to the matching system
/// settings, and retry — on the one [ErrorScreen] skeleton.
library;

import 'package:flutter/material.dart';

import '../../../core/ui/app_states.dart';
import '../../../engine/models.dart';

class RunErrorScreen extends StatelessWidget {
  const RunErrorScreen({
    super.key,
    required this.error,
    required this.onRetry,
    required this.barTitle,
    this.onOpenSettings,
  });

  final RunError? error;
  final VoidCallback onRetry;
  final String barTitle;
  final VoidCallback? onOpenSettings;

  static const String _fallback = 'The engine failed to prepare the ghost. '
      'Try again.';

  @override
  Widget build(BuildContext context) {
    // §33: a GPS refusal headlines the spec copy; anything else keeps the
    // generic run-start headline.
    final gpsRefusal = error?.gpsSettingsAction == true;
    return ErrorScreen(
      barTitle: barTitle,
      title: gpsRefusal ? 'GPS UNAVAILABLE' : 'Could not start a run',
      message: error?.message ?? _fallback,
      actions: [
        if (onOpenSettings != null)
          OutlinedButton.icon(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.location_on_outlined),
            label: const Text('Open location settings'),
          ),
        FilledButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}
