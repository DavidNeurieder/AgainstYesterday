// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use super::coordinate::Coordinate;
use super::distance::distance;
use crate::units::Distance;

/// Total geodesic length of a polyline, summed segment by segment.
///
/// Returns zero for fewer than two points.
pub fn polyline_length(points: &[Coordinate]) -> Distance {
    points
        .windows(2)
        .map(|pair| distance(pair[0], pair[1]))
        .fold(Distance::ZERO, |acc, d| acc + d)
}

/// An axis-aligned lat/lon bounding box containing a set of coordinates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BoundingBox {
    /// South-western corner (minimum latitude and longitude).
    pub min: Coordinate,
    /// North-eastern corner (maximum latitude and longitude).
    pub max: Coordinate,
}

impl BoundingBox {
    /// The total meridional (north-south) extent in meters.
    pub fn height(self) -> Distance {
        distance(
            self.min,
            Coordinate::new(self.max.latitude(), self.min.longitude()).expect("in range"),
        )
    }

    /// The total zonal (east-west) extent in meters, measured at the box's
    /// central latitude.
    pub fn width(self) -> Distance {
        let mid = (self.min.latitude() + self.max.latitude()) / 2.0;
        distance(
            Coordinate::new(mid, self.min.longitude()).expect("in range"),
            Coordinate::new(mid, self.max.longitude()).expect("in range"),
        )
    }
}

/// The bounding box of a set of coordinates, or `None` if empty.
pub fn bounding_box(points: &[Coordinate]) -> Option<BoundingBox> {
    let mut iter = points.iter().copied();
    let first = iter.next()?;

    let mut min_lat = first.latitude();
    let mut max_lat = first.latitude();
    let mut min_lon = first.longitude();
    let mut max_lon = first.longitude();

    for p in iter {
        min_lat = min_lat.min(p.latitude());
        max_lat = max_lat.max(p.latitude());
        min_lon = min_lon.min(p.longitude());
        max_lon = max_lon.max(p.longitude());
    }

    let min = Coordinate::new(min_lat, min_lon).expect("bounds of valid coords are in range");
    let max = Coordinate::new(max_lat, max_lon).expect("bounds of valid coords are in range");
    Some(BoundingBox { min, max })
}
