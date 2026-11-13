// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route table for the app (§42): ROUTES / HISTORY / SETTINGS shell plus
/// pushed full-screen flows: /record and the detail screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/presentation/activity_detail_screen.dart';
import '../features/activity/presentation/replay_screen.dart';
import '../features/dev/presentation/diagnostics_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/recording/presentation/record_flow_screen.dart';
import '../features/recording/presentation/route_record_flow_screen.dart';
import '../features/routes/presentation/route_detail_screen.dart';
import '../features/routes/presentation/route_statistics_screen.dart';
import '../features/routes/presentation/routes_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/statistics/presentation/statistics_screen.dart';
import 'app_shell.dart';
import 'dependencies.dart';

/// The shell plus full-screen flows.
GoRouter buildRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: [
      // The old Routes tab is now the landing tab; keep deep links working.
      GoRoute(path: '/routes', redirect: (context, state) => '/'),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
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
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
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
      // Race a specific route (M19): the same flow bound to one route, with
      // that route's pre-race and the 3-2-1-GO countdown before the timer.
      GoRoute(
        path: '/race/:id',
        builder: (context, state) =>
            RecordFlowScreen(routeId: state.pathParameters['id']),
      ),
      // Race a specific run's ghost on its route.
      GoRoute(
        path: '/race/:id/ghost/:ghostId',
        builder: (context, state) => RecordFlowScreen(
          routeId: state.pathParameters['id'],
          ghostActivityId: state.pathParameters['ghostId'],
        ),
      ),
      // Record-a-route (M18): prep → recording → name-and-save → saved.
      GoRoute(
        path: '/record-route',
        builder: (context, state) => const RouteRecordFlowScreen(),
      ),
      GoRoute(
        path: '/statistics',
        builder: (context, state) => const StatisticsScreen(),
      ),
      // Developer diagnostics (M15 Phase 10). Gated in the router as well as
      // in the shell: with dev tools off, a deep link or manual push lands
      // back on the landing tab instead of exposing the readout.
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
        path: '/activity/:id/replay',
        builder: (context, state) =>
            ReplayScreen(activityId: state.pathParameters['id']!),
      ),
      // Statistics for one route, pushed from its detail app bar: a card hub
      // plus one page per card. Declared before the detail route so the deeper
      // paths always win.
      GoRoute(
        path: '/route/:id/statistics/:section',
        builder: (context, state) {
          final section =
              RouteStatsSection.fromSlug(state.pathParameters['section']!);
          if (section == null) {
            return const _NotFound();
          }
          return RouteStatisticsSectionScreen(
            routeId: state.pathParameters['id']!,
            section: section,
          );
        },
      ),
      GoRoute(
        path: '/route/:id/statistics',
        builder: (context, state) => RouteStatisticsScreen(
          routeId: state.pathParameters['id']!,
        ),
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
