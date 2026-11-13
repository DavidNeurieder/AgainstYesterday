// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Gap-to-PB curve over the route (§23, M26).
///
/// Samples come from the engine (`EngineService.computePaceAnalysis`); the
/// constants here describe how the chart is drawn.
library;

export 'package:against_yesterday/engine/models.dart' show GapPoint;

/// Distance between two curve samples, in meters.
const double gapSampleStepMeters = 100;

/// Covered distance below which the chart is not worth drawing (roughly
/// two samples plus the origin).
const double gapChartMinimumMeters = 250;
