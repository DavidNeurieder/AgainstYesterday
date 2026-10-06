// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route table for the app (§42): HOME / RECORD / ROUTES.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/activity/presentation/activity_detail_screen.dart';
import '../features/dev/presentation/diagnostics_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/recording/presentation/record_flow_screen.dart';
import '../features/result/presentation/result_screen.dart';
import '../features/routes/presentation/route_detail_screen.dart';
import '../features/routes/presentation/routes_screen.dart';
import 'app_shell.dart';
import 'dependencies.dart';

/// The triple-tab shell.
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
                path: '/record',
                builder: (context, state) => const RecordFlowScreen(),
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
        ],
      ),
      // Full-screen overlays pushed above the shell (M11).
      GoRoute(
        path: '/record/result',
        builder: (context, state) => const ResultScreen(),
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
