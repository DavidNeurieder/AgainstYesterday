// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Domain value types.
//!
//! Distances, durations, speeds, and timestamps are distinct newtypes rather
//! than naked `f64`s, so that meters can never be silently confused with
//! seconds anywhere in the engine API.

use std::fmt;
use std::ops::{Add, Div, Mul, Sub};

/// A length, stored as meters.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Distance(f64);

impl Distance {
    /// A zero-length distance.
    pub const ZERO: Distance = Distance(0.0);

    /// Distance from a number of meters.
    pub fn from_meters(meters: f64) -> Self {
        Distance(meters)
    }

    /// The distance in meters.
    pub fn meters(self) -> f64 {
        self.0
    }

    /// The distance in kilometers.
    pub fn kilometers(self) -> f64 {
        self.0 / 1000.0
    }
}

impl Default for Distance {
    fn default() -> Self {
        Distance::ZERO
    }
}

impl Add for Distance {
    type Output = Distance;
    fn add(self, rhs: Distance) -> Distance {
        Distance(self.0 + rhs.0)
    }
}

impl Sub for Distance {
    type Output = Distance;
    fn sub(self, rhs: Distance) -> Distance {
        Distance(self.0 - rhs.0)
    }
}

impl Mul<f64> for Distance {
    type Output = Distance;
    fn mul(self, rhs: f64) -> Distance {
        Distance(self.0 * rhs)
    }
}

impl Div<f64> for Distance {
    type Output = Distance;
    fn div(self, rhs: f64) -> Distance {
        Distance(self.0 / rhs)
    }
}

impl fmt::Display for Distance {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0 >= 1000.0 {
            write!(f, "{:.2} km", self.0 / 1000.0)
        } else {
            write!(f, "{:.2} m", self.0)
        }
    }
}

/// A span of time, stored as seconds.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Duration(f64);

impl Duration {
    /// A zero-length duration.
    pub const ZERO: Duration = Duration(0.0);

    /// Duration from a number of seconds.
    pub fn from_secs(seconds: f64) -> Self {
        Duration(seconds)
    }

    /// Duration from a number of milliseconds.
    pub fn from_millis(milliseconds: f64) -> Self {
        Duration(milliseconds / 1000.0)
    }

    /// Duration from a number of minutes.
    pub fn from_minutes(minutes: f64) -> Self {
        Duration::from_secs(minutes * 60.0)
    }

    /// The duration in seconds.
    pub fn as_secs(self) -> f64 {
        self.0
    }

    /// The duration in minutes.
    pub fn as_minutes(self) -> f64 {
        self.0 / 60.0
    }
}

impl Default for Duration {
    fn default() -> Self {
        Duration::ZERO
    }
}

impl Add for Duration {
    type Output = Duration;
    fn add(self, rhs: Duration) -> Duration {
        Duration(self.0 + rhs.0)
    }
}

impl Sub for Duration {
    type Output = Duration;
    fn sub(self, rhs: Duration) -> Duration {
        Duration(self.0 - rhs.0)
    }
}

impl Mul<f64> for Duration {
    type Output = Duration;
    fn mul(self, rhs: f64) -> Duration {
        Duration(self.0 * rhs)
    }
}

impl Div<f64> for Duration {
    type Output = Duration;
    fn div(self, rhs: f64) -> Duration {
        Duration(self.0 / rhs)
    }
}

impl fmt::Display for Duration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let total = self.0.max(0.0);
        let minutes = (total / 60.0).floor() as u64;
        let seconds = (total % 60.0) as u64;
        write!(f, "{minutes:02}:{seconds:02}")
    }
}

/// A speed, stored as meters per second.
#[derive(Debug, Clone, Copy, PartialEq, PartialOrd)]
pub struct Speed(f64);

impl Speed {
    /// The zero speed.
    pub const ZERO: Speed = Speed(0.0);

    /// Speed from a number of meters per second.
    pub fn from_mps(meters_per_second: f64) -> Self {
        Speed(meters_per_second)
    }

    /// Speed from a number of kilometers per hour.
    pub fn from_kmh(kilometers_per_hour: f64) -> Self {
        Speed(kilometers_per_hour / 3.6)
    }

    /// The speed in meters per second.
    pub fn mps(self) -> f64 {
        self.0
    }

    /// The speed in kilometers per hour.
    pub fn kmh(self) -> f64 {
        self.0 * 3.6
    }
}

impl Default for Speed {
    fn default() -> Self {
        Speed::ZERO
    }
}

impl fmt::Display for Speed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:.2} m/s", self.0)
    }
}

/// A point in time, stored as milliseconds since the Unix epoch.
///
/// Storing whole milliseconds as an integer preserves ordering and precision
/// without floating-point ambiguity, and supports the fraction-of-a-second
/// timestamps found in GPX files.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Timestamp {
    unix_ms: i64,
}

impl Timestamp {
    /// A timestamp from milliseconds since the Unix epoch.
    pub fn from_unix_ms(unix_ms: i64) -> Self {
        Timestamp { unix_ms }
    }

    /// A timestamp from seconds since the Unix epoch; fractional seconds are
    /// rounded to the nearest millisecond.
    pub fn from_unix_secs(seconds: f64) -> Self {
        Timestamp {
            unix_ms: (seconds * 1000.0).round() as i64,
        }
    }

    /// Milliseconds since the Unix epoch.
    pub fn unix_ms(self) -> i64 {
        self.unix_ms
    }

    /// Seconds since the Unix epoch, as a float for downstream math.
    pub fn unix_secs(self) -> f64 {
        self.unix_ms as f64 / 1000.0
    }

    /// The time elapsed between `earlier` and this timestamp.
    ///
    /// Returns a negative duration if `earlier` is actually after this
    /// timestamp.
    pub fn elapsed_since(self, earlier: Timestamp) -> Duration {
        Duration::from_millis((self.unix_ms - earlier.unix_ms) as f64)
    }
}

impl fmt::Display for Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ms", self.unix_ms)
    }
}
