// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// App shell: bottom navigation across Home / Routes / History (§42).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'dependencies.dart';

/// Scaffold with a [NavigationBar] driving the three shell branches.
///
/// When developer tools are enabled (M15 Phase 10), a small diagnostics
/// button floats at the top right so a developer can open the live readout
/// from any tab.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devToolsOn = ref.watch(devToolsEnabledProvider);
    final topInset = MediaQuery.paddingOf(context).top + 8;
    return Scaffold(
      body: Stack(
        children: [
          navigationShell,
          if (devToolsOn)
            Positioned(
              top: topInset,
              right: 8,
              child: _DevToolsButton(onPressed: () {
                context.push('/dev/diagnostics');
              }),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) {
          navigationShell.goBranch(
            index,
            initialLocation: index == navigationShell.currentIndex,
          );
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.route_outlined),
            selectedIcon: Icon(Icons.route),
            label: 'Routes',
          ),
          NavigationDestination(
            icon: Icon(Icons.history_outlined),
            selectedIcon: Icon(Icons.history),
            label: 'History',
          ),
        ],
      ),
    );
  }
}

/// The dev-only entry button to the diagnostics screen.
class _DevToolsButton extends StatelessWidget {
  const _DevToolsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('dev-diagnostics'),
      color: Colors.transparent,
      child: IconButton(
        tooltip: 'Diagnostics',
        onPressed: onPressed,
        icon: const Icon(Icons.bug_report_outlined),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}