// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use std::path::PathBuf;

use pyo3::exceptions::{PyIndexError, PyValueError};
use pyo3::prelude::*;
use pyo3::types::{PyFloat, PyModule, PyString, PyType};

use gps_engine::analytics::{
    AnalyticsQuality as RustAnalyticsQuality, TrackAnalytics as RustTrackAnalytics,
};
use gps_engine::geo::Bearing;
use gps_engine::{
    Attempt as RustAttempt, AttemptAxis as RustAttemptAxis, AttemptSample as RustAttemptSample,
    CanonicalizeConfig as RustCanonicalizeConfig, ComparisonConfig as RustComparisonConfig,
    Coordinate, DiscoveredRoute as RustDiscoveredRoute, Distance, Duration,
    FilterConfig as RustFilterConfig, Ghost as RustGhost, GhostSnapshot as RustGhostSnapshot,
    GhostState as RustGhostState, GpsFix as RustGpsFix, LiveConfig as RustLiveConfig,
    LiveGhost as RustLiveGhost, LiveGhostSnapshot as RustLiveGhostSnapshot,
    LiveMatchStatus as RustLiveMatchStatus, LiveRecorder as RustLiveRecorder,
    LiveSnapshot as RustLiveSnapshot, MatchConfig as RustMatchConfig, MatchScore as RustMatchScore,
    MovingAxisConfig as RustAttemptMovingConfig, MovingConfig as RustMovingConfig,
    ProcessingReport as RustProcessingReport, Projection as RustProjection, ReplaySession,
    ReplaySnapshot as RustReplaySnapshot, ReplayState as RustReplayState, Route as RustRoute,
    RouteCatalog as RustRouteCatalog, RoutePoint as RustRoutePoint,
    SimplifyConfig as RustSimplifyConfig, Speed, Timestamp, Track as RustTrack,
    TrackPoint as RustTrackPoint, canonicalize as canonicalize_impl, compare_either_direction,
    compare_performances as compare_performances_impl, parse_gpx as parse_gpx_impl,
    write_gpx as write_gpx_impl, write_gpx_file,
};

/// Build one of the Python-facing exception classes from
/// `against_yesterday.errors`.
///
/// Importing lazily (instead of holding a static class object) keeps the native
/// module importable on its own: callers that import `_native` directly still
/// get a plain `ValueError` fallback if the Python package is unavailable.
fn python_error(name: &'static str, message: impl Into<String>) -> PyErr {
    let message = message.into();
    Python::with_gil(|py| {
        let resolved = (|| -> PyResult<PyErr> {
            let module = py.import("against_yesterday.errors")?;
            let class = module.getattr(name)?.downcast::<PyType>()?.clone();
            Ok(PyErr::from_type(class, message.clone()))
        })();
        resolved.unwrap_or_else(|_| PyValueError::new_err(message.clone()))
    })
}

fn invalid_input(message: impl Into<String>) -> PyErr {
    python_error("InvalidInputError", message)
}

fn geo_err(err: gps_engine::GeoError) -> PyErr {
    python_error("GeoError", err.to_string())
}

fn track_err(err: gps_engine::TrackError) -> PyErr {
    python_error("TrackError", err.to_string())
}

fn parse_err(err: gps_engine::GpxError) -> PyErr {
    python_error("ParseError", err.to_string())
}

fn write_err(err: gps_engine::GpxError) -> PyErr {
    python_error("GpxWriteError", err.to_string())
}

fn route_err(err: gps_engine::RouteError) -> PyErr {
    python_error("RouteError", err.to_string())
}

fn attempt_err(err: gps_engine::AttemptError) -> PyErr {
    python_error("AttemptError", err.to_string())
}

fn canonical_err(err: gps_engine::CanonicalError) -> PyErr {
    python_error("CanonicalizationError", err.to_string())
}

fn finite(name: &'static str, value: f64) -> PyResult<f64> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(invalid_input(format!("{name} must be finite")))
    }
}

fn non_negative(name: &'static str, value: f64) -> PyResult<f64> {
    let value = finite(name, value)?;
    if value >= 0.0 {
        Ok(value)
    } else {
        Err(invalid_input(format!("{name} must be non-negative")))
    }
}

fn positive(name: &'static str, value: f64) -> PyResult<f64> {
    let value = finite(name, value)?;
    if value > 0.0 {
        Ok(value)
    } else {
        Err(invalid_input(format!("{name} must be positive")))
    }
}

fn bounded(name: &'static str, value: f64, min: f64, max: f64) -> PyResult<f64> {
    let value = finite(name, value)?;
    if (min..=max).contains(&value) {
        Ok(value)
    } else {
        Err(invalid_input(format!("{name} must be in [{min}, {max}]")))
    }
}

fn optional_non_negative(name: &'static str, value: Option<f64>) -> PyResult<Option<f64>> {
    value.map(|v| non_negative(name, v)).transpose()
}

fn optional_positive(name: &'static str, value: Option<f64>) -> PyResult<Option<f64>> {
    value.map(|v| positive(name, v)).transpose()
}

fn fraction(name: &'static str, value: f64) -> PyResult<f64> {
    bounded(name, value, 0.0, 1.0)
}

fn ensure(condition: bool, message: impl Into<String>) -> PyResult<()> {
    if condition {
        Ok(())
    } else {
        Err(invalid_input(message))
    }
}

/// A property value that is still callable, preserving the pre-property
/// method-call form for one release.
fn callable_float(value: f64) -> PyObject {
    Python::with_gil(|py| {
        py.import("against_yesterday._compat")
            .and_then(|module| module.getattr("CallableFloat"))
            .and_then(|class| class.call1((value,)))
            .map(|value| value.unbind())
            .unwrap_or_else(|_| PyFloat::new(py, value).into_any().unbind())
    })
}

/// Same compatibility shim as `callable_float` for string-valued accessors.
fn callable_str(value: &str) -> PyObject {
    Python::with_gil(|py| {
        py.import("against_yesterday._compat")
            .and_then(|module| module.getattr("CallableStr"))
            .and_then(|class| class.call1((value,)))
            .map(|value| value.unbind())
            .unwrap_or_else(|_| PyString::new(py, value).into_any().unbind())
    })
}

/// Resolve a Python enum member, falling back to a plain string when the
/// package module is not importable (for example when `_native` is imported
/// directly from a build tree).
fn enum_value(
    class_name: &'static str,
    member_name: &'static str,
    fallback_value: &'static str,
) -> PyObject {
    Python::with_gil(|py| {
        py.import("against_yesterday.enums")
            .and_then(|module| module.getattr(class_name))
            .and_then(|class| class.getattr(member_name))
            .map(|value| value.unbind())
            .unwrap_or_else(|_| callable_str(fallback_value))
    })
}

fn parse_coordinate(latitude: f64, longitude: f64) -> PyResult<Coordinate> {
    bounded("latitude", latitude, -90.0, 90.0)?;
    bounded("longitude", longitude, -180.0, 180.0)?;
    Coordinate::new(latitude, longitude).map_err(geo_err)
}

#[pyclass(name = "TrackPoint", module = "against_yesterday")]
#[derive(Clone)]
struct PyTrackPoint {
    #[pyo3(get)]
    latitude: f64,
    #[pyo3(get)]
    longitude: f64,
    #[pyo3(get)]
    timestamp_ms: i64,
    #[pyo3(get)]
    altitude_m: Option<f64>,
    #[pyo3(get)]
    speed_mps: Option<f64>,
    #[pyo3(get)]
    accuracy_m: Option<f64>,
    #[pyo3(get)]
    bearing_deg: Option<f64>,
}

#[pymethods]
impl PyTrackPoint {
    #[new]
    #[pyo3(signature = (latitude, longitude, timestamp_ms, altitude_m=None, speed_mps=None, accuracy_m=None, bearing_deg=None))]
    fn new(
        latitude: f64,
        longitude: f64,
        timestamp_ms: i64,
        altitude_m: Option<f64>,
        speed_mps: Option<f64>,
        accuracy_m: Option<f64>,
        bearing_deg: Option<f64>,
    ) -> PyResult<Self> {
        bounded("latitude", latitude, -90.0, 90.0)?;
        bounded("longitude", longitude, -180.0, 180.0)?;
        let altitude_m = altitude_m.map(|v| finite("altitude_m", v)).transpose()?;
        let speed_mps = speed_mps
            .map(|v| non_negative("speed_mps", v))
            .transpose()?;
        let accuracy_m = accuracy_m
            .map(|v| non_negative("accuracy_m", v))
            .transpose()?;
        let bearing_deg = bearing_deg
            .map(|v| bounded("bearing_deg", v, 0.0, 360.0))
            .transpose()?;
        Ok(PyTrackPoint {
            latitude,
            longitude,
            timestamp_ms,
            altitude_m,
            speed_mps,
            accuracy_m,
            bearing_deg,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "TrackPoint(lat={}, lon={}, timestamp_ms={}, altitude_m={:?}, speed_mps={:?}, accuracy_m={:?}, bearing_deg={:?})",
            self.latitude,
            self.longitude,
            self.timestamp_ms,
            self.altitude_m,
            self.speed_mps,
            self.accuracy_m,
            self.bearing_deg
        )
    }
}

impl TryFrom<&PyTrackPoint> for RustTrackPoint {
    type Error = PyErr;

    fn try_from(point: &PyTrackPoint) -> Result<Self, Self::Error> {
        let coord = parse_coordinate(point.latitude, point.longitude)?;
        let mut rust = RustTrackPoint::new(Timestamp::from_unix_ms(point.timestamp_ms), coord);
        if let Some(altitude) = point.altitude_m {
            rust = rust.with_altitude(altitude).map_err(track_err)?;
        }
        if let Some(speed) = point.speed_mps {
            rust = rust.with_speed(speed).map_err(track_err)?;
        }
        if let Some(accuracy) = point.accuracy_m {
            rust = rust.with_accuracy(accuracy).map_err(track_err)?;
        }
        if let Some(bearing_deg) = point.bearing_deg {
            let bearing = Bearing::from_degrees(bearing_deg).map_err(geo_err)?;
            rust = rust.with_bearing(bearing);
        }
        Ok(rust)
    }
}

impl From<&RustTrackPoint> for PyTrackPoint {
    fn from(point: &RustTrackPoint) -> Self {
        PyTrackPoint {
            latitude: point.coordinate().latitude(),
            longitude: point.coordinate().longitude(),
            timestamp_ms: point.timestamp().unix_ms(),
            altitude_m: point.altitude(),
            speed_mps: point.speed(),
            accuracy_m: point.accuracy(),
            bearing_deg: point.bearing().map(|b| b.as_degrees()),
        }
    }
}

#[pyclass(name = "TrackPointIterator", module = "against_yesterday")]
struct PyTrackPointIterator {
    points: std::vec::IntoIter<RustTrackPoint>,
}

#[pymethods]
impl PyTrackPointIterator {
    fn __repr__(&self) -> String {
        format!(
            "TrackPointIterator(remaining={})",
            self.points.as_slice().len()
        )
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
        slf
    }

    fn __next__(&mut self) -> Option<PyTrackPoint> {
        self.points.next().map(|point| PyTrackPoint::from(&point))
    }
}

#[pyclass(name = "MovingConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyMovingConfig {
    #[pyo3(get)]
    min_speed_mps: f64,
    #[pyo3(get)]
    min_stop_duration_s: f64,
}

#[pymethods]
impl PyMovingConfig {
    #[new]
    #[pyo3(signature = (min_speed_mps=0.5, min_stop_duration_s=5.0))]
    fn new(min_speed_mps: f64, min_stop_duration_s: f64) -> PyResult<Self> {
        Ok(PyMovingConfig {
            min_speed_mps: non_negative("min_speed_mps", min_speed_mps)?,
            min_stop_duration_s: non_negative("min_stop_duration_s", min_stop_duration_s)?,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "MovingConfig(min_speed_mps={}, min_stop_duration_s={})",
            self.min_speed_mps, self.min_stop_duration_s
        )
    }
}

impl From<&PyMovingConfig> for RustMovingConfig {
    fn from(config: &PyMovingConfig) -> Self {
        RustMovingConfig {
            min_speed: Speed::from_mps(config.min_speed_mps),
            min_stop_duration: Duration::from_secs(config.min_stop_duration_s),
        }
    }
}

#[pyclass(name = "FilterConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyFilterConfig {
    #[pyo3(get)]
    max_accuracy_m: Option<f64>,
    #[pyo3(get)]
    max_speed_kmh: Option<f64>,
    #[pyo3(get)]
    max_jump_m: Option<f64>,
    #[pyo3(get)]
    max_time_gap_s: Option<f64>,
}

#[pymethods]
impl PyFilterConfig {
    #[new]
    #[pyo3(signature = (max_accuracy_m=Some(50.0), max_speed_kmh=Some(500.0), max_jump_m=Some(200.0), max_time_gap_s=Some(60.0)))]
    fn new(
        max_accuracy_m: Option<f64>,
        max_speed_kmh: Option<f64>,
        max_jump_m: Option<f64>,
        max_time_gap_s: Option<f64>,
    ) -> PyResult<Self> {
        Ok(PyFilterConfig {
            max_accuracy_m: optional_non_negative("max_accuracy_m", max_accuracy_m)?,
            max_speed_kmh: optional_positive("max_speed_kmh", max_speed_kmh)?,
            max_jump_m: optional_non_negative("max_jump_m", max_jump_m)?,
            max_time_gap_s: optional_positive("max_time_gap_s", max_time_gap_s)?,
        })
    }

    #[staticmethod]
    fn matching() -> Self {
        let cfg = RustFilterConfig::matching();
        PyFilterConfig {
            max_accuracy_m: cfg.max_accuracy.map(|d| d.meters()),
            max_speed_kmh: cfg.max_speed.map(|s| s.kmh()),
            max_jump_m: cfg.max_jump.map(|d| d.meters()),
            max_time_gap_s: cfg.max_time_gap.map(|d| d.as_secs()),
        }
    }

    fn __repr__(&self) -> String {
        format!(
            "FilterConfig(max_accuracy_m={:?}, max_speed_kmh={:?}, max_jump_m={:?}, max_time_gap_s={:?})",
            self.max_accuracy_m, self.max_speed_kmh, self.max_jump_m, self.max_time_gap_s
        )
    }
}

impl From<&PyFilterConfig> for RustFilterConfig {
    fn from(config: &PyFilterConfig) -> Self {
        RustFilterConfig {
            max_accuracy: config.max_accuracy_m.map(Distance::from_meters),
            max_speed: config.max_speed_kmh.map(Speed::from_kmh),
            max_jump: config.max_jump_m.map(Distance::from_meters),
            max_time_gap: config.max_time_gap_s.map(Duration::from_secs),
        }
    }
}

#[pyclass(name = "SimplifyConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PySimplifyConfig {
    #[pyo3(get)]
    tolerance_m: f64,
}

#[pymethods]
impl PySimplifyConfig {
    #[new]
    #[pyo3(signature = (tolerance_m=2.0))]
    fn new(tolerance_m: f64) -> PyResult<Self> {
        Ok(PySimplifyConfig {
            tolerance_m: non_negative("tolerance_m", tolerance_m)?,
        })
    }

    fn __repr__(&self) -> String {
        format!("SimplifyConfig(tolerance_m={})", self.tolerance_m)
    }
}

impl From<&PySimplifyConfig> for RustSimplifyConfig {
    fn from(config: &PySimplifyConfig) -> Self {
        RustSimplifyConfig {
            tolerance: Distance::from_meters(config.tolerance_m),
        }
    }
}

#[pyclass(name = "ProcessingReport", module = "against_yesterday")]
#[derive(Clone)]
struct PyProcessingReport {
    #[pyo3(get)]
    input_points: usize,
    #[pyo3(get)]
    output_points: usize,
    #[pyo3(get)]
    removed_points: usize,
    #[pyo3(get)]
    distance_before_m: f64,
    #[pyo3(get)]
    distance_after_m: f64,
}

#[pymethods]
impl PyProcessingReport {
    fn __repr__(&self) -> String {
        format!(
            "ProcessingReport(input_points={}, output_points={}, removed_points={}, distance_before_m={}, distance_after_m={})",
            self.input_points,
            self.output_points,
            self.removed_points,
            self.distance_before_m,
            self.distance_after_m
        )
    }
}

impl From<RustProcessingReport> for PyProcessingReport {
    fn from(report: RustProcessingReport) -> Self {
        PyProcessingReport {
            input_points: report.input_points,
            output_points: report.output_points,
            removed_points: report.removed_points,
            distance_before_m: report.distance_before.meters(),
            distance_after_m: report.distance_after.meters(),
        }
    }
}

#[pyclass(name = "Projection", module = "against_yesterday")]
#[derive(Clone)]
struct PyProjection {
    #[pyo3(get)]
    distance_along_m: f64,
    #[pyo3(get)]
    lateral_error_m: f64,
    #[pyo3(get)]
    fraction: f64,
    #[pyo3(get)]
    latitude: f64,
    #[pyo3(get)]
    longitude: f64,
    #[pyo3(get)]
    segment_index: usize,
}

#[pymethods]
impl PyProjection {
    fn __repr__(&self) -> String {
        format!(
            "Projection(distance_along_m={}, lateral_error_m={}, fraction={}, lat={}, lon={}, segment_index={})",
            self.distance_along_m,
            self.lateral_error_m,
            self.fraction,
            self.latitude,
            self.longitude,
            self.segment_index
        )
    }
}

impl From<RustProjection> for PyProjection {
    fn from(p: RustProjection) -> Self {
        PyProjection {
            distance_along_m: p.distance_along.meters(),
            lateral_error_m: p.lateral_error.meters(),
            fraction: p.fraction,
            latitude: p.projected.latitude(),
            longitude: p.projected.longitude(),
            segment_index: p.segment_index,
        }
    }
}

#[pyclass(name = "RoutePoint", module = "against_yesterday")]
#[derive(Clone)]
struct PyRoutePoint {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    latitude: f64,
    #[pyo3(get)]
    longitude: f64,
}

#[pymethods]
impl PyRoutePoint {
    fn __repr__(&self) -> String {
        format!(
            "RoutePoint(distance_m={}, lat={}, lon={})",
            self.distance_m, self.latitude, self.longitude
        )
    }
}

impl From<RustRoutePoint> for PyRoutePoint {
    fn from(p: RustRoutePoint) -> Self {
        PyRoutePoint {
            distance_m: p.distance.meters(),
            latitude: p.coordinate.latitude(),
            longitude: p.coordinate.longitude(),
        }
    }
}

#[pyclass(name = "RouteCoordinateIterator", module = "against_yesterday")]
struct PyRouteCoordinateIterator {
    coordinates: std::vec::IntoIter<Coordinate>,
}

#[pymethods]
impl PyRouteCoordinateIterator {
    fn __repr__(&self) -> String {
        format!(
            "RouteCoordinateIterator(remaining={})",
            self.coordinates.as_slice().len()
        )
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
        slf
    }

    fn __next__(&mut self) -> Option<(f64, f64)> {
        self.coordinates
            .next()
            .map(|c| (c.latitude(), c.longitude()))
    }
}

#[pyclass(name = "Route", module = "against_yesterday")]
#[derive(Clone)]
struct PyRoute {
    inner: RustRoute,
}

#[pymethods]
impl PyRoute {
    #[new]
    fn new(coordinates: Vec<(f64, f64)>) -> PyResult<Self> {
        let geometry = coordinates
            .into_iter()
            .map(|(lat, lon)| parse_coordinate(lat, lon))
            .collect::<PyResult<Vec<_>>>()?;
        let inner = RustRoute::new(geometry).map_err(route_err)?;
        Ok(PyRoute { inner })
    }

    #[getter]
    fn length_m(&self) -> f64 {
        self.inner.length().meters()
    }

    fn geometry(&self) -> Vec<(f64, f64)> {
        self.inner
            .geometry()
            .iter()
            .map(|c| (c.latitude(), c.longitude()))
            .collect()
    }

    #[getter]
    fn coordinates(&self) -> Vec<(f64, f64)> {
        self.geometry()
    }

    fn start(&self) -> (f64, f64) {
        let c = self.inner.start();
        (c.latitude(), c.longitude())
    }

    fn end(&self) -> (f64, f64) {
        let c = self.inner.end();
        (c.latitude(), c.longitude())
    }

    fn coordinate_at(&self, distance_m: f64) -> PyResult<Option<(f64, f64)>> {
        let distance_m = non_negative("distance_m", distance_m)?;
        Ok(self
            .inner
            .coordinate_at(Distance::from_meters(distance_m))
            .map(|c| (c.latitude(), c.longitude())))
    }

    fn project(&self, latitude: f64, longitude: f64) -> PyResult<PyProjection> {
        let c = parse_coordinate(latitude, longitude)?;
        Ok(PyProjection::from(self.inner.project(c)))
    }

    fn nearest(&self, latitude: f64, longitude: f64) -> PyResult<PyRoutePoint> {
        let c = parse_coordinate(latitude, longitude)?;
        Ok(PyRoutePoint::from(self.inner.nearest(c)))
    }

    fn reversed(&self) -> PyRoute {
        PyRoute {
            inner: self.inner.reversed(),
        }
    }

    fn runs_in_reverse(
        &self,
        start_lat: f64,
        start_lon: f64,
        end_lat: f64,
        end_lon: f64,
    ) -> PyResult<bool> {
        let start = parse_coordinate(start_lat, start_lon)?;
        let end = parse_coordinate(end_lat, end_lon)?;
        Ok(self.inner.runs_in_reverse(start, end))
    }

    fn __iter__(&self) -> PyRouteCoordinateIterator {
        PyRouteCoordinateIterator {
            coordinates: self.inner.geometry().to_vec().into_iter(),
        }
    }

    fn __len__(&self) -> usize {
        self.inner.geometry().len()
    }

    fn __getitem__(&self, index: isize) -> PyResult<(f64, f64)> {
        let len = self.inner.geometry().len() as isize;
        let index = if index < 0 { len + index } else { index };
        if index < 0 || index >= len {
            return Err(PyIndexError::new_err("route index out of range"));
        }
        let c = self.inner.geometry()[index as usize];
        Ok((c.latitude(), c.longitude()))
    }

    fn __repr__(&self) -> String {
        format!(
            "Route(length_m={:.3}, points={})",
            self.inner.length().meters(),
            self.inner.geometry().len()
        )
    }
}

#[pyclass(name = "Track", module = "against_yesterday")]
#[derive(Clone)]
struct PyTrack {
    inner: RustTrack,
}

#[pymethods]
impl PyTrack {
    #[new]
    fn new(points: Vec<PyTrackPoint>) -> PyResult<Self> {
        let rust_points = points
            .iter()
            .map(RustTrackPoint::try_from)
            .collect::<PyResult<Vec<_>>>()?;
        let inner = RustTrack::new(rust_points).map_err(track_err)?;
        Ok(PyTrack { inner })
    }

    #[staticmethod]
    fn from_gpx_path(path: PathBuf) -> PyResult<Self> {
        let inner = gps_engine::read_gpx_file(path).map_err(parse_err)?;
        Ok(PyTrack { inner })
    }

    #[staticmethod]
    fn from_gpx(data: &str) -> PyResult<Self> {
        let inner = parse_gpx_impl(data.as_bytes()).map_err(parse_err)?;
        Ok(PyTrack { inner })
    }

    fn to_gpx(&self) -> PyResult<String> {
        let mut out = Vec::new();
        write_gpx_impl(&self.inner, &mut out).map_err(write_err)?;
        String::from_utf8(out).map_err(|e| python_error("GpxWriteError", e.to_string()))
    }

    fn to_gpx_path(&self, path: PathBuf) -> PyResult<()> {
        write_gpx_file(&self.inner, path).map_err(write_err)
    }

    #[getter]
    fn point_count(&self) -> usize {
        self.inner.len()
    }

    #[getter]
    fn distance_m(&self) -> f64 {
        self.inner.distance().meters()
    }

    #[getter]
    fn duration_s(&self) -> f64 {
        self.inner.duration().as_secs()
    }

    #[getter]
    fn average_speed_mps(&self) -> f64 {
        self.inner.average_speed().mps()
    }

    #[getter]
    fn elevation_gain_m(&self) -> f64 {
        self.inner.elevation_gain()
    }

    #[getter]
    fn elevation_loss_m(&self) -> f64 {
        self.inner.elevation_loss()
    }

    #[getter]
    fn start_time_ms(&self) -> Option<i64> {
        self.inner.start().map(|p| p.timestamp().unix_ms())
    }

    #[getter]
    fn end_time_ms(&self) -> Option<i64> {
        self.inner.end().map(|p| p.timestamp().unix_ms())
    }

    #[pyo3(signature = (config=None))]
    fn moving_duration_s(&self, config: Option<PyMovingConfig>) -> f64 {
        let cfg = config
            .as_ref()
            .map(RustMovingConfig::from)
            .unwrap_or_default();
        self.inner.moving_duration(&cfg).as_secs()
    }

    #[pyo3(signature = (config=None))]
    fn paused_duration_s(&self, config: Option<PyMovingConfig>) -> f64 {
        let cfg = config
            .as_ref()
            .map(RustMovingConfig::from)
            .unwrap_or_default();
        self.inner.paused_duration(&cfg).as_secs()
    }

    #[pyo3(signature = (config=None))]
    fn moving_speed_mps(&self, config: Option<PyMovingConfig>) -> f64 {
        let cfg = config
            .as_ref()
            .map(RustMovingConfig::from)
            .unwrap_or_default();
        self.inner.moving_speed(&cfg).mps()
    }

    fn points(&self) -> Vec<PyTrackPoint> {
        self.inner.points().iter().map(PyTrackPoint::from).collect()
    }

    fn coordinates(&self) -> Vec<(f64, f64)> {
        self.inner
            .coordinates()
            .into_iter()
            .map(|c| (c.latitude(), c.longitude()))
            .collect()
    }

    #[pyo3(signature = (config=None))]
    fn filter(
        &self,
        py: Python<'_>,
        config: Option<PyFilterConfig>,
    ) -> (PyTrack, PyProcessingReport) {
        let cfg = config
            .as_ref()
            .map(RustFilterConfig::from)
            .unwrap_or_default();
        let track = self.inner.clone();
        let (track, report) = py.allow_threads(move || track.filter(&cfg));
        (PyTrack { inner: track }, PyProcessingReport::from(report))
    }

    #[pyo3(signature = (tolerance_m=2.0, config=None))]
    fn simplify(
        &self,
        py: Python<'_>,
        tolerance_m: f64,
        config: Option<PySimplifyConfig>,
    ) -> PyResult<PyTrack> {
        let cfg = match config {
            Some(cfg) => cfg,
            None => PySimplifyConfig::new(tolerance_m)?,
        };
        let cfg = RustSimplifyConfig::from(&cfg);
        let track = self.inner.clone();
        let track = py.allow_threads(move || track.simplify(&cfg));
        Ok(PyTrack { inner: track })
    }

    #[pyo3(signature = (interval_m))]
    fn resample_by_distance(&self, py: Python<'_>, interval_m: f64) -> PyResult<PyTrack> {
        let interval_m = positive("interval_m", interval_m)?;
        let track = self.inner.clone();
        let result =
            py.allow_threads(move || track.resample_by_distance(Distance::from_meters(interval_m)));
        Ok(PyTrack {
            inner: result.map_err(track_err)?,
        })
    }

    fn reversed(&self) -> PyTrack {
        PyTrack {
            inner: self.inner.reversed(),
        }
    }

    #[pyo3(signature = (config=None))]
    fn analytics(&self, py: Python<'_>, config: Option<PyMovingConfig>) -> PyTrackAnalytics {
        let cfg = config
            .as_ref()
            .map(RustMovingConfig::from)
            .unwrap_or_default();
        let track = self.inner.clone();
        let analytics = py.allow_threads(move || RustTrackAnalytics::from_track(&track, &cfg));
        PyTrackAnalytics::from(analytics)
    }

    fn __iter__(&self) -> PyTrackPointIterator {
        PyTrackPointIterator {
            points: self.inner.points().to_vec().into_iter(),
        }
    }

    fn __len__(&self) -> usize {
        self.inner.len()
    }

    fn __getitem__(&self, index: isize) -> PyResult<PyTrackPoint> {
        let len = self.inner.len() as isize;
        let index = if index < 0 { len + index } else { index };
        if index < 0 || index >= len {
            return Err(PyIndexError::new_err("track index out of range"));
        }
        Ok(PyTrackPoint::from(&self.inner.points()[index as usize]))
    }

    fn __repr__(&self) -> String {
        format!(
            "Track(points={}, distance_m={:.3}, duration_s={:.3})",
            self.inner.len(),
            self.inner.distance().meters(),
            self.inner.duration().as_secs()
        )
    }
}

#[pyclass(name = "AttemptSample", module = "against_yesterday")]
#[derive(Clone)]
struct PyAttemptSample {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    elapsed_s: f64,
}

#[pymethods]
impl PyAttemptSample {
    #[new]
    fn new(distance_m: f64, elapsed_s: f64) -> PyResult<Self> {
        Ok(PyAttemptSample {
            distance_m: non_negative("distance_m", distance_m)?,
            elapsed_s: non_negative("elapsed_s", elapsed_s)?,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "AttemptSample(distance_m={}, elapsed_s={})",
            self.distance_m, self.elapsed_s
        )
    }
}

impl From<&PyAttemptSample> for RustAttemptSample {
    fn from(s: &PyAttemptSample) -> Self {
        RustAttemptSample {
            distance: Distance::from_meters(s.distance_m),
            elapsed: Duration::from_secs(s.elapsed_s),
        }
    }
}

impl From<RustAttemptSample> for PyAttemptSample {
    fn from(s: RustAttemptSample) -> Self {
        PyAttemptSample {
            distance_m: s.distance.meters(),
            elapsed_s: s.elapsed.as_secs(),
        }
    }
}

#[pyclass(name = "AttemptSampleIterator", module = "against_yesterday")]
struct PyAttemptSampleIterator {
    samples: std::vec::IntoIter<RustAttemptSample>,
}

#[pymethods]
impl PyAttemptSampleIterator {
    fn __repr__(&self) -> String {
        format!(
            "AttemptSampleIterator(remaining={})",
            self.samples.as_slice().len()
        )
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
        slf
    }

    fn __next__(&mut self) -> Option<PyAttemptSample> {
        self.samples.next().map(PyAttemptSample::from)
    }
}

#[pyclass(name = "AttemptMovingConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyAttemptMovingConfig {
    #[pyo3(get)]
    min_speed_mps: f64,
    #[pyo3(get)]
    min_stop_duration_s: f64,
}

#[pymethods]
impl PyAttemptMovingConfig {
    #[new]
    #[pyo3(signature = (min_speed_mps=0.5, min_stop_duration_s=5.0))]
    fn new(min_speed_mps: f64, min_stop_duration_s: f64) -> PyResult<Self> {
        Ok(PyAttemptMovingConfig {
            min_speed_mps: non_negative("min_speed_mps", min_speed_mps)?,
            min_stop_duration_s: non_negative("min_stop_duration_s", min_stop_duration_s)?,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "AttemptMovingConfig(min_speed_mps={}, min_stop_duration_s={})",
            self.min_speed_mps, self.min_stop_duration_s
        )
    }
}

impl From<&PyAttemptMovingConfig> for RustAttemptMovingConfig {
    fn from(c: &PyAttemptMovingConfig) -> Self {
        RustAttemptMovingConfig {
            min_speed: Speed::from_mps(c.min_speed_mps),
            min_stop_duration: Duration::from_secs(c.min_stop_duration_s),
        }
    }
}

#[pyclass(name = "Attempt", module = "against_yesterday")]
#[derive(Clone)]
struct PyAttempt {
    inner: RustAttempt,
}

#[pymethods]
impl PyAttempt {
    #[staticmethod]
    fn from_samples(samples: Vec<PyAttemptSample>) -> PyResult<Self> {
        let samples = samples.iter().map(RustAttemptSample::from).collect();
        let inner = RustAttempt::from_samples(samples).map_err(attempt_err)?;
        Ok(PyAttempt { inner })
    }

    #[staticmethod]
    #[pyo3(signature = (track, route, axis="clock", moving_config=None))]
    fn from_track(
        track: &PyTrack,
        route: &PyRoute,
        axis: &str,
        moving_config: Option<PyAttemptMovingConfig>,
    ) -> PyResult<Self> {
        let axis = match axis {
            "clock" => RustAttemptAxis::Clock,
            "moving" => RustAttemptAxis::Moving,
            _ => return Err(invalid_input("axis must be 'clock' or 'moving'")),
        };
        let cfg = moving_config
            .as_ref()
            .map(RustAttemptMovingConfig::from)
            .unwrap_or_default();
        let inner = RustAttempt::from_track_with(&track.inner, &route.inner, axis, &cfg);
        Ok(PyAttempt { inner })
    }

    fn time_at(&self, distance_m: f64) -> PyResult<Option<f64>> {
        let distance_m = non_negative("distance_m", distance_m)?;
        Ok(self
            .inner
            .time_at(Distance::from_meters(distance_m))
            .map(|d| d.as_secs()))
    }

    fn distance_at(&self, elapsed_s: f64) -> PyResult<Option<f64>> {
        let elapsed_s = non_negative("elapsed_s", elapsed_s)?;
        Ok(self
            .inner
            .distance_at(Duration::from_secs(elapsed_s))
            .map(|d| d.meters()))
    }

    #[getter]
    fn elapsed_time_s(&self) -> f64 {
        self.inner.elapsed_time.as_secs()
    }

    #[getter]
    fn distance_m(&self) -> f64 {
        self.inner.distance.meters()
    }

    fn samples(&self) -> Vec<PyAttemptSample> {
        self.inner
            .samples
            .iter()
            .copied()
            .map(PyAttemptSample::from)
            .collect()
    }

    fn __iter__(&self) -> PyAttemptSampleIterator {
        PyAttemptSampleIterator {
            samples: self.inner.samples.clone().into_iter(),
        }
    }

    fn __len__(&self) -> usize {
        self.inner.samples.len()
    }

    fn __getitem__(&self, index: isize) -> PyResult<PyAttemptSample> {
        let len = self.inner.samples.len() as isize;
        let index = if index < 0 { len + index } else { index };
        if index < 0 || index >= len {
            return Err(PyIndexError::new_err("attempt index out of range"));
        }
        Ok(PyAttemptSample::from(self.inner.samples[index as usize]))
    }

    fn __repr__(&self) -> String {
        format!(
            "Attempt(distance_m={:.3}, elapsed_time_s={:.3}, samples={})",
            self.inner.distance.meters(),
            self.inner.elapsed_time.as_secs(),
            self.inner.samples.len()
        )
    }
}

#[pyclass(name = "ComparisonConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyComparisonConfig {
    #[pyo3(get)]
    step_m: f64,
}

#[pymethods]
impl PyComparisonConfig {
    #[new]
    #[pyo3(signature = (step_m=100.0))]
    fn new(step_m: f64) -> PyResult<Self> {
        Ok(PyComparisonConfig {
            step_m: positive("step_m", step_m)?,
        })
    }

    fn __repr__(&self) -> String {
        format!("ComparisonConfig(step_m={})", self.step_m)
    }
}

impl From<&PyComparisonConfig> for RustComparisonConfig {
    fn from(c: &PyComparisonConfig) -> Self {
        RustComparisonConfig {
            step: Distance::from_meters(c.step_m),
        }
    }
}

#[pyclass(name = "ComparisonPoint", module = "against_yesterday")]
#[derive(Clone)]
struct PyComparisonPoint {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    time_difference_s: f64,
}

#[pymethods]
impl PyComparisonPoint {
    fn __repr__(&self) -> String {
        format!(
            "ComparisonPoint(distance_m={}, time_difference_s={})",
            self.distance_m, self.time_difference_s
        )
    }
}

#[pyclass(name = "PerformanceComparison", module = "against_yesterday")]
#[derive(Clone)]
struct PyPerformanceComparison {
    #[pyo3(get)]
    total_time_difference_s: f64,
    #[pyo3(get)]
    distance_difference_m: f64,
    #[pyo3(get)]
    points: Vec<PyComparisonPoint>,
}

#[pymethods]
impl PyPerformanceComparison {
    fn __repr__(&self) -> String {
        format!(
            "PerformanceComparison(total_time_difference_s={}, distance_difference_m={}, points={})",
            self.total_time_difference_s,
            self.distance_difference_m,
            self.points.len()
        )
    }
}

#[pyfunction]
#[pyo3(signature = (reference, current, config=None))]
fn compare_performances(
    py: Python<'_>,
    reference: &PyAttempt,
    current: &PyAttempt,
    config: Option<PyComparisonConfig>,
) -> PyPerformanceComparison {
    let cfg = config
        .as_ref()
        .map(RustComparisonConfig::from)
        .unwrap_or_default();
    let reference = reference.inner.clone();
    let current = current.inner.clone();
    let cmp = py.allow_threads(move || compare_performances_impl(&reference, &current, &cfg));
    PyPerformanceComparison {
        total_time_difference_s: cmp.total_time_difference.as_secs(),
        distance_difference_m: cmp.distance_difference.meters(),
        points: cmp
            .points
            .into_iter()
            .map(|p| PyComparisonPoint {
                distance_m: p.distance.meters(),
                time_difference_s: p.time_difference.as_secs(),
            })
            .collect(),
    }
}

#[pyclass(name = "GhostState", module = "against_yesterday")]
#[derive(Clone)]
struct PyGhostState {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    time_difference_s: f64,
    #[pyo3(get)]
    ahead: bool,
}

#[pymethods]
impl PyGhostState {
    fn __repr__(&self) -> String {
        format!(
            "GhostState(distance_m={}, time_difference_s={}, ahead={})",
            self.distance_m, self.time_difference_s, self.ahead
        )
    }
}

impl From<RustGhostState> for PyGhostState {
    fn from(s: RustGhostState) -> Self {
        PyGhostState {
            distance_m: s.distance.meters(),
            time_difference_s: s.time_difference.as_secs(),
            ahead: s.ahead,
        }
    }
}

#[pyclass(name = "GhostSnapshot", module = "against_yesterday")]
#[derive(Clone)]
struct PyGhostSnapshot {
    #[pyo3(get)]
    state: PyGhostState,
    #[pyo3(get)]
    spatial_gap_m: f64,
    #[pyo3(get)]
    confidence: f64,
}

#[pymethods]
impl PyGhostSnapshot {
    fn __repr__(&self) -> String {
        format!(
            "GhostSnapshot(distance_m={}, time_difference_s={}, ahead={}, spatial_gap_m={}, confidence={})",
            self.state.distance_m,
            self.state.time_difference_s,
            self.state.ahead,
            self.spatial_gap_m,
            self.confidence
        )
    }
}

impl From<RustGhostSnapshot> for PyGhostSnapshot {
    fn from(s: RustGhostSnapshot) -> Self {
        PyGhostSnapshot {
            state: PyGhostState::from(s.state),
            spatial_gap_m: s.spatial_gap.meters(),
            confidence: s.confidence,
        }
    }
}

#[pyclass(name = "Ghost", module = "against_yesterday")]
#[derive(Clone)]
struct PyGhost {
    inner: RustGhost,
}

#[pymethods]
impl PyGhost {
    #[new]
    fn new(reference: &PyAttempt, current: &PyAttempt) -> Self {
        PyGhost {
            inner: RustGhost::new(reference.inner.clone(), current.inner.clone()),
        }
    }

    fn state_at(&self, elapsed_s: f64) -> PyResult<Option<PyGhostState>> {
        let elapsed_s = non_negative("elapsed_s", elapsed_s)?;
        Ok(self
            .inner
            .state_at(Duration::from_secs(elapsed_s))
            .map(PyGhostState::from))
    }

    fn state_at_distance(&self, distance_m: f64) -> PyResult<Option<PyGhostState>> {
        let distance_m = non_negative("distance_m", distance_m)?;
        Ok(self
            .inner
            .state_at_distance(Distance::from_meters(distance_m))
            .map(PyGhostState::from))
    }

    fn snapshot_at(&self, elapsed_s: f64) -> PyResult<Option<PyGhostSnapshot>> {
        let elapsed_s = non_negative("elapsed_s", elapsed_s)?;
        Ok(self
            .inner
            .snapshot_at(Duration::from_secs(elapsed_s))
            .map(PyGhostSnapshot::from))
    }

    fn snapshot_at_distance(&self, distance_m: f64) -> PyResult<Option<PyGhostSnapshot>> {
        let distance_m = non_negative("distance_m", distance_m)?;
        Ok(self
            .inner
            .snapshot_at_distance(Distance::from_meters(distance_m))
            .map(PyGhostSnapshot::from))
    }

    fn __repr__(&self) -> String {
        "Ghost()".to_string()
    }
}

#[pyclass(name = "GpsFix", module = "against_yesterday")]
#[derive(Clone)]
struct PyGpsFix {
    inner: RustGpsFix,
}

#[pymethods]
impl PyGpsFix {
    #[new]
    #[pyo3(signature = (timestamp_ms, latitude, longitude, accuracy_m=None, altitude_m=None, speed_mps=None, bearing_deg=None))]
    fn new(
        timestamp_ms: i64,
        latitude: f64,
        longitude: f64,
        accuracy_m: Option<f64>,
        altitude_m: Option<f64>,
        speed_mps: Option<f64>,
        bearing_deg: Option<f64>,
    ) -> PyResult<Self> {
        let coord = parse_coordinate(latitude, longitude)?;
        let accuracy = optional_non_negative("accuracy_m", accuracy_m)?;
        let altitude = altitude_m.map(|v| finite("altitude_m", v)).transpose()?;
        let speed = optional_non_negative("speed_mps", speed_mps)?;
        let bearing = bearing_deg
            .map(|v| bounded("bearing_deg", v, 0.0, 360.0))
            .transpose()?;
        let mut fix = RustGpsFix::new(Timestamp::from_unix_ms(timestamp_ms), coord);
        fix.accuracy = accuracy.map(Distance::from_meters);
        fix.altitude = altitude;
        fix.speed = speed.map(Speed::from_mps);
        if let Some(b) = bearing {
            fix.bearing = Some(Bearing::from_degrees(b).map_err(geo_err)?);
        }
        Ok(PyGpsFix { inner: fix })
    }

    #[getter]
    fn timestamp_ms(&self) -> i64 {
        self.inner.timestamp.unix_ms()
    }
    #[getter]
    fn latitude(&self) -> f64 {
        self.inner.coordinate.latitude()
    }
    #[getter]
    fn longitude(&self) -> f64 {
        self.inner.coordinate.longitude()
    }
    #[getter]
    fn accuracy_m(&self) -> Option<f64> {
        self.inner.accuracy.map(|d| d.meters())
    }
    #[getter]
    fn altitude_m(&self) -> Option<f64> {
        self.inner.altitude
    }
    #[getter]
    fn speed_mps(&self) -> Option<f64> {
        self.inner.speed.map(|s| s.mps())
    }
    #[getter]
    fn bearing_deg(&self) -> Option<f64> {
        self.inner.bearing.map(|b| b.as_degrees())
    }

    fn __repr__(&self) -> String {
        format!(
            "GpsFix(timestamp_ms={}, lat={}, lon={}, accuracy_m={:?}, altitude_m={:?}, speed_mps={:?}, bearing_deg={:?})",
            self.inner.timestamp.unix_ms(),
            self.inner.coordinate.latitude(),
            self.inner.coordinate.longitude(),
            self.inner.accuracy.map(|d| d.meters()),
            self.inner.altitude,
            self.inner.speed.map(|s| s.mps()),
            self.inner.bearing.map(|b| b.as_degrees())
        )
    }
}

#[pyclass(name = "LiveConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyLiveConfig {
    #[pyo3(get)]
    off_route_threshold_m: f64,
}

#[pymethods]
impl PyLiveConfig {
    #[new]
    #[pyo3(signature = (off_route_threshold_m=30.0))]
    fn new(off_route_threshold_m: f64) -> PyResult<Self> {
        Ok(PyLiveConfig {
            off_route_threshold_m: non_negative("off_route_threshold_m", off_route_threshold_m)?,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "LiveConfig(off_route_threshold_m={})",
            self.off_route_threshold_m
        )
    }
}

impl From<&PyLiveConfig> for RustLiveConfig {
    fn from(c: &PyLiveConfig) -> Self {
        RustLiveConfig {
            off_route_threshold: Distance::from_meters(c.off_route_threshold_m),
            ..RustLiveConfig::default()
        }
    }
}

#[pyclass(name = "LiveGhostSnapshot", module = "against_yesterday")]
#[derive(Clone)]
struct PyLiveGhostSnapshot {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    time_difference_s: f64,
    #[pyo3(get)]
    ahead: bool,
    #[pyo3(get)]
    spatial_gap_m: f64,
    #[pyo3(get)]
    confidence: f64,
}

#[pymethods]
impl PyLiveGhostSnapshot {
    fn __repr__(&self) -> String {
        format!(
            "LiveGhostSnapshot(distance_m={}, time_difference_s={}, ahead={}, spatial_gap_m={}, confidence={})",
            self.distance_m,
            self.time_difference_s,
            self.ahead,
            self.spatial_gap_m,
            self.confidence
        )
    }
}

impl From<RustLiveGhostSnapshot> for PyLiveGhostSnapshot {
    fn from(s: RustLiveGhostSnapshot) -> Self {
        PyLiveGhostSnapshot {
            distance_m: s.state.distance.meters(),
            time_difference_s: s.state.time_difference.as_secs(),
            ahead: s.state.ahead,
            spatial_gap_m: s.spatial_gap.meters(),
            confidence: s.confidence,
        }
    }
}

#[pyclass(name = "LiveSnapshot", module = "against_yesterday")]
struct PyLiveSnapshot {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    moving_s: f64,
    #[pyo3(get)]
    pace_mps: f64,
    #[pyo3(get)]
    route_progress: f64,
    #[pyo3(get)]
    off_route_m: Option<f64>,
    #[pyo3(get)]
    accuracy_m: Option<f64>,
    #[pyo3(get)]
    latitude: Option<f64>,
    #[pyo3(get)]
    longitude: Option<f64>,
    #[pyo3(get)]
    match_status: PyObject,
    #[pyo3(get)]
    match_confidence: f64,
}

impl From<RustLiveSnapshot> for PyLiveSnapshot {
    fn from(s: RustLiveSnapshot) -> Self {
        let (latitude, longitude) = match s.position {
            Some(c) => (Some(c.latitude()), Some(c.longitude())),
            None => (None, None),
        };
        let (member, value) = match s.match_status {
            RustLiveMatchStatus::None => ("NONE", "none"),
            RustLiveMatchStatus::Initializing => ("INITIALIZING", "initializing"),
            RustLiveMatchStatus::Matched => ("MATCHED", "matched"),
            RustLiveMatchStatus::Uncertain => ("UNCERTAIN", "uncertain"),
            RustLiveMatchStatus::OffRoute => ("OFF_ROUTE", "off_route"),
            RustLiveMatchStatus::Reacquiring => ("REACQUIRING", "reacquiring"),
        };
        let match_status = enum_value("LiveMatchStatus", member, value);
        PyLiveSnapshot {
            distance_m: s.distance.meters(),
            moving_s: s.moving.as_secs(),
            pace_mps: s.pace.mps(),
            route_progress: s.route_progress,
            off_route_m: s.off_route.map(|d| d.meters()),
            accuracy_m: s.accuracy.map(|d| d.meters()),
            latitude,
            longitude,
            match_status,
            match_confidence: s.match_confidence,
        }
    }
}

#[pymethods]
impl PyLiveSnapshot {
    fn __repr__(&self) -> String {
        format!(
            "LiveSnapshot(distance_m={}, moving_s={}, route_progress={}, match_confidence={})",
            self.distance_m, self.moving_s, self.route_progress, self.match_confidence
        )
    }
}

#[pyclass(name = "LiveGhost", module = "against_yesterday")]
#[derive(Clone)]
struct PyLiveGhost {
    inner: RustLiveGhost,
}

#[pymethods]
impl PyLiveGhost {
    #[new]
    fn new(samples: Vec<(f64, f64)>) -> PyResult<Self> {
        let mut validated = Vec::with_capacity(samples.len());
        for (distance_m, elapsed_s) in samples {
            validated.push((
                Distance::from_meters(non_negative("distance_m", distance_m)?),
                Duration::from_secs(non_negative("elapsed_s", elapsed_s)?),
            ));
        }
        Ok(PyLiveGhost {
            inner: RustLiveGhost { samples: validated },
        })
    }

    #[getter]
    fn elapsed_time_s(&self) -> PyObject {
        callable_float(self.inner.elapsed_time().as_secs())
    }

    fn distance_at(&self, elapsed_s: f64) -> PyResult<f64> {
        let elapsed_s = non_negative("elapsed_s", elapsed_s)?;
        Ok(self
            .inner
            .distance_at(Duration::from_secs(elapsed_s))
            .meters())
    }

    fn time_at(&self, distance_m: f64) -> PyResult<f64> {
        let distance_m = non_negative("distance_m", distance_m)?;
        Ok(self
            .inner
            .time_at(Distance::from_meters(distance_m))
            .as_secs())
    }

    fn snapshot(&self, current_distance_m: f64, moving_s: f64) -> PyResult<PyLiveGhostSnapshot> {
        let current_distance_m = non_negative("current_distance_m", current_distance_m)?;
        let moving_s = non_negative("moving_s", moving_s)?;
        Ok(PyLiveGhostSnapshot::from(self.inner.snapshot(
            Distance::from_meters(current_distance_m),
            Duration::from_secs(moving_s),
        )))
    }

    fn samples(&self) -> Vec<(f64, f64)> {
        self.inner
            .samples
            .iter()
            .map(|(d, t)| (d.meters(), t.as_secs()))
            .collect()
    }

    fn __repr__(&self) -> String {
        format!(
            "LiveGhost(samples={}, elapsed_time_s={})",
            self.inner.samples.len(),
            self.inner.elapsed_time().as_secs()
        )
    }
}

#[pyclass(name = "LiveRecorder", module = "against_yesterday")]
struct PyLiveRecorder {
    inner: RustLiveRecorder,
}

#[pymethods]
impl PyLiveRecorder {
    #[new]
    #[pyo3(signature = (route=None, config=None))]
    fn new(route: Option<&PyRoute>, config: Option<PyLiveConfig>) -> Self {
        let cfg = config
            .as_ref()
            .map(RustLiveConfig::from)
            .unwrap_or_default();
        let route = route.map(|r| r.inner.clone());
        PyLiveRecorder {
            inner: RustLiveRecorder::new(cfg, route),
        }
    }

    #[pyo3(signature = (ghost=None))]
    fn set_ghost(&mut self, ghost: Option<&PyLiveGhost>) {
        self.inner.set_ghost(ghost.map(|g| g.inner.clone()));
    }

    fn push(&mut self, fix: &PyGpsFix) {
        self.inner.push(fix.inner);
    }

    fn pause(&mut self) {
        self.inner.pause();
    }
    fn resume(&mut self) {
        self.inner.resume();
    }

    #[pyo3(signature = (distance_m, moving_s))]
    fn seed(&mut self, distance_m: f64, moving_s: f64) -> PyResult<()> {
        let distance_m = non_negative("distance_m", distance_m)?;
        let moving_s = non_negative("moving_s", moving_s)?;
        self.inner.seed(
            Distance::from_meters(distance_m),
            Duration::from_secs(moving_s),
        );
        Ok(())
    }

    fn finish(&mut self) {
        self.inner.finish();
    }
    fn complete_route(&mut self) {
        self.inner.complete_route();
    }

    #[getter]
    fn distance_m(&self) -> PyObject {
        callable_float(self.inner.distance().meters())
    }

    #[getter]
    fn moving_s(&self) -> PyObject {
        callable_float(self.inner.moving().as_secs())
    }

    #[getter]
    fn pace_mps(&self) -> PyObject {
        callable_float(self.inner.pace().mps())
    }

    #[getter]
    fn loop_length_m(&self) -> PyObject {
        callable_float(self.inner.loop_length().meters())
    }

    fn snapshot(&self) -> PyLiveSnapshot {
        PyLiveSnapshot::from(self.inner.snapshot())
    }

    fn ghost_snapshot(&self) -> Option<PyLiveGhostSnapshot> {
        self.inner.ghost_snapshot().map(PyLiveGhostSnapshot::from)
    }

    #[getter]
    fn elapsed_for_gap_s(&self) -> PyObject {
        callable_float(self.inner.elapsed_for_gap().as_secs())
    }

    fn __repr__(&self) -> String {
        format!(
            "LiveRecorder(distance_m={}, moving_s={}, pace_mps={})",
            self.inner.distance().meters(),
            self.inner.moving().as_secs(),
            self.inner.pace().mps()
        )
    }
}

#[pyclass(name = "ReplaySnapshot", module = "against_yesterday")]
struct PyReplaySnapshot {
    #[pyo3(get)]
    elapsed_s: f64,
    #[pyo3(get)]
    total_s: f64,
    #[pyo3(get)]
    state: PyObject,
    #[pyo3(get)]
    speed: f64,
    #[pyo3(get)]
    applied_fixes: usize,
    #[pyo3(get)]
    total_fixes: usize,
    #[pyo3(get)]
    latitude: Option<f64>,
    #[pyo3(get)]
    longitude: Option<f64>,
    #[pyo3(get)]
    accuracy_m: Option<f64>,
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    moving_s: f64,
    #[pyo3(get)]
    pace_mps: f64,
    #[pyo3(get)]
    route_progress: f64,
    #[pyo3(get)]
    reversed: bool,
    #[pyo3(get)]
    off_route_m: Option<f64>,
    #[pyo3(get)]
    match_status: PyObject,
    #[pyo3(get)]
    match_confidence: f64,
    #[pyo3(get)]
    ghost: Option<PyLiveGhostSnapshot>,
}

impl From<RustReplaySnapshot> for PyReplaySnapshot {
    fn from(s: RustReplaySnapshot) -> Self {
        let (member, value) = match s.state {
            RustReplayState::Playing => ("PLAYING", "playing"),
            RustReplayState::Paused => ("PAUSED", "paused"),
            RustReplayState::Finished => ("FINISHED", "finished"),
        };
        let state = enum_value("ReplayState", member, value);
        let (latitude, longitude) = match s.position {
            Some(c) => (Some(c.latitude()), Some(c.longitude())),
            None => (None, None),
        };
        let (member, value) = match s.match_status {
            RustLiveMatchStatus::None => ("NONE", "none"),
            RustLiveMatchStatus::Initializing => ("INITIALIZING", "initializing"),
            RustLiveMatchStatus::Matched => ("MATCHED", "matched"),
            RustLiveMatchStatus::Uncertain => ("UNCERTAIN", "uncertain"),
            RustLiveMatchStatus::OffRoute => ("OFF_ROUTE", "off_route"),
            RustLiveMatchStatus::Reacquiring => ("REACQUIRING", "reacquiring"),
        };
        let match_status = enum_value("LiveMatchStatus", member, value);
        PyReplaySnapshot {
            elapsed_s: s.elapsed.as_secs(),
            total_s: s.total.as_secs(),
            state,
            speed: s.speed,
            applied_fixes: s.applied_fixes,
            total_fixes: s.total_fixes,
            latitude,
            longitude,
            accuracy_m: s.accuracy.map(|d| d.meters()),
            distance_m: s.distance.meters(),
            moving_s: s.moving.as_secs(),
            pace_mps: s.pace.mps(),
            route_progress: s.route_progress,
            reversed: s.reversed,
            off_route_m: s.off_route.map(|d| d.meters()),
            match_status,
            match_confidence: s.match_confidence,
            ghost: s.ghost.map(PyLiveGhostSnapshot::from),
        }
    }
}

#[pymethods]
impl PyReplaySnapshot {
    fn __repr__(&self) -> String {
        format!(
            "ReplaySnapshot(elapsed_s={}, total_s={}, applied_fixes={}/{})",
            self.elapsed_s, self.total_s, self.applied_fixes, self.total_fixes
        )
    }
}

#[pyclass(name = "ReplaySession", module = "against_yesterday")]
struct PyReplaySession {
    inner: ReplaySession,
}

#[pymethods]
impl PyReplaySession {
    #[new]
    #[pyo3(signature = (fixes, route=None, ghost=None))]
    fn new(fixes: Vec<PyGpsFix>, route: Option<&PyRoute>, ghost: Option<&PyLiveGhost>) -> Self {
        let fixes = fixes.into_iter().map(|f| f.inner).collect();
        let route = route.map(|r| r.inner.clone());
        let ghost = ghost.map(|g| g.inner.clone());
        PyReplaySession {
            inner: ReplaySession::with_ghost(fixes, route, ghost),
        }
    }

    #[getter]
    fn duration_s(&self) -> PyObject {
        callable_float(self.inner.duration().as_secs())
    }

    #[getter]
    fn elapsed_s(&self) -> PyObject {
        callable_float(self.inner.elapsed().as_secs())
    }

    #[getter]
    fn state(&self) -> PyObject {
        let (member, value) = match self.inner.state() {
            RustReplayState::Playing => ("PLAYING", "playing"),
            RustReplayState::Paused => ("PAUSED", "paused"),
            RustReplayState::Finished => ("FINISHED", "finished"),
        };
        enum_value("ReplayState", member, value)
    }

    fn play(&mut self) {
        self.inner.play();
    }
    fn pause(&mut self) {
        self.inner.pause();
    }
    fn set_speed(&mut self, speed: f64) -> PyResult<()> {
        self.inner.set_speed(positive("speed", speed)?);
        Ok(())
    }
    fn seek(&mut self, elapsed_s: f64) -> PyResult<()> {
        let elapsed_s = non_negative("elapsed_s", elapsed_s)?;
        self.inner.seek(Duration::from_secs(elapsed_s));
        Ok(())
    }
    fn advance(&mut self, delta_s: f64) -> PyResult<PyReplaySnapshot> {
        let delta_s = non_negative("delta_s", delta_s)?;
        Ok(PyReplaySnapshot::from(
            self.inner.advance(Duration::from_secs(delta_s)),
        ))
    }
    fn snapshot(&self) -> PyReplaySnapshot {
        PyReplaySnapshot::from(self.inner.snapshot())
    }

    fn __repr__(&self) -> String {
        format!(
            "ReplaySession(duration_s={}, elapsed_s={})",
            self.inner.duration().as_secs(),
            self.inner.elapsed().as_secs()
        )
    }
}

#[pyclass(name = "MatchConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyMatchConfig {
    #[pyo3(get)]
    lateral_tolerance_m: f64,
    #[pyo3(get)]
    min_spatial_overlap: f64,
    #[pyo3(get)]
    min_distance_ratio: f64,
    #[pyo3(get)]
    max_distance_ratio: f64,
    #[pyo3(get)]
    max_start_distance_m: f64,
    #[pyo3(get)]
    max_end_distance_m: f64,
}

#[pymethods]
impl PyMatchConfig {
    #[new]
    #[pyo3(signature = (lateral_tolerance_m=25.0, min_spatial_overlap=0.6, min_distance_ratio=0.70, max_distance_ratio=1.45, max_start_distance_m=150.0, max_end_distance_m=150.0))]
    fn new(
        lateral_tolerance_m: f64,
        min_spatial_overlap: f64,
        min_distance_ratio: f64,
        max_distance_ratio: f64,
        max_start_distance_m: f64,
        max_end_distance_m: f64,
    ) -> PyResult<Self> {
        let lateral_tolerance_m = non_negative("lateral_tolerance_m", lateral_tolerance_m)?;
        let min_spatial_overlap = fraction("min_spatial_overlap", min_spatial_overlap)?;
        let min_distance_ratio = non_negative("min_distance_ratio", min_distance_ratio)?;
        let max_distance_ratio = non_negative("max_distance_ratio", max_distance_ratio)?;
        let max_start_distance_m = non_negative("max_start_distance_m", max_start_distance_m)?;
        let max_end_distance_m = non_negative("max_end_distance_m", max_end_distance_m)?;
        ensure(
            max_distance_ratio >= min_distance_ratio,
            "max_distance_ratio must be >= min_distance_ratio",
        )?;
        Ok(PyMatchConfig {
            lateral_tolerance_m,
            min_spatial_overlap,
            min_distance_ratio,
            max_distance_ratio,
            max_start_distance_m,
            max_end_distance_m,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "MatchConfig(lateral_tolerance_m={}, min_spatial_overlap={}, min_distance_ratio={}, max_distance_ratio={}, max_start_distance_m={}, max_end_distance_m={})",
            self.lateral_tolerance_m,
            self.min_spatial_overlap,
            self.min_distance_ratio,
            self.max_distance_ratio,
            self.max_start_distance_m,
            self.max_end_distance_m
        )
    }
}

impl From<&PyMatchConfig> for RustMatchConfig {
    fn from(c: &PyMatchConfig) -> Self {
        RustMatchConfig {
            lateral_tolerance: Distance::from_meters(c.lateral_tolerance_m),
            min_spatial_overlap: c.min_spatial_overlap,
            min_distance_ratio: c.min_distance_ratio,
            max_distance_ratio: c.max_distance_ratio,
            max_start_distance: Distance::from_meters(c.max_start_distance_m),
            max_end_distance: Distance::from_meters(c.max_end_distance_m),
        }
    }
}

#[pyclass(name = "MatchScore", module = "against_yesterday")]
#[derive(Clone)]
struct PyMatchScore {
    #[pyo3(get)]
    start_distance_m: f64,
    #[pyo3(get)]
    end_distance_m: f64,
    #[pyo3(get)]
    distance_ratio: f64,
    #[pyo3(get)]
    spatial_overlap: f64,
    #[pyo3(get)]
    direction_similarity: f64,
    #[pyo3(get)]
    continuity: f64,
    #[pyo3(get)]
    overall_score: f64,
    inner: RustMatchScore,
}

#[pymethods]
impl PyMatchScore {
    #[pyo3(signature = (config=None))]
    fn is_match(&self, config: Option<PyMatchConfig>) -> bool {
        let cfg = config
            .as_ref()
            .map(RustMatchConfig::from)
            .unwrap_or_default();
        self.inner.is_match(&cfg)
    }

    fn __repr__(&self) -> String {
        format!(
            "MatchScore(overall={}, overlap={}, direction={}, continuity={})",
            self.overall_score, self.spatial_overlap, self.direction_similarity, self.continuity
        )
    }
}

impl From<RustMatchScore> for PyMatchScore {
    fn from(s: RustMatchScore) -> Self {
        PyMatchScore {
            start_distance_m: s.start_distance.meters(),
            end_distance_m: s.end_distance.meters(),
            distance_ratio: s.distance_ratio,
            spatial_overlap: s.spatial_overlap,
            direction_similarity: s.direction_similarity,
            continuity: s.continuity,
            overall_score: s.overall_score,
            inner: s,
        }
    }
}

#[pyfunction]
#[pyo3(signature = (a, b, config=None))]
fn compare_tracks(
    py: Python<'_>,
    a: &PyTrack,
    b: &PyTrack,
    config: Option<PyMatchConfig>,
) -> PyMatchScore {
    let cfg = config
        .as_ref()
        .map(RustMatchConfig::from)
        .unwrap_or_default();
    let a = a.inner.clone();
    let b = b.inner.clone();
    let score = py.allow_threads(move || gps_engine::compare_with(&a, &b, &cfg));
    PyMatchScore::from(score)
}

#[pyfunction]
#[pyo3(signature = (a, b, config=None))]
fn compare_tracks_either_direction(
    py: Python<'_>,
    a: &PyTrack,
    b: &PyTrack,
    config: Option<PyMatchConfig>,
) -> Option<PyMatchScore> {
    let cfg = config
        .as_ref()
        .map(RustMatchConfig::from)
        .unwrap_or_default();
    let a = a.inner.clone();
    let b = b.inner.clone();
    py.allow_threads(move || compare_either_direction(&a, &b, &cfg))
        .map(PyMatchScore::from)
}

#[pyclass(name = "CanonicalizeConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyCanonicalizeConfig {
    #[pyo3(get)]
    step_m: f64,
    #[pyo3(get)]
    max_lateral_m: f64,
}

#[pymethods]
impl PyCanonicalizeConfig {
    #[new]
    #[pyo3(signature = (step_m=20.0, max_lateral_m=40.0))]
    fn new(step_m: f64, max_lateral_m: f64) -> PyResult<Self> {
        Ok(PyCanonicalizeConfig {
            step_m: positive("step_m", step_m)?,
            max_lateral_m: non_negative("max_lateral_m", max_lateral_m)?,
        })
    }

    fn __repr__(&self) -> String {
        format!(
            "CanonicalizeConfig(step_m={}, max_lateral_m={})",
            self.step_m, self.max_lateral_m
        )
    }
}

impl From<&PyCanonicalizeConfig> for RustCanonicalizeConfig {
    fn from(c: &PyCanonicalizeConfig) -> Self {
        RustCanonicalizeConfig {
            step: Distance::from_meters(c.step_m),
            max_lateral: Distance::from_meters(c.max_lateral_m),
        }
    }
}

#[pyfunction]
#[pyo3(signature = (tracks, config=None))]
fn canonicalize_route(
    py: Python<'_>,
    tracks: Vec<PyTrack>,
    config: Option<PyCanonicalizeConfig>,
) -> PyResult<PyRoute> {
    let rust_tracks: Vec<RustTrack> = tracks.into_iter().map(|t| t.inner).collect();
    let cfg = config
        .as_ref()
        .map(RustCanonicalizeConfig::from)
        .unwrap_or_default();
    let result = py.allow_threads(move || canonicalize_impl(&rust_tracks, &cfg));
    Ok(PyRoute {
        inner: result.map_err(canonical_err)?,
    })
}

#[pyclass(name = "TrackAddition", module = "against_yesterday")]
#[derive(Clone)]
struct PyTrackAddition {
    #[pyo3(get)]
    route_id: usize,
    #[pyo3(get)]
    is_new: bool,
    #[pyo3(get)]
    matched: Option<PyMatchScore>,
}

#[pymethods]
impl PyTrackAddition {
    fn __repr__(&self) -> String {
        format!(
            "TrackAddition(route_id={}, is_new={}, matched={})",
            self.route_id,
            self.is_new,
            self.matched.is_some()
        )
    }
}

#[pyclass(name = "DiscoveredRoute", module = "against_yesterday")]
#[derive(Clone)]
struct PyDiscoveredRoute {
    #[pyo3(get)]
    id: usize,
    #[pyo3(get)]
    track_count: usize,
    representative: PyTrack,
}

#[pymethods]
impl PyDiscoveredRoute {
    #[getter]
    fn representative(&self) -> PyTrack {
        self.representative.clone()
    }

    fn __repr__(&self) -> String {
        format!(
            "DiscoveredRoute(id={}, track_count={})",
            self.id, self.track_count
        )
    }
}

fn py_discovered_route(route: &RustDiscoveredRoute) -> PyDiscoveredRoute {
    PyDiscoveredRoute {
        id: route.id,
        track_count: route.track_count,
        representative: PyTrack {
            inner: route.representative().clone(),
        },
    }
}

#[pyclass(name = "DiscoveredRouteIterator", module = "against_yesterday")]
struct PyDiscoveredRouteIterator {
    routes: std::vec::IntoIter<PyDiscoveredRoute>,
}

#[pymethods]
impl PyDiscoveredRouteIterator {
    fn __repr__(&self) -> String {
        format!(
            "DiscoveredRouteIterator(remaining={})",
            self.routes.as_slice().len()
        )
    }

    fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
        slf
    }

    fn __next__(&mut self) -> Option<PyDiscoveredRoute> {
        self.routes.next()
    }
}

#[pyclass(name = "RouteCatalog", module = "against_yesterday")]
struct PyRouteCatalog {
    inner: RustRouteCatalog,
}

#[pymethods]
impl PyRouteCatalog {
    #[new]
    #[pyo3(signature = (config=None))]
    fn new(config: Option<PyMatchConfig>) -> Self {
        let cfg = config
            .as_ref()
            .map(RustMatchConfig::from)
            .unwrap_or_default();
        PyRouteCatalog {
            inner: RustRouteCatalog::new(cfg),
        }
    }

    fn add_track(&mut self, track: &PyTrack) -> PyTrackAddition {
        let add = self.inner.add_track(&track.inner);
        PyTrackAddition {
            route_id: add.route_id,
            is_new: add.is_new,
            matched: add.matched.map(PyMatchScore::from),
        }
    }

    fn route_count(&self) -> usize {
        self.inner.route_count()
    }

    fn routes(&self) -> Vec<PyDiscoveredRoute> {
        self.inner
            .routes()
            .iter()
            .map(py_discovered_route)
            .collect()
    }

    fn __iter__(&self) -> PyDiscoveredRouteIterator {
        PyDiscoveredRouteIterator {
            routes: self
                .inner
                .routes()
                .iter()
                .map(py_discovered_route)
                .collect::<Vec<_>>()
                .into_iter(),
        }
    }

    fn __len__(&self) -> usize {
        self.inner.route_count()
    }

    fn representative(&self, route_id: usize) -> Option<PyTrack> {
        self.inner
            .representative(route_id)
            .map(|t| PyTrack { inner: t.clone() })
    }

    fn __repr__(&self) -> String {
        format!("RouteCatalog(route_count={})", self.inner.route_count())
    }
}

#[pyclass(name = "AnalyticsQuality", module = "against_yesterday")]
#[derive(Clone)]
struct PyAnalyticsQuality {
    #[pyo3(get)]
    accepted_samples: u32,
    #[pyo3(get)]
    rejected_samples: u32,
    #[pyo3(get)]
    coverage_ratio: f64,
    #[pyo3(get)]
    gps_gap_count: u32,
    #[pyo3(get)]
    has_sufficient_distance: bool,
    #[pyo3(get)]
    has_elevation_data: bool,
}

impl From<RustAnalyticsQuality> for PyAnalyticsQuality {
    fn from(q: RustAnalyticsQuality) -> Self {
        PyAnalyticsQuality {
            accepted_samples: q.accepted_samples,
            rejected_samples: q.rejected_samples,
            coverage_ratio: q.coverage_ratio,
            gps_gap_count: q.gps_gap_count,
            has_sufficient_distance: q.has_sufficient_distance,
            has_elevation_data: q.has_elevation_data,
        }
    }
}

#[pymethods]
impl PyAnalyticsQuality {
    fn __repr__(&self) -> String {
        format!(
            "AnalyticsQuality(accepted_samples={}, rejected_samples={}, coverage_ratio={}, gps_gap_count={})",
            self.accepted_samples, self.rejected_samples, self.coverage_ratio, self.gps_gap_count
        )
    }
}

#[pyclass(name = "TrackAnalytics", module = "against_yesterday")]
#[derive(Clone)]
struct PyTrackAnalytics {
    #[pyo3(get)]
    distance_m: f64,
    #[pyo3(get)]
    elapsed_time_ms: u64,
    #[pyo3(get)]
    moving_time_ms: u64,
    #[pyo3(get)]
    paused_time_ms: u64,
    #[pyo3(get)]
    stopped_time_ms: u64,
    #[pyo3(get)]
    average_pace_ms_per_km: Option<u64>,
    #[pyo3(get)]
    average_speed_mps: Option<f64>,
    #[pyo3(get)]
    moving_speed_mps: Option<f64>,
    #[pyo3(get)]
    max_speed_mps: Option<f64>,
    #[pyo3(get)]
    best_pace_ms_per_km: Option<u64>,
    #[pyo3(get)]
    smoothed_best_pace_ms_per_km: Option<u64>,
    #[pyo3(get)]
    elevation_gain_m: Option<f64>,
    #[pyo3(get)]
    elevation_loss_m: Option<f64>,
    #[pyo3(get)]
    robust_elevation_gain_m: Option<f64>,
    #[pyo3(get)]
    robust_elevation_loss_m: Option<f64>,
    #[pyo3(get)]
    elevation_min_m: Option<f64>,
    #[pyo3(get)]
    elevation_max_m: Option<f64>,
    #[pyo3(get)]
    pace_samples: Vec<(f64, u64)>,
    #[pyo3(get)]
    smoothed_pace_samples: Vec<(f64, u64)>,
    #[pyo3(get)]
    elevation_samples: Vec<(f64, f64)>,
    #[pyo3(get)]
    quality: PyAnalyticsQuality,
    inner_json: String,
}

#[pymethods]
impl PyTrackAnalytics {
    fn to_json(&self) -> String {
        self.inner_json.clone()
    }

    fn __repr__(&self) -> String {
        format!(
            "TrackAnalytics(distance_m={}, elapsed_time_ms={})",
            self.distance_m, self.elapsed_time_ms
        )
    }
}

impl From<RustTrackAnalytics> for PyTrackAnalytics {
    fn from(a: RustTrackAnalytics) -> Self {
        let inner_json = a.to_json();
        PyTrackAnalytics {
            distance_m: a.distance_m,
            elapsed_time_ms: a.elapsed_time_ms,
            moving_time_ms: a.moving_time_ms,
            paused_time_ms: a.paused_time_ms,
            stopped_time_ms: a.stopped_time_ms,
            average_pace_ms_per_km: a.average_pace_ms_per_km,
            average_speed_mps: a.average_speed_mps,
            moving_speed_mps: a.moving_speed_mps,
            max_speed_mps: a.max_speed_mps,
            best_pace_ms_per_km: a.best_pace_ms_per_km,
            smoothed_best_pace_ms_per_km: a.smoothed_best_pace_ms_per_km,
            elevation_gain_m: a.elevation_gain_m,
            elevation_loss_m: a.elevation_loss_m,
            robust_elevation_gain_m: a.robust_elevation_gain_m,
            robust_elevation_loss_m: a.robust_elevation_loss_m,
            elevation_min_m: a.elevation_min_m,
            elevation_max_m: a.elevation_max_m,
            pace_samples: a.pace_samples,
            smoothed_pace_samples: a.smoothed_pace_samples,
            elevation_samples: a.elevation_samples,
            quality: PyAnalyticsQuality::from(a.quality),
            inner_json,
        }
    }
}

#[pyfunction]
fn parse_gpx(data: &str) -> PyResult<PyTrack> {
    PyTrack::from_gpx(data)
}

#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add_class::<PyTrackPoint>()?;
    m.add_class::<PyTrackPointIterator>()?;
    m.add_class::<PyTrack>()?;
    m.add_class::<PyFilterConfig>()?;
    m.add_class::<PySimplifyConfig>()?;
    m.add_class::<PyMovingConfig>()?;
    m.add_class::<PyProcessingReport>()?;
    m.add_class::<PyProjection>()?;
    m.add_class::<PyRoutePoint>()?;
    m.add_class::<PyRouteCoordinateIterator>()?;
    m.add_class::<PyRoute>()?;
    m.add_class::<PyAttemptSample>()?;
    m.add_class::<PyAttemptSampleIterator>()?;
    m.add_class::<PyAttemptMovingConfig>()?;
    m.add_class::<PyAttempt>()?;
    m.add_class::<PyComparisonConfig>()?;
    m.add_class::<PyComparisonPoint>()?;
    m.add_class::<PyPerformanceComparison>()?;
    m.add_class::<PyGhostState>()?;
    m.add_class::<PyGhostSnapshot>()?;
    m.add_class::<PyGhost>()?;
    m.add_class::<PyGpsFix>()?;
    m.add_class::<PyLiveConfig>()?;
    m.add_class::<PyLiveGhostSnapshot>()?;
    m.add_class::<PyLiveSnapshot>()?;
    m.add_class::<PyLiveGhost>()?;
    m.add_class::<PyLiveRecorder>()?;
    m.add_class::<PyReplaySnapshot>()?;
    m.add_class::<PyReplaySession>()?;
    m.add_class::<PyMatchConfig>()?;
    m.add_class::<PyMatchScore>()?;
    m.add_class::<PyCanonicalizeConfig>()?;
    m.add_class::<PyTrackAddition>()?;
    m.add_class::<PyDiscoveredRoute>()?;
    m.add_class::<PyDiscoveredRouteIterator>()?;
    m.add_class::<PyRouteCatalog>()?;
    m.add_class::<PyAnalyticsQuality>()?;
    m.add_class::<PyTrackAnalytics>()?;
    m.add_function(wrap_pyfunction!(parse_gpx, m)?)?;
    m.add_function(wrap_pyfunction!(compare_performances, m)?)?;
    m.add_function(wrap_pyfunction!(compare_tracks, m)?)?;
    m.add_function(wrap_pyfunction!(compare_tracks_either_direction, m)?)?;
    m.add_function(wrap_pyfunction!(canonicalize_route, m)?)?;
    Ok(())
}
