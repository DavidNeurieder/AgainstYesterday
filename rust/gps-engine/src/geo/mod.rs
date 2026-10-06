// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Geographic primitives.
//!
//! All coordinates are lon/lat degrees and all distances are geodetic
//! (great-circle, spherical earth model). This module is deliberately
//! dependency-free so the formulas are small, readable, and exactly testable.

mod bearing;
mod coordinate;
mod distance;
mod interpolation;
mod polyline;
mod projection;

pub use bearing::{Bearing, bearing};
pub use coordinate::Coordinate;
pub use distance::{EARTH_RADIUS_METERS, destination, distance};
pub use interpolation::interpolate;
pub use polyline::{BoundingBox, bounding_box, polyline_length};
pub use projection::{PolylineBounds, Projection, project_to_polyline, project_to_segment};
