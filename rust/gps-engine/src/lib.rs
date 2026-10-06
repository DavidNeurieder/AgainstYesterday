// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! A standalone GPS engine for track processing, route matching, and ghost
//! racing.
//!
//! The crate is intentionally pure and deterministic: the same input always
//! produces the same output, with no platform, network, or database
//! dependencies.
//!
//! The conceptual pipeline is:
//!
//! ```text
//! GPX → Track → process (filter / simplify / resample) → Route
//!     → Attempt → Performance → Ghost
//! ```
//!
//! Currently implemented: domain value types ([`units`]), the [`geo`]
//! primitives, the [`track`] model with construction-time validation and
//! processing, GPX input ([`gpx`]), synthetic generation ([`synthetic`]),
//! the [`route`] model with matching/discovery/canonicalization, the
//! [`attempt`] representation (GPS → route distance → elapsed time), and
//! race analysis ([`ghost`]).

#![deny(unsafe_code)]
#![deny(clippy::undocumented_unsafe_blocks)]
#![warn(missing_docs)]
#![warn(rust_2018_idioms)]

// Safety policy: the crate core is `unsafe`-free (denied). The single
// exception is the [`capi`] module, which must touch raw pointers at the
// FFI boundary; every unsafe block there carries a documented SAFETY note,
// enforced by `clippy::undocumented_unsafe_blocks`.

/// Typed errors produced by the engine.
pub mod error;

/// Raw GPS ingestion and per-sample quality (M15).
pub mod gps;

/// Geographic primitives: coordinates, distance, bearing, interpolation,
/// polylines, and projection.
pub mod geo;

/// GPS activity model: [`TrackPoint`] and validated [`Track`], plus track
/// statistics and processing (filtering, simplification, resampling).
pub mod track;

/// GPX track input: adapter from GPX XML documents to validated [`Track`]s.
pub mod gpx;

/// Canonical polyline routes with a stable distance axis.
pub mod route;

/// A recording reduced to the route axis: distance ↔ elapsed time, plus
/// pointwise performance comparison between two attempts.
pub mod attempt;

/// Race a live attempt against a reference (PB) attempt.
pub mod ghost;

/// `#[no_mangle] extern "C"` bridge for the Flutter app's FFI layer (M9).
#[allow(unsafe_code)]
#[cfg(not(doc))]
pub mod capi;

/// Synthetic GPS generation: deterministic test tracks from clean routes.
pub mod synthetic;

/// Standard processing pipeline and labeled-corpus evaluation (§33/§38–40).
pub mod evaluate;

/// Domain value types: [`Distance`], [`Duration`], [`Speed`], [`Timestamp`].
pub mod units;

pub use attempt::{
    Attempt, AttemptError, AttemptSample,
    performance::{
        ComparisonConfig, ComparisonPoint, PerformanceComparison, compare as compare_performances,
    },
};
pub use error::{GeoError, GpxError, RouteError, TrackError, TrackField};
pub use evaluate::{ConfusionMatrix, LabeledPair, evaluate, parse_manifest, standard_pipeline};
pub use geo::{Bearing, Coordinate, PolylineBounds, Projection};
pub use ghost::{Ghost, GhostSnapshot, GhostState};
pub use gps::{
    Fixture, GpsFix, GpsQuality, GpsTrace, ProcessedSample, RejectionReason, TrackProcessing,
};
pub use gpx::{parse_gpx, read_gpx, read_gpx_file, write_gpx, write_gpx_file};
pub use route::{
    CanonicalError, CanonicalizeConfig, ContinuityConfig, ContinuousProjection, DiscoveredRoute,
    MatchConfig, MatchScore, Route, RouteCatalog, RoutePoint, TrackAddition, canonicalize, compare,
    compare_either_direction, compare_with,
};
pub use track::{
    FilterConfig, FilterReason, MovingConfig, ProcessingReport, SimplifyConfig, Track, TrackPoint,
    filter, filter_detailed, resample_by_distance, simplify,
};
pub use units::{Distance, Duration, Speed, Timestamp};
