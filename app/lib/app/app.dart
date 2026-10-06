// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App root: provider scope + theme + router (M1 shell).
///
/// As a [ConsumerStatefulWidget] it also observes app lifecycle changes and
/// forwards them to the recording controller (M13, §28), so a run stays
/// accurate and recoverable across backgrounding.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../features/recording/application/recording_controller.dart';
import 'router.dart';

class GpsApp extends ConsumerStatefulWidget {
  const GpsApp({super.key});

  @override
  ConsumerState<GpsApp> createState() => _GpsAppState();
}

class _GpsAppState extends ConsumerState<GpsApp> with WidgetsBindingObserver {
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
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp.router(
        title: 'Against Yesterday',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: buildRouter(),
      ),
    );
  }
}