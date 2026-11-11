// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// The running artifact's own version, for Settings → About (§26).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The version and build number the artifact was built with — the `version:`
/// line of `pubspec.yaml` (`0.1.0+1`), which Flutter also hands to Android as
/// `versionName`/`versionCode`. Read from the platform's package metadata at
/// runtime, so About can never disagree with what was actually installed.
///
/// `0.1.0 (1)` for a release build; the build number is dropped when the
/// platform reports none. Empty while the lookup is in flight, and in hermetic
/// widget tests there is no platform metadata to read at all.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.buildNumber.isEmpty
      ? info.version
      : '${info.version} (${info.buildNumber})';
});
