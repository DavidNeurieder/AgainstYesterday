// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Track analytics derived from a validated [`Track`].
//!
//! All numerical analysis lives here so the Flutter client, route statistics,
//! and ghost racing share one definition. Raw GPS data is never modified; this
//! module only produces derived, annotated results.

use crate::track::MovingConfig;
use crate::track::Track;

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
        let dt = pts[i].timestamp().elapsed_since(pts[i - 1].timestamp()).as_secs();
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
        for j in (i + 1 - window)..=i {
            sum += seg_paces[j].1;
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
