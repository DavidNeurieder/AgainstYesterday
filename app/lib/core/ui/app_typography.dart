// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Typography helpers: numbers render with tabular figures so digits line up
/// while the rest of the app keeps the system font.
library;

import 'package:flutter/painting.dart';

/// The same [TextStyle] armed with proportional-free figures.
TextStyle tabular(TextStyle style) =>
    style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);