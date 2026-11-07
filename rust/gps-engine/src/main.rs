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
//! gps-engine map     a.gpx [more.gpx|dirs...]
//! gps-engine discover ./tracks/
//! gps-engine evaluate ./testdata/synthetic/
//! gps-engine benchmark ./tracks/
//! ```
//!
//! This binary orchestrates the (pure, deterministic) library; only the
//! benchmark uses wall-clock time.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

use gps_engine::{
    DEFAULT_MAP_STYLE_URL, Distance, FilterConfig, MapOptions, MapTrack, MatchConfig, MatchScore,
    PreparedTrack, ProcessingReport, RouteCatalog, SimplifyConfig, Track, compare_either_direction,
    compare_either_direction_prepared, compare_segments, compare_with, filter, read_gpx_file,
    render_map_html, resample_by_distance, simplify, write_gpx_file,
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
        "map" => cmd_map(&args[2..]),
        "discover" => cmd_discover(&args[2..]),
        "evaluate" => cmd_evaluate(&args[2..]),
        "benchmark" => cmd_benchmark(&args[2..]),
        "group" | "organize" | "cluster" | "arrange" | "partition" | "bucket" => {
            cmd_group(&args[2..])
        }
        "segments" | "sections" | "segment" | "section" => cmd_segments(&args[2..]),
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
  gps-engine map        file.gpx [more.gpx|dirs...] [--out map.html] [--no-open]
  gps-engine discover   ./tracks/
  gps-engine group      file.gpx [more.gpx|dirs...] [--out dir] [--move]
  gps-engine segments   file.gpx [more.gpx|dirs...] [--segments N]
  gps-engine evaluate   ./testdata/synthetic/
  gps-engine benchmark  ./tracks/

`map` writes a self-contained HTML page that overlays the tracks on a
MapLibre basemap (OpenStreetMap data, fetched when the page is opened) and
hands it to the default browser. Files that cannot be read as a valid track
are reported and skipped, so one bad recording does not hide the rest.
Pass `--out -` to print the document to stdout, `--no-open` to skip the
browser, `--title` to set the page title, and `--style-url` to use a
different style document. `benchmark` and `discover` report and skip unreadable
recordings the same way, so one bad file never hides the rest of the corpus. `group` clusters the corpus the same way and copies each recording into `<out>/route_<id>/`, so tracks on the same route end up in the same folder (`--move` to move instead of copy)."#
    );
}

type CmdResult = Result<(), String>;

/// Matching pipeline used by `compare`/`discover`/`evaluate`/`benchmark`:
/// denoise with the run/ride profile so matching always sees comparable
/// geometry, then simplify and resample to a 25 m cadence.
fn process(track: &Track) -> (Track, ProcessingReport) {
    pipeline(track, &FilterConfig::matching())
}

/// Recording pipeline for the `process` command: keep the engine's general
/// plausibility (cars and trains included) so a fast track is cleaned, not
/// collapsed to its endpoints.
fn process_recording(track: &Track) -> (Track, ProcessingReport) {
    pipeline(track, &FilterConfig::default())
}

fn pipeline(track: &Track, config: &FilterConfig) -> (Track, ProcessingReport) {
    let (filtered, report) = filter(track, config);
    let simplified = simplify(&filtered, &SimplifyConfig::default());
    let resampled = resample_by_distance(&simplified, Distance::from_meters(25.0))
        .expect("resampling a processed track keeps it valid");
    (resampled, report)
}

fn load_gpx(path: &Path) -> Result<Track, String> {
    read_gpx_file(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// Loads every readable GPX file, reporting unreadable recordings on stderr.
///
/// A single malformed file must not sink a whole corpus command, so the caller
/// gets the tracks that did parse plus the number of files skipped.
fn load_tracks_lenient(files: &[PathBuf]) -> (Vec<(PathBuf, Track)>, usize) {
    let mut loaded = Vec::with_capacity(files.len());
    let mut skipped = 0usize;
    for file in files {
        match load_gpx(file) {
            Ok(track) => loaded.push((file.clone(), track)),
            Err(message) => {
                eprintln!("warning: {message} (skipped)");
                skipped += 1;
            }
        }
    }
    (loaded, skipped)
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
    let (processed, report) = process_recording(&raw);

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

/// Parsed arguments for `map`.
struct MapArgs {
    inputs: Vec<String>,
    out: Option<String>,
    title: Option<String>,
    style_url: Option<String>,
    no_open: bool,
}

fn cmd_map(args: &[String]) -> CmdResult {
    let parsed = parse_map_args(args)?;
    let files = collect_map_files(&parsed.inputs)?;

    let mut loaded: Vec<(String, Track)> = Vec::with_capacity(files.len());
    let (parsed_tracks, skipped) = load_tracks_lenient(&files);
    for (file, track) in parsed_tracks {
        let file_name = file
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| file.display().to_string());
        let label = if loaded.iter().any(|(name, _)| name == &file_name) {
            file.display().to_string()
        } else {
            file_name
        };
        loaded.push((label, track));
    }
    if loaded.is_empty() {
        return Err(format!("no usable GPX tracks in {} file(s)", files.len()));
    }

    let map_tracks: Vec<MapTrack<'_>> = loaded
        .iter()
        .map(|(name, track)| MapTrack::new(name, track))
        .collect();
    let options = MapOptions {
        title: parsed.title.unwrap_or_else(|| default_map_title(&loaded)),
        style_url: parsed
            .style_url
            .unwrap_or_else(|| DEFAULT_MAP_STYLE_URL.to_string()),
    };
    let html = render_map_html(&map_tracks, &options);
    let out = parsed
        .out
        .unwrap_or_else(|| default_map_out(&parsed.inputs));

    if out == "-" {
        print!("{html}");
        return Ok(());
    }
    std::fs::write(&out, html).map_err(|e| format!("{out}: {e}"))?;
    println!("Wrote        {out}");
    println!("Tracks       {}", loaded.len());
    if skipped > 0 {
        println!("Skipped      {skipped} unreadable file(s)");
    }
    if !parsed.no_open {
        match open_in_browser(Path::new(&out)) {
            Ok(()) => println!("Opening      {out}"),
            Err(message) => eprintln!("warning: could not open {out}: {message}"),
        }
    }
    Ok(())
}

/// Hands the generated page to the default browser of the host platform.
///
/// The opener is spawned without waiting: `xdg-open` (and its macOS/Windows
/// equivalents) must not keep the CLI or a calling script alive. Opening is a
/// convenience, not part of the output: a missing opener is reported as a
/// warning and the successfully written page stays usable.
fn open_in_browser(path: &Path) -> Result<(), String> {
    let target = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(&target);
        command
    };
    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("cmd");
        // `start` treats the first quoted argument as a window title.
        command.args(["/C", "start", ""]).arg(&target);
        command
    };
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(&target);
        command
    };

    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

fn parse_map_args(args: &[String]) -> Result<MapArgs, String> {
    let mut parsed = MapArgs {
        inputs: Vec::new(),
        out: None,
        title: None,
        style_url: None,
        no_open: false,
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--out" => parsed.out = Some(map_flag_value(args, &mut index, "--out")?),
            "--title" => parsed.title = Some(map_flag_value(args, &mut index, "--title")?),
            "--style-url" => {
                parsed.style_url = Some(map_flag_value(args, &mut index, "--style-url")?)
            }
            "--no-open" => parsed.no_open = true,
            flag if flag.starts_with('-') => return Err(format!("unknown argument: {flag}")),
            input => parsed.inputs.push(input.to_string()),
        }
        index += 1;
    }
    if parsed.inputs.is_empty() {
        return Err("map needs at least one GPX file or directory".to_string());
    }
    Ok(parsed)
}

fn map_flag_value(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    let value = args
        .get(*index + 1)
        .ok_or_else(|| format!("{flag} needs a value"))?;
    *index += 1;
    Ok(value.clone())
}

/// Expands files and directories into the GPX files to draw.
fn collect_map_files(inputs: &[String]) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    for input in inputs {
        let path = Path::new(input);
        if path.is_dir() {
            let found = collect_gpx_files(path)?;
            if found.is_empty() {
                return Err(format!("no .gpx files found in {input}"));
            }
            files.extend(found);
        } else {
            if !path.exists() {
                return Err(format!("{input}: no such file or directory"));
            }
            files.push(path.to_path_buf());
        }
    }
    Ok(files)
}

/// `run.gpx` for a single input, otherwise `map.html` in the current directory.
fn default_map_out(inputs: &[String]) -> String {
    if let [only] = inputs {
        let path = Path::new(only);
        if path.is_file() {
            return path.with_extension("html").display().to_string();
        }
    }
    "map.html".to_string()
}

fn default_map_title(loaded: &[(String, Track)]) -> String {
    match loaded {
        [(name, _)] => format!("{name} · gps-engine map"),
        _ => format!("gps-engine map · {} tracks", loaded.len()),
    }
}

fn cmd_discover(args: &[String]) -> CmdResult {
    let dir = require_one(args, "discover")?;
    let files = collect_gpx_files(Path::new(&dir))?;
    if files.is_empty() {
        return Err(format!("no .gpx files found in {dir}"));
    }

    let (parsed, skipped) = load_tracks_lenient(&files);
    if parsed.is_empty() {
        return Err(format!("no usable GPX tracks in {} file(s)", files.len()));
    }

    let mut catalog = RouteCatalog::new(MatchConfig::default());
    for (file, raw) in &parsed {
        let (processed, _) = process(raw);
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
        parsed.len()
    );
    if skipped > 0 {
        println!("Skipped files:      {skipped}");
    }
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

/// Groups GPX recordings into one subdirectory per discovered route.
///
/// Tracks that cluster to the same route land in the same output folder
/// (`<out>/route_<id>/`), so a corpus can be browsed or re-processed route
/// by route. Unreadable recordings are reported and skipped.
fn cmd_group(args: &[String]) -> CmdResult {
    let parsed = parse_group_args(args)?;
    let files = collect_map_files(&parsed.inputs)?;
    if files.is_empty() {
        return Err("no .gpx files found in the given inputs".to_string());
    }

    let (loaded, skipped) = load_tracks_lenient(&files);
    if loaded.is_empty() {
        return Err(format!("no usable GPX tracks in {} file(s)", files.len()));
    }

    let mut catalog = RouteCatalog::new(MatchConfig::default());
    let mut assignments: Vec<(PathBuf, usize)> = Vec::with_capacity(loaded.len());
    for (file, raw) in &loaded {
        let (processed, _) = process(raw);
        let addition = catalog.add_track(&processed);
        assignments.push((file.clone(), addition.route_id));
    }

    let out = parsed.out.clone().unwrap_or_else(|| "grouped".to_string());
    let out_path = Path::new(&out);
    std::fs::create_dir_all(out_path).map_err(|e| format!("{out}: {e}"))?;

    // Keep track of destination names per route so two recordings that share
    // a basename do not overwrite each other.
    let mut used: std::collections::HashMap<usize, std::collections::HashSet<String>> =
        std::collections::HashMap::new();

    for (file, route_id) in &assignments {
        let route_dir = out_path.join(format!("route_{}", route_id));
        std::fs::create_dir_all(&route_dir).map_err(|e| format!("{}: {e}", route_dir.display()))?;

        let base = file
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| format!("track_{}.gpx", route_id));

        let names = used.entry(*route_id).or_default();
        let dest_name = if names.contains(&base) {
            let stem = Path::new(&base)
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "track".to_string());
            let ext = Path::new(&base)
                .extension()
                .map(|e| format!(".{}", e.to_string_lossy()))
                .unwrap_or_default();
            let mut i = 1usize;
            loop {
                let candidate = format!("{}_{}{}", stem, i, ext);
                if !names.contains(&candidate) {
                    break candidate;
                }
                i += 1;
            }
        } else {
            base
        };
        names.insert(dest_name.clone());

        let dest = route_dir.join(&dest_name);
        if parsed.move_files {
            if std::fs::rename(file, &dest).is_err() {
                std::fs::copy(file, &dest).map_err(|e| format!("{}: {e}", dest.display()))?;
                let _ = std::fs::remove_file(file);
            }
        } else {
            std::fs::copy(file, &dest).map_err(|e| format!("{}: {e}", dest.display()))?;
        }
    }

    println!(
        "Grouped      {} tracks into {} routes in {}",
        loaded.len(),
        catalog.route_count(),
        out
    );
    if skipped > 0 {
        println!("Skipped files:      {skipped}");
    }
    Ok(())
}

#[derive(Debug)]
struct GroupArgs {
    inputs: Vec<String>,
    out: Option<String>,
    move_files: bool,
}

fn parse_group_args(args: &[String]) -> Result<GroupArgs, String> {
    let mut parsed = GroupArgs {
        inputs: Vec::new(),
        out: None,
        move_files: false,
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--out" | "--output" | "-o" => {
                parsed.out = Some(group_flag_value(args, &mut index, "--out")?)
            }
            "--move" => parsed.move_files = true,
            "--copy" => parsed.move_files = false,
            flag if flag.starts_with('-') => return Err(format!("unknown argument: {flag}")),
            value => parsed.inputs.push(value.to_string()),
        }
        index += 1;
    }

    // Allow `group <input> <output>` without a flag, mirroring common
    // invocations of file-organising tools.
    if parsed.out.is_none() && parsed.inputs.len() >= 2 {
        let last = parsed.inputs.last().cloned().unwrap();
        let last_path = std::path::Path::new(&last);
        let treat_as_output =
            last_path.is_dir() || !last_path.exists() || last_path.extension().is_none();
        // A trailing directory or extensionless path is the destination.
        if treat_as_output {
            parsed.out = Some(parsed.inputs.pop().unwrap());
        }
    }

    if parsed.inputs.is_empty() {
        return Err("group needs at least one GPX file or directory".to_string());
    }
    Ok(parsed)
}

fn group_flag_value(args: &[String], index: &mut usize, flag: &str) -> Result<String, String> {
    let value = args
        .get(*index + 1)
        .ok_or_else(|| format!("{flag} needs a value"))?;
    *index += 1;
    Ok(value.clone())
}
/// Splits a group of tracks into equal-distance sections and compares the
/// per-section speeds (and elevation) across them.
fn cmd_segments(args: &[String]) -> CmdResult {
    let parsed = parse_segments_args(args)?;
    let files = collect_map_files(&parsed.inputs)?;
    if files.is_empty() {
        return Err("no .gpx files found in the given inputs".to_string());
    }

    let (loaded, skipped) = load_tracks_lenient(&files);
    if loaded.is_empty() {
        return Err(format!("no usable GPX tracks in {} file(s)", files.len()));
    }

    let tracks: Vec<Track> = loaded.iter().map(|(_, raw)| process(raw).0).collect();

    let segments = if let Some(d) = parsed.distance {
        let min_len = tracks
            .iter()
            .map(|t| {
                let pts = t.points();
                let mut cum = 0.0f64;
                for i in 1..pts.len() {
                    cum += gps_engine::geo::distance(pts[i - 1].coordinate(), pts[i].coordinate()).meters();
                }
                cum
            })
            .fold(f64::INFINITY, f64::min);
        if !min_len.is_finite() || min_len <= 0.0 {
            return Err("tracks have zero length".to_string());
        }
        ((min_len / d).ceil() as usize).max(1)
    } else {
        parsed.segments
    };

    let comparison = compare_segments(&tracks, segments).map_err(|e| e.to_string())?;

    println!(
        "Segments     {} sections across {} tracks",
        segments,
        tracks.len()
    );
    if skipped > 0 {
        println!("Skipped files:      {skipped}");
    }
    println!("──────────────────────────────────────────────");
    print!("{:>4}  {:>10}  {:>10}", "sec", "start", "end");
    for i in 0..tracks.len() {
        print!("  {:>9}", format!("track{}", i));
    }
    println!("  {:>9}  {:>9}  {:>9}", "min", "max", "spread");
    for c in &comparison {
        print!(
            "{:>4}  {:>10}  {:>10}",
            c.index,
            format!("{:.0}m", c.start_distance.meters()),
            format!("{:.0}m", c.end_distance.meters())
        );
        for s in &c.segments {
            print!("  {:>8.2}kmh", s.average_speed.kmh());
        }
        print!(
            "  {:>8.2}  {:>8.2}  {:>8.2}",
            c.min_speed.kmh(),
            c.max_speed.kmh(),
            c.speed_spread.kmh()
        );
        println!();
    }
    Ok(())
}

#[derive(Debug)]
struct SegmentsArgs {
    inputs: Vec<String>,
    segments: usize,
    distance: Option<f64>,
}

fn parse_segments_args(args: &[String]) -> Result<SegmentsArgs, String> {
    let mut parsed = SegmentsArgs {
        inputs: Vec::new(),
        segments: 5,
        distance: None,
    };
    let mut index = 0;
    while index < args.len() {
        match args[index].as_str() {
            "--segments" | "--sections" | "-n" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| "--segments needs a value".to_string())?;
                parsed.segments = value
                    .parse()
                    .map_err(|_| format!("invalid segment count: {value}"))?;
                if parsed.segments == 0 {
                    return Err("segments must be greater than zero".to_string());
                }
                index += 1;
            }
            "--distance" | "--segment-distance" => {
                let value = args
                    .get(index + 1)
                    .ok_or_else(|| "--distance needs a value".to_string())?;
                let d: f64 = value
                    .parse()
                    .map_err(|_| format!("invalid segment distance: {value}"))?;
                if d <= 0.0 {
                    return Err("segment distance must be greater than zero".to_string());
                }
                if parsed.distance.is_some() {
                    return Err("specify either --segments or --distance, not both".to_string());
                }
                parsed.distance = Some(d);
                index += 1;
            }
            flag if flag.starts_with('-') => return Err(format!("unknown argument: {flag}")),
            value => parsed.inputs.push(value.to_string()),
        }
        index += 1;
    }
    if parsed.inputs.is_empty() {
        return Err("segments needs at least one GPX file or directory".to_string());
    }
    Ok(parsed)
}

fn cmd_evaluate(args: &[String]) -> CmdResult {
    let dir = require_one(args, "evaluate")?;
    let root = Path::new(&dir);
    let manifest_path = root.join("manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path).map_err(|e| {
        format!(
            "{}: {e}\n\
             hint: `evaluate` scores a *labeled* corpus: a manifest.json next to the tracks \
             lists pairs as {{\"a\": \"clean.gpx\", \"b\": \"noisy.gpx\", \"expected\": \
             \"same\"|\"different\"}} (example: rust/gps-engine/testdata/synthetic/manifest.json). \
             For an unlabeled directory use `discover`, `benchmark`, or `map` instead.",
            manifest_path.display()
        )
    })?;
    let labels = gps_engine::parse_manifest(&manifest_text)?;

    // Only the recordings the manifest labels are needed: an unreadable file
    // that no pair references must not sink the run, and a large corpus should
    // not be parsed just to score a handful of pairs. Referenced recordings
    // stay strict — silently dropping one would corrupt the confusion matrix.
    let mut tracks: std::collections::HashMap<String, Track> = std::collections::HashMap::new();
    for pair in &labels {
        for name in [&pair.a, &pair.b] {
            if tracks.contains_key(name) {
                continue;
            }
            let raw = load_gpx(&root.join(name))?;
            tracks.insert(name.clone(), process(&raw).0);
        }
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

    let (parsed, skipped) = load_tracks_lenient(&files);
    if parsed.is_empty() {
        return Err(format!("no usable GPX tracks in {} file(s)", files.len()));
    }
    let tracks: Vec<Track> = parsed.iter().map(|(_, raw)| process(raw).0).collect();
    let n = tracks.len();
    let config = MatchConfig::default();
    // Index every track's geometry once: the benchmark compares each recording
    // against many others, so rebuilding the polyline index per pair would
    // dominate the measurement.
    let prepared: Vec<PreparedTrack> = tracks.iter().map(PreparedTrack::new).collect();

    let start = Instant::now();
    let mut catalog = RouteCatalog::new(config);
    for track in &tracks {
        catalog.add_track(track);
    }
    let discovery_ms = start.elapsed().as_secs_f64() * 1000.0;

    println!("benchmark   dir: {dir}");
    println!("──────────────────────────────────────────────");
    println!("Tracks loaded:      {n}");
    if skipped > 0 {
        println!("Skipped files:      {skipped}");
    }
    if cfg!(debug_assertions) {
        println!("Note:               debug build — `cargo run --release` is about 10x faster");
    }
    println!(
        "Discovery (all):    {:>10.3} ms   {} routes",
        discovery_ms,
        catalog.route_count()
    );

    // Pairwise matching on growing subsets (the O(n²) behaviour §34 warns about).
    // Each unordered pair is compared once, in both travel orientations.
    for &subset in &[10_usize, 50, n] {
        if subset < 2 || subset > n {
            continue;
        }
        let slice = &tracks[..subset];
        let prepared_slice = &prepared[..subset];
        let start = Instant::now();
        let mut matching = 0usize;
        for i in 0..slice.len() {
            for j in (i + 1)..slice.len() {
                if compare_either_direction_prepared(
                    &prepared_slice[i],
                    &prepared_slice[j],
                    &slice[j],
                    &config,
                )
                .is_some()
                {
                    matching += 1;
                }
            }
        }
        let ms = start.elapsed().as_secs_f64() * 1000.0;
        let pairs = (subset * (subset - 1) / 2) as f64;
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
