// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App root: provider scope + theme + router (M1 shell).
///
/// Forwards app lifecycle changes to the recording controller (M13, §28), so
/// a run stays accurate and recoverable across backgrounding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../features/recording/application/recording_controller.dart';
import 'router.dart';

class AgainstYesterdayApp extends ConsumerStatefulWidget {
  const AgainstYesterdayApp({super.key});

  @override
  ConsumerState<AgainstYesterdayApp> createState() => _AgainstYesterdayAppState();
}

class _AgainstYesterdayAppState extends ConsumerState<AgainstYesterdayApp> {
  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      // The lifecycle observer lives INSIDE the scope: a state above its own
      // ProviderScope cannot resolve providers (`containerOf` only looks
      // upward), so a real platform lifecycle message would otherwise crash
      // any tree pumped without an outer scope (bare `pumpWidget(app)`).
      child: _LifecycleRelay(
        child: MaterialApp.router(
          title: 'Against Yesterday',
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          routerConfig: buildRouter(),
        ),
      ),
    );
  }
}

class _LifecycleRelay extends ConsumerStatefulWidget {
  const _LifecycleRelay({required this.child});

  final Widget child;

  @override
  ConsumerState<_LifecycleRelay> createState() => _LifecycleRelayState();
}

class _LifecycleRelayState extends ConsumerState<_LifecycleRelay>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = ref.read(recordingControllerProvider.notifier);
    switch (state) {
      case AppLifecycleState.resumed:
        controller.appForegrounded();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        controller.appBackgrounded();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
