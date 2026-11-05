// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! HTML map rendering: embedded geometry, bounds, escaping, determinism.

use gps_engine::{
    DEFAULT_MAP_STYLE_URL, MapOptions, MapTrack, Track, read_gpx_file, render_map_html,
};

const MANIFEST_DIR: &str = env!("CARGO_MANIFEST_DIR");

fn load(name: &str) -> Track {
    read_gpx_file(format!("{MANIFEST_DIR}/testdata/unit/{name}")).unwrap()
}

#[test]
fn embeds_every_track_and_its_geometry() {
    let looped = load("noisy_loop.gpx");
    let straight = load("straight.gpx");
    let html = render_map_html(
        &[
            MapTrack::new("loop", &looped),
            MapTrack::new("straight run", &straight),
        ],
        &MapOptions::default(),
    );

    assert!(html.starts_with("<!DOCTYPE html>"));
    assert!(html.contains("new maplibregl.Map"));
    assert!(html.contains("https://unpkg.com/maplibre-gl@5.13.0/dist/maplibre-gl.js"));
    assert!(html.contains("const STYLE_URL = \"https://tiles.openfreemap.org/styles/liberty\";"));
    assert!(html.contains("\"color\":\"#e6194b\""));
    assert!(html.contains("\"name\":\"loop\""));
    assert!(html.contains("\"name\":\"straight run\""));
    assert!(html.contains("[13.400000,52.500000]"));
    assert!(html.contains("277.14 m · 02:00 · 6 pts"));
    assert!(html.contains("\"kind\":\"start\""));
    assert!(html.contains("\"kind\":\"finish\""));
    assert!(html.contains("const BOUNDS = [[13.4"));
    assert!(html.contains("OpenStreetMap contributors"));
    assert!(html.contains("OpenFreeMap</a> / OpenMapTiles"));
    assert_eq!(
        DEFAULT_MAP_STYLE_URL,
        "https://tiles.openfreemap.org/styles/liberty"
    );
}

#[test]
fn rendering_is_deterministic() {
    let track = load("noisy_loop.gpx");
    let tracks = [MapTrack::new("loop", &track)];
    let options = MapOptions::default();
    assert_eq!(
        render_map_html(&tracks, &options),
        render_map_html(&tracks, &options)
    );
}

#[test]
fn empty_track_list_still_renders_a_page() {
    let html = render_map_html(&[], &MapOptions::default());
    assert!(html.contains("const ROUTES = {\"type\":\"FeatureCollection\",\"features\":[]};"));
    assert!(html.contains("const BOUNDS = null;"));
    assert!(html.contains("<title>gps-engine map</title>"));
}

#[test]
fn track_names_and_titles_are_escaped() {
    let track = load("straight.gpx");
    let hostile = "</script><img src=x onerror=alert(1)> & \"quoted\"";
    let html = render_map_html(
        &[MapTrack::new(hostile, &track)],
        &MapOptions {
            title: hostile.to_string(),
            style_url: "https://tiles.example.org/style.json?key=1&kind=2".to_string(),
        },
    );

    // Markup in the legend is inert text...
    assert!(!html.contains("<img src=x"));
    assert!(!html.contains("onerror=alert(1)>"));
    assert!(html.contains("&lt;/script&gt;&lt;img"));
    // ...and in the embedded JSON it cannot terminate the script element.
    assert!(html.contains("\\u003c/script\\u003e"));
    assert!(html.contains("\\u0026 \\\"quoted\\\""));
    assert!(html.contains("<title>&lt;/script&gt;"));
    // Query separators in the style URL stay inside the JSON string.
    assert!(html.contains(
        "const STYLE_URL = \"https://tiles.example.org/style.json?key=1\\u0026kind=2\";"
    ));
}

#[test]
fn custom_style_url_is_embedded() {
    let track = load("straight.gpx");
    let html = render_map_html(
        &[MapTrack::new("run", &track)],
        &MapOptions {
            title: "Unit map".to_string(),
            style_url: "https://tiles.example.org/style.json".to_string(),
        },
    );
    assert!(html.contains("<title>Unit map</title>"));
    assert!(html.contains("const STYLE_URL = \"https://tiles.example.org/style.json\";"));
    assert!(!html.contains("tiles.openfreemap.org/styles/liberty"));
}
