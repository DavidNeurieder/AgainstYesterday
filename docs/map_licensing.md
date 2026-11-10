# Map licensing, attribution and offline policy

The built-in map has three parts with separate obligations: the rendering
engine, the geographic data, and the tile service. This page records all three
so they are in-repo, not tribal knowledge.

## Renderer: MapLibre Native

The map is rendered by MapLibre Native through the `maplibre_gl` Dart plugin
(`app/pubspec.yaml`, currently 0.27.1), the engine behind Organic Maps.

- Engines / SDK: **BSD-3-Clause** (© MapLibre contributors).
- `maplibre_gl` is published on pub.dev by MapLibre.org; the license is
  declared in the package and in the resolved lockfile.

The app builds this renderer only when the `MAP_VIEW=true` dart-define selects
it (device builds); the default is the app's own self-contained painter, which
has no third-party obligations.

## Data: OpenStreetMap

The map data is OpenStreetMap and is licensed under the **Open Database
License (ODbL)**. That is why every map carries the attribution below and why
the app **does not bundle tiles** (see the offline policy).

## Tile service: OpenFreeMap by default

The default style document is OpenFreeMap's "Liberty" style
(`MapLibreStyles.openfreemapLiberty`, overridable at build time with
`MAP_STYLE_URL`), served over the network per map view.

- OpenFreeMap (FreeMap Initiative) serves tiles with the OpenMapTiles schema.
  The software is MIT; it is free, with no API key or account.
- Its terms allow reasonable personal use but prohibit **automated bulk
  collection**. The app honours that: an offline download only happens when the
  user opens a route or one of its runs, is per-route, size-capped, and one at
  a time — never a background sweep of the whole library (see below).

## Attribution

Map data must be attributed under ODbL; the tile terms repeat the same
attribution line. The app shows it in both places:

- on the map itself (MapLibre's attribution button, bottom-left), and
- in-app, outside the map: Settings → Map ("Map data © OpenStreetMap
  contributors (ODbL) · Tiles © OpenFreeMap / OpenMapTiles").

The canonical line used across the app is:

```
Map data © OpenStreetMap contributors (ODbL) · Tiles © OpenFreeMap / OpenMapTiles
```

## CLI HTML map (`gps-engine map`)

The engine's companion CLI can render GPX tracks to a standalone HTML page
(`cargo run --bin gps-engine -- map ...`, see the crate README). It uses the
same stack and carries the same obligations:

- **Renderer:** MapLibre GL JS, **BSD-3-Clause**, pinned to a release and
  loaded from unpkg when the page is opened (not bundled).
- **Data/tiles:** the same OpenFreeMap Liberty style and OpenStreetMap data as
  the app.
- **Attribution:** the canonical line above is rendered into the page footer
  with links, in addition to MapLibre's attribution control.
- **No bundled tiles:** the page fetches its library and tiles at view time.
  Without network it falls back to a plain background and still draws the
  tracks; `--style-url` points it at a self-hosted style document.

## Offline policy

Offline is **on-device, per-route downloads only**:

- Saved automatically the first time a route, one of its runs, a replay or a
  race is opened. One region per route, so every run of the same course shares
  the same local map; a ready region is never re-downloaded. The route detail
  card and Settings → Map report progress and offer delete with confirmation,
  and route detail keeps a retry control if a save failed.
- Browsing is the trigger: nothing is downloaded at startup or for routes the
  user has not opened, so the app never collects tiles in bulk.
- Size-capped by a client-side budget: `regionZoomFor` picks the highest zoom
  (12–15) whose estimated Web-Mercator tile count fits `kOfflineMaxTiles`, so a
  download stays a neighbourhood, not a region pack.
- One download per route at a time (overlapping requests are ignored).
- Metadata (the region list) survives restarts via the app's persistence
  store; the tiles themselves live in MapLibre Native's offline database.

**Recorded decision: no bundled starter region.** Shipping tiles inside the APK
would make the app a redistributor of OSM-derived data — ODbL share-alike plus
the tiles' no-bulk-redistribution terms — so the APK stays tile-free. A bundled
region would only be reconsidered from a self-hosted MBTiles extract with
attribution, as a separate decision.

## Self-hosting (the documented path for large-scale offline use)

For anything beyond per-route tiles, host your own tile server and point the
app at it:

- OpenFreeMap publishes the full planet weekly as MBTiles (MIT software, OSM
  ODbL data).
- Point the app at your server by overriding the style document at build time:
  `--dart-define=MAP_STYLE_URL=https://tiles.example.org/style.json` (the
  style document carries the tile URLs). Attribution to OSM is still required.