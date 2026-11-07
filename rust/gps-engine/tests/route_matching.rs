// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Continuity-aware live route-matching fixtures.
//!
//! Exercises the live [`RouteMatcher`] behaviors layered in over the global
//! nearest projection: self-intersections and overlaps keep correct progress,
//! detours freeze coverage, reacquisition restores it, and scoring/state
//! remain deterministic.

use gps_engine::gps::GpsFix;
use gps_engine::live::{LiveConfig, LiveMatchStatus, LiveRecorder};
use gps_engine::route::Route;
use gps_engine::units::{Distance, Timestamp};
use gps_engine::{Coordinate, Speed};
use proptest::prelude::*;

fn c(lat: f64, lon: f64) -> Coordinate {
    Coordinate::new(lat, lon).unwrap()
}

fn fix_at(coord: Coordinate, second: i64) -> GpsFix {
    GpsFix::new(Timestamp::from_unix_secs(second as f64), coord)
}

fn fix(lat: f64, lon: f64, second: i64) -> GpsFix {
    fix_at(c(lat, lon), second)
}

fn run_along(route: &Route, step_m: f64) -> LiveRecorder {
    let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route.clone()));
    let total = route.length().meters();
    let mut d = 0.0_f64;
    let mut t = 0_i64;
    while d <= total + 1e-6 {
        let dm = d.min(total);
        let coord = route.coordinate_at(Distance::from_meters(dm)).unwrap();
        rec.push(fix_at(coord, t));
        t += 1;
        d += step_m;
    }
    let end = route.coordinate_at(route.length()).unwrap();
    rec.push(fix_at(end, t));
    rec
}

mod straight_route {
    use super::*;

    #[test]
    fn clean_progress_reaches_finish() {
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5100, 13.4000)]).unwrap();
        let rec = run_along(&route, 5.0);
        assert!(
            rec.distance().meters() >= route.length().meters() - 1.0,
            "got {} of {}",
            rec.distance().meters(),
            route.length().meters()
        );
        let snap = rec.snapshot();
        assert!(snap.route_progress >= 0.999);
        assert_eq!(snap.match_status, LiveMatchStatus::Matched);
    }
}

mod figure_eight {
    use super::*;

    fn bow_tie() -> Route {
        Route::new(vec![
            c(52.5000, 13.4000),
            c(52.5020, 13.4020),
            c(52.5000, 13.4020),
            c(52.5020, 13.4000),
            c(52.5000, 13.4000),
        ])
        .unwrap()
    }

    #[test]
    fn crossing_does_not_jump_progress() {
        let route = bow_tie();
        let rec = run_along(&route, 5.0);
        let total = route.length().meters();
        assert!(
            rec.distance().meters() >= total - 1.0,
            "got {} of {}",
            rec.distance().meters(),
            total
        );
        assert!(rec.snapshot().route_progress >= 0.999);
    }
}

mod repeated_overlap {
    use super::*;

    #[test]
    fn second_lap_does_not_snap_to_first() {
        // The same loop traced twice: global projection would stall at the end
        // of lap 1 because every lap-2 fix is geometrically identical to lap 1.
        let a = c(52.5000, 13.4000);
        let b = c(52.5020, 13.4000);
        let d = c(52.5020, 13.4020);
        let e = c(52.5000, 13.4020);
        let route = Route::new(vec![a, b, d, e, a, b, d, e, a]).unwrap();
        let rec = run_along(&route, 5.0);
        let total = route.length().meters();
        assert!(
            rec.distance().meters() >= total - 1.0,
            "stalled at {} of {}",
            rec.distance().meters(),
            total
        );
    }
}

mod parallel_paths {
    use super::*;

    #[test]
    fn continuity_stays_on_the_active_corridor() {
        // Two northbound corridors ~80 m apart, connected by a short east leg.
        // The runner stays on the east corridor; global nearest projection near
        // the connection could flirt with the west corridor, but continuity
        // anchored on recent progress keeps coverage advancing on the intended
        // path.
        let route = Route::new(vec![
            c(52.5000, 13.4000),
            c(52.5030, 13.4000),
            c(52.5030, 13.4012), // cross east (~80 m)
            c(52.5000, 13.4012), // go south on east corridor
            c(52.4970, 13.4012),
        ])
        .unwrap();
        let rec = run_along(&route, 5.0);
        let total = route.length().meters();
        assert!(
            rec.distance().meters() >= total - 1.0,
            "got {} of {}",
            rec.distance().meters(),
            total
        );
        assert_eq!(rec.snapshot().match_status, LiveMatchStatus::Matched);
    }
}

mod hairpin {
    use super::*;

    #[test]
    fn out_and_back_reaches_finish() {
        let a = c(52.5000, 13.4000);
        let b = c(52.5050, 13.4000);
        let route = Route::new(vec![a, b, a]).unwrap();
        let rec = run_along(&route, 5.0);
        let total = route.length().meters();
        assert!(
            rec.distance().meters() >= total - 1.0,
            "got {} of {}",
            rec.distance().meters(),
            total
        );
    }
}

mod gps_dropout {
    use super::*;

    #[test]
    fn time_gap_on_route_does_not_corrupt_progress() {
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5060, 13.4000)]).unwrap();
        let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route.clone()));
        rec.push(fix(52.5000, 13.4000, 0));
        rec.push(fix(52.5005, 13.4000, 10));
        let before = rec.distance().meters();
        assert!(before > 40.0);

        // 30 s dropout, then a fix further along the same route. Progress must
        // reflect the new on-route position (not jump to a wrong branch) and
        // never regress.
        rec.push(fix(52.5020, 13.4000, 40));
        let after = rec.distance().meters();
        assert!(
            after >= before,
            "progress regressed across dropout: {before} -> {after}"
        );
        assert!(
            after > 150.0,
            "expected progress after dropout fix, got {after}"
        );
    }
}

mod off_route {
    use super::*;

    #[test]
    fn sustained_detour_freezes_reliable_coverage() {
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5100, 13.4000)]).unwrap();
        let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route));
        for i in 0..=30 {
            rec.push(fix(52.5000 + i as f64 * 0.00005, 13.4000, i));
        }
        let on_route = rec.distance().meters();
        assert!(on_route > 100.0);

        // Far detour (~340 m east) long enough to exceed hysteresis.
        for i in 31..=45 {
            rec.push(fix(52.5015 + (i - 31) as f64 * 0.00003, 13.4050, i));
        }
        let frozen = rec.distance().meters();
        assert!(
            frozen <= on_route + 1.0,
            "detour advanced coverage {on_route} -> {frozen}"
        );
        assert!(rec.snapshot().off_route.is_some());
    }
}

mod reacquisition {
    use super::*;

    #[test]
    fn rejoins_route_after_detour() {
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5100, 13.4000)]).unwrap();
        let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route));
        for i in 0..=30 {
            rec.push(fix(52.5000 + i as f64 * 0.00005, 13.4000, i));
        }
        let on_route = rec.distance().meters();
        for i in 31..=45 {
            rec.push(fix(52.5015 + (i - 31) as f64 * 0.00003, 13.4050, i));
        }
        let frozen = rec.distance().meters();
        assert!(frozen <= on_route + 1.0);

        // Rejoin further north with a stable sequence.
        for i in 46..=65 {
            rec.push(fix(52.5040 + (i - 46) as f64 * 0.00005, 13.4000, i));
        }
        assert!(
            rec.distance().meters() > frozen + 50.0,
            "no reacquisition: frozen {frozen}, now {}",
            rec.distance().meters()
        );
    }
}

mod reverse_direction {
    use super::*;

    #[test]
    fn reverse_travel_does_not_advance_coverage() {
        // Run forward, then feed fixes moving back along the same line. A
        // fixed-direction route traversed in reverse should not gain reliable
        // forward coverage (heading/progress continuity resist it).
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5080, 13.4000)]).unwrap();
        let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route));
        for i in 0..=40 {
            rec.push(fix(52.5000 + i as f64 * 0.00005, 13.4000, i));
        }
        let forward = rec.distance().meters();
        assert!(forward > 150.0);

        // Move back toward the start with reported bearing south.
        for i in 41..=55 {
            let lat = 52.5020 - (i - 41) as f64 * 0.00005;
            let mut f = fix(lat, 13.4000, i);
            f.bearing = Some(gps_engine::geo::Bearing::from_degrees(180.0).unwrap());
            f.speed = Some(Speed::from_mps(2.5));
            rec.push(f);
        }
        let after = rec.distance().meters();
        assert!(
            after <= forward + 2.0,
            "reverse travel advanced coverage {forward} -> {after}"
        );
    }
}

mod noisy_gps {
    use super::*;

    #[test]
    fn jitter_around_route_still_completes() {
        // Small lateral noise (well within tolerance) must not prevent a clean
        // run from reaching the finish.
        let route = Route::new(vec![c(52.5000, 13.4000), c(52.5060, 13.4000)]).unwrap();
        let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route.clone()));
        let total = route.length().meters();
        let mut d = 0.0_f64;
        let mut t = 0_i64;
        while d <= total + 1e-6 {
            let dm = d.min(total);
            let on = route.coordinate_at(Distance::from_meters(dm)).unwrap();
            // Alternate ~6 m east/west jitter.
            let jitter_deg = if t % 2 == 0 { 0.00009 } else { -0.00009 };
            let coord = c(on.latitude(), on.longitude() + jitter_deg);
            rec.push(fix_at(coord, t));
            t += 1;
            d += 5.0;
        }
        let end = route.coordinate_at(route.length()).unwrap();
        rec.push(fix_at(end, t));
        assert!(
            rec.distance().meters() >= total - 1.0,
            "got {} of {}",
            rec.distance().meters(),
            total
        );
    }
}

mod properties {
    use super::*;

    fn straight() -> Route {
        Route::new(vec![c(52.5000, 13.4000), c(52.5080, 13.4000)]).unwrap()
    }

    proptest! {
        #[test]
        fn accepted_coverage_is_monotone_and_bounded(step in 1.0f64..12.0) {
            let route = straight();
            let total = route.length().meters();
            let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route.clone()));
            let mut d = 0.0_f64;
            let mut t = 0_i64;
            let mut prev = 0.0_f64;
            while d <= total + 1e-6 {
                let dm = d.min(total);
                let coord = route.coordinate_at(Distance::from_meters(dm)).unwrap();
                rec.push(fix_at(coord, t));
                let cur = rec.distance().meters();
                prop_assert!(cur + 1e-9 >= prev, "regressed {prev} -> {cur}");
                prop_assert!(cur <= total + 1e-6, "exceeded route {cur} > {total}");
                prev = cur;
                t += 1;
                d += step;
            }
        }

        #[test]
        fn repeated_identical_fix_does_not_advance(
            lat in 52.5000f64..52.5060,
            repeats in 2usize..20,
        ) {
            let route = straight();
            let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route));
            rec.push(fix(52.5000, 13.4000, 0));
            rec.push(fix(lat, 13.4000, 1));
            let after = rec.distance().meters();
            // Re-send the same position/timestamp step pattern (stopped).
            let coord = c(lat, 13.4000);
            for i in 2..(2 + repeats as i64) {
                let mut f = fix_at(coord, i);
                f.speed = Some(Speed::from_mps(0.0));
                rec.push(f);
            }
            prop_assert!(
                rec.distance().meters() <= after + 1.0,
                "identical fixes advanced {} -> {}",
                after,
                rec.distance().meters()
            );
        }

        #[test]
        fn off_route_jitter_never_exceeds_route_length(
            offset_deg in 0.002f64..0.01,
            steps in 5usize..30,
        ) {
            // Large lateral offsets keep reported (reliable) distance bounded.
            let route = straight();
            let total = route.length().meters();
            let mut rec = LiveRecorder::new(LiveConfig::default(), Some(route));
            for i in 0..steps as i64 {
                rec.push(fix(52.5010 + i as f64 * 0.00005, 13.4000 + offset_deg, i));
            }
            prop_assert!(rec.distance().meters() <= total + 1e-6);
            prop_assert!(rec.distance().meters() >= -1e-6);
        }
    }
}
