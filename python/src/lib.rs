// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

use pyo3::create_exception;
use pyo3::exceptions::PyValueError;
use pyo3::prelude::*;
use pyo3::types::PyModule;

use gps_engine::{
    Coordinate, Distance, Duration, FilterConfig as RustFilterConfig,
    MovingConfig as RustMovingConfig, ProcessingReport as RustProcessingReport,
    SimplifyConfig as RustSimplifyConfig, Speed, Timestamp, Track as RustTrack,
    TrackPoint as RustTrackPoint, geo::Bearing, parse_gpx as parse_gpx_impl,
    write_gpx as write_gpx_impl, write_gpx_file,
};

create_exception!(_native, EngineError, PyValueError);
create_exception!(_native, GeoError, EngineError);
create_exception!(_native, TrackError, EngineError);
create_exception!(_native, GpxError, EngineError);

fn geo_err(err: gps_engine::GeoError) -> PyErr {
    GeoError::new_err(err.to_string())
}

fn track_err(err: gps_engine::TrackError) -> PyErr {
    TrackError::new_err(err.to_string())
}

fn gpx_err(err: gps_engine::GpxError) -> PyErr {
    GpxError::new_err(err.to_string())
}

#[pyclass(name = "TrackPoint", module = "against_yesterday")]
#[derive(Clone)]
struct PyTrackPoint {
    #[pyo3(get)]
    latitude: f64,
    #[pyo3(get)]
    longitude: f64,
    /// Milliseconds since the Unix epoch.
    #[pyo3(get)]
    timestamp_ms: i64,
    #[pyo3(get)]
    altitude_m: Option<f64>,
    #[pyo3(get)]
    speed_mps: Option<f64>,
    #[pyo3(get)]
    accuracy_m: Option<f64>,
    /// Bearing in degrees clockwise from north.
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
    ) -> Self {
        PyTrackPoint {
            latitude,
            longitude,
            timestamp_ms,
            altitude_m,
            speed_mps,
            accuracy_m,
            bearing_deg,
        }
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
        let coord = Coordinate::new(point.latitude, point.longitude).map_err(geo_err)?;
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

#[pyclass(name = "MovingConfig", module = "against_yesterday")]
#[derive(Clone)]
struct PyMovingConfig {
    #[pyo3(get, set)]
    min_speed_mps: f64,
    #[pyo3(get, set)]
    min_stop_duration_s: f64,
}

#[pymethods]
impl PyMovingConfig {
    #[new]
    #[pyo3(signature = (min_speed_mps=0.5, min_stop_duration_s=5.0))]
    fn new(min_speed_mps: f64, min_stop_duration_s: f64) -> Self {
        PyMovingConfig {
            min_speed_mps,
            min_stop_duration_s,
        }
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
    #[pyo3(get, set)]
    max_accuracy_m: Option<f64>,
    #[pyo3(get, set)]
    max_speed_kmh: Option<f64>,
    #[pyo3(get, set)]
    max_jump_m: Option<f64>,
    #[pyo3(get, set)]
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
    ) -> Self {
        PyFilterConfig {
            max_accuracy_m,
            max_speed_kmh,
            max_jump_m,
            max_time_gap_s,
        }
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
    #[pyo3(get, set)]
    tolerance_m: f64,
}

#[pymethods]
impl PySimplifyConfig {
    #[new]
    #[pyo3(signature = (tolerance_m=2.0))]
    fn new(tolerance_m: f64) -> Self {
        PySimplifyConfig { tolerance_m }
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
    fn from_gpx_path(path: String) -> PyResult<Self> {
        let inner = gps_engine::read_gpx_file(path).map_err(gpx_err)?;
        Ok(PyTrack { inner })
    }

    #[staticmethod]
    fn from_gpx(data: &str) -> PyResult<Self> {
        let inner = parse_gpx_impl(data.as_bytes()).map_err(gpx_err)?;
        Ok(PyTrack { inner })
    }

    fn to_gpx(&self) -> PyResult<String> {
        let mut out = Vec::new();
        write_gpx_impl(&self.inner, &mut out).map_err(gpx_err)?;
        String::from_utf8(out).map_err(|e| GpxError::new_err(e.to_string()))
    }

    fn to_gpx_path(&self, path: String) -> PyResult<()> {
        write_gpx_file(&self.inner, path).map_err(gpx_err)
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
    fn filter(&self, config: Option<PyFilterConfig>) -> (PyTrack, PyProcessingReport) {
        let cfg = config
            .as_ref()
            .map(RustFilterConfig::from)
            .unwrap_or_default();
        let (track, report) = self.inner.filter(&cfg);
        (PyTrack { inner: track }, PyProcessingReport::from(report))
    }

    #[pyo3(signature = (tolerance_m=2.0, config=None))]
    fn simplify(&self, tolerance_m: f64, config: Option<PySimplifyConfig>) -> PyTrack {
        let cfg = config.unwrap_or_else(|| PySimplifyConfig::new(tolerance_m));
        let track = self.inner.simplify(&RustSimplifyConfig::from(&cfg));
        PyTrack { inner: track }
    }

    #[pyo3(signature = (interval_m))]
    fn resample_by_distance(&self, interval_m: f64) -> PyResult<PyTrack> {
        let track = self
            .inner
            .resample_by_distance(Distance::from_meters(interval_m))
            .map_err(track_err)?;
        Ok(PyTrack { inner: track })
    }

    fn reversed(&self) -> PyTrack {
        PyTrack {
            inner: self.inner.reversed(),
        }
    }

    fn __len__(&self) -> usize {
        self.inner.len()
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

#[pyfunction]
fn parse_gpx(data: &str) -> PyResult<PyTrack> {
    PyTrack::from_gpx(data)
}

#[pymodule]
fn _native(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    m.add_class::<PyTrackPoint>()?;
    m.add_class::<PyTrack>()?;
    m.add_class::<PyFilterConfig>()?;
    m.add_class::<PySimplifyConfig>()?;
    m.add_class::<PyMovingConfig>()?;
    m.add_class::<PyProcessingReport>()?;
    m.add("EngineError", m.py().get_type::<EngineError>())?;
    m.add("GeoError", m.py().get_type::<GeoError>())?;
    m.add("TrackError", m.py().get_type::<TrackError>())?;
    m.add("GpxError", m.py().get_type::<GpxError>())?;
    m.add_function(wrap_pyfunction!(parse_gpx, m)?)?;
    Ok(())
}
