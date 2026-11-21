// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

pub mod elevation;
pub(crate) mod filtering;
mod model;
pub mod pace;
mod point;
mod resampling;
mod reverse;
pub mod segments;
mod simplification;
mod statistics;

pub use elevation::{ElevationBreakdown, ElevationConfig};
pub use filtering::{
    CursorConfig, FilterConfig, FilterCursor, FilterReason, ProcessingReport, filter,
    filter_detailed,
};
pub use model::Track;
pub use pace::{
    RollingBestPaceConfig, RollingPace, RollingPaceConfig, RollingPaceSample,
    rolling_best_pace_ms_per_km, rolling_pace_samples_ms_per_km,
};
pub use point::TrackPoint;
pub use resampling::resample_by_distance;
pub use reverse::reverse;
pub use segments::{
    RouteSegment, RouteSegmentComparison, SegmentComparison, SegmentError, TrackSegment,
    compare_route_segments, compare_segments, route_segments, segments,
};
pub use simplification::{SimplifyConfig, simplify};
pub use statistics::{MovingConfig, moving_duration};
