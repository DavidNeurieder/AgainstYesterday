// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Attempt: a recording reduced to the canonical route axis.
//!
//! The route projection turns messy GPS into a one-dimensional curve:
//!
//! ```text
//! raw GPS ─→ route distance → elapsed time
//! ----------------------------------------
//! 0m    → 00:00
//! 500m  → 02:31
//! 1000m → 05:04
//! ```
//!
//! This is the data structure that makes racing and ghosts possible.
//! [`Attempt`] answers `time_at(distance)` and `distance_at(elapsed)`;
//! [`attempt::performance`] compares two attempts pointwise.

use thiserror::Error;

use crate::Track;
use crate::geo::distance as geo_distance;
use crate::route::Route;
use crate::track::MovingConfig;
use crate::units::{Distance, Duration, Speed};

pub mod performance;

/// One sample of route distance against elapsed time.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AttemptSample {
    /// Distance along the route that had been covered by then, in meters.
    pub distance: Distance,
    /// Elapsed time since the attempt started.
    pub elapsed: Duration,
}

/// Errors produced when constructing an [`Attempt`].
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AttemptError {
    /// No samples were supplied.
    #[error("attempt has no samples")]
    Empty,
    /// A sample carries a non-finite distance or elapsed time.
    #[error("sample at index {0} has a non-finite value")]
    NonFinite(usize),
    /// A sample violates non-decreasing ordering.
    #[error("sample at index {index} is not ordered (distance and elapsed must be non-decreasing)")]
    NonMonotonic {
        /// 0-based index of the offending sample.
        index: usize,
    },
}

/// A recording expressed as *route distance → elapsed time*.
///
/// `samples` is a non-decreasing coverage curve: distance advances when the
/// runner first reaches a new point along the route (so pauses add time but
/// not distance, and back-tracking never rolls coverage back). Querying
/// "first time past X" is therefore a simple interpolation.
#[derive(Debug, Clone, PartialEq)]
pub struct Attempt {
    /// Monotonic (distance, elapsed) coverage samples.
    pub samples: Vec<AttemptSample>,
    /// Final elapsed time (`samples.last().elapsed`).
    pub elapsed_time: Duration,
    /// Final coverage along the route (`samples.last().distance`).
    pub distance: Distance,
}

/// Which time axis an [`Attempt`] is built on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AttemptAxis {
    /// Wall-clock elapsed time since the first track point (the legacy axis).
    #[default]
    Clock,
    /// Moving time: gaps count only when the segment shows real motion
    /// (see [`MovingAxisConfig`]). Pauses and long stops do not advance the
    /// axis, so the ghost compares performance at the same distance without a
    /// break inflating the deficit.
    Moving,
}

/// Rules for the [`AttemptAxis::Moving`] axis.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MovingAxisConfig {
    /// Gaps whose average speed is below this are treated as stops.
    pub min_speed: Speed,
    /// A gap must last at least this long before it can count as a stop.
    pub min_stop_duration: Duration,
}

impl Default for MovingAxisConfig {
    fn default() -> Self {
        let moving = MovingConfig::default();
        MovingAxisConfig {
            min_speed: moving.min_speed,
            min_stop_duration: moving.min_stop_duration,
        }
    }
}

impl Attempt {
    /// Builds an attempt from an already-monotonic sample series.
    ///
    /// Distances and elapses must be non-decreasing and finite.
    pub fn from_samples(samples: Vec<AttemptSample>) -> Result<Self, AttemptError> {
        if samples.is_empty() {
            return Err(AttemptError::Empty);
        }

        let mut prev_distance = 0.0f64;
        let mut prev_elapsed = 0.0f64;
        for (i, sample) in samples.iter().enumerate() {
            let d = sample.distance.meters();
            let t = sample.elapsed.as_secs();
            if !d.is_finite() || !t.is_finite() {
                return Err(AttemptError::NonFinite(i));
            }
            if i > 0 && (d < prev_distance || t < prev_elapsed) {
                return Err(AttemptError::NonMonotonic { index: i });
            }
            prev_distance = d;
            prev_elapsed = t;
        }

        let last = *samples.last().expect("non-empty");
        Ok(Self {
            samples,
            elapsed_time: last.elapsed,
            distance: last.distance,
        })
    }

    /// Reduces a `(track, route)` recording to the route axis on the
    /// wall-clock axis (backward-compatible default).
    pub fn from_track(track: &Track, route: &Route) -> Self {
        Self::from_track_with(
            track,
            route,
            AttemptAxis::Clock,
            &MovingAxisConfig::default(),
        )
    }

    /// Reduces a `(track, route)` recording to the route axis.
    ///
    /// Coverage is the maximum route distance reached so far (never rolls
    /// back). The sample `elapsed` follows `axis`: [`AttemptAxis::Clock`] is
    /// wall time since the start; [`AttemptAxis::Moving`] accumulates only
    /// moving segments so explicit pauses and long stops do not advance it.
    pub fn from_track_with(
        track: &Track,
        route: &Route,
        axis: AttemptAxis,
        moving: &MovingAxisConfig,
    ) -> Self {
        let t0_ms = track
            .start()
            .expect("track non-empty")
            .timestamp()
            .unix_ms();
        let route_len = route.length().meters();

        let mut coverage = 0.0f64;
        let mut moving_elapsed = 0.0f64;
        let mut prev = None;
        let mut samples: Vec<AttemptSample> = Vec::with_capacity(track.len());

        for p in track.points() {
            let along = route
                .project(p.coordinate())
                .distance_along
                .meters()
                .clamp(0.0, route_len);
            coverage = coverage.max(along);

            let elapsed = match axis {
                AttemptAxis::Clock => {
                    Duration::from_millis((p.timestamp().unix_ms() - t0_ms) as f64)
                }
                AttemptAxis::Moving => {
                    if let Some((prev_point, _prev_cov)) = prev {
                        let prev_p: &crate::TrackPoint = prev_point;
                        let dt = p.timestamp().elapsed_since(prev_p.timestamp()).as_secs();
                        if dt > 0.0 {
                            moving_elapsed += moving_segment_dt(prev_p, p, dt, moving);
                        }
                    }
                    Duration::from_secs(moving_elapsed)
                }
            };

            samples.push(AttemptSample {
                distance: Distance::from_meters(coverage),
                elapsed,
            });
            prev = Some((p, coverage));
        }

        Self::from_samples(samples).expect("from_track produces a monotonic coverage curve")
    }

    /// Elapsed time when the runner first reached `distance`.
    ///
    /// `None` when the distance was never covered (beyond the final
    /// coverage) or is non-finite. Distances at or below zero yield the start
    /// time.
    pub fn time_at(&self, distance: Distance) -> Option<Duration> {
        let d = distance.meters();
        if !d.is_finite() {
            return None;
        }
        if d <= 0.0 {
            return Some(Duration::ZERO);
        }

        let last = *self.samples.last().expect("non-empty");
        if d > last.distance.meters() {
            return None;
        }
        if d == last.distance.meters() {
            return Some(last.elapsed);
        }
        if d < self.samples[0].distance.meters() {
            // Never recorded on the curve: uncovered between the start line
            // and the first sample (e.g. an imperfect start).
            return None;
        }

        // First sample whose coverage already reaches `d` — that instant is
        // the earliest time coverage was at or past the target.
        let j = self.samples.iter().position(|s| s.distance.meters() >= d)?;
        if self.samples[j].distance.meters() == d {
            return Some(self.samples[j].elapsed);
        }
        let a = self.samples[j - 1];
        let b = self.samples[j];
        let (d0, d1) = (a.distance.meters(), b.distance.meters());
        if d1 <= d0 {
            return Some(b.elapsed); // vertical coverage segment
        }
        let fraction = (d - d0) / (d1 - d0);
        Some(Duration::from_secs(
            a.elapsed.as_secs() + fraction * (b.elapsed.as_secs() - a.elapsed.as_secs()),
        ))
    }

    /// Distance covered by `elapsed` time.
    ///
    /// `None` for negative or non-finite times. Past the final sample the
    /// terminal distance is returned (the runner finished).
    pub fn distance_at(&self, elapsed: Duration) -> Option<Distance> {
        let t = elapsed.as_secs();
        if !t.is_finite() {
            return None;
        }
        if t < 0.0 {
            return None;
        }

        let last = *self.samples.last().expect("non-empty");
        if t >= last.elapsed.as_secs() {
            return Some(last.distance);
        }

        let i = self
            .samples
            .iter()
            .rposition(|s| s.elapsed.as_secs() <= t)?;
        let a = self.samples[i];
        let b = self.samples[i + 1];
        let (t0, t1) = (a.elapsed.as_secs(), b.elapsed.as_secs());
        if t1 <= t0 {
            return Some(a.distance);
        }
        let fraction = (t - t0) / (t1 - t0);
        Some(Distance::from_meters(
            a.distance.meters() + fraction * (b.distance.meters() - a.distance.meters()),
        ))
    }
}

/// Moving time contributed by one segment, or `0.0` when it is a stop.
fn moving_segment_dt(
    a: &crate::TrackPoint,
    b: &crate::TrackPoint,
    dt: f64,
    config: &MovingAxisConfig,
) -> f64 {
    if dt <= 0.0 {
        return 0.0;
    }
    if dt < config.min_stop_duration.as_secs() {
        return dt;
    }
    let speed = geo_distance(a.coordinate(), b.coordinate()).meters() / dt;
    if speed >= config.min_speed.mps() {
        dt
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrackPoint;
    use crate::geo::Coordinate;
    use crate::route::Route;

    /// A straight 1000 m route along a meridian.
    fn straight_route() -> Route {
        let start = Coordinate::new(52.50, 13.40).unwrap();
        let end = Coordinate::new(52.509_005, 13.40).unwrap();
        Route::new(vec![start, end]).unwrap()
    }

    #[test]
    fn rejects_empty_and_non_monotonic_samples() {
        assert_eq!(Attempt::from_samples(vec![]), Err(AttemptError::Empty));

        let bad = vec![
            AttemptSample {
                distance: Distance::from_meters(100.0),
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(50.0),
                elapsed: Duration::from_secs(10.0),
            },
        ];
        assert_eq!(
            Attempt::from_samples(bad),
            Err(AttemptError::NonMonotonic { index: 1 })
        );
    }

    #[test]
    fn exact_5_mps_split_times() {
        // Deterministic spec example: 0 → 1000 m at a constant 5 m/s gives
        // 100m → 20s, 500m → 100s, 1000m → 200s. The track is built by hand
        // (one exact on-route sample per second) so every split is exact.
        let route = straight_route();
        let points: Vec<TrackPoint> = (0..=200)
            .map(|s| {
                TrackPoint::new(
                    crate::units::Timestamp::from_unix_ms(s * 1_000),
                    route
                        .coordinate_at(Distance::from_meters(s as f64 * 5.0))
                        .expect("within route"),
                )
            })
            .collect();
        let track = Track::new(points).unwrap();
        let attempt = Attempt::from_track(&track, &route);

        let time = |d: f64| attempt.time_at(Distance::from_meters(d)).unwrap().as_secs();
        assert!((time(0.0) - 0.0).abs() < 1e-6);
        assert!(
            (time(100.0) - 20.0).abs() < 1e-6,
            "100m took {}",
            time(100.0)
        );
        assert!(
            (time(500.0) - 100.0).abs() < 1e-6,
            "500m took {}",
            time(500.0)
        );
        assert!(
            (time(1000.0) - 200.0).abs() < 1e-6,
            "1000m took {}",
            time(1000.0)
        );
        assert!((attempt.elapsed_time.as_secs() - 200.0).abs() < 1e-6);
        assert!((attempt.distance.meters() - 1000.0).abs() < 1e-6);
    }

    #[test]
    fn pauses_add_time_but_not_distance() {
        // Two moving segments separated by a long stop: coverage must not
        // advance during the stop, and the pause must appear in elapsed time.
        let samples: Vec<AttemptSample> = vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(300.0),
                elapsed: Duration::from_secs(60.0),
            },
            AttemptSample {
                distance: Distance::from_meters(300.0),
                elapsed: Duration::from_secs(120.0),
            }, // stop
            AttemptSample {
                distance: Distance::from_meters(1000.0),
                elapsed: Duration::from_secs(260.0),
            },
        ];
        let attempt = Attempt::from_samples(samples).unwrap();

        assert!((attempt.distance.meters() - 1000.0).abs() < 1e-9);
        assert!((attempt.elapsed_time.as_secs() - 260.0).abs() < 1e-9);
        // 300 m was reached at 60 s (before the pause), not 120 s.
        assert!(
            (attempt
                .time_at(Distance::from_meters(300.0))
                .unwrap()
                .as_secs()
                - 60.0)
                .abs()
                < 1e-9
        );
        // 1000 m: 60 s moving + 60 s pause + (700 m at 5 m/s) 140 s = 260 s.
        assert!(
            (attempt
                .time_at(Distance::from_meters(1000.0))
                .unwrap()
                .as_secs()
                - 260.0)
                .abs()
                < 1e-9
        );
    }

    #[test]
    fn back_tracking_stagnates_coverage() {
        // `from_samples` receives the monotonic coverage curve that
        // `from_track` guarantees: back-tracking adds time but never rolls
        // distance back (500 m stays covered while the runner returns).
        let samples: Vec<AttemptSample> = vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(500.0),
                elapsed: Duration::from_secs(100.0),
            },
            AttemptSample {
                distance: Distance::from_meters(500.0),
                elapsed: Duration::from_secs(190.0),
            },
            AttemptSample {
                distance: Distance::from_meters(600.0),
                elapsed: Duration::from_secs(220.0),
            },
        ];
        let attempt = Attempt::from_samples(samples).unwrap();
        assert!((attempt.distance.meters() - 600.0).abs() < 1e-9);
        // While backtracking, the runner is still at 500 m coverage.
        assert!(
            (attempt
                .distance_at(Duration::from_secs(190.0))
                .unwrap()
                .meters()
                - 500.0)
                .abs()
                < 1e-9
        );
        assert!(
            attempt
                .time_at(Distance::from_meters(600.0))
                .unwrap()
                .as_secs()
                > 0.0
        );
    }

    #[test]
    fn queries_out_of_range_return_none() {
        let samples: Vec<AttemptSample> = vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(1000.0),
                elapsed: Duration::from_secs(300.0),
            },
        ];
        let attempt = Attempt::from_samples(samples).unwrap();
        assert_eq!(
            attempt.time_at(Distance::from_meters(-5.0)),
            Some(Duration::ZERO)
        );
        assert_eq!(attempt.time_at(Distance::from_meters(2000.0)), None);
        assert_eq!(attempt.time_at(Distance::from_meters(f64::NAN)), None);
        assert_eq!(attempt.distance_at(Duration::from_secs(-1.0)), None);
        assert_eq!(
            attempt.distance_at(Duration::from_secs(9999.0)),
            Some(Distance::from_meters(1000.0)),
            "beyond finish the terminal distance is returned"
        );
    }

    #[test]
    fn irregular_sampling_interpolates_linearly() {
        // Sparse, uneven samples: 1 km covered in 10 minutes but with jumps.
        let samples: Vec<AttemptSample> = vec![
            AttemptSample {
                distance: Distance::ZERO,
                elapsed: Duration::ZERO,
            },
            AttemptSample {
                distance: Distance::from_meters(1000.0),
                elapsed: Duration::from_secs(600.0),
            },
        ];
        let attempt = Attempt::from_samples(samples).unwrap();
        // 5 km split? outside route: None.
        let halfway = attempt
            .time_at(Distance::from_meters(500.0))
            .unwrap()
            .as_secs();
        assert!(
            (halfway - 300.0).abs() < 1e-9,
            "linear midpoint should be 300 s, got {halfway}"
        );
    }

    #[test]
    fn moving_axis_excludes_pauses() {
        // 300 m in 60 s, a 60 s stop (no ground), then 700 m in 140 s.
        let route = straight_route();
        let mut points = vec![TrackPoint::new(
            crate::units::Timestamp::from_unix_ms(0),
            route.coordinate_at(Distance::from_meters(0.0)).unwrap(),
        )];
        points.push(TrackPoint::new(
            crate::units::Timestamp::from_unix_ms(60_000),
            route.coordinate_at(Distance::from_meters(300.0)).unwrap(),
        ));
        // Stop: same place 60 s later.
        points.push(TrackPoint::new(
            crate::units::Timestamp::from_unix_ms(120_000),
            route.coordinate_at(Distance::from_meters(300.0)).unwrap(),
        ));
        points.push(TrackPoint::new(
            crate::units::Timestamp::from_unix_ms(260_000),
            route.coordinate_at(Distance::from_meters(1000.0)).unwrap(),
        ));
        let track = Track::new(points).unwrap();

        let clock = Attempt::from_track(&track, &route);
        assert!((clock.elapsed_time.as_secs() - 260.0).abs() < 1e-6);

        let moving = Attempt::from_track_with(
            &track,
            &route,
            AttemptAxis::Moving,
            &MovingAxisConfig::default(),
        );
        // 60 s moving + 0 s stop + 140 s moving = 200 s.
        assert!(
            (moving.elapsed_time.as_secs() - 200.0).abs() < 1e-3,
            "moving axis got {}",
            moving.elapsed_time.as_secs()
        );
        // 300 m was reached at 60 s of moving time (not 120 s wall clock).
        assert!(
            (moving
                .time_at(Distance::from_meters(300.0))
                .unwrap()
                .as_secs()
                - 60.0)
                .abs()
                < 1e-3
        );
    }

    #[test]
    fn from_track_handles_imperfect_start() {
        // A track that begins 100 m into the route reports its first coverage
        // at 100 m, and time_at(50) is below the curve.
        let route = straight_route();
        let mut points = vec![TrackPoint::new(
            crate::units::Timestamp::from_unix_ms(0),
            route.coordinate_at(Distance::from_meters(100.0)).unwrap(),
        )];
        for k in 1..=9 {
            points.push(TrackPoint::new(
                crate::units::Timestamp::from_unix_ms(k * 10_000),
                route
                    .coordinate_at(Distance::from_meters(100.0 + k as f64 * 100.0))
                    .unwrap(),
            ));
        }
        let track = Track::new(points).unwrap();
        let attempt = Attempt::from_track(&track, &route);
        assert!((attempt.distance.meters() - 1000.0).abs() < 1e-6);
        assert!(
            attempt.time_at(Distance::from_meters(50.0)).is_none(),
            "50 m lies before the recorded start"
        );
    }
}
