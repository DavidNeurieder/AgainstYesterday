// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Settings placeholder (§26).
///
/// The full settings table — voice feedback, haptics, countdown, units, GPX
/// import/export, delete-all — is a later milestone; for now the gear on
/// Home lands here so the affordance navigates somewhere real.
library;

import 'package:flutter/material.dart';

import '../../../core/ui/app_states.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const Center(
        child: EmptyState(
          icon: Icons.settings_outlined,
          message: 'Settings arrive in a later milestone.',
        ),
      ),
    );
  }
}