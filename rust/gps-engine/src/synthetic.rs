// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Synthetic GPS generation (test utility).
//!
//! Given a clean route, this module produces test tracks with controlled,
//! **deterministic** imperfections — the seeds are fixed, the random number
//! generator is a well-defined arithmetic sequence, and the same seed always
//! produces the same track. This lets a whole test corpus be generated
//! without any real recorded data.
//!
//! Presets cover the track shapes the specifications care about:
//!
//! - `Clean`   — sample the route exactly, no defects.
//! - `Noisy`   — position noise around the route.
//! - `Sparse`  — a relaxed sampling interval.
//! - `Dense`   — a tight sampling interval.
//! - `Gapped`  — periodic dropped samples (missing GPS points).
//! - `Stopped` — stationary points that advance time without moving.
//! - `Outliers` — occasional wildly-off positions.
//!
//! Distance and duration sampling plus small random noise.
//!
//! Reverse and detour variants are explicit track transforms:
//! [`crate::synthetic::reverse`] and [`crate::synthetic::add_detour`].

use crate::geo::{Bearing, Coordinate, bearing, destination, distance, interpolate};
use crate::track::{Track, TrackPoint};
use crate::units::{Distance, Duration, Speed, Timestamp};

/// The uncorrupted state of the runner at one nominal sample time.
///
/// `observed` fixtures deliberately throw this information away: once noise,
/// jumps, stops and gaps are applied, only the damaged fix remains. The
/// quality benchmark needs the clean trajectory as well, so it can score
/// distance, position, pace, false movement and recovery against ground truth.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GroundTruthSample {
    /// Nominal observation time. It exists even when the observed fix was
    /// dropped by a configured gap.
    pub timestamp: Timestamp,
    /// Where the runner actually was at `timestamp`, on the route corridor.
    pub coordinate: Coordinate,
    /// Distance already covered along the oriented route, in meters.
    pub route_distance: f64,
    /// True ground speed at this instant. Zero while stationary.
    pub speed: Speed,
    /// Whether the runner was genuinely stationary.
    pub stationary: bool,
    /// Whether no observed fix was emitted at this nominal time.
    pub outage: bool,
    /// True altitude at this nominal time, when the config models elevation.
    pub altitude: Option<f64>,
}

/// One generated observation before it is converted into a [`TrackPoint`].
type GeneratedStep = (Timestamp, Coordinate, Option<f64>);

/// A generated observation together with the truth it was derived from.
#[derive(Debug, Clone, PartialEq)]
pub struct SyntheticResult {
    /// The noisy observed track, identical to [`generate`]'s output.
    pub observed: Track,
    /// One truth row per nominal sample, including rows for dropped fixes.
    pub truth: Vec<GroundTruthSample>,
}

impl SyntheticResult {
    /// Looks up ground truth by exact timestamp.
    pub fn truth_at(&self, timestamp: Timestamp) -> Option<GroundTruthSample> {
        self.truth
            .iter()
            .find(|sample| sample.timestamp == timestamp)
            .copied()
    }
}

/// A deterministic 64-bit PRNG (SplitMix64).
///
/// Not cryptographically secure — explicitly a test utility.
pub struct Rng {
    state: u64,
}

impl Rng {
    /// Seeds the generator. The same seed always yields the same sequence.
    pub fn new(seed: u64) -> Self {
        Rng {
            state: seed.wrapping_add(0x9E37_79B9_7F4A_7C15),
        }
    }

    /// The next pseudo-random 64-bit value.
    pub fn next_u64(&mut self) -> u64 {
        let mut z = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        self.state = z;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A uniform sample in `[0, 1)`.
    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 * (1.0 / (1u64 << 53) as f64)
    }

    /// A uniform sample in `[lo, hi)`.
    pub fn range(&mut self, lo: f64, hi: f64) -> f64 {
        lo + (hi - lo) * self.unit()
    }

    /// `true` with probability `p`.
    pub fn chance(&mut self, p: f64) -> bool {
        p > 0.0 && self.unit() < p
    }
}

/// Control parameters for [`generate`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SyntheticConfig {
    /// Seconds between nominal samples along the route.
    pub sampling_interval: Duration,
    /// Nominal ground speed used to convert time into distance.
    pub speed: Speed,
    /// Position jitter applied to every sample, in meters.
    pub position_noise: Distance,
    /// Probability that a sample is dropped (a missing GPS point).
    pub gap_probability: f64,
    /// Probability that a sample jumps far away from the route.
    pub outlier_probability: f64,
    /// Probability that a sample is stationary (time passes, no movement).
    pub stop_probability: f64,
    /// Positional drift applied to stationary samples, in meters.
    ///
    /// `ZERO` (the default) keeps the legacy behaviour where a stationary
    /// sample repeats the previous observed coordinate exactly.
    pub stationary_drift: Distance,
    /// How far outliers are displaced, in meters.
    pub outlier_distance: Distance,
    /// Peak-to-trough altitude of a deterministic cosine hill profile, in
    /// meters. `ZERO` leaves generated fixes without altitude, preserving the
    /// legacy fixtures exactly.
    pub altitude_amplitude_m: f64,
    /// Distance between hill crests in the deterministic altitude profile.
    pub altitude_wavelength_m: f64,
    /// Uniform altitude jitter in meters, applied only when a profile exists.
    pub altitude_noise_m: f64,
    /// Traverse the route from finish to start instead.
    pub reverse: bool,
    /// Seed for the deterministic generator.
    pub seed: u64,
}

impl Default for SyntheticConfig {
    fn default() -> Self {
        SyntheticConfig {
            sampling_interval: Duration::from_secs(2.0),
            speed: Speed::from_kmh(9.0),
            position_noise: Distance::from_meters(5.0),
            gap_probability: 0.02,
            outlier_probability: 0.004,
            stop_probability: 0.01,
            stationary_drift: Distance::ZERO,
            outlier_distance: Distance::from_meters(500.0),
            altitude_amplitude_m: 0.0,
            altitude_wavelength_m: 1_000.0,
            altitude_noise_m: 0.0,
            reverse: false,
            seed: 42,
        }
    }
}

impl SyntheticConfig {
    /// A perfect recording of the route.
    pub fn clean(seed: u64) -> Self {
        SyntheticConfig {
            position_noise: Distance::ZERO,
            gap_probability: 0.0,
            outlier_probability: 0.0,
            stop_probability: 0.0,
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Jittered recording; `noise` is the position error in meters.
    pub fn noisy(seed: u64, noise: f64) -> Self {
        SyntheticConfig {
            position_noise: Distance::from_meters(noise),
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Sparse: long gaps between samples.
    pub fn sparse(seed: u64) -> Self {
        SyntheticConfig {
            sampling_interval: Duration::from_secs(45.0),
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Dense: frequent samples.
    pub fn dense(seed: u64) -> Self {
        SyntheticConfig {
            sampling_interval: Duration::from_millis(500.0),
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Gapped: a quarter of samples are missing.
    pub fn gapped(seed: u64) -> Self {
        SyntheticConfig {
            position_noise: Distance::ZERO,
            gap_probability: 0.25,
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Stopped: many stationary points.
    pub fn stopped(seed: u64) -> Self {
        SyntheticConfig {
            position_noise: Distance::ZERO,
            stop_probability: 0.3,
            seed,
            ..SyntheticConfig::default()
        }
    }

    /// Outliers: frequent large excursions.
    pub fn outliers(seed: u64) -> Self {
        SyntheticConfig {
            position_noise: Distance::ZERO,
            outlier_probability: 0.15,
            seed,
            ..SyntheticConfig::default()
        }
    }
}

/// Generates a synthetic track from a route polyline, using `config`.
///
/// The result is a valid [`Track`] by construction: timestamps strictly
/// increase and coordinates are clamped to valid ranges. Sample positions
/// (outliers excluded) stay within `position_noise` of the route.
pub fn generate(route: &[Coordinate], config: &SyntheticConfig) -> Track {
    generate_with_truth(route, config).observed
}

/// Generates a synthetic track plus the clean trajectory it was derived from.
///
/// The observed track is exactly the same as [`generate`]. The truth rows are
/// additional diagnostics: one row per nominal sample time, including rows for
/// fixes suppressed by `gap_probability`.
pub fn generate_with_truth(route: &[Coordinate], config: &SyntheticConfig) -> SyntheticResult {
    let mut rng = Rng::new(config.seed);
    let mut walk = route.to_vec();
    if config.reverse {
        walk.reverse();
    }
    let (steps, truth) = forward(&walk, config, &mut rng);

    let points = steps
        .into_iter()
        .map(|(t, c, altitude)| {
            let mut point = TrackPoint::new(t, c);
            if let Some(altitude) = altitude {
                point = point
                    .with_altitude(altitude)
                    .expect("synthetic generator produced an invalid altitude");
            }
            point
        })
        .collect::<Vec<_>>();

    SyntheticResult {
        observed: Track::new(points).expect("synthetic generator produced an invalid track"),
        truth,
    }
}

/// Deterministic altitude at a distance along the route, when configured.
fn altitude_at(distance_m: f64, config: &SyntheticConfig) -> Option<f64> {
    if !config.altitude_amplitude_m.is_finite() || config.altitude_amplitude_m <= 0.0 {
        return None;
    }
    let wavelength = config.altitude_wavelength_m.max(1.0);
    let phase = std::f64::consts::TAU * distance_m / wavelength;
    Some(config.altitude_amplitude_m * 0.5 * (1.0 - phase.cos()))
}

/// Walks a route (already oriented) at the configured speed, sampling with
/// the configured defects. Returns observed `(timestamp, coordinate, altitude)`
/// triples and the matching ground-truth rows.
fn forward(
    route: &[Coordinate],
    config: &SyntheticConfig,
    rng: &mut Rng,
) -> (Vec<GeneratedStep>, Vec<GroundTruthSample>) {
    debug_assert!(
        route.len() >= 2,
        "synthetic generator needs a route polyline"
    );

    // Cumulative geodesic length along the route.
    let mut cumulative = Vec::with_capacity(route.len());
    cumulative.push(0.0);
    for pair in route.windows(2) {
        cumulative
            .push(cumulative.last().expect("non-empty") + distance(pair[0], pair[1]).meters());
    }
    let total = *cumulative.last().expect("non-empty");

    // Distance travelled per nominal sample.
    let step_meters = config.speed.mps() * config.sampling_interval.as_secs();

    if total < 1e-9 {
        // Degenerate (all-coincident) route: a short stationary "track".
        let end_ms = (config.sampling_interval.as_secs() * 1000.0).round() as i64;
        let start = Timestamp::from_unix_ms(0);
        let end = Timestamp::from_unix_ms(end_ms);
        let altitude = altitude_at(0.0, config);
        return (
            vec![(start, route[0], altitude), (end, route[0], altitude)],
            vec![
                GroundTruthSample {
                    timestamp: start,
                    coordinate: route[0],
                    route_distance: 0.0,
                    speed: config.speed,
                    stationary: false,
                    outage: false,
                    altitude,
                },
                GroundTruthSample {
                    timestamp: end,
                    coordinate: route[0],
                    route_distance: 0.0,
                    speed: Speed::ZERO,
                    stationary: true,
                    outage: false,
                    altitude,
                },
            ],
        );
    }

    let mut points: Vec<GeneratedStep> = Vec::new();
    let mut truth: Vec<GroundTruthSample> = Vec::new();
    let mut sample_no = 0i64;
    let mut prev_coord = route[0];
    let mut prev_truth = GroundTruthSample {
        timestamp: Timestamp::from_unix_ms(0),
        coordinate: route[0],
        route_distance: 0.0,
        speed: config.speed,
        stationary: false,
        outage: false,
        altitude: altitude_at(0.0, config),
    };
    // A gap after nominal sample `k` suppresses `k + 1` and `k + 2`, matching
    // the legacy `sample_no += 3` behaviour without skipping their truth rows.
    let mut skipped = 0u8;

    loop {
        let target = sample_no as f64 * step_meters;
        if target > total + 1e-9 {
            break;
        }
        let t_ms = (sample_no as f64 * config.sampling_interval.as_secs() * 1000.0).round() as i64;
        let timestamp = Timestamp::from_unix_ms(t_ms);

        let base = if target >= total - 1e-9 {
            *route.last().expect("non-empty")
        } else {
            coord_at(route, &cumulative, target)
        };

        if skipped > 0 {
            skipped -= 1;
            truth.push(GroundTruthSample {
                timestamp,
                coordinate: base,
                route_distance: target.min(total),
                speed: config.speed,
                stationary: false,
                outage: true,
                altitude: altitude_at(target.min(total), config),
            });
            prev_truth = *truth.last().expect("just pushed");
            sample_no += 1;
            continue;
        }

        let stopped = rng.chance(config.stop_probability);
        let outlier = !stopped && rng.chance(config.outlier_probability);
        let gap_after = rng.chance(config.gap_probability);

        let coordinate = if outlier {
            offset(
                base,
                config.outlier_distance.meters(),
                rng.range(0.0, 360.0),
            )
        } else if stopped {
            if config.stationary_drift.meters() > 0.0 {
                offset(
                    prev_coord,
                    config.stationary_drift.meters(),
                    rng.range(0.0, 360.0),
                )
            } else {
                prev_coord
            }
        } else if config.position_noise.meters() > 0.0 {
            offset(base, config.position_noise.meters(), rng.range(0.0, 360.0))
        } else {
            base
        };

        let true_altitude = altitude_at(target.min(total), config);
        let observed_altitude = true_altitude.map(|altitude| {
            if config.altitude_noise_m > 0.0 {
                altitude + rng.range(-config.altitude_noise_m, config.altitude_noise_m)
            } else {
                altitude
            }
        });
        points.push((timestamp, coordinate, observed_altitude));
        prev_coord = coordinate;

        let truth_sample = if stopped {
            GroundTruthSample {
                timestamp,
                coordinate: prev_truth.coordinate,
                route_distance: prev_truth.route_distance,
                speed: Speed::ZERO,
                stationary: true,
                outage: false,
                altitude: prev_truth.altitude,
            }
        } else {
            GroundTruthSample {
                timestamp,
                coordinate: base,
                route_distance: target.min(total),
                speed: config.speed,
                stationary: false,
                outage: false,
                altitude: true_altitude,
            }
        };
        truth.push(truth_sample);
        prev_truth = truth_sample;

        if gap_after {
            skipped = 2;
        }
        sample_no += 1;
    }

    // Always end exactly at the route finish unless the final sample already
    // covered it.
    let last_coord = points.last().map(|p| p.1).unwrap_or(route[0]);
    if distance(last_coord, *route.last().expect("non-empty")).meters() > 1e-9 {
        let end_t_ms =
            (sample_no as f64 * config.sampling_interval.as_secs() * 1000.0).round() as i64;
        let timestamp = Timestamp::from_unix_ms(end_t_ms);
        let finish_altitude = altitude_at(total, config);
        let observed_altitude = finish_altitude.map(|altitude| {
            if config.altitude_noise_m > 0.0 {
                altitude + rng.range(-config.altitude_noise_m, config.altitude_noise_m)
            } else {
                altitude
            }
        });
        points.push((
            timestamp,
            *route.last().expect("non-empty"),
            observed_altitude,
        ));
        truth.push(GroundTruthSample {
            timestamp,
            coordinate: *route.last().expect("non-empty"),
            route_distance: total,
            speed: config.speed,
            stationary: false,
            outage: false,
            altitude: finish_altitude,
        });
    }

    debug_assert!(
        points.len() >= 2 && points[points.len() - 1].0 >= points[points.len() - 2].0,
        "synthetic timestamps must be ordered"
    );
    (points, truth)
}

/// Coordinate at distance `target` along a polyline via `cumulative` offsets.
fn coord_at(route: &[Coordinate], cumulative: &[f64], target: f64) -> Coordinate {
    let n = route.len();
    debug_assert!(n >= 2 && cumulative.len() == n);
    let mut seg = 0usize;
    while seg + 1 < n && cumulative[seg + 1] < target {
        seg += 1;
    }
    let seg_len = cumulative[seg + 1] - cumulative[seg];
    let t = if seg_len > 1e-12 {
        ((target - cumulative[seg]) / seg_len).clamp(0.0, 1.0)
    } else {
        0.0
    };
    interpolate(route[seg], route[seg + 1], t)
}

/// Displaces `base` by `dist` meters in direction `heading` (degrees).
fn offset(base: Coordinate, dist: f64, heading: f64) -> Coordinate {
    match Bearing::from_degrees(heading) {
        Ok(bearing) => destination(base, bearing, Distance::from_meters(dist)),
        Err(_) => base,
    }
}

/// Reverses a track: the route plays finish → start while keeping the same
/// total duration and monotonic ascending timestamps. See
/// [`Track::reversed`].
pub fn reverse(track: &Track) -> Track {
    track.reversed()
}

/// Applies a lateral excursion (a detour) to the middle half of the track,
/// deviating by `distance` meters perpendicular to the direction of travel.
///
/// Points near the ends stay on the route; the excursion ramps up and back
/// down smoothly through the middle.
pub fn add_detour(track: &Track, distance: Distance) -> Track {
    let points = track.points();
    let n = points.len();
    if n < 3 || distance.meters() <= 0.0 {
        return track.clone();
    }

    let mut out: Vec<TrackPoint> = Vec::with_capacity(n);
    for (i, p) in points.iter().enumerate() {
        let fraction = i as f64 / (n - 1) as f64;
        // Ramp 0 → 1 → 0 across the middle half of the track.
        let ramp = if fraction < 0.25 {
            0.0
        } else if fraction < 0.5 {
            (fraction - 0.25) * 4.0
        } else if fraction < 0.75 {
            (0.75 - fraction) * 4.0
        } else {
            0.0
        };

        if ramp <= 0.0 {
            out.push(*p);
            continue;
        }

        // Local direction of travel, estimated from the surrounding points.
        let prev = points[i.max(1) - 1].coordinate();
        let next = points[(i + 1).min(n - 1)].coordinate();
        let course = bearing(prev, next).unwrap_or(Bearing::NORTH);
        let perpendicular =
            Bearing::from_degrees(course.as_degrees() + 90.0).unwrap_or(Bearing::NORTH);

        let displaced = destination(
            p.coordinate(),
            perpendicular,
            Distance::from_meters(distance.meters() * ramp),
        );
        out.push(TrackPoint::new(p.timestamp(), displaced));
    }

    Track::new(out).expect("detour track stays valid")
}
