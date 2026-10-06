// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Strict, mathematically simple geometry tests.

use gps_engine::geo::{
    bounding_box, destination, distance, interpolate, polyline_length, project_to_polyline,
    project_to_segment,
};
use gps_engine::units::Distance;
use gps_engine::{Bearing, Coordinate, GeoError};

const R: f64 = gps_engine::geo::EARTH_RADIUS_METERS;
const DEG: f64 = std::f64::consts::PI / 180.0 * R;

fn coord(lat: f64, lon: f64) -> Coordinate {
    Coordinate::new(lat, lon).unwrap()
}

fn near_abs(a: f64, b: f64, tol: f64) {
    assert!(
        (a - b).abs() <= tol,
        "expected {a} ≈ {b} within {tol}, diff {}",
        (a - b).abs()
    );
}

fn near_m(a: Distance, b: f64, tol: f64) {
    near_abs(a.meters(), b, tol);
}

#[test]
fn distance_zero_is_zero() {
    let p = coord(52.5, 13.4);
    near_m(distance(p, p), 0.0, 1e-9);
}

#[test]
fn distance_one_degree_of_meridian() {
    // 1° of latitude on the sphere = π·R/180.
    near_m(distance(coord(0.0, 0.0), coord(1.0, 0.0)), DEG, 1e-6);
}

#[test]
fn distance_one_degree_of_equator() {
    near_m(distance(coord(0.0, 0.0), coord(0.0, 1.0)), DEG, 1e-6);
}

#[test]
fn distance_is_symmetric() {
    let a = coord(51.5, -0.1);
    let b = coord(48.8, 2.3);
    near_m(distance(a, b), distance(b, a).meters(), 1e-9);
}

#[test]
fn distance_half_circumference_between_poles() {
    near_m(
        distance(coord(90.0, 0.0), coord(-90.0, 0.0)),
        std::f64::consts::PI * R,
        1e-3,
    );
}

#[test]
fn bearing_cardinal_directions() {
    near_abs(bearing_test(coord(0.0, 0.0), coord(1.0, 0.0)), 0.0, 0.01);
    near_abs(bearing_test(coord(0.0, 0.0), coord(0.0, 1.0)), 90.0, 0.01);
    near_abs(bearing_test(coord(0.0, 0.0), coord(-1.0, 0.0)), 180.0, 0.01);
    near_abs(bearing_test(coord(0.0, 0.0), coord(0.0, -1.0)), 270.0, 0.01);
}

fn bearing_test(a: Coordinate, b: Coordinate) -> f64 {
    gps_engine::geo::bearing(a, b).unwrap().as_degrees()
}

#[test]
fn bearing_from_degrees_normalizes() {
    near_abs(
        Bearing::from_degrees(360.0).unwrap().as_degrees(),
        0.0,
        1e-9,
    );
    near_abs(
        Bearing::from_degrees(-90.0).unwrap().as_degrees(),
        270.0,
        1e-9,
    );
}

#[test]
fn destination_round_trips() {
    let start = coord(52.52, 13.405);
    let target = coord(52.53, 13.42);
    let brg = gps_engine::geo::bearing(start, target).unwrap();
    let dist = distance(start, target);
    let arrived = destination(start, brg, dist);
    near_abs(arrived.latitude(), target.latitude(), 1e-9);
    near_abs(arrived.longitude(), target.longitude(), 1e-9);
}

#[test]
fn interpolate_hits_endpoints_and_midpoint() {
    let a = coord(10.0, 20.0);
    let b = coord(30.0, 40.0);
    assert_eq!(interpolate(a, b, 0.0), a);
    assert_eq!(interpolate(a, b, 1.0), b);
    assert_eq!(interpolate(a, b, 0.5), coord(20.0, 30.0));
}

#[test]
fn interpolate_clamps_out_of_range() {
    let a = coord(10.0, 20.0);
    let b = coord(30.0, 40.0);
    assert_eq!(interpolate(a, b, -3.0), a);
    assert_eq!(interpolate(a, b, 7.0), b);
}

#[test]
fn polyline_length_sum_of_segments() {
    let pts = [coord(0.0, 0.0), coord(0.0, 1.0), coord(1.0, 1.0)];
    near_m(polyline_length(&pts), 2.0 * DEG, 1e-6);
}

#[test]
fn polyline_length_single_point_is_zero() {
    near_m(polyline_length(&[coord(1.0, 1.0)]), 0.0, 1e-12);
}

#[test]
fn project_to_segment_middle() {
    // Segment along the equator; the perpendicular foot is exactly halfway.
    let a = coord(0.0, 0.0);
    let b = coord(0.0, 1.0);
    let p = coord(0.5, 0.5);
    let proj = project_to_segment(p, a, b, 0);

    near_m(proj.distance_along, 0.5 * DEG, 1e-6);
    near_abs(proj.fraction, 0.5, 1e-12);
    assert_eq!(proj.projected, coord(0.0, 0.5));
    // Lateral error is the 0.5° meridian separation from the equator foot.
    near_m(proj.lateral_error, 0.5 * DEG, 1e-6);
}

#[test]
fn project_to_segment_middle_on_meridian() {
    // Segment along a meridian; the foot is exactly at latitude 0.5.
    let a = coord(0.0, 0.0);
    let b = coord(1.0, 0.0);
    let p = coord(0.5, 0.5);
    let proj = project_to_segment(p, a, b, 0);

    near_m(proj.distance_along, 0.5 * DEG, 1e-6);
    near_abs(proj.fraction, 0.5, 1e-12);
    assert_eq!(proj.projected, coord(0.5, 0.0));
    // Lateral error is the ~0.5° zonal separation at latitude 0.5.
    near_m(
        proj.lateral_error,
        distance(p, coord(0.5, 0.0)).meters(),
        1e-6,
    );
}

#[test]
fn project_to_segment_before_start_clamps() {
    let a = coord(0.0, 0.0);
    let b = coord(0.0, 1.0);
    let p = coord(0.5, -0.5);
    let proj = project_to_segment(p, a, b, 0);

    near_m(proj.distance_along, 0.0, 1e-9);
    near_abs(proj.fraction, 0.0, 1e-12);
    assert_eq!(proj.projected, a);
    near_m(proj.lateral_error, distance(p, a).meters(), 1e-6);
}

#[test]
fn project_to_segment_after_end_clamps() {
    let a = coord(0.0, 0.0);
    let b = coord(0.0, 1.0);
    let p = coord(0.5, 1.5);
    let proj = project_to_segment(p, a, b, 0);

    near_m(proj.distance_along, distance(a, b).meters(), 1e-6);
    near_abs(proj.fraction, 1.0, 1e-12);
    assert_eq!(proj.projected, b);
    near_m(proj.lateral_error, distance(p, b).meters(), 1e-6);
}

#[test]
fn project_to_polyline_selects_nearest_segment() {
    let line = [coord(0.0, 0.0), coord(1.0, 0.0), coord(2.0, 1.0)];
    let p = coord(1.95, 0.95);
    let proj = project_to_polyline(p, &line).unwrap();
    assert_eq!(proj.segment_index, 1);
    near_abs(proj.fraction, 0.95, 0.01);
}

#[test]
fn project_to_polyline_none_for_short_polyline() {
    assert!(project_to_polyline(coord(0.0, 0.0), &[coord(0.0, 0.0)]).is_none());
}

#[test]
fn bounding_box_known() {
    let pts = [coord(0.0, 5.0), coord(3.0, 2.0), coord(1.0, 4.0)];
    let bb = bounding_box(&pts).unwrap();
    assert_eq!(bb.min, coord(0.0, 2.0));
    assert_eq!(bb.max, coord(3.0, 5.0));
    near_m(
        bb.width(),
        distance(coord(1.5, 2.0), coord(1.5, 5.0)).meters(),
        1e-6,
    );
    near_m(
        bb.height(),
        distance(coord(0.0, 2.0), coord(3.0, 2.0)).meters(),
        1e-6,
    );
}

#[test]
fn bounding_box_empty_is_none() {
    assert!(bounding_box(&[]).is_none());
}

#[test]
fn coordinate_rejects_invalid() {
    assert_eq!(
        Coordinate::new(91.0, 0.0),
        Err(GeoError::LatitudeOutOfRange(91.0))
    );
    assert_eq!(
        Coordinate::new(0.0, -181.0),
        Err(GeoError::LongitudeOutOfRange(-181.0))
    );
    assert!(matches!(
        Coordinate::new(f64::NAN, 0.0),
        Err(GeoError::NonFinite(_))
    ));
    assert!(matches!(
        Coordinate::new(0.0, f64::INFINITY),
        Err(GeoError::NonFinite(_))
    ));
}
