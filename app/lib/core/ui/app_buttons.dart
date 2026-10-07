// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Shared button recipes (§27): one primary filled button for the app so
/// heights, radii and the white-on-background contrast stop drifting between
/// screens (history of 10/12/18/20 px radii is why this exists).
library;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The app's full-width primary action: white fill on the dark background,
/// 56 px tall by default (start/race buttons want 64–72).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.height = 56,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: AppColors.you,
      foregroundColor: AppColors.background,
      minimumSize: Size.fromHeight(height),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    );
    final child = Text(label, style: Theme.of(context).textTheme.titleMedium);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: icon == null
          ? FilledButton(onPressed: onPressed, style: style, child: child)
          : FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon),
              label: child,
            ),
    );
  }
}