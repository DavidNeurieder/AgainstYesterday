// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Property tests for `Route` projection invariants (§32).

use gps_engine::Route;
use gps_engine::geo::{Coordinate, PolylineBounds, distance, project_to_polyline};
use gps_engine::units::Distance;
use proptest::prelude::*;

fn coord() -> impl Strategy<Value = Coordinate> {
    (-89.9f64..89.9, -180.0f64..180.0)
        .prop_map(|(lat, lon)| Coordinate::new(lat, lon).expect("strategy stays in range"))
}

/// A compact polyline route with meaningful length (≥ 10 m), built from up to
/// six coordinates with generous spacing between samples.
fn small_route() -> impl Strategy<Value = Route> {
    proptest::collection::vec(coord(), 2..=6)
        .prop_filter("route must be non-degenerate", |coords| {
            coords
                .windows(2)
                .any(|w| distance(w[0], w[1]).meters() > 0.005)
                && distance(coords[0], *coords.last().unwrap()).meters() > 10.0
        })
        .prop_map(|coords| Route::new(coords).expect("valid route"))
}

proptest! {
    #[test]
    fn projection_stays_within_route_bounds(route in small_route(), point in coord()) {
        let len = route.length().meters();
        let proj = route.project(point);
        // Clamping: never outside the route, with no more than rounding slack.
        prop_assert!(
            proj.distance_along.meters() >= -1e-6,
            "distance_along clamped below 0"
        );
        prop_assert!(
            proj.distance_along.meters() <= len + 1e-6,
            "distance_along exceeded route length {}",
            len
        );
        prop_assert!(proj.lateral_error.meters() >= 0.0);
        prop_assert!(proj.lateral_error.meters().is_finite());
        prop_assert!(proj.fraction >= 0.0 && proj.fraction <= 1.001);
    }

    #[test]
    fn on_route_points_project_back(route in small_route(), fraction_advance in 0.0f64..=1.0) {
        let len = route.length().meters();
        let along = fraction_advance * len;
        let c = route.coordinate_at(Distance::from_meters(along)).expect("within bounds");
        let proj = route.project(c);
        prop_assert!(
            (proj.distance_along.meters() - along).abs() < 0.001,
            "projected {} vs expected {along}",
            proj.distance_along.meters()
        );
    }

    #[test]
    fn coordinate_at_respects_bounds(route in small_route(), any in -2.0f64..2.0) {
        let len = route.length().meters();
        // Normalised query in [0, 1]; reflect negatives so we test both sides.
        let f = any.abs().min(1.0);
        for probe in [0.0f64, len, len * f] {
            prop_assert!(route.coordinate_at(Distance::from_meters(probe)).is_some());
        }
        prop_assert!(route.coordinate_at(Distance::from_meters(len * 1.5 + 1.0)).is_none());
        prop_assert!(route.coordinate_at(Distance::from_meters(-1.0)).is_none());
    }

    #[test]
    fn endpoints_are_exact(route in small_route()) {
        let start = route.coordinate_at(Distance::ZERO).unwrap();
        let end = route.coordinate_at(route.length()).unwrap();
        prop_assert!(distance(start, route.start()).meters() < 1e-9);
        prop_assert!(distance(end, route.end()).meters() < 1e-9);
    }

    #[test]
    fn vertices_project_to_cumulative_axes(route in small_route(), vertice_index in 0usize..=5) {
        let geo = route.geometry();
        if vertice_index >= geo.len() {
            return Ok(());
        }
        let vertex = geo[vertice_index];
        let proj = route.project(vertex);
        // The vertex of index k sits at its cumulative offset; projecting it
        // must land there (within numerical tolerance).
        let expected = match vertice_index {
            0 => 0.0,
            k => {
                let mut acc = 0.0;
                for w in geo[..=k].windows(2) {
                    acc += distance(w[0], w[1]).meters();
                }
                acc
            }
        };
        prop_assert!(
            (proj.distance_along.meters() - expected).abs() < 0.01,
            "vertex {vertice_index} projected to {actual} (expected {expected})",
            actual = proj.distance_along.meters(),
        );
        prop_assert!(proj.lateral_error.meters() < 1e-6);
    }

    #[test]
    fn nearest_matches_project(route in small_route(), point in coord()) {
        let proj = route.project(point);
        let nearest = route.nearest(point);
        prop_assert!((proj.distance_along.meters() - nearest.distance.meters()).abs() < 1e-6);
    }

    #[test]
    fn pruned_projection_agrees_with_exact(
        route in small_route(),
        point in coord(),
        tol in 1.0f64..200.0,
    ) {
        // `PolylineBounds::project_within` is the fast path used by matching:
        // it must never disagree with the exact nearest projection about
        // whether a point lies within `tol`. Over-rejection here would drop
        // real spatial overlap.
        let geometry = route.geometry();
        let bounds = PolylineBounds::new(geometry);
        let exact = project_to_polyline(point, geometry);
        let pruned = bounds.project_within(point, Distance::from_meters(tol));

        match exact {
            None => prop_assert!(pruned.is_none()),
            Some(e) => {
                if e.lateral_error.meters() <= tol {
                    let p = match pruned {
                    Some(p) => p,
                    None => {
                        return Err(proptest::test_runner::TestCaseError::fail(
                            "within-tol point must survive pruning",
                        ))
                    }
                };
                    prop_assert!(
                        (p.lateral_error.meters() - e.lateral_error.meters()).abs() < 1e-6,
                        "pruned lateral {} != exact {}",
                        p.lateral_error.meters(),
                        e.lateral_error.meters()
                    );
                } else {
                    prop_assert!(
                        pruned.is_none(),
                        "beyond-tol point must be rejected (tol {tol} m)"
                    );
                }
            }
        }
    }
}
