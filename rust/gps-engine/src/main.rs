// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Companion CLI for the GPS engine.
//!
//! Commands:
//!
//! ```text
//! gps-engine inspect file.gpx
//! gps-engine process file.gpx
//! gps-engine compare a.gpx b.gpx
//! gps-engine discover ./tracks/
//! gps-engine benchmark ./tracks/
//! ```
//!
//! This binary orchestrates the (pure, deterministic) library; only the
//! benchmark uses wall-clock time.

use std::path::{Path, PathBuf};
use std::time::Instant;

use gps_engine::{
    Distance, FilterConfig, MatchConfig, MatchScore, ProcessingReport, RouteCatalog,
    SimplifyConfig, Track, compare_either_direction, compare_with, filter, read_gpx_file,
    resample_by_distance, simplify, write_gpx_file,
};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        usage();
        std::process::exit(2);
    }

    let result = match args[1].as_str() {
        "inspect" => cmd_inspect(&args[2..]),
        "process" => cmd_process(&args[2..]),
        "compare" => cmd_compare(&args[2..]),
        "discover" => cmd_discover(&args[2..]),
        "evaluate" => cmd_evaluate(&args[2..]),
        "benchmark" => cmd_benchmark(&args[2..]),
        "help" | "--help" | "-h" => {
            usage();
            Ok(())
        }
        other => Err(format!("unknown command: {other}")),
    };

    if let Err(message) = result {
        eprintln!("error: {message}");
        std::process::exit(1);
    }
}

fn usage() {
    println!(
        r#"gps-engine — companion CLI

usage:
  gps-engine inspect    file.gpx
  gps-engine process    file.gpx [--out file.gpx]
  gps-engine compare    a.gpx b.gpx
  gps-engine discover   ./tracks/
  gps-engine evaluate   ./testdata/synthetic/
  gps-engine benchmark  ./tracks/"#
    );
}

type CmdResult = Result<(), String>;

/// Standard processing pipeline used throughout the CLI (and by the matching
/// tests): filter, simplify, resample to a 25 m cadence.
fn process(track: &Track) -> (Track, ProcessingReport) {
    let (filtered, report) = filter(track, &FilterConfig::default());
    let simplified = simplify(&filtered, &SimplifyConfig::default());
    let resampled = resample_by_distance(&simplified, Distance::from_meters(25.0))
        .expect("resampling a processed track keeps it valid");
    (resampled, report)
}

fn load_gpx(path: &Path) -> Result<Track, String> {
    read_gpx_file(path).map_err(|e| format!("{}: {e}", path.display()))
}

fn collect_gpx_files(dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(dir)
        .map_err(|e| format!("{}: {e}", dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| {
            p.extension()
                .map(|ext| ext.eq_ignore_ascii_case("gpx"))
                .unwrap_or(false)
        })
        .collect();
    files.sort();
    Ok(files)
}

fn require_one(args: &[String], command: &str) -> Result<String, String> {
    match args {
        [one] => Ok(one.clone()),
        _ => Err(format!("{command} needs exactly one path argument")),
    }
}

fn format_hms(duration: gps_engine::Duration) -> String {
    let total = duration.as_secs().max(0.0) as u64;
    let (hours, rest) = (total / 3600, total % 3600);
    let (minutes, seconds) = (rest / 60, rest % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

fn print_track_summary(name: &str, track: &Track) {
    println!("Track   {name}", name = name);
    println!("──────────────────────────────────────────────");
    println!("Points:    {:>12}", track.len());
    println!("Duration:  {:>12}", format_hms(track.duration()));
    println!(
        "Moving:    {:>12}",
        format_hms(track.moving_duration(&Default::default()))
    );
    println!("Distance:  {:>12}", track.distance());
    println!("Avg speed: {:>12}", track.average_speed());
    println!(
        "Elevation: {:>11} +{} m / -{} m",
        "",
        track.elevation_gain() as u64,
        track.elevation_loss() as u64
    );
    println!();
}

fn cmd_inspect(args: &[String]) -> CmdResult {
    let path = require_one(args, "inspect")?;
    let track = load_gpx(Path::new(&path))?;
    print_track_summary(&path, &track);
    Ok(())
}

fn cmd_process(args: &[String]) -> CmdResult {
    let (path, out) = split_out(args)?;
    let raw = load_gpx(Path::new(&path))?;
    let (processed, report) = process(&raw);

    println!("Processing  {path}");
    println!("──────────────────────────────────────────────");
    println!("Input points:    {:>9}", report.input_points);
    println!("Removed points:  {:>9}", report.removed_points);
    println!("Distance before: {:>9}", report.distance_before);
    println!("Distance after:  {:>9}", report.distance_after);
    println!();
    print_track_summary(&format!("{path} (processed)"), &processed);
    if let Some(out) = out {
        write_gpx_file(&processed, &out).map_err(|e| format!("{out}: {e}"))?;
        println!("Wrote        {out}");
    }
    Ok(())
}

/// Splits `file.gpx [--out file.gpx]` into positional path and optional out.
fn split_out(args: &[String]) -> Result<(String, Option<String>), String> {
    if args.is_empty() || args.len() > 3 {
        return Err("process takes file.gpx [--out file.gpx]".to_string());
    }
    let path = args[0].clone();
    let mut out = None;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--out" => {
                if i + 1 >= args.len() {
                    return Err("--out needs a path".to_string());
                }
                out = Some(args[i + 1].clone());
                i += 2;
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok((path, out))
}

fn score_report(score: &MatchScore, config: &MatchConfig) -> String {
    let classification = if score.is_match(config) {
        "SAME ROUTE"
    } else {
        "DIFFERENT ROUTE"
    };
    format!(
        "Start distance:    {:>8.1} m\n\
         End distance:      {:>8.1} m\n\
         Distance ratio:    {:>8.3}\n\
         Spatial overlap:   {:>7.1}%\n\
         Direction:         {:>8.3}\n\
         \n\
         Classification:    {classification}",
        score.start_distance.meters(),
        score.end_distance.meters(),
        score.distance_ratio,
        score.spatial_overlap * 100.0,
        score.direction_similarity,
    )
}

fn cmd_compare(args: &[String]) -> CmdResult {
    if args.len() != 2 {
        return Err("compare needs exactly two GPX files".into());
    }
    let a = process(&load_gpx(Path::new(&args[0]))?).0;
    let b = process(&load_gpx(Path::new(&args[1]))?).0;
    let config = MatchConfig::default();

    println!("Compare   {} vs {}", args[0], args[1]);
    println!("──────────────────────────────────────────────");
    match compare_either_direction(&a, &b, &config) {
        Some(score) => println!("{}", score_report(&score, &config)),
        None => {
            // Forward-only metrics for diagnostics when neither orientation matched.
            println!("{}", score_report(&compare_with(&a, &b, &config), &config));
        }
    }
    Ok(())
}

fn cmd_discover(args: &[String]) -> CmdResult {
    let dir = require_one(args, "discover")?;
    let files = collect_gpx_files(Path::new(&dir))?;
    if files.is_empty() {
        return Err(format!("no .gpx files found in {dir}"));
    }

    let mut catalog = RouteCatalog::new(MatchConfig::default());
    for file in &files {
        let track = load_gpx(file)?;
        let (processed, _) = process(&track);
        let addition = catalog.add_track(&processed);
        println!(
            "{:<3} route #{:<3} {}",
            if addition.is_new { "NEW" } else { "ADD" },
            addition.route_id,
            file.display(),
        );
    }

    println!();
    println!(
        "Discovered  {} routes from {} tracks",
        catalog.route_count(),
        files.len()
    );
    for (i, route) in catalog.routes().iter().enumerate() {
        let rep = route.representative();
        println!(
            "#{i}   {} tracks    len {}   duration {}",
            route.track_count,
            rep.distance(),
            format_hms(rep.duration())
        );
    }
    Ok(())
}

/// Runs the §39 manifest evaluation against a corpus directory.
fn cmd_evaluate(args: &[String]) -> CmdResult {
    let dir = require_one(args, "evaluate")?;
    let manifest_path = std::path::Path::new(&dir).join("manifest.json");
    let manifest_text =
        std::fs::read_to_string(&manifest_path).map_err(|e| format!("{dir}/manifest.json: {e}"))?;
    let labels = gps_engine::parse_manifest(&manifest_text)?;

    let files = collect_gpx_files(std::path::Path::new(&dir))?;
    let mut tracks: std::collections::HashMap<String, Track> = std::collections::HashMap::new();
    for file in &files {
        let name = file
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .ok_or_else(|| format!("{}: no file name", file.display()))?;
        let raw = load_gpx(file)?;
        tracks.insert(name, process(&raw).0);
    }

    println!(
        "Evaluate  {dir}  ({} labeled pairs, {} tracks)",
        labels.len(),
        tracks.len()
    );
    println!("──────────────────────────────────────────────");
    let matrix = gps_engine::evaluate(&labels, &tracks, &MatchConfig::default());
    println!("{}", matrix.report());
    Ok(())
}

fn cmd_benchmark(args: &[String]) -> CmdResult {
    let dir = require_one(args, "benchmark")?;
    let files = collect_gpx_files(Path::new(&dir))?;
    if files.is_empty() {
        return Err(format!("no .gpx files found in {dir}"));
    }

    let mut tracks: Vec<Track> = Vec::new();
    for file in &files {
        let raw = load_gpx(file)?;
        tracks.push(process(&raw).0);
    }
    let n = tracks.len();

    let start = Instant::now();
    let mut catalog = RouteCatalog::new(MatchConfig::default());
    for track in &tracks {
        catalog.add_track(track);
    }
    let discovery_ms = start.elapsed().as_secs_f64() * 1000.0;

    println!("benchmark   dir: {dir}");
    println!("──────────────────────────────────────────────");
    println!("Tracks loaded:      {n}");
    println!(
        "Discovery (all):    {:>10.3} ms   {} routes",
        discovery_ms,
        catalog.route_count()
    );

    // Pairwise matching on growing subsets (the O(n²) behaviour §34 warns about).
    for &subset in &[10_usize, 50, n] {
        if subset < 2 || subset > n {
            continue;
        }
        let slice = &tracks[..subset];
        let start = Instant::now();
        let mut matching = 0usize;
        for i in 0..slice.len() {
            for j in 0..slice.len() {
                if i != j
                    && compare_either_direction(&slice[i], &slice[j], &MatchConfig::default())
                        .is_some()
                {
                    matching += 1;
                }
            }
        }
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        let pairs = (subset * subset) as f64;
        println!(
            "Pairwise           {:>4}²: {:>10.3} ms   ({:.0} pairs/s, {} matched)",
            subset,
            ms,
            pairs / (ms / 1000.0),
            matching
        );
    }
    Ok(())
}
