// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Opens external web links from Settings → About (M21, §26).
///
/// The About card points at the project's GitHub repository and its issue
/// tracker. Handing a URL to the platform's browser is the one thing Settings
/// does that leaves the phone, so it sits behind a tiny seam with a provider —
/// the hermetic suites inject a recording fake (see `settings_test.dart`).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the project lives, and where to report a problem with it.
const String kGitHubUrl = 'https://github.com/DavidNeurieder/AgainstYesterday';
const String kIssuesUrl = '$kGitHubUrl/issues';

/// Opens a web [uri] in the platform's default browser.
abstract interface class LinkLauncher {
  /// Returns `true` when the platform accepted the URL, `false` when nothing
  /// could handle it (or the launcher is unavailable) so the caller can tell
  /// the runner rather than failing silently.
  Future<bool> open(Uri uri);
}

/// The real launcher, backed by the `url_launcher` plugin.
class ExternalLinkLauncher implements LinkLauncher {
  const ExternalLinkLauncher();

  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No handler, a missing plugin on a hermetic host, or a platform
      // refusal: report the same "couldn't open it" instead of throwing.
      return false;
    }
  }
}

/// The launcher the app uses; tests override it with a recording fake.
final linkLauncherProvider = Provider<LinkLauncher>(
  (_) => const ExternalLinkLauncher(),
);
