// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Route saved (§8 "After saving"): the new course is in the catalog and the
/// recorded time stands as its first personal best. Two exits — into the route
/// detail (VIEW ROUTE) or back to Home (DONE).
library;

import 'package:flutter/material.dart' hide Route;
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/app_buttons.dart';
import '../../../engine/models.dart';

class RouteRecordSavedScreen extends StatelessWidget {
  const RouteRecordSavedScreen({super.key, required this.route});

  final Route route;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Route saved')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(
                Icons.emoji_events_outlined,
                size: 72,
                color: AppColors.pb,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                route.name,
                textAlign: TextAlign.center,
                style: textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Personal best', textAlign: TextAlign.center),
              const SizedBox(height: 4),
              Text(
                route.personalBest?.format() ?? '—',
                textAlign: TextAlign.center,
                style: textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.pb,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${route.distance.format()} · your first attempt is the '
                'baseline to race.',
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const Spacer(),
              PrimaryButton(
                label: 'VIEW ROUTE',
                height: 64,
                icon: Icons.route,
                onPressed: () => context.go('/route/${route.id}'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => context.go('/'),
                child: const Text('DONE'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}