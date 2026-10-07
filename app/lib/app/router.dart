// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route table for the app (§42): HOME / ROUTES / HISTORY shell plus pushed
/// full-screen flows: /record, /settings and the detail screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/presentation/activity_detail_screen.dart';
import '../features/dev/presentation/diagnostics_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/recording/presentation/record_flow_screen.dart';
import '../features/recording/presentation/route_record_flow_screen.dart';
import '../features/result/presentation/result_screen.dart';
import '../features/routes/presentation/route_detail_screen.dart';
import '../features/routes/presentation/routes_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'app_shell.dart';
import 'dependencies.dart';

/// The shell plus full-screen flows.
GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/routes',
                builder: (context, state) => const RoutesScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/history',
                builder: (context, state) => const HistoryScreen(),
              ),
            ],
          ),
        ],
      ),
      // Recording is a pushed full-screen flow on top of the shell (M16).
      GoRoute(
        path: '/record',
        builder: (context, state) => const RecordFlowScreen(),
      ),
      // Record-a-route (M18): prep → recording → name-and-save → saved.
      GoRoute(
        path: '/record-route',
        builder: (context, state) => const RouteRecordFlowScreen(),
      ),
      GoRoute(
        path: '/record/result',
        builder: (context, state) => const ResultScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      // Developer diagnostics (M15 Phase 10). Gated in the router as well as
      // in the shell: with dev tools off, a deep link or manual push lands
      // back on Home instead of exposing the readout.
      GoRoute(
        path: '/dev/diagnostics',
        redirect: (context, state) {
          final enabled = ProviderScope.containerOf(
            context,
            listen: false,
          ).read(devToolsEnabledProvider);
          return enabled ? null : '/';
        },
        builder: (context, state) => const DiagnosticsScreen(),
      ),
      GoRoute(
        path: '/activity/:id',
        builder: (context, state) =>
            ActivityDetailScreen(activityId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/route/:id',
        builder: (context, state) =>
            RouteDetailScreen(routeId: state.pathParameters['id']!),
      ),
    ],
    errorBuilder: (context, state) => const _NotFound(),
  );
}

class _NotFound extends StatelessWidget {
  const _NotFound();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Text(
          'Nothing here',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
  }
}
