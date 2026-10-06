// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Track orientation transforms.

use crate::track::{Track, TrackPoint};
use crate::units::Timestamp;

/// Reverses a track: the route plays finish → start while keeping the same
/// total duration and monotonic ascending timestamps.
pub fn reverse(track: &Track) -> Track {
    let points = track.points();
    let start_ms = points
        .first()
        .expect("track non-empty")
        .timestamp()
        .unix_ms() as f64;
    let end_ms = points
        .last()
        .expect("track non-empty")
        .timestamp()
        .unix_ms() as f64;
    let total_ms = end_ms - start_ms;
    let spread = (points.len() - 1).max(1) as f64;

    let reversed: Vec<TrackPoint> = points
        .iter()
        .rev()
        .enumerate()
        .map(|(i, p)| {
            let t = start_ms + total_ms * (i as f64 / spread);
            TrackPoint::new(Timestamp::from_unix_ms(t.round() as i64), p.coordinate())
        })
        .collect();

    Track::new(reversed).expect("reversed track stays valid")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo::Coordinate;
    use crate::units::Timestamp;

    fn tiny_track() -> Track {
        let points = vec![
            TrackPoint::new(
                Timestamp::from_unix_ms(0),
                Coordinate::new(52.50, 13.40).unwrap(),
            ),
            TrackPoint::new(
                Timestamp::from_unix_ms(10_000),
                Coordinate::new(52.51, 13.40).unwrap(),
            ),
            TrackPoint::new(
                Timestamp::from_unix_ms(20_000),
                Coordinate::new(52.52, 13.40).unwrap(),
            ),
        ];
        Track::new(points).unwrap()
    }

    #[test]
    fn reversed_plays_finish_to_start() {
        let original = tiny_track();
        let reversed = original.reversed();

        assert_eq!(
            reversed.start().unwrap().coordinate(),
            original.end().unwrap().coordinate()
        );
        assert_eq!(
            reversed.end().unwrap().coordinate(),
            original.start().unwrap().coordinate()
        );
        assert!(
            (reversed.duration().as_secs() - original.duration().as_secs()).abs() < 1e-6,
            "duration must be preserved"
        );
    }

    #[test]
    fn reversed_has_monotonic_timestamps() {
        let reversed = tiny_track().reversed();
        let ts: Vec<i64> = reversed
            .points()
            .iter()
            .map(|p| p.timestamp().unix_ms())
            .collect();
        assert!(
            ts.windows(2).all(|w| w[0] <= w[1]),
            "timestamps must not decrease"
        );
    }
}
