// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Companion CLI end to end: `map` rendering and `benchmark` corpus loading.

use std::path::PathBuf;
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_gps-engine");
const FIXTURE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/unit/noisy_loop.gpx");
const UNIT_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/unit");

/// Valid GPX, but the second fix is older than the first: the engine rejects
/// the track as non-monotonic.
const BAD_GPX: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
  <trk><trkseg>
    <trkpt lat="52.5000" lon="13.4000"><time>2024-01-01T00:00:10Z</time></trkpt>
    <trkpt lat="52.5010" lon="13.4010"><time>2024-01-01T00:00:00Z</time></trkpt>
  </trkseg></trk>
</gpx>
"#;

fn temp_dir(label: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock after the epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "gps-engine-map-{label}-{}-{nanos}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).expect("temporary directory");
    dir
}

#[test]
fn writes_a_browser_page() {
    let dir = temp_dir("single");
    let out = dir.join("map.html");
    let output = Command::new(BIN)
        .args(["map", FIXTURE, "--out"])
        .arg(&out)
        .arg("--no-open")
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let html = std::fs::read_to_string(&out).expect("map written");
    assert!(html.contains("new maplibregl.Map"));
    assert!(html.contains("noisy_loop.gpx"));
    assert!(html.contains("\"geometry\":{\"type\":\"LineString\""));
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains(out.to_str().expect("utf-8 path")));
    assert!(!stdout.contains("Opening"), "{stdout}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[cfg(target_os = "linux")]
#[test]
fn opens_the_page_with_the_platform_opener() {
    use std::os::unix::fs::PermissionsExt;

    let dir = temp_dir("open");
    let out = dir.join("map.html");
    let marker = dir.join("opened.txt");
    let opener = dir.join("xdg-open");
    std::fs::write(
        &opener,
        format!(
            "#!/bin/sh\nprintf '%s' \"$1\" > '{}'\n",
            marker.to_str().expect("utf-8 path")
        ),
    )
    .expect("fake opener written");
    let mut permissions = std::fs::metadata(&opener)
        .expect("opener metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&opener, permissions).expect("opener executable");

    let path = format!(
        "{}:{}",
        dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let output = Command::new(BIN)
        .args(["map", FIXTURE, "--out"])
        .arg(&out)
        .env("PATH", path)
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(String::from_utf8_lossy(&output.stdout).contains("Opening"));

    // The opener is spawned asynchronously, so wait for its marker.
    let mut opened = None;
    for _ in 0..100 {
        if let Ok(value) = std::fs::read_to_string(&marker) {
            opened = Some(value);
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let opened = opened.expect("fake opener ran");
    assert!(opened.ends_with("map.html"), "opened {opened}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn accepts_a_directory_and_custom_title_and_style() {
    let dir = temp_dir("directory");
    let out = dir.join("map.html");
    let output = Command::new(BIN)
        .args(["map", UNIT_DIR, "--out"])
        .arg(&out)
        .args([
            "--title",
            "Unit tracks",
            "--style-url",
            "https://tiles.example.org/style.json",
            "--no-open",
        ])
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let html = std::fs::read_to_string(&out).expect("map written");
    assert!(html.contains("<title>Unit tracks</title>"));
    assert!(html.contains("const STYLE_URL = \"https://tiles.example.org/style.json\";"));
    assert!(html.contains("\"name\":\"straight.gpx\""));
    assert!(html.contains("\"name\":\"noisy_loop.gpx\""));
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn skips_unreadable_files_and_still_writes_the_map() {
    let dir = temp_dir("partial");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");
    let out = dir.join("map.html");

    let output = Command::new(BIN)
        .args(["map", dir.to_str().expect("utf-8 path"), "--out"])
        .arg(&out)
        .arg("--no-open")
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(stderr.contains("monotonic ordering"), "{stderr}");
    assert!(stderr.contains("(skipped)"), "{stderr}");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Tracks       1"), "{stdout}");
    assert!(
        stdout.contains("Skipped      1 unreadable file(s)"),
        "{stdout}"
    );

    let html = std::fs::read_to_string(&out).expect("map written");
    assert!(html.contains("\"name\":\"good.gpx\""));
    assert!(!html.contains("out-of-order.gpx"));
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn unreadable_directory_fails_when_no_track_parsed() {
    let dir = temp_dir("all-bad");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let output = Command::new(BIN)
        .arg("map")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(
        stderr.contains("no usable GPX tracks in 1 file(s)"),
        "{stderr}"
    );
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn benchmark_skips_unreadable_recordings() {
    let dir = temp_dir("benchmark-partial");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let output = Command::new(BIN)
        .arg("benchmark")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(stderr.contains("(skipped)"), "{stderr}");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("Tracks loaded:      1"), "{stdout}");
    assert!(stdout.contains("Skipped files:      1"), "{stdout}");
    assert!(stdout.contains("Discovery (all):"), "{stdout}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn benchmark_fails_when_no_track_parsed() {
    let dir = temp_dir("benchmark-bad");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let output = Command::new(BIN)
        .arg("benchmark")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(
        stderr.contains("no usable GPX tracks in 1 file(s)"),
        "{stderr}"
    );
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn discover_skips_unreadable_recordings() {
    let dir = temp_dir("discover-partial");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let output = Command::new(BIN)
        .arg("discover")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(stderr.contains("(skipped)"), "{stderr}");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("NEW route #0"), "{stdout}");
    assert!(
        stdout.contains("Discovered  1 routes from 1 tracks"),
        "{stdout}"
    );
    assert!(stdout.contains("Skipped files:      1"), "{stdout}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn discover_fails_when_no_track_parsed() {
    let dir = temp_dir("discover-bad");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let output = Command::new(BIN)
        .arg("discover")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(
        stderr.contains("no usable GPX tracks in 1 file(s)"),
        "{stderr}"
    );
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn group_copies_tracks_into_per_route_folders() {
    let dir = temp_dir("group-partial");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let out = temp_dir("group-out");
    let output = Command::new(BIN)
        .args(["group"])
        .arg(&dir)
        .arg(&out)
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("out-of-order.gpx"), "{stderr}");
    assert!(stderr.contains("(skipped)"), "{stderr}");

    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.contains("Grouped      1 tracks into 1 routes"),
        "{stdout}"
    );
    assert!(stdout.contains("Skipped files:      1"), "{stdout}");

    assert!(out.join("route_0").join("good.gpx").is_file(), "{out:?}");
    // Source is left in place (copy, not move).
    assert!(dir.join("good.gpx").is_file());

    std::fs::remove_dir_all(dir).expect("cleanup");
    std::fs::remove_dir_all(out).expect("cleanup");
}

#[test]
fn group_fails_when_no_track_parsed() {
    let dir = temp_dir("group-bad");
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");

    let out = temp_dir("group-bad-out");
    let output = Command::new(BIN)
        .args(["group"])
        .arg(&dir)
        .arg(&out)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("no usable GPX tracks in 1 file(s)"),
        "{stderr}"
    );
    std::fs::remove_dir_all(dir).expect("cleanup");
    std::fs::remove_dir_all(out).expect("cleanup");
}

#[test]
fn group_accepts_out_flag_and_move() {
    let dir = temp_dir("group-move");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");

    let out = temp_dir("group-move-out");
    let output = Command::new(BIN)
        .args(["group"])
        .arg(&dir)
        .args(["--out"])
        .arg(&out)
        .arg("--move")
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(out.join("route_0").join("good.gpx").is_file());
    assert!(!dir.join("good.gpx").exists(), "moved, not copied");
    std::fs::remove_dir_all(dir).expect("cleanup");
    std::fs::remove_dir_all(out).expect("cleanup");
}

#[test]
fn evaluate_loads_only_the_recordings_its_manifest_labels() {
    let dir = temp_dir("evaluate-referenced");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    // Unreferenced and unreadable: must not affect the run.
    std::fs::write(dir.join("out-of-order.gpx"), BAD_GPX).expect("bad fixture written");
    std::fs::write(
        dir.join("manifest.json"),
        r#"{"matches":[{"a":"good.gpx","b":"good.gpx","expected":"same"}]}"#,
    )
    .expect("manifest written");

    let output = Command::new(BIN)
        .arg("evaluate")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).is_empty(),
        "unreferenced files are not parsed at all"
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(stdout.contains("1 labeled pairs, 1 tracks"), "{stdout}");
    let true_positives = stdout
        .lines()
        .find_map(|line| line.strip_prefix("true positives:"))
        .expect("report lists true positives");
    assert_eq!(true_positives.trim(), "1", "{stdout}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn evaluate_names_a_missing_referenced_track() {
    let dir = temp_dir("evaluate-missing-track");
    std::fs::copy(FIXTURE, dir.join("good.gpx")).expect("fixture copied");
    std::fs::write(
        dir.join("manifest.json"),
        r#"{"matches":[{"a":"good.gpx","b":"absent.gpx","expected":"same"}]}"#,
    )
    .expect("manifest written");

    let output = Command::new(BIN)
        .arg("evaluate")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("absent.gpx"), "{stderr}");
    std::fs::remove_dir_all(dir).expect("cleanup");
}

#[test]
fn prints_the_document_to_stdout_with_dash() {
    let output = Command::new(BIN)
        .args(["map", FIXTURE, "--out", "-"])
        .output()
        .expect("binary runs");

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let html = String::from_utf8(output.stdout).expect("utf-8 HTML");
    assert!(html.starts_with("<!DOCTYPE html>"));
    assert!(html.ends_with("</html>\n"));
    assert!(!html.contains("Wrote"));
}

#[test]
fn missing_input_is_a_clear_error() {
    let output = Command::new(BIN).arg("map").output().expect("binary runs");

    assert!(!output.status.success());
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("map needs at least one GPX file or directory"));
}

#[test]
fn unknown_flag_is_rejected() {
    let output = Command::new(BIN)
        .args(["map", FIXTURE, "--colour", "red"])
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("unknown argument: --colour"));
}

#[test]
fn missing_directory_has_no_gpx_files() {
    let dir = temp_dir("empty");
    let output = Command::new(BIN)
        .arg("map")
        .arg(&dir)
        .output()
        .expect("binary runs");

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("no .gpx files found"));
    std::fs::remove_dir_all(dir).expect("cleanup");
}
