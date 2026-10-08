// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// First-launch onboarding (§34): three swipeable screens of product copy,
/// ending in GET STARTED, which marks the intro as seen and drops the user
/// straight into the record-a-route flow. Never more than three screens, no
/// account step (§34).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../settings/application/haptics.dart';
import '../../settings/application/settings_controller.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  static const List<(String, String)> _screens = [
    ('Against Yesterday', 'Race your best.'),
    ('Choose a route.', 'Your previous best becomes your opponent.'),
    ('See the gap.', 'Know exactly when you\'re winning or losing.'),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() {
    AppHaptics.light(ref);
    final settings = ref.read(settingsRepositoryProvider);
    // The state flips synchronously, so the gate opens before the first
    // frame after the navigation below; the disk write catches up on its
    // own (best effort).
    ref
        .read(settingsRepositoryProvider.notifier)
        .save(settings.copyWith(onboardingSeen: true));
    context.go('/record-route');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (page) => setState(() => _page = page),
                children: [
                  for (var i = 0; i < _screens.length; i++)
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            _screens[i].$1,
                            textAlign: TextAlign.center,
                            style: textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.lg),
                          Text(
                            _screens[i].$2,
                            textAlign: TextAlign.center,
                            style: textTheme.titleMedium?.copyWith(
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                          if (i == _screens.length - 1) ...[
                            const SizedBox(height: AppSpacing.xl),
                            FilledButton(
                              onPressed: _start,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.you,
                                foregroundColor: AppColors.background,
                                minimumSize: const Size.fromHeight(64),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(20),
                                ),
                              ),
                              child: const Text('GET STARTED'),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            // Page dots; each carries a spoken screen count (§32) and a
            // generous tap target instead of a bare 8 px bubble.
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _screens.length; i++)
                    Semantics(
                      button: true,
                      label: 'Screen ${i + 1} of ${_screens.length}',
                      child: GestureDetector(
                        onTap: () => _controller.animateToPage(
                          i,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        ),
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: i == _page ? 24 : 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: i == _page
                                    ? AppColors.textPrimary
                                    : AppColors.outline,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
