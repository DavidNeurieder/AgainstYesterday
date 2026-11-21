// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Additive uncertainty contracts: estimates attach without changing behavior.

use gps_engine::analytics::TrackAnalytics;
use gps_engine::attempt::AttemptSample;
use gps_engine::geo::Coordinate;
use gps_engine::ghost::live_ghost_snapshot;
use gps_engine::gps::{GpsFix, GpsTrace};
use gps_engine::live::{LiveConfig, LiveRecorder, LiveSnapshot};
use gps_engine::route::{ContinuityConfig, Route, RouteMatcher, RouteObservation};
use gps_engine::track::{FilterConfig, MovingConfig, Track, TrackPoint};
use gps_engine::units::{Distance, Duration, Speed, Timestamp};
use gps_engine::{
    Attempt, Confidence, DistanceBreakdown, GhostSnapshot, MatchStep, MotionState,
    PositionEstimate, ProcessedSample, VelocityEstimate,
};

fn coordinate() -> Coordinate {
    Coordinate::new(52.5, 13.4).expect("valid coordinate")
}

fn timestamp(seconds: f64) -> Timestamp {
    Timestamp::from_unix_secs(seconds)
}

fn position() -> PositionEstimate {
    PositionEstimate::new(
        timestamp(0.0),
        coordinate(),
        Distance::from_meters(6.0),
        Confidence::new(0.8),
    )
}

fn velocity() -> VelocityEstimate {
    VelocityEstimate::new(Speed::from_mps(3.0), None, Confidence::new(0.6))
}

fn breakdown() -> DistanceBreakdown {
    DistanceBreakdown::new()
        .with_raw(Distance::from_meters(100.0))
        .with_filtered(Distance::from_meters(98.0))
        .with_route(Distance::from_meters(97.0))
}

fn processed_sample() -> ProcessedSample {
    let trace = GpsTrace::new(vec![
        GpsFix::new(timestamp(0.0), coordinate()),
        GpsFix::new(timestamp(2.0), coordinate()),
    ])
    .expect("two fixes");
    trace
        .process(&FilterConfig::matching())
        .expect("process")
        .samples
        .into_iter()
        .next()
        .expect("one audit per fix")
}

fn match_step() -> MatchStep {
    let route = Route::new(vec![
        coordinate(),
        Coordinate::new(52.500_5, 13.4).expect("valid coordinate"),
    ])
    .expect("route");
    let mut matcher = RouteMatcher::new(ContinuityConfig::default());
    matcher.update_observation(
        &route,
        &RouteObservation {
            coordinate: coordinate(),
            timestamp: timestamp(0.0),
            accuracy: None,
            speed: None,
            bearing: None,
        },
    )
}

fn live_snapshot() -> LiveSnapshot {
    LiveRecorder::new(LiveConfig::default(), None).snapshot()
}

fn ghost_snapshot() -> GhostSnapshot {
    let attempt = Attempt::from_samples(vec![
        AttemptSample {
            distance: Distance::ZERO,
            elapsed: Duration::ZERO,
        },
        AttemptSample {
            distance: Distance::from_meters(1000.0),
            elapsed: Duration::from_secs(200.0),
        },
    ])
    .expect("attempt");
    live_ghost_snapshot(
        &attempt,
        Distance::from_meters(100.0),
        Duration::from_secs(20.0),
    )
}

#[test]
fn host_types_start_without_estimates() {
    let sample = processed_sample();
    assert_eq!(sample.position_estimate(), None);
    assert_eq!(sample.velocity_estimate(), None);
    assert_eq!(sample.motion_state(), None);

    let point = TrackPoint::new(timestamp(0.0), coordinate());
    assert_eq!(point.position_estimate(), None);
    assert_eq!(point.velocity_estimate(), None);
    assert_eq!(point.motion_state(), None);

    let step = match_step();
    assert_eq!(step.position_estimate(), None);
    assert_eq!(step.velocity_estimate(), None);
    assert_eq!(step.motion_state(), None);

    let snapshot = live_snapshot();
    assert_eq!(snapshot.position_estimate(), None);
    assert_eq!(snapshot.velocity_estimate(), None);
    assert_eq!(snapshot.motion_state(), None);
    assert_eq!(snapshot.distance_breakdown(), None);

    let ghost = ghost_snapshot();
    assert_eq!(ghost.position_confidence(), None);
    assert_eq!(ghost.match_confidence(), None);
}

#[test]
fn builders_attach_estimates_without_touching_existing_fields() {
    let sample = processed_sample();
    let raw_fix = sample.sample;
    let attached = sample
        .with_position_estimate(position())
        .with_velocity_estimate(velocity())
        .with_motion_state(MotionState::Stationary(Confidence::new(0.9)));
    assert_eq!(attached.sample, raw_fix);
    assert_eq!(attached.position_estimate(), Some(position()));
    assert_eq!(attached.velocity_estimate(), Some(velocity()));
    assert_eq!(
        attached.motion_state(),
        Some(MotionState::Stationary(Confidence::new(0.9)))
    );

    let point = TrackPoint::new(timestamp(0.0), coordinate())
        .with_position_estimate(position())
        .with_velocity_estimate(velocity())
        .with_motion_state(MotionState::Moving(Confidence::ONE));
    assert_eq!(point.coordinate(), coordinate());
    assert_eq!(point.position_estimate(), Some(position()));
    assert_eq!(point.velocity_estimate(), Some(velocity()));
    assert!(point.motion_state().is_some_and(|state| state.is_moving()));

    let step = match_step();
    let reliable = step.projection.distance;
    let step = step
        .with_position_estimate(position())
        .with_velocity_estimate(velocity())
        .with_motion_state(MotionState::Unknown(Confidence::ZERO));
    assert_eq!(step.projection.distance, reliable);
    assert_eq!(step.position_estimate(), Some(position()));
    assert_eq!(step.velocity_estimate(), Some(velocity()));
    assert!(step.motion_state().is_some_and(|state| state.is_unknown()));

    let snapshot = live_snapshot();
    let distance = snapshot.distance;
    let snapshot = snapshot
        .with_position_estimate(position())
        .with_velocity_estimate(velocity())
        .with_motion_state(MotionState::Moving(Confidence::ONE))
        .with_distance_breakdown(breakdown());
    assert_eq!(snapshot.distance, distance);
    assert_eq!(snapshot.position_estimate(), Some(position()));
    assert_eq!(snapshot.velocity_estimate(), Some(velocity()));
    assert_eq!(snapshot.distance_breakdown(), Some(breakdown()));

    let ghost = ghost_snapshot();
    let original_confidence = ghost.confidence;
    let ghost = ghost
        .with_position_confidence(Confidence::new(0.4))
        .with_match_confidence(Confidence::new(0.7));
    assert_eq!(ghost.confidence, original_confidence);
    assert_eq!(ghost.position_confidence(), Some(Confidence::new(0.4)));
    assert_eq!(ghost.match_confidence(), Some(Confidence::new(0.7)));
}

#[test]
fn attaching_estimates_does_not_change_analytics() {
    let plain = Track::new(vec![
        TrackPoint::new(timestamp(0.0), coordinate()),
        TrackPoint::new(
            timestamp(2.0),
            Coordinate::new(52.500_5, 13.4).expect("valid coordinate"),
        ),
    ])
    .expect("track");
    let annotated = Track::new(
        plain
            .points()
            .iter()
            .map(|point| {
                point
                    .with_position_estimate(position())
                    .with_velocity_estimate(velocity())
                    .with_motion_state(MotionState::Moving(Confidence::ONE))
            })
            .collect(),
    )
    .expect("annotated track");
    assert_eq!(
        TrackAnalytics::from_track(&plain, &MovingConfig::default()),
        TrackAnalytics::from_track(&annotated, &MovingConfig::default())
    );
}
