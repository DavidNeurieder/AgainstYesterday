// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Minimal end-to-end demonstration of the engine on synthetic data.

use gps_engine::geo::{distance, polyline_length, project_to_polyline};
use gps_engine::units::Timestamp;
use gps_engine::{Coordinate, Track, TrackPoint};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let points = vec![
        TrackPoint::new(
            Timestamp::from_unix_ms(0),
            Coordinate::new(52.5200, 13.4050)?,
        ),
        TrackPoint::new(
            Timestamp::from_unix_ms(60_000),
            Coordinate::new(52.5210, 13.4070)?,
        ),
        TrackPoint::new(
            Timestamp::from_unix_ms(120_000),
            Coordinate::new(52.5225, 13.4095)?,
        ),
        TrackPoint::new(
            Timestamp::from_unix_ms(180_000),
            Coordinate::new(52.5240, 13.4120)?,
        ),
    ];

    let track = Track::new(points)?;
    println!("points:   {}", track.len());
    println!("duration: {}", track.duration());

    let coords: Vec<Coordinate> = track.points().iter().map(|p| p.coordinate()).collect();
    let length = polyline_length(&coords);
    println!("length:   {length}");

    let probe = Coordinate::new(52.5230, 13.4105)?;
    match project_to_polyline(probe, &coords) {
        Some(projection) => {
            let along = distance(coords[0], projection.projected).meters();
            println!(
                "probe {} projects to segment {} at {:.1} m along (lateral {:.1} m)",
                probe.latitude(),
                projection.segment_index,
                along,
                projection.lateral_error.meters()
            );
        }
        None => println!("track too short to project onto"),
    }

    println!("ok");
    Ok(())
}
