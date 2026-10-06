// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

mod filtering;
mod model;
mod point;
mod resampling;
mod reverse;
mod simplification;
mod statistics;

pub use filtering::{FilterConfig, FilterReason, ProcessingReport, filter, filter_detailed};
pub use model::Track;
pub use point::TrackPoint;
pub use resampling::resample_by_distance;
pub use reverse::reverse;
pub use simplification::{SimplifyConfig, simplify};
pub use statistics::{MovingConfig, moving_duration};
