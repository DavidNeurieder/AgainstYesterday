// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Self-contained HTML map for inspecting tracks in a browser.
//!
//! [`render_map_html`] turns one or more tracks into a single HTML document
//! that overlays them on a real basemap with MapLibre GL JS. The document is
//! plain text: the engine itself never touches the network, while the page
//! fetches the MapLibre library and the OpenFreeMap style (OpenStreetMap data)
//! when it is opened. Map data stays attributed in the page, per
//! [`docs/map_licensing.md`](../../../docs/map_licensing.md).
//!
//! The output is deterministic: the same tracks and options always produce the
//! same bytes, so generated maps can be compared in tests.

use std::fmt;
use std::fmt::Write as _;

use crate::geo::{BoundingBox, Coordinate, bounding_box};
use crate::track::Track;
use crate::units::Duration;

/// Default MapLibre style document: OpenFreeMap's "Liberty" style.
///
/// The app's `MAP_STYLE_URL` defaults to the same document, so a CLI map and a
/// device map show the same cartography. Override it to point at a self-hosted
/// tile server.
pub const DEFAULT_MAP_STYLE_URL: &str = "https://tiles.openfreemap.org/styles/liberty";

/// Pinned MapLibre GL JS release (BSD-3-Clause) loaded by the generated page.
const MAPLIBRE_VERSION: &str = "5.13.0";

/// Track colours, cycled in order so overlays stay distinguishable.
const PALETTE: [&str; 10] = [
    "#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#008080", "#9a6324", "#800000",
    "#808000", "#000075",
];

/// One track drawn on the generated map.
#[derive(Debug, Clone, Copy)]
pub struct MapTrack<'a> {
    /// Legend label, usually the GPX file name.
    pub name: &'a str,
    /// Geometry to draw, in recording order.
    pub track: &'a Track,
}

impl<'a> MapTrack<'a> {
    /// Labels `track` with `name` for the map legend.
    pub fn new(name: &'a str, track: &'a Track) -> Self {
        MapTrack { name, track }
    }
}

/// Options for [`render_map_html`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MapOptions {
    /// Document and legend title.
    pub title: String,
    /// MapLibre style document URL; its tiles are fetched when the page opens.
    pub style_url: String,
}

impl Default for MapOptions {
    fn default() -> Self {
        MapOptions {
            title: "gps-engine map".to_string(),
            style_url: DEFAULT_MAP_STYLE_URL.to_string(),
        }
    }
}

/// Renders a standalone HTML page showing every track on a MapLibre basemap.
///
/// Each track gets its own colour, its start and finish are marked, and the
/// legend lists distance, duration, and point count. Clicking a line opens a
/// popup with the same summary. The page is fully self-contained apart from
/// the CDN library and the map tiles it loads at view time; when the style
/// cannot be fetched (an offline host) it falls back to a plain background so
/// the tracks are still drawn.
pub fn render_map_html(tracks: &[MapTrack<'_>], options: &MapOptions) -> String {
    let features: Vec<String> = tracks
        .iter()
        .enumerate()
        .map(|(index, map_track)| {
            feature_json(
                map_track.name,
                PALETTE[index % PALETTE.len()],
                map_track.track,
            )
        })
        .collect();
    let coordinates: Vec<Coordinate> = tracks
        .iter()
        .flat_map(|map_track| map_track.track.points().iter().map(|p| p.coordinate()))
        .collect();

    let mut html = String::with_capacity(4096 + coordinates.len() * 26);
    html.push_str("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n");
    html.push_str("<meta charset=\"utf-8\">\n");
    html.push_str("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n");
    push(
        &mut html,
        format_args!("<title>{}</title>\n", escape_html(&options.title)),
    );
    push(
        &mut html,
        format_args!(
            "<link rel=\"stylesheet\" href=\"https://unpkg.com/maplibre-gl@{MAPLIBRE_VERSION}/dist/maplibre-gl.css\">\n"
        ),
    );
    push(
        &mut html,
        format_args!(
            "<script src=\"https://unpkg.com/maplibre-gl@{MAPLIBRE_VERSION}/dist/maplibre-gl.js\"></script>\n"
        ),
    );
    html.push_str(STYLE);
    html.push_str("</head>\n<body>\n<div id=\"map\"></div>\n");
    html.push_str("<div id=\"notice\" hidden></div>\n");
    html.push_str("<div id=\"legend\">\n");
    push(
        &mut html,
        format_args!(
            "<div class=\"legend-title\">{}</div>\n",
            escape_html(&options.title)
        ),
    );
    for (index, map_track) in tracks.iter().enumerate() {
        let color = PALETTE[index % PALETTE.len()];
        let track = map_track.track;
        push(
            &mut html,
            format_args!(
                "<div class=\"track\"><span class=\"swatch\" style=\"background:{color}\"></span>\
                 <div><div class=\"track-name\">{}</div><div class=\"track-meta\">{} · {} · {} pts</div></div></div>\n",
                escape_html(map_track.name),
                track.distance(),
                format_duration(track.duration()),
                track.len(),
            ),
        );
    }
    html.push_str(
        "<div class=\"hint\">Lines: tracks · <span class=\"dot start\"></span> start · \
         <span class=\"dot finish\"></span> finish</div>\n</div>\n",
    );
    html.push_str(
        "<div id=\"attribution\">Map data © <a href=\"https://www.openstreetmap.org/copyright\">OpenStreetMap contributors</a> (ODbL) · Tiles © <a href=\"https://openfreemap.org/\">OpenFreeMap</a> / OpenMapTiles</div>\n",
    );
    html.push_str("<script>\n");
    push(
        &mut html,
        format_args!(
            "const ROUTES = {{\"type\":\"FeatureCollection\",\"features\":[{}]}};\n",
            features.join(",")
        ),
    );
    push(
        &mut html,
        format_args!("const ENDS = {};\n", ends_json(tracks)),
    );
    push(
        &mut html,
        format_args!("const BOUNDS = {};\n", bounds_json(&coordinates)),
    );
    push(
        &mut html,
        format_args!("const STYLE_URL = {};\n", json_string(&options.style_url)),
    );
    html.push_str(SCRIPT);
    html.push_str("</script>\n</body>\n</html>\n");
    html
}

/// Appends formatted text; writing to a `String` cannot fail.
fn push(out: &mut String, arguments: fmt::Arguments<'_>) {
    out.write_fmt(arguments)
        .expect("writing to a String cannot fail");
}

/// One GeoJSON feature per track: a LineString plus legend/popup properties.
fn feature_json(name: &str, color: &str, track: &Track) -> String {
    let mut json = String::with_capacity(96 + track.len() * 24);
    json.push_str("{\"type\":\"Feature\",\"properties\":{");
    push(
        &mut json,
        format_args!(
            "\"name\":{},\"color\":\"{color}\",\"distance\":{},\"duration\":{},\"points\":{}",
            json_string(name),
            json_string(&track.distance().to_string()),
            json_string(&format_duration(track.duration())),
            track.len(),
        ),
    );
    json.push_str("},\"geometry\":{\"type\":\"LineString\",\"coordinates\":[");
    for (index, point) in track.points().iter().enumerate() {
        if index > 0 {
            json.push(',');
        }
        let coordinate = point.coordinate();
        push(
            &mut json,
            format_args!(
                "[{:.6},{:.6}]",
                coordinate.longitude(),
                coordinate.latitude()
            ),
        );
    }
    json.push_str("]}}");
    json
}

/// Start and finish points, tagged so the JS can colour them differently.
fn ends_json(tracks: &[MapTrack<'_>]) -> String {
    let mut features = Vec::with_capacity(tracks.len() * 2);
    for map_track in tracks {
        if let (Some(start), Some(end)) = (map_track.track.start(), map_track.track.end()) {
            features.push(point_json(start.coordinate(), "start"));
            features.push(point_json(end.coordinate(), "finish"));
        }
    }
    format!(
        "{{\"type\":\"FeatureCollection\",\"features\":[{}]}}",
        features.join(",")
    )
}

fn point_json(coordinate: Coordinate, kind: &str) -> String {
    format!(
        "{{\"type\":\"Feature\",\"properties\":{{\"kind\":\"{kind}\"}},\
         \"geometry\":{{\"type\":\"Point\",\"coordinates\":[{:.6},{:.6}]}}}}",
        coordinate.longitude(),
        coordinate.latitude()
    )
}

/// MapLibre `bounds` argument, padded when every track overlaps a single point.
fn bounds_json(points: &[Coordinate]) -> String {
    let Some(bounds) = bounding_box(points) else {
        return "null".to_string();
    };
    let BoundingBox { min, max } = bounds;
    let (mut west, mut south) = (min.longitude(), min.latitude());
    let (mut east, mut north) = (max.longitude(), max.latitude());
    if (east - west).abs() < 1e-6 {
        west -= 5e-4;
        east += 5e-4;
    }
    if (north - south).abs() < 1e-6 {
        south -= 5e-4;
        north += 5e-4;
    }
    format!("[[{west:.6},{south:.6}],[{east:.6},{north:.6}]]")
}

/// `h:mm:ss`, or `m:ss` under an hour — the CLI's track summary format.
fn format_duration(duration: Duration) -> String {
    let total = duration.as_secs().max(0.0) as u64;
    let (hours, rest) = (total / 3600, total % 3600);
    let (minutes, seconds) = (rest / 60, rest % 60);
    if hours > 0 {
        format!("{hours}:{minutes:02}:{seconds:02}")
    } else {
        format!("{minutes:02}:{seconds:02}")
    }
}

/// Escapes text for an HTML text node or a double-quoted attribute.
fn escape_html(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            other => escaped.push(other),
        }
    }
    escaped
}

/// A JSON string literal, safe to embed in a `<script>` element.
///
/// Beyond the mandatory quotes/backslashes, `<`, `>`, `&` and the JavaScript
/// line separators are `\u`-escaped so a crafted file name can never close the
/// script block or smuggle markup into the page.
fn json_string(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len() + 2);
    escaped.push('"');
    for character in text.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            '<' => escaped.push_str("\\u003c"),
            '>' => escaped.push_str("\\u003e"),
            '&' => escaped.push_str("\\u0026"),
            '\u{2028}' => escaped.push_str("\\u2028"),
            '\u{2029}' => escaped.push_str("\\u2029"),
            control if control.is_control() => {
                push(&mut escaped, format_args!("\\u{:04x}", control as u32));
            }
            other => escaped.push(other),
        }
    }
    escaped.push('"');
    escaped
}

const STYLE: &str = r##"<style>
  html, body { margin: 0; height: 100%; }
  body {
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: #1b1b1b;
  }
  #map { position: absolute; inset: 0; background: #e8ecef; }
  #legend {
    position: absolute; top: 12px; right: 12px; z-index: 2;
    max-width: min(340px, 60vw); max-height: 60vh; overflow-y: auto;
    padding: 12px 14px; border-radius: 10px;
    background: rgba(255, 255, 255, 0.94);
    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.18);
    font-size: 13px;
  }
  .legend-title { font-weight: 700; font-size: 14px; margin-bottom: 8px; }
  .track {
    display: flex; gap: 8px; align-items: flex-start;
    padding: 5px 0; border-top: 1px solid rgba(0, 0, 0, 0.08);
  }
  .track:first-of-type { border-top: 0; }
  .swatch { flex: none; width: 12px; height: 12px; margin-top: 3px; border-radius: 3px; }
  .track-name { font-weight: 600; word-break: break-word; }
  .track-meta { color: #555; font-variant-numeric: tabular-nums; }
  .hint { margin-top: 10px; color: #555; font-size: 12px; }
  .dot {
    display: inline-block; width: 9px; height: 9px; border-radius: 50%;
    border: 2px solid #fff; box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.25);
    vertical-align: -1px;
  }
  .dot.start { background: #2e7d32; }
  .dot.finish { background: #c62828; }
  #notice {
    position: absolute; top: 12px; left: 50%; transform: translateX(-50%);
    z-index: 3; max-width: min(520px, 86vw); padding: 8px 12px;
    border-radius: 8px; background: rgba(255, 244, 214, 0.96);
    color: #4a3a00; font-size: 13px;
    box-shadow: 0 2px 10px rgba(0, 0, 0, 0.18);
  }
  #notice[hidden] { display: none; }
  #attribution {
    position: absolute; right: 8px; bottom: 8px; z-index: 2;
    padding: 4px 8px; border-radius: 6px;
    background: rgba(255, 255, 255, 0.9);
    color: #333; font-size: 11px;
  }
  #attribution a { color: inherit; }
  .popup-title { font-weight: 700; margin-bottom: 2px; }
</style>
"##;

const SCRIPT: &str = r##"const EMPTY_STYLE = {
  version: 8,
  sources: {},
  layers: [{ id: "background", type: "background", paint: { "background-color": "#eef1f4" } }],
};
const notice = document.getElementById("notice");

function showNotice(text) {
  notice.textContent = text;
  notice.hidden = false;
}

if (typeof maplibregl === "undefined") {
  showNotice("MapLibre GL JS could not be loaded (offline?). The routes are embedded in this file but cannot be drawn without it.");
} else {
  const options = { container: "map", style: STYLE_URL };
  if (BOUNDS) {
    options.bounds = BOUNDS;
    options.fitBoundsOptions = { padding: 64, maxZoom: 16 };
  } else {
    options.center = [0, 0];
    options.zoom = 1;
  }

  const map = new maplibregl.Map(options);
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-left");
  map.addControl(new maplibregl.ScaleControl({ unit: "metric" }), "bottom-left");

  let drawn = false;
  let fellBack = false;

  function draw() {
    if (drawn) return;
    drawn = true;
    map.addSource("routes", { type: "geojson", data: ROUTES });
    map.addLayer({
      id: "route-casing",
      type: "line",
      source: "routes",
      layout: { "line-join": "round", "line-cap": "round" },
      paint: { "line-color": "#ffffff", "line-width": 7, "line-opacity": 0.85 },
    });
    map.addLayer({
      id: "route-line",
      type: "line",
      source: "routes",
      layout: { "line-join": "round", "line-cap": "round" },
      paint: { "line-color": ["get", "color"], "line-width": 3.5 },
    });
    map.addSource("ends", { type: "geojson", data: ENDS });
    map.addLayer({
      id: "route-ends",
      type: "circle",
      source: "ends",
      paint: {
        "circle-radius": 5,
        "circle-color": ["match", ["get", "kind"], "start", "#2e7d32", "finish", "#c62828", "#616161"],
        "circle-stroke-color": "#ffffff",
        "circle-stroke-width": 2,
      },
    });
    map.on("click", "route-line", (event) => {
      const properties = event.features[0].properties;
      const body = document.createElement("div");
      const title = document.createElement("div");
      title.className = "popup-title";
      title.textContent = properties.name;
      const meta = document.createElement("div");
      meta.textContent = properties.distance + " · " + properties.duration + " · " + properties.points + " pts";
      body.append(title, meta);
      new maplibregl.Popup({ closeButton: false })
        .setLngLat(event.lngLat)
        .setDOMContent(body)
        .addTo(map);
    });
    map.on("mouseenter", "route-line", () => { map.getCanvas().style.cursor = "pointer"; });
    map.on("mouseleave", "route-line", () => { map.getCanvas().style.cursor = ""; });
  }

  map.on("load", draw);
  map.on("style.load", draw);
  map.on("error", (event) => {
    // A missing style document (offline machine) must not leave a blank page:
    // swap in a plain background once so the routes still render.
    if (drawn || fellBack || !event || !event.error) return;
    fellBack = true;
    showNotice("Basemap tiles are unavailable; showing routes on a plain background.");
    map.setStyle(EMPTY_STYLE);
  });
}
"##;
