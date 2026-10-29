// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The real app, semantics-enabled, for the on-device process-death harness.
///
/// `flutter test` installs a fresh test APK and **uninstalls it on exit**, so
/// app storage cannot survive between two test invocations. `flutter run`
/// does not uninstall, and a second run reinstalls with `install -r`, which
/// preserves the data directory — that is what makes a genuine process-death
/// assertion possible (`tool/android_integration_test.sh --process-death`).
///
/// This entry point differs from `lib/main.dart` in exactly one way: it turns
/// Flutter's semantic tree on unconditionally, so uiautomator can see the
/// widgets and the harness can drive the app with real taps. It is a
/// production-shaped app otherwise — same shell, same real `JsonFileStore`
/// over the app documents directory.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:against_yesterday/app/app.dart';
import 'package:against_yesterday/persistence/persistence.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep the semantic tree alive even with no accessibility client attached,
  // so `uiautomator dump` returns the app's widgets.
  SemanticsBinding.instance.ensureSemantics();

  final directory = await getApplicationDocumentsDirectory();
  runApp(
    ProviderScope(
      overrides: [
        persistenceStoreProvider.overrideWithValue(JsonFileStore(directory)),
      ],
      child: const AgainstYesterdayApp(),
    ),
  );
}
