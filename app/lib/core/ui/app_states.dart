// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared Loading / Empty / Error treatments (§27, §28) so every screen
/// answers "loading / loaded / empty / error" the same way.
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// An icon-led calm message where a section has nothing to show yet.
///
/// [compact] renders the inline row used inside lists (Home section hints);
/// the default is the centered, larger treatment for whole screens.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon = Icons.inbox_outlined,
    required this.message,
    this.action,
    this.compact = false,
    this.iconColor = AppColors.textMuted,
  });

  final IconData icon;
  final String message;
  final Widget? action;
  final bool compact;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final text = Text(
      message,
      textAlign: compact ? TextAlign.start : TextAlign.center,
      style: textTheme.bodyMedium?.copyWith(color: AppColors.textMuted),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon, size: 28, color: AppColors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: text),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Icon(icon, size: 48, color: iconColor),
          const SizedBox(height: 12),
          text,
          if (action case final action?) ...[
            const SizedBox(height: AppSpacing.lg),
            action,
          ],
        ],
      ),
    );
  }
}

/// A non-animating loading cue (an icon, not a spinner comment) so widget
/// tests that drive the fake tick clock never fight a perpetual animation.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          const Icon(Icons.hourglass_top, size: 48, color: AppColors.textMuted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}

/// A consistent block for a screen-level failure: icon, title, message and
/// any recovery actions (§33).
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.error_outline,
    this.iconColor = AppColors.error,
    this.actions = const [],
  });

  final String title;
  final String? message;
  final IconData icon;
  final Color iconColor;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: iconColor),
            const SizedBox(height: AppSpacing.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge,
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(height: AppSpacing.sm),
                actions[i],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// §33's full-screen error treatment: an [AppBar] over [ErrorState], with the
/// recovery actions supplied by the caller. The three spec screens (GPS,
/// route load, save) all share this skeleton so a failure always looks and
/// acts the same.
class ErrorScreen extends StatelessWidget {
  const ErrorScreen({
    super.key,
    required this.title,
    this.barTitle,
    this.message,
    this.icon = Icons.error_outline,
    this.actions = const [],
  });

  final String title;
  final String? barTitle;
  final String? message;
  final IconData icon;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: barTitle == null ? null : AppBar(title: Text(barTitle!)),
      body: SafeArea(
        child: ErrorState(
          title: title,
          message: message,
          icon: icon,
          actions: actions,
        ),
      ),
    );
  }
}

/// §33's inline save-error block for the finish and result screens: the run
/// itself is safely shown, only the disk write failed, so TRY AGAIN rewrites
/// the storage the controller still holds in memory.
class SaveErrorState extends StatelessWidget {
  const SaveErrorState({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ErrorState(
      title: 'COULDN\'T SAVE ACTIVITY',
      message: 'Your activity is safely stored and can be retried.',
      actions: [
        FilledButton(onPressed: onRetry, child: const Text('TRY AGAIN')),
      ],
    );
  }
}