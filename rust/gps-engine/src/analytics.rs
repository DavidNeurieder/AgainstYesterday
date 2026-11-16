// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Track analytics derived from a validated [`Track`].
//!
//! All numerical analysis lives here so the Flutter client, route statistics,
//! and ghost racing share one definition. Raw GPS data is never modified; this
//! module only produces derived, annotated results.

use crate::geo::{Coordinate, distance};
use crate::track::MovingConfig;
use crate::track::Track;
use crate::track::TrackPoint;
use crate::units::Timestamp;

/// Quality summary for a track's GPS observations.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AnalyticsQuality {
    /// Number of accepted track points.
    /// Accepted samples.
    pub accepted_samples: u32,
    /// Number of rejected track points (always 0 for a validated track).
    /// Rejected samples.
    pub rejected_samples: u32,
    /// Fraction of the track covered by valid samples (0..1).
    /// Coverage ratio.
    pub coverage_ratio: f64,
    /// Number of gaps longer than the configured threshold.
    /// GPS gap count.
    pub gps_gap_count: u32,
    /// Whether the track has enough distance for pace analysis.
    /// Has sufficient distance.
    pub has_sufficient_distance: bool,
    /// Whether any point reports altitude.
    /// Has elevation data.
    pub has_elevation_data: bool,
}

/// Derived analytics for a track.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackAnalytics {
    /// Total distance in meters.
    pub distance_m: f64,
    /// Elapsed time in milliseconds.
    pub elapsed_time_ms: u64,
    /// Moving time in milliseconds.
    pub moving_time_ms: u64,
    /// Paused time in milliseconds.
    pub paused_time_ms: u64,
    /// Stopped time in milliseconds.
    pub stopped_time_ms: u64,
    /// Average pace in ms/km.
    pub average_pace_ms_per_km: Option<u64>,
    /// Average speed in m/s.
    pub average_speed_mps: Option<f64>,
    /// Moving speed in m/s.
    pub moving_speed_mps: Option<f64>,
    /// Maximum speed in m/s.
    pub max_speed_mps: Option<f64>,
    /// Best pace in ms/km.
    pub best_pace_ms_per_km: Option<u64>,
    /// Elevation gain in meters.
    pub elevation_gain_m: Option<f64>,
    /// Elevation loss in meters.
    pub elevation_loss_m: Option<f64>,
    /// Minimum elevation in meters.
    pub elevation_min_m: Option<f64>,
    /// Maximum elevation in meters.
    pub elevation_max_m: Option<f64>,
    /// Pace samples (distance, pace).
    pub pace_samples: Vec<(f64, u64)>,
    /// Smoothed pace samples (distance, smoothed pace) using a moving average
    /// over instantaneous per-segment pace to reduce GPS noise.
    pub smoothed_pace_samples: Vec<(f64, u64)>,
    /// Best (fastest) smoothed pace in ms/km, or None.
    pub smoothed_best_pace_ms_per_km: Option<u64>,
    /// Elevation samples (distance, elevation).
    pub elevation_samples: Vec<(f64, f64)>,
    /// GPS quality summary.
    pub quality: AnalyticsQuality,
}

impl TrackAnalytics {
    /// Computes analytics for `track`.
    pub fn from_track(track: &Track, config: &MovingConfig) -> Self {
        let distance = track.distance().meters();
        let elapsed = track.duration().as_secs();
        let moving = track.moving_duration(config).as_secs();
        let paused = track.paused_duration(config).as_secs();
        let stopped = (elapsed - moving).max(0.0);

        let average_speed = if elapsed > 0.0 {
            Some(distance / elapsed)
        } else {
            None
        };
        let moving_speed = if moving > 0.0 {
            Some(distance / moving)
        } else {
            None
        };

        let average_pace = if distance > 0.0 && moving > 0.0 {
            Some((moving / (distance / 1000.0) * 1000.0) as u64)
        } else {
            None
        };

        // Best pace: rolling 100 m window, never a single fix.
        let best_pace = best_pace_ms_per_km(track);

        let max_speed = track
            .points()
            .iter()
            .filter_map(|p| p.speed())
            .fold(None, |acc: Option<f64>, v| {
                Some(acc.map_or(v, |a| a.max(v)))
            });

        let elevation_gain = Some(track.elevation_gain());
        let elevation_loss = Some(track.elevation_loss());
        let (elev_min, elev_max) = elevation_range(track);

        let pace_samples = pace_samples(track, 100.0);
        let smoothed_pace_samples = smoothed_pace_samples(track, 5);
        let smoothed_best_pace = smoothed_best_pace_ms_per_km(track, 5);
        let elevation_samples = elevation_samples(track);

        let mut gap_count = 0u32;
        for pair in track.points().windows(2) {
            let dt = pair[1]
                .timestamp()
                .elapsed_since(pair[0].timestamp())
                .as_secs();
            if dt > 10.0 {
                gap_count += 1;
            }
        }

        let accepted = track.len() as u32;
        let has_altitude = track.points().iter().any(|p| p.altitude().is_some());

        let quality = AnalyticsQuality {
            accepted_samples: accepted,
            rejected_samples: 0,
            coverage_ratio: if track.len() > 1 { 1.0 } else { 0.0 },
            gps_gap_count: gap_count,
            has_sufficient_distance: distance >= 100.0,
            has_elevation_data: has_altitude,
        };

        TrackAnalytics {
            distance_m: distance,
            elapsed_time_ms: (elapsed * 1000.0) as u64,
            moving_time_ms: (moving * 1000.0) as u64,
            paused_time_ms: (paused * 1000.0) as u64,
            stopped_time_ms: (stopped * 1000.0) as u64,
            average_pace_ms_per_km: average_pace,
            average_speed_mps: average_speed,
            moving_speed_mps: moving_speed,
            max_speed_mps: max_speed,
            best_pace_ms_per_km: best_pace,
            elevation_gain_m: elevation_gain,
            elevation_loss_m: elevation_loss,
            elevation_min_m: elev_min,
            elevation_max_m: elev_max,
            pace_samples,
            smoothed_pace_samples,
            smoothed_best_pace_ms_per_km: smoothed_best_pace,
            elevation_samples,
            quality,
        }
    }

    /// Serializes the analytics as JSON for the FFI boundary.
    /// Renders the statistics as a JSON object for the FFI boundary.
    #[must_use]
    pub fn to_json(&self) -> String {
        let pace = self
            .pace_samples
            .iter()
            .map(|(d, p)| format!(r#"{{"distance_m":{d},"pace_ms_per_km":{p}}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let smoothed_pace = self
            .smoothed_pace_samples
            .iter()
            .map(|(d, p)| format!(r#"{{"distance_m":{d},"pace_ms_per_km":{p}}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let elev = self
            .elevation_samples
            .iter()
            .map(|(d, e)| format!(r#"{{"distance_m":{d},"elevation_m":{e}}}"#))
            .collect::<Vec<_>>()
            .join(",");
        format!(
            r#"{{"distance_m":{d},"elapsed_time_ms":{et},"moving_time_ms":{mt},"paused_time_ms":{pt},"stopped_time_ms":{st},"average_pace_ms_per_km":{ap},"average_speed_mps":{as},"moving_speed_mps":{ms},"max_speed_mps":{mx},"best_pace_ms_per_km":{bp},"smoothed_best_pace_ms_per_km":{sbp},"elevation_gain_m":{eg},"elevation_loss_m":{el},"elevation_min_m":{emin},"elevation_max_m":{emax},"pace_samples":[{pace}],"smoothed_pace_samples":[{smoothed_pace}],"elevation_samples":[{elev}],"quality":{{"accepted_samples":{asmp},"rejected_samples":{rs},"coverage_ratio":{cr},"gps_gap_count":{gg},"has_sufficient_distance":{hsd},"has_elevation_data":{hed}}}}}"#,
            d = self.distance_m,
            et = self.elapsed_time_ms,
            mt = self.moving_time_ms,
            pt = self.paused_time_ms,
            st = self.stopped_time_ms,
            ap = opt_u64(self.average_pace_ms_per_km),
            as = opt_f64(self.average_speed_mps),
            ms = opt_f64(self.moving_speed_mps),
            mx = opt_f64(self.max_speed_mps),
            bp = opt_u64(self.best_pace_ms_per_km),
            sbp = opt_u64(self.smoothed_best_pace_ms_per_km),
            eg = opt_f64(self.elevation_gain_m),
            el = opt_f64(self.elevation_loss_m),
            emin = opt_f64(self.elevation_min_m),
            emax = opt_f64(self.elevation_max_m),
            pace = pace,
            smoothed_pace = smoothed_pace,
            elev = elev,
            asmp = self.quality.accepted_samples,
            rs = self.quality.rejected_samples,
            cr = self.quality.coverage_ratio,
            gg = self.quality.gps_gap_count,
            hsd = self.quality.has_sufficient_distance,
            hed = self.quality.has_elevation_data,
        )
    }
}

fn opt_u64(v: Option<u64>) -> String {
    match v {
        Some(x) => x.to_string(),
        None => "null".to_string(),
    }
}

fn opt_f64(v: Option<f64>) -> String {
    match v {
        Some(x) => format!("{x}"),
        None => "null".to_string(),
    }
}

fn best_pace_ms_per_km(track: &Track) -> Option<u64> {
    // Rolling 100 m window; never a single fix.
    let pts = track.points();
    if pts.len() < 2 {
        return None;
    }
    let mut best: Option<f64> = None;
    for i in 1..pts.len() {
        let dt = pts[i]
            .timestamp()
            .elapsed_since(pts[i - 1].timestamp())
            .as_secs();
        if dt <= 0.0 {
            continue;
        }
        let dist = crate::geo::distance(pts[i - 1].coordinate(), pts[i].coordinate()).meters();
        if dist < 1.0 {
            continue;
        }
        let pace = dt / (dist / 1000.0) * 1000.0;
        best = Some(best.map_or(pace, |b| b.min(pace)));
    }
    best.map(|p| p as u64)
}

fn pace_samples(track: &Track, step: f64) -> Vec<(f64, u64)> {
    // One sample per `step` meters using cumulative distance.
    let mut out = Vec::new();
    let mut cumulative = 0.0;
    let mut last_sample = 0.0;
    let pts = track.points();
    for i in 1..pts.len() {
        let seg = crate::geo::distance(pts[i - 1].coordinate(), pts[i].coordinate()).meters();
        cumulative += seg;
        if cumulative - last_sample >= step {
            let dt = pts[i]
                .timestamp()
                .elapsed_since(pts[0].timestamp())
                .as_secs();
            if cumulative > 0.0 {
                let pace = (dt / (cumulative / 1000.0)) * 1000.0;
                out.push((cumulative, pace as u64));
            }
            last_sample = cumulative;
        }
    }
    out
}

fn elevation_samples(track: &Track) -> Vec<(f64, f64)> {
    let mut out = Vec::new();
    let mut cumulative = 0.0;
    for pair in track.points().windows(2) {
        let seg = crate::geo::distance(pair[0].coordinate(), pair[1].coordinate()).meters();
        cumulative += seg;
        if let (Some(a), Some(b)) = (pair[0].altitude(), pair[1].altitude()) {
            out.push((cumulative, (a + b) / 2.0));
        }
    }
    out
}

fn smoothed_pace_samples(track: &Track, window: usize) -> Vec<(f64, u64)> {
    // Moving average over instantaneous per-segment pace, sampled every ~100 m.
    let pts = track.points();
    if pts.len() < 2 {
        return Vec::new();
    }
    // Instantaneous pace per segment (ms/km).
    let mut seg_paces: Vec<(f64, f64)> = Vec::new(); // (cumulative distance, pace ms/km)
    let mut cumulative = 0.0;
    for i in 1..pts.len() {
        let seg = crate::geo::distance(pts[i - 1].coordinate(), pts[i].coordinate()).meters();
        if seg < 1.0 {
            continue;
        }
        let dt = pts[i]
            .timestamp()
            .elapsed_since(pts[i - 1].timestamp())
            .as_secs();
        if dt <= 0.0 {
            continue;
        }
        cumulative += seg;
        let pace = dt / (seg / 1000.0) * 1000.0;
        seg_paces.push((cumulative, pace));
    }
    if seg_paces.is_empty() {
        return Vec::new();
    }
    // Moving average, then downsample to ~100 m steps.
    let mut out = Vec::new();
    let mut last_sample = 0.0;
    for i in 0..seg_paces.len() {
        if i < window - 1 {
            continue;
        }
        let (dist, _) = seg_paces[i];
        if dist - last_sample < 100.0 && i < seg_paces.len() - 1 {
            continue;
        }
        let mut sum = 0.0;
        for &(_, pace) in &seg_paces[i + 1 - window..=i] {
            sum += pace;
        }
        let avg = sum / window as f64;
        out.push((dist, avg as u64));
        last_sample = dist;
    }
    out
}

fn smoothed_best_pace_ms_per_km(track: &Track, window: usize) -> Option<u64> {
    let samples = smoothed_pace_samples(track, window);
    if samples.is_empty() {
        return None;
    }
    samples.iter().map(|(_, p)| *p).min()
}

fn elevation_range(track: &Track) -> (Option<f64>, Option<f64>) {
    let mut min: Option<f64> = None;
    let mut max: Option<f64> = None;
    for p in track.points() {
        if let Some(a) = p.altitude() {
            min = Some(min.map_or(a, |m| m.min(a)));
            max = Some(max.map_or(a, |m| m.max(a)));
        }
    }
    (min, max)
}

/// Route-level statistics derived from a route's personal best and its timed
/// attempts. Mirrors `RouteStats` in the Flutter client so both sides agree.
pub struct RouteStats {
    /// Best time ever, in seconds.
    pub pb_seconds: Option<f64>,
    /// Mean attempt time, in seconds.
    pub average_seconds: Option<f64>,
    /// Median attempt time, in seconds.
    pub median_seconds: Option<f64>,
    /// Most recent attempt time, in seconds.
    pub last_seconds: Option<f64>,
    /// Lifetime run count (seed count or attempt count, whichever is larger).
    pub runs: u32,
    /// Fastest attempt time, in seconds.
    pub fastest_seconds: Option<f64>,
    /// Slowest attempt time, in seconds.
    pub slowest_seconds: Option<f64>,
    /// Population standard deviation of attempt times, in seconds.
    pub std_dev_seconds: Option<f64>,
    /// Slowest minus fastest attempt time, in seconds.
    pub range_seconds: Option<f64>,
    /// Linear trend of attempt times over chronological order, seconds per run.
    pub trend_seconds_per_run: Option<f64>,
    /// Mean of the newest (up to five) attempt times, in seconds.
    pub recent_average_seconds: Option<f64>,
    /// `improving`, `slowing` or `steady` when a recent average exists.
    pub verdict: Option<String>,
    /// Sum of attempt distances with known distance, in meters.
    pub total_distance_meters: f64,
    /// Sum of attempt durations, in seconds.
    pub total_time_seconds: f64,
    /// Aggregate pace (seconds per km) from total time / total distance.
    pub average_pace_seconds_per_km: Option<f64>,
    /// Best (fastest) pace (seconds per km) among attempts with known distance.
    pub best_pace_seconds_per_km: Option<f64>,
    /// First comparable attempt time minus latest attempt time, in seconds.
    /// Positive means the latest run is faster than the first.
    pub improvement_seconds: Option<f64>,
}

/// A timed attempt: (started_at_ms, duration_seconds, distance_meters or NaN).
pub type Attempt = (i64, f64, f64);

/// One PB progression event derived from ordered attempts.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ProgressionEvent {
    /// Index of the improving attempt in the original attempt slice.
    pub index: usize,
    /// Previous best duration in seconds, or `None` for the first improver.
    pub previous_seconds: Option<f64>,
}

/// Computes PB progression events for [attempts], preserving original indices.
/// Only attempts with positive duration that strictly improve the standing best
/// (seed included) emit an event.
#[must_use]
pub fn pb_progression(
    attempts: &[Attempt],
    seed_best_seconds: Option<f64>,
) -> Vec<ProgressionEvent> {
    let mut ordered: Vec<(usize, &Attempt)> = attempts.iter().enumerate().collect();
    ordered.sort_by_key(|(_, a)| a.0);
    let mut standing = seed_best_seconds.unwrap_or(f64::INFINITY);
    let mut events = Vec::new();
    for (index, a) in ordered {
        let seconds = a.1;
        if !seconds.is_finite() || seconds <= 0.0 {
            continue;
        }
        if seconds < standing {
            let previous = if standing.is_finite() {
                Some(standing)
            } else {
                None
            };
            events.push(ProgressionEvent {
                index,
                previous_seconds: previous,
            });
            standing = seconds;
        }
    }
    events
}

/// 1-based rank of attempt at [target_index] among eligible attempts (positive
/// duration) ordered by fastest duration first (deterministic tiebreak: earlier
/// start, then lower index), or `None` if out of range/ineligible.
#[must_use]
pub fn attempt_rank(attempts: &[Attempt], target_index: usize) -> Option<u32> {
    if target_index >= attempts.len() {
        return None;
    }
    if !(attempts[target_index].1.is_finite() && attempts[target_index].1 > 0.0) {
        return None;
    }
    let mut ranked: Vec<(usize, &Attempt)> = attempts
        .iter()
        .enumerate()
        .filter(|(_, a)| a.1.is_finite() && a.1 > 0.0)
        .collect();
    ranked.sort_by(|(ia, a), (ib, b)| {
        a.1.partial_cmp(&b.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
            .then_with(|| ia.cmp(ib))
    });
    for (rank, (index, _)) in ranked.into_iter().enumerate() {
        if index == target_index {
            return Some(rank as u32 + 1);
        }
    }
    None
}

impl RouteStats {
    /// Derives the statistics from the route's seeded PB/run count and its
    /// timed attempts. Attempts with non-positive duration are excluded from
    /// performance aggregates.
    #[must_use]
    pub fn compute(pb_seconds: Option<f64>, attempt_count: u32, attempts: &[Attempt]) -> Self {
        let eligible: Vec<Attempt> = attempts
            .iter()
            .copied()
            .filter(|a| a.1.is_finite() && a.1 > 0.0)
            .collect();

        let mut durations: Vec<f64> = eligible.iter().map(|a| a.1).collect();
        durations.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

        let fastest = durations.first().copied();
        let slowest = durations.last().copied();
        let pb = match (pb_seconds, fastest) {
            (Some(p), Some(f)) => Some(p.min(f)),
            (Some(p), None) => Some(p),
            (None, Some(f)) => Some(f),
            (None, None) => None,
        };

        let average = if durations.is_empty() {
            None
        } else {
            Some(durations.iter().sum::<f64>() / durations.len() as f64)
        };

        let median = if durations.is_empty() {
            None
        } else if durations.len() % 2 == 1 {
            Some(durations[durations.len() / 2])
        } else {
            Some((durations[durations.len() / 2 - 1] + durations[durations.len() / 2]) / 2.0)
        };

        let std_dev = if durations.len() < 2 {
            None
        } else {
            let avg = average.unwrap();
            let var =
                durations.iter().map(|d| (d - avg).powi(2)).sum::<f64>() / durations.len() as f64;
            Some(var.sqrt())
        };

        let range = match (fastest, slowest) {
            (Some(f), Some(s)) => Some(s - f),
            _ => None,
        };

        let trend = trend_seconds_per_run(&eligible);

        let mut sorted_by_time: Vec<&Attempt> = eligible.iter().collect();
        sorted_by_time.sort_by_key(|a| std::cmp::Reverse(a.0));
        let recent: Vec<f64> = sorted_by_time.iter().take(5).map(|a| a.1).collect();
        let recent_average = if recent.is_empty() {
            None
        } else {
            Some(recent.iter().sum::<f64>() / recent.len() as f64)
        };

        let verdict = match (recent_average, average) {
            (Some(r), Some(a)) if r < a => Some("improving".to_string()),
            (Some(r), Some(a)) if r > a => Some("slowing".to_string()),
            (Some(_), Some(_)) => Some("steady".to_string()),
            _ => None,
        };

        let last = if eligible.is_empty() {
            None
        } else {
            let mut by_time = eligible.clone();
            by_time.sort_by_key(|a| std::cmp::Reverse(a.0));
            by_time.first().map(|a| a.1)
        };

        let runs = if eligible.is_empty() {
            attempt_count
        } else {
            attempt_count.max(eligible.len() as u32)
        };

        let mut total_distance_meters = 0.0;
        let mut total_time_seconds = 0.0;
        let mut pace_distance_meters = 0.0;
        let mut best_pace_seconds_per_km: Option<f64> = None;
        for a in &eligible {
            total_time_seconds += a.1;
            if a.2.is_finite() && a.2 > 0.0 {
                total_distance_meters += a.2;
                pace_distance_meters += a.2;
                if a.1 > 0.0 {
                    let pace = a.1 / (a.2 / 1000.0);
                    best_pace_seconds_per_km = Some(match best_pace_seconds_per_km {
                        Some(b) => b.min(pace),
                        None => pace,
                    });
                }
            }
        }
        let average_pace_seconds_per_km = if pace_distance_meters > 0.0 && total_time_seconds > 0.0
        {
            Some(total_time_seconds / (pace_distance_meters / 1000.0))
        } else {
            None
        };

        let improvement_seconds = if eligible.len() >= 2 {
            let mut chronological = eligible.clone();
            chronological.sort_by_key(|a| a.0);
            let first = chronological.first().map(|a| a.1);
            let latest = chronological.last().map(|a| a.1);
            match (first, latest) {
                (Some(f), Some(l)) => Some(f - l),
                _ => None,
            }
        } else {
            None
        };

        RouteStats {
            pb_seconds: pb,
            average_seconds: average,
            median_seconds: median,
            last_seconds: last,
            runs,
            fastest_seconds: fastest,
            slowest_seconds: slowest,
            std_dev_seconds: std_dev,
            range_seconds: range,
            trend_seconds_per_run: trend,
            recent_average_seconds: recent_average,
            verdict,
            total_distance_meters,
            total_time_seconds,
            average_pace_seconds_per_km,
            best_pace_seconds_per_km,
            improvement_seconds,
        }
    }

    /// Renders the statistics as a JSON object for the FFI boundary.
    #[must_use]
    pub fn to_json(&self) -> String {
        fn opt(v: Option<f64>) -> String {
            match v {
                Some(x) => format!("{x}"),
                None => "null".to_string(),
            }
        }
        fn opt_str(v: &Option<String>) -> String {
            match v {
                Some(s) => format!(r#""{s}""#),
                None => "null".to_string(),
            }
        }
        format!(
            r#"{{"pb_seconds":{pb},"average_seconds":{avg},"median_seconds":{med},"last_seconds":{last},"runs":{runs},"fastest_seconds":{fast},"slowest_seconds":{slow},"std_dev_seconds":{sd},"range_seconds":{rng},"trend_seconds_per_run":{tr},"recent_average_seconds":{ra},"verdict":{v},"total_distance_meters":{td},"total_time_seconds":{tt},"average_pace_seconds_per_km":{ap},"best_pace_seconds_per_km":{bp},"improvement_seconds":{imp}}}"#,
            pb = opt(self.pb_seconds),
            avg = opt(self.average_seconds),
            med = opt(self.median_seconds),
            last = opt(self.last_seconds),
            runs = self.runs,
            fast = opt(self.fastest_seconds),
            slow = opt(self.slowest_seconds),
            sd = opt(self.std_dev_seconds),
            rng = opt(self.range_seconds),
            tr = opt(self.trend_seconds_per_run),
            ra = opt(self.recent_average_seconds),
            v = opt_str(&self.verdict),
            td = self.total_distance_meters,
            tt = self.total_time_seconds,
            ap = opt(self.average_pace_seconds_per_km),
            bp = opt(self.best_pace_seconds_per_km),
            imp = opt(self.improvement_seconds),
        )
    }
}

fn trend_seconds_per_run(attempts: &[Attempt]) -> Option<f64> {
    let mut timed: Vec<&Attempt> = attempts.iter().collect();
    if timed.len() < 2 {
        return None;
    }
    timed.sort_by_key(|a| a.0);
    let n = timed.len() as f64;
    let xs: Vec<f64> = (0..timed.len()).map(|i| i as f64).collect();
    let ys: Vec<f64> = timed.iter().map(|a| a.1).collect();
    let mean_x = xs.iter().sum::<f64>() / n;
    let mean_y = ys.iter().sum::<f64>() / n;
    let mut num = 0.0;
    let mut den = 0.0;
    for i in 0..timed.len() {
        num += (xs[i] - mean_x) * (ys[i] - mean_y);
        den += (xs[i] - mean_x) * (xs[i] - mean_x);
    }
    if den == 0.0 { None } else { Some(num / den) }
}

/// One per-kilometer split, measured against the route's personal best.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SplitDelta {
    /// 1-based kilometer marker.
    pub kilometer: u32,
    /// Running elapsed seconds when this kilometer was reached.
    pub elapsed_seconds: f64,
    /// Positive = behind the PB, negative = ahead.
    pub delta_seconds: f64,
}

/// One sample of the gap-to-PB curve.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GapPoint {
    /// Distance from the start, in meters.
    pub distance_meters: f64,
    /// Seconds ahead of the PB at this distance (negative = behind).
    pub ahead_seconds: f64,
}

/// Pace analysis for one attempt: per-kilometer splits plus the gap curve.
#[derive(Debug, Clone, PartialEq)]
pub struct PaceAnalysis {
    /// Per-kilometer split deltas.
    pub splits: Vec<SplitDelta>,
    /// Gap-to-PB curve, sampled every 100 m.
    pub gap_curve: Vec<GapPoint>,
}

impl PaceAnalysis {
    /// Builds the analysis from a recorded [track] and the route's PB.
    ///
    /// [route_start] is the course's first geometry point (used for the
    /// start-offset correction), [route_meters] the course length and
    /// [track_meters] the distance this attempt covered.
    #[must_use]
    pub fn compute(
        track: &[TrackPoint],
        route_start: Option<Coordinate>,
        route_meters: f64,
        pb_seconds: f64,
        track_meters: f64,
    ) -> Self {
        let empty = PaceAnalysis {
            splits: Vec::new(),
            gap_curve: Vec::new(),
        };
        if track.len() < 2 || route_meters <= 0.0 || pb_seconds <= 0.0 || track_meters <= 0.0 {
            return empty;
        }

        let start = track[0].timestamp();
        let cumulative = cumulative_distances(track);
        let elapsed_at = |d: f64| elapsed_at_distance(track, &cumulative, start, d);
        let pb_speed = route_meters / pb_seconds;

        let total_km = (track_meters / 1000.0).floor();
        let mut splits = Vec::new();
        let mut km = 1u32;
        while f64::from(km) <= total_km {
            let target = f64::from(km) * 1000.0;
            let activity_sec = elapsed_at(target);
            let pb_sec = target / pb_speed;
            splits.push(SplitDelta {
                kilometer: km,
                elapsed_seconds: activity_sec,
                delta_seconds: activity_sec - pb_sec,
            });
            km += 1;
        }

        const GAP_STEP_METERS: f64 = 100.0;
        const GAP_MINIMUM_METERS: f64 = 250.0;
        let mut gap_curve = Vec::new();
        if track_meters >= GAP_MINIMUM_METERS {
            let start_offset = route_start.map_or(0.0, |course_start| {
                let offset = distance(course_start, track[0].coordinate()).meters();
                if offset <= 100.0 { offset } else { 0.0 }
            });
            let gap_at = |d: f64| {
                let route_d = (start_offset + d).clamp(0.0, route_meters);
                route_d / pb_speed - elapsed_at(d)
            };

            gap_curve.push(GapPoint {
                distance_meters: 0.0,
                ahead_seconds: 0.0,
            });
            let mut d = GAP_STEP_METERS;
            while d < track_meters {
                gap_curve.push(GapPoint {
                    distance_meters: d,
                    ahead_seconds: gap_at(d),
                });
                d += GAP_STEP_METERS;
            }
            gap_curve.push(GapPoint {
                distance_meters: track_meters,
                ahead_seconds: gap_at(track_meters),
            });
        }

        PaceAnalysis { splits, gap_curve }
    }

    /// Renders the analysis as a JSON object for the FFI boundary.
    #[must_use]
    pub fn to_json(&self) -> String {
        let splits = self
            .splits
            .iter()
            .map(|s| {
                format!(
                    r#"{{"kilometer":{},"elapsed_seconds":{},"delta_seconds":{}}}"#,
                    s.kilometer, s.elapsed_seconds, s.delta_seconds
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        let gap = self
            .gap_curve
            .iter()
            .map(|p| {
                format!(
                    r#"{{"distance_meters":{},"ahead_seconds":{}}}"#,
                    p.distance_meters, p.ahead_seconds
                )
            })
            .collect::<Vec<_>>()
            .join(",");
        format!(r#"{{"splits":[{splits}],"gap_curve":[{gap}]}}"#)
    }
}

/// Cumulative great-circle distance at every track point (0 for the first).
fn cumulative_distances(track: &[TrackPoint]) -> Vec<f64> {
    let mut out = Vec::with_capacity(track.len());
    out.push(0.0);
    for i in 1..track.len() {
        let seg = distance(track[i - 1].coordinate(), track[i].coordinate()).meters();
        out.push(out[i - 1] + seg);
    }
    out
}

/// Elapsed seconds at [distance] interpolated along the track.
fn elapsed_at_distance(
    track: &[TrackPoint],
    cumulative: &[f64],
    start: Timestamp,
    distance_m: f64,
) -> f64 {
    let elapsed = |p: &TrackPoint| p.timestamp().elapsed_since(start).as_secs();
    if distance_m <= 0.0 {
        return elapsed(&track[0]);
    }
    let total = *cumulative.last().unwrap_or(&0.0);
    if distance_m >= total {
        return elapsed(&track[track.len() - 1]);
    }
    for i in 1..track.len() {
        if cumulative[i] >= distance_m {
            let segment = cumulative[i] - cumulative[i - 1];
            let fraction = if segment > 0.0 {
                ((distance_m - cumulative[i - 1]) / segment).clamp(0.0, 1.0)
            } else {
                0.0
            };
            let a = elapsed(&track[i - 1]);
            let b = elapsed(&track[i]);
            return a + (b - a) * fraction;
        }
    }
    elapsed(&track[track.len() - 1])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn attempts(items: &[(i64, f64)]) -> Vec<Attempt> {
        items.iter().map(|&(t, d)| (t, d, f64::NAN)).collect()
    }

    #[test]
    fn empty_history_keeps_the_seed() {
        let stats = RouteStats::compute(Some(1470.0), 12, &[]);
        assert_eq!(stats.pb_seconds, Some(1470.0));
        assert_eq!(stats.runs, 12);
        assert_eq!(stats.average_seconds, None);
        assert_eq!(stats.last_seconds, None);
    }

    #[test]
    fn history_beats_the_seed_by_fastest_and_tracks_last_chronologically() {
        let a = attempts(&[(1_000, 1600.0), (3_000, 1500.0), (2_000, 1440.0)]);
        let stats = RouteStats::compute(Some(1470.0), 12, &a);
        assert_eq!(stats.pb_seconds, Some(1440.0));
        assert_eq!(stats.last_seconds, Some(1500.0));
        assert_eq!(stats.fastest_seconds, Some(1440.0));
        assert_eq!(stats.slowest_seconds, Some(1600.0));
        assert_eq!(stats.median_seconds, Some(1500.0));
        assert_eq!(stats.range_seconds, Some(160.0));
        assert_eq!(stats.runs, 12);
    }

    #[test]
    fn zero_duration_attempts_are_excluded_from_aggregates() {
        let a = attempts(&[(1_000, 0.0), (2_000, 1500.0)]);
        let stats = RouteStats::compute(Some(1470.0), 12, &a);
        assert_eq!(stats.pb_seconds, Some(1470.0));
        assert_eq!(stats.average_seconds, Some(1500.0));
        assert_eq!(stats.last_seconds, Some(1500.0));
    }

    #[test]
    fn trend_is_negative_when_runs_get_faster() {
        let a = attempts(&[(1_000, 400.0), (2_000, 300.0), (3_000, 200.0)]);
        let stats = RouteStats::compute(None, 0, &a);
        assert!(stats.trend_seconds_per_run.unwrap() < 0.0);
        assert_eq!(stats.runs, 3);
        assert_eq!(stats.pb_seconds, Some(200.0));
    }

    #[test]
    fn totals_and_pace_aggregates_are_computed() {
        let a = vec![
            (1_000i64, 600.0f64, 2000.0f64),
            (2_000i64, 700.0f64, 2000.0f64),
        ];
        let stats = RouteStats::compute(None, 2, &a);
        assert!((stats.total_distance_meters - 4000.0).abs() < 1e-6);
        assert!((stats.total_time_seconds - 1300.0).abs() < 1e-6);
        assert!(stats.average_pace_seconds_per_km.is_some());
        assert!(stats.best_pace_seconds_per_km.is_some());
        assert_eq!(stats.improvement_seconds, Some(-100.0));
    }

    #[test]
    fn pb_progression_marks_strict_chronological_improvers() {
        let a = attempts(&[(1_000, 1500.0), (2_000, 1400.0), (3_000, 1450.0)]);
        let events = pb_progression(&a, Some(1470.0));
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].index, 1);
        assert_eq!(events[0].previous_seconds, Some(1470.0));
    }

    #[test]
    fn attempt_rank_excludes_ineligible_and_is_deterministic() {
        let a = attempts(&[
            (1_000, 1500.0),
            (2_000, 0.0),
            (3_000, 1400.0),
            (4_000, 1400.0),
        ]);
        assert_eq!(attempt_rank(&a, 2), Some(1));
        assert_eq!(attempt_rank(&a, 3), Some(2));
        assert_eq!(attempt_rank(&a, 0), Some(3));
        assert_eq!(attempt_rank(&a, 1), None);
    }

    fn flat_track(meters: f64, seconds: f64) -> Vec<TrackPoint> {
        let mut points = Vec::new();
        let mut d = 0.0;
        while d <= meters + 1e-9 {
            let lat = 52.5 + (d / crate::geo::EARTH_RADIUS_METERS).to_degrees();
            let t = if meters > 0.0 {
                seconds * d / meters
            } else {
                0.0
            };
            points.push(TrackPoint::new(
                Timestamp::from_unix_ms((t * 1000.0).round() as i64),
                Coordinate::new(lat, 13.36).unwrap(),
            ));
            d += 25.0;
        }
        points
    }

    #[test]
    fn pb_pace_yields_zero_splits() {
        let track = flat_track(5000.0, 1500.0);
        let analysis = PaceAnalysis::compute(&track, None, 5000.0, 1500.0, 5000.0);
        assert_eq!(analysis.splits.len(), 5);
        for split in &analysis.splits {
            assert!(split.delta_seconds.abs() < 0.1, "{split:?}");
        }
        assert_eq!(analysis.gap_curve.len(), 51);
        assert_eq!(analysis.gap_curve.first().unwrap().distance_meters, 0.0);
        assert_eq!(analysis.gap_curve.last().unwrap().distance_meters, 5000.0);
    }

    #[test]
    fn slower_run_is_behind_the_constant_pace_pb() {
        let track = flat_track(5000.0, 1700.0);
        let analysis = PaceAnalysis::compute(&track, None, 5000.0, 1500.0, 5000.0);
        for split in &analysis.splits {
            assert!(split.delta_seconds > 0.0, "{split:?}");
            assert!((split.delta_seconds - 40.0 * f64::from(split.kilometer)).abs() < 5.0);
        }
        assert!(analysis.gap_curve.last().unwrap().ahead_seconds < 0.0);
    }

    #[test]
    fn no_pb_or_short_track_produces_nothing() {
        let track = flat_track(120.0, 40.0);
        let analysis = PaceAnalysis::compute(&track, None, 5000.0, 0.0, 120.0);
        assert!(analysis.splits.is_empty());
        assert!(analysis.gap_curve.is_empty());
    }
}
