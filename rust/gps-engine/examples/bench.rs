// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! §34 benchmark harness: progressively larger deterministic synthetic
//! workloads.
//!
//! All workloads are generated (no real data needed) with fixed seeds, so the
//! *workload* is reproducible; only the wall-clock numbers vary. Run it in
//! release mode for meaningful times:
//!
//! ```text
//! cargo run --release --example bench -- --tracks 200
//! ```
//!
//! Flags:
//! - `--tracks N`             corpus size (default 20)
//! - `--pairs S`              pairwise comparison subset size (default 24)
//! - `--route-km R`           loop route perimeter (default 10)
//! - `--seed S`               corpus seed (default 42)

use std::time::Instant;

use gps_engine::geo::Coordinate;
use gps_engine::synthetic::SyntheticConfig;
use gps_engine::units::{Distance, Speed};
use gps_engine::{MatchConfig, Route, RouteCatalog, compare_either_direction, filter, simplify};

fn parse_args() -> (usize, usize, f64, u64) {
    let mut tracks = 20usize;
    let mut pairs = 24usize;
    let mut km = 10.0f64;
    let mut seed = 42u64;
    let mut it = std::env::args().skip(1);
    while let Some(arg) = it.next() {
        let value = |it: &mut dyn Iterator<Item = String>| it.next().expect("flag needs a value");
        match arg.as_str() {
            "--tracks" => tracks = value(&mut it).parse().expect("integer"),
            "--pairs" => pairs = value(&mut it).parse().expect("integer"),
            "--route-km" => km = value(&mut it).parse().expect("number"),
            "--seed" => seed = value(&mut it).parse().expect("integer"),
            other => panic!("unknown flag: {other}"),
        }
    }
    (tracks, pairs, km, seed)
}

fn ms(f: impl FnOnce()) -> f64 {
    let start = Instant::now();
    f();
    start.elapsed().as_secs_f64() * 1000.0
}

/// A closed square loop around (52.50, 13.40) of perimeter `km`.
fn loop_route(km: f64) -> Route {
    let side = km / 4.0;
    let deg = side / 111.0; // one degree of latitude ≈ 111 km
    let base = Coordinate::new(52.50, 13.40).unwrap();
    let corners = [
        Coordinate::new(base.latitude(), base.longitude()).unwrap(),
        Coordinate::new(base.latitude() + deg, base.longitude()).unwrap(),
        Coordinate::new(base.latitude() + deg, base.longitude() + deg).unwrap(),
        Coordinate::new(base.latitude(), base.longitude() + deg).unwrap(),
        Coordinate::new(base.latitude(), base.longitude()).unwrap(),
    ];
    Route::new(corners.to_vec()).unwrap()
}

fn header(title: &str) {
    println!("{title}");
    println!("  {:-<72}", "");
}

fn bench_geometry(route: &Route) {
    header("geometry");
    for count in [1_000usize, 10_000, 100_000] {
        let elapsed = ms(|| {
            let len = route.length().meters();
            for i in 0..count {
                let along = (i as f64 / count as f64) * len;
                let p = route.coordinate_at(Distance::from_meters(along)).unwrap();
                let _ = route.project(p).distance_along;
            }
        });
        println!(
            "  project + sample   {:>9} pts   {:>9.2} ms",
            count, elapsed
        );
    }
}

fn processed_len(track: &gps_engine::Track) -> usize {
    let (f, _) = filter(track, &gps_engine::FilterConfig::default());
    let s = simplify(&f, &gps_engine::SimplifyConfig::default());
    s.resample_by_distance(Distance::from_meters(25.0))
        .unwrap()
        .points()
        .len()
}

fn bench_processing(corpus: &[gps_engine::Track]) {
    header("processing (filter + simplify + resample)");
    for &batch in &[1usize, 100, 1000] {
        let usable = batch.min(corpus.len());
        let elapsed = ms(|| {
            let mut total = 0usize;
            for t in &corpus[..usable] {
                total += processed_len(t);
            }
            std::hint::black_box(total);
        });
        println!(
            "  {} track(s)   {:>7} pts/track   {:>9.2} ms",
            usable,
            corpus[0].points().len(),
            elapsed
        );
    }
}

fn bench_matching(corpus: &[gps_engine::Track], pairs: usize) {
    header("matching");

    let config = MatchConfig::default();
    let droutes = ms(|| {
        let mut catalog = RouteCatalog::new(config);
        for t in corpus {
            catalog.add_track(t);
        }
        std::hint::black_box(catalog.route_count());
    });
    println!(
        "  discovery          {:>6} tracks   {:>9.2} ms",
        corpus.len(),
        droutes
    );

    let pair_sizes = {
        let mut sizes = [8usize, 24, pairs].to_vec();
        sizes.sort_unstable();
        sizes.dedup();
        sizes
    };
    for &s in &pair_sizes {
        if s < 2 || s > corpus.len() {
            continue;
        }
        let slice = &corpus[..s];
        let (matched, elapsed) = {
            let mut matched = 0usize;
            let t = ms(|| {
                for i in 0..slice.len() {
                    for j in 0..slice.len() {
                        if i != j
                            && compare_either_direction(&slice[i], &slice[j], &config).is_some()
                        {
                            matched += 1;
                        }
                    }
                }
                std::hint::black_box(matched);
            });
            (matched, t)
        };
        println!(
            "  pairwise           {:>4}²   {:>9.2} ms   {:.0}/s   {} matched",
            s,
            elapsed,
            (s * s) as f64 / (elapsed / 1000.0),
            matched
        );
    }
}

fn main() {
    let (tracks, pairs, km, seed) = parse_args();
    let route = loop_route(km);
    println!("bench  corpus: {tracks} tracks, loop {km} km, seed {seed}\n");

    let total = ms(|| {
        let mut corpus: Vec<gps_engine::Track> = Vec::with_capacity(tracks);
        for i in 0..tracks {
            let config = SyntheticConfig::noisy((seed + i as u64) * 0x9E37_779B_u64, 8.0);
            corpus.push(gps_engine::synthetic::generate(route.geometry(), &config));
        }
        bench_geometry(&route);
        bench_processing(&corpus);
        bench_matching(&corpus, pairs);
    });

    println!("\n  total (incl. corpus generation): {:.2} ms", total);
    let _ = Speed::ZERO; // keep units in scope
}
