// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Runtime signals that are not compile-time `--dart-define` flags.
library;

import 'dart:io';

/// Whether this process is the widget-test runner.
///
/// `flutter test` sets `FLUTTER_TEST=true` in the tester's environment; the
/// check is read at runtime because it is not a compile-time define. An
/// on-device integration test does not inherit the variable, so it still sees
/// the production defaults (real map, real receiver).
bool get isFlutterTest => Platform.environment['FLUTTER_TEST'] == 'true';
