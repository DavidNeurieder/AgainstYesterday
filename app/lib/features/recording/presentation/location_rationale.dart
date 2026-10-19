// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The pre-permission location explanation (§33, M14).
///
/// Android's own permission dialog explains nothing: it is the first thing a
/// new install sees, with no hint of why the app wants location. Both run
/// flows therefore give the reason *before* preparation asks for the
/// permission — once per install, guarded by
/// [locationRationaleSeenProvider]. The explanation is informational, never a
/// gate: the runner can dismiss it and still meet Android's dialog, and the
/// run-start error screen remains the place that recovers a denial.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/dependencies.dart';
import '../../../core/theme/app_colors.dart';
import '../../settings/application/settings_controller.dart';

/// Whether the one-time §33 explanation is still owed.
///
/// Synchronous on purpose: the flows call it in `initState`, and every launch
/// after the first (and every hermetic store, where
/// [locationRationaleSeenProvider] is already `true`) must take the plain,
/// immediate preparation path with no extra frame.
bool locationRationalePending(WidgetRef ref) =>
    ref.read(deviceGpsProvider) != null &&
    !ref.read(locationRationaleSeenProvider);

/// Gives the §33 location explanation, then records it as given.
///
/// Only call when [locationRationalePending] holds. The explanation appears
/// only when Android would actually ask (a granted or permanently denied
/// permission has no dialog to introduce); either way it is marked seen, so a
/// fresh install is asked at most once.
Future<void> showLocationRationale(BuildContext context, WidgetRef ref) async {
  final source = ref.read(deviceGpsProvider);
  var askable = false;
  if (source != null) {
    askable = await source.canAskPermission();
  }
  // Marked before showing: the reason has been owed and is now given, even if
  // the runner never meets a system dialog afterwards. The in-memory flag
  // flips synchronously; the disk write catches up on its own (best effort),
  // like the intro's dismissal.
  unawaited(
    ref.read(settingsRepositoryProvider.notifier).markLocationRationaleSeen(),
  );
  if (!askable || !context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.my_location, color: AppColors.you),
      title: const Text('Why location?'),
      content: const Text(
        'Against Yesterday records your run from your phone\'s GPS receiver: '
        'the track you cover, your pace, and the ghost you race.\n\n'
        'Android will ask you to allow location access next.',
      ),
      actions: [
        FilledButton(
          key: const ValueKey('location-rationale-continue'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}
