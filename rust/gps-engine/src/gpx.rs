// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! GPX track input.
//!
//! GPX is treated purely as an adapter:
//!
//! ```text
//! GPX  →  TrackPoint  →  Track
//! ```
//!
//! Nothing else in the engine cares where a track came from. The parser reads
//! every `<trkpt>` in the document in order (all segments of all `<trk>`
//! elements are flattened), keeping the standard `lat`/`lon` attributes,
//! `<ele>`, and `<time>` fields. A Garmin-style `<gpxtpx:Speed>` extension is
//! also recognized and mapped onto [`TrackPoint::speed`].
//!
//! A `<trkpt>` without a `<time>` element is given the previous point's
//! timestamp plus one second (or the epoch, for the first point), keeping the
//! result ordered and deterministic.

use std::io::{Read, Write};
use std::path::Path;

use quick_xml::Reader;
use quick_xml::events::{BytesStart, Event};

use crate::error::{GpxError, TrackField};
use crate::geo::Coordinate;
use crate::track::{Track, TrackPoint};
use crate::units::Timestamp;

/// Parses a GPX document from in-memory bytes into a validated [`Track`].
///
/// See the [module docs](self) for the supported subset.
pub fn parse_gpx(data: &[u8]) -> Result<Track, GpxError> {
    let mut reader = Reader::from_reader(data);
    reader.config_mut().trim_text(true);
    reader.config_mut().check_end_names = true;

    let mut buf: Vec<u8> = Vec::new();
    let mut points: Vec<TrackPoint> = Vec::new();

    // Per-`<trkpt>` accumulation, cleared after each point is emitted.
    let mut in_trkpt = false;
    let mut lat: Option<f64> = None;
    let mut lon: Option<f64> = None;
    let mut ele: Option<f64> = None;
    let mut speed: Option<f64> = None;
    let mut time: Option<Timestamp> = None;

    // Text capture while inside an `<ele>`, `<time>`, or Speed element.
    let mut text_buf = String::new();
    let mut field: Option<PendingField> = None;

    // Last emitted timestamp, for synthesizing missing `<time>` values.
    let mut last_time: Option<Timestamp> = None;

    loop {
        let event = reader
            .read_event_into(&mut buf)
            .map_err(|e| GpxError::Parse(e.to_string()))?;

        match event {
            Event::Start(start) => match start.local_name().as_ref() {
                b"trkpt" => {
                    if in_trkpt {
                        // Previous `<trkpt>` was not closed; flush it so its
                        // data is not silently dropped.
                        emit_pending(&mut points, lat, lon, ele, speed, time, &mut last_time)?;
                        reset_pending(&mut lat, &mut lon, &mut ele, &mut speed, &mut time);
                    }
                    begin_trkpt(&start, &mut lat, &mut lon)?;
                    in_trkpt = true;
                }
                b"ele" if in_trkpt => {
                    field = Some(PendingField::Ele);
                    text_buf.clear();
                }
                b"time" if in_trkpt => {
                    field = Some(PendingField::Time);
                    text_buf.clear();
                }
                name if in_trkpt && (name == b"Speed" || name == b"speed") => {
                    field = Some(PendingField::Speed);
                    text_buf.clear();
                }
                _ => {}
            },
            Event::Empty(empty) => {
                if empty.local_name().as_ref() == b"trkpt" {
                    begin_trkpt(&empty, &mut lat, &mut lon)?;
                    emit_pending(&mut points, lat, lon, ele, speed, time, &mut last_time)?;
                    reset_pending(&mut lat, &mut lon, &mut ele, &mut speed, &mut time);
                }
            }
            Event::End(end) => match end.local_name().as_ref() {
                b"trkpt" => {
                    emit_pending(&mut points, lat, lon, ele, speed, time, &mut last_time)?;
                    reset_pending(&mut lat, &mut lon, &mut ele, &mut speed, &mut time);
                    in_trkpt = false;
                }
                b"ele" | b"time" | b"Speed" | b"speed" => {
                    if let Some(which) = field.take() {
                        capture_field(
                            which,
                            &text_buf,
                            &mut ele,
                            &mut speed,
                            &mut time,
                            points.len(),
                        )?;
                    }
                }
                _ => {}
            },
            Event::Text(text) => {
                if field.is_some() {
                    text_buf.push_str(
                        &text
                            .unescape()
                            .map_err(|e| GpxError::Parse(e.to_string()))?,
                    );
                }
            }
            Event::CData(cdata) => {
                if field.is_some() {
                    text_buf.push_str(&cdata.decode().map_err(|e| GpxError::Parse(e.to_string()))?);
                }
            }
            Event::Eof => break,
            Event::Decl(_) | Event::DocType(_) | Event::Comment(_) | Event::PI(_) => {}
        }

        buf.clear();
    }

    Track::new(points).map_err(GpxError::from)
}

/// Reads a whole GPX file from disk.
pub fn read_gpx_file(path: impl AsRef<Path>) -> Result<Track, GpxError> {
    let bytes = std::fs::read(path).map_err(|e| GpxError::Io(e.to_string()))?;
    parse_gpx(&bytes)
}

/// Reads a GPX document from any reader.
pub fn read_gpx(mut reader: impl Read) -> Result<Track, GpxError> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(|e| GpxError::Io(e.to_string()))?;
    parse_gpx(&bytes)
}

/// Writes `track` as a GPX 1.1 document to `writer`.
///
/// Emits one `<trkseg>` containing every point's `lat`/`lon`, `<ele>` (when
/// the point has an altitude), and a full-precision `<time>` in UTC. Speed and
/// accuracy fields are not serialized. Output is deterministic — the same
/// track always produces byte-identical GPX.
pub fn write_gpx(track: &Track, writer: &mut impl Write) -> Result<(), GpxError> {
    let mut body = String::with_capacity(96 * track.points().len());
    for point in track.points() {
        let (lat, lon) = (
            point.coordinate().latitude(),
            point.coordinate().longitude(),
        );
        body.push_str(&format!(
            "      <trkpt lat=\"{lat:.6}\" lon=\"{lon:.6}\">\n"
        ));
        if let Some(ele) = point.altitude() {
            body.push_str(&format!("        <ele>{ele:.2}</ele>\n"));
        }
        body.push_str(&format!(
            "        <time>{}</time>\n",
            format_rfc3339(point.timestamp())
        ));
        body.push_str("      </trkpt>\n");
    }

    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    out.push_str("<gpx version=\"1.1\" creator=\"gps-engine\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n");
    out.push_str("  <trk>\n");
    out.push_str("    <name>gps-engine export</name>\n");
    out.push_str("    <trkseg>\n");
    out.push_str(&body);
    out.push_str("    </trkseg>\n");
    out.push_str("  </trk>\n");
    out.push_str("</gpx>\n");

    writer
        .write_all(out.as_bytes())
        .map_err(|e| GpxError::Io(e.to_string()))
}

/// Writes `track` as a GPX document to `path`.
pub fn write_gpx_file(track: &Track, path: impl AsRef<Path>) -> Result<(), GpxError> {
    let mut file = std::fs::File::create(path).map_err(|e| GpxError::Io(e.to_string()))?;
    write_gpx(track, &mut file)
}

/// Formats `timestamp` as UTC RFC 3339 at millisecond precision.
fn format_rfc3339(timestamp: Timestamp) -> String {
    let ms = timestamp.unix_ms();
    let days = ms.div_euclid(86_400_000);
    let intra_day = ms.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    let hour = intra_day / 3_600_000;
    let minute = (intra_day % 3_600_000) / 60_000;
    let second = (intra_day % 60_000) / 1_000;
    let millis = intra_day % 1_000;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

/// Proleptic Gregorian calendar date from days since 1970-01-01.
///
/// Inverse of [`days_from_civil`] (Howard Hinnant's `civil_from_days`).
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// The element currently being read inside a `<trkpt>`, if any.
#[derive(Debug, Clone, Copy, PartialEq)]
enum PendingField {
    Ele,
    Time,
    Speed,
}

/// Parses the `lat`/`lon` attributes of a `<trkpt>` start element.
fn begin_trkpt(
    start: &BytesStart<'_>,
    lat: &mut Option<f64>,
    lon: &mut Option<f64>,
) -> Result<(), GpxError> {
    *lat = None;
    *lon = None;
    for attr in start.attributes() {
        let attr = attr.map_err(|e| GpxError::Parse(e.to_string()))?;
        let value = std::str::from_utf8(attr.value.as_ref())
            .map_err(|_| GpxError::Parse("non-UTF-8 attribute value".into()))?;
        match attr.key.as_ref() {
            b"lat" => {
                if let Ok(v) = value.parse() {
                    *lat = Some(v);
                } else {
                    return Err(GpxError::Coordinate(value.to_string()));
                }
            }
            b"lon" => {
                if let Ok(v) = value.parse() {
                    *lon = Some(v);
                } else {
                    return Err(GpxError::Coordinate(value.to_string()));
                }
            }
            _ => {}
        }
    }
    if lat.is_none() || lon.is_none() {
        return Err(GpxError::Parse("trkpt missing lat/lon attributes".into()));
    }
    Ok(())
}

/// Routes collected `<ele>`/`<time>`/`<speed>` text into the pending fields.
fn capture_field(
    which: PendingField,
    text_buf: &str,
    ele: &mut Option<f64>,
    speed: &mut Option<f64>,
    time: &mut Option<Timestamp>,
    index: usize,
) -> Result<(), GpxError> {
    let raw = text_buf.trim();
    match which {
        PendingField::Ele => *ele = Some(parse_f64(raw, TrackField::Altitude, index)?),
        PendingField::Speed => *speed = Some(parse_f64(raw, TrackField::Speed, index)?),
        PendingField::Time => *time = Some(parse_rfc3339(raw)?),
    }
    Ok(())
}

fn parse_f64(raw: &str, field: TrackField, index: usize) -> Result<f64, GpxError> {
    let value: f64 = raw.parse().map_err(|_| GpxError::InvalidValue {
        index,
        field,
        value: raw.to_string(),
    })?;
    if !value.is_finite() {
        return Err(GpxError::InvalidValue {
            index,
            field,
            value: raw.to_string(),
        });
    }
    Ok(value)
}

/// Builds a [`TrackPoint`] from the pending fields and appends it.
fn emit_pending(
    points: &mut Vec<TrackPoint>,
    lat: Option<f64>,
    lon: Option<f64>,
    ele: Option<f64>,
    speed: Option<f64>,
    time: Option<Timestamp>,
    last_time: &mut Option<Timestamp>,
) -> Result<(), GpxError> {
    let lat = lat.ok_or_else(|| GpxError::Parse("trkpt without lat".into()))?;
    let lon = lon.ok_or_else(|| GpxError::Parse("trkpt without lon".into()))?;
    let coordinate = Coordinate::new(lat, lon).map_err(|e| GpxError::Coordinate(e.to_string()))?;

    let timestamp = match time {
        Some(t) => t,
        None => match *last_time {
            Some(prev) => Timestamp::from_unix_ms(prev.unix_ms() + 1000),
            None => Timestamp::from_unix_ms(0),
        },
    };

    let mut point = TrackPoint::new(timestamp, coordinate);
    if let Some(e) = ele {
        point = point.with_altitude(e).map_err(GpxError::Track)?;
    }
    if let Some(s) = speed {
        point = point.with_speed(s).map_err(GpxError::Track)?;
    }

    *last_time = Some(timestamp);
    points.push(point);
    Ok(())
}

fn reset_pending(
    lat: &mut Option<f64>,
    lon: &mut Option<f64>,
    ele: &mut Option<f64>,
    speed: &mut Option<f64>,
    time: &mut Option<Timestamp>,
) {
    *lat = None;
    *lon = None;
    *ele = None;
    *speed = None;
    *time = None;
}

/// Parses an RFC 3339 timestamp (as used by GPX `<time>`) into unix
/// milliseconds. Accepts `YYYY-MM-DD[T ]HH:MM:SS[.fffffffff][Z|±hh:mm]`.
fn parse_rfc3339(raw: &str) -> Result<Timestamp, GpxError> {
    fn fail(raw: &str, reason: &str) -> GpxError {
        GpxError::InvalidTime {
            index: 0,
            value: raw.to_string(),
            reason: reason.to_string(),
        }
    }

    let b = raw.as_bytes();
    if b.len() < 20 {
        return Err(fail(raw, "expected YYYY-MM-DD[T ]HH:MM:SS"));
    }
    fn digit(b: &[u8], i: usize) -> Option<i64> {
        match b.get(i) {
            Some(&c) if c.is_ascii_digit() => Some((c - b'0') as i64),
            _ => None,
        }
    }
    fn tag(b: &[u8], i: usize, want: u8) -> bool {
        b.get(i) == Some(&want)
    }

    let (year, month, day, hour, minute, second, millis, offset_secs, end) = (|| {
        let year = digit(b, 0)? * 1000 + digit(b, 1)? * 100 + digit(b, 2)? * 10 + digit(b, 3)?;
        if !tag(b, 4, b'-') {
            return None;
        }
        let month = digit(b, 5)? * 10 + digit(b, 6)?;
        if !tag(b, 7, b'-') {
            return None;
        }
        let day = digit(b, 8)? * 10 + digit(b, 9)?;
        if b[10] != b'T' && b[10] != b' ' {
            return None;
        }
        let hour = digit(b, 11)? * 10 + digit(b, 12)?;
        if !tag(b, 13, b':') {
            return None;
        }
        let minute = digit(b, 14)? * 10 + digit(b, 15)?;
        if !tag(b, 16, b':') {
            return None;
        }
        let second = digit(b, 17)? * 10 + digit(b, 18)?;

        // Fractional seconds, milliseconds precision.
        let mut idx = 19usize;
        let mut millis = 0i64;
        if tag(b, idx, b'.') {
            idx += 1;
            let mut weight = 100i64;
            let mut consumed = 0;
            while consumed < 3
                && let Some(&c) = b.get(idx)
                && c.is_ascii_digit()
            {
                millis += (c - b'0') as i64 * weight;
                weight /= 10;
                consumed += 1;
                idx += 1;
            }
            while let Some(&c) = b.get(idx)
                && c.is_ascii_digit()
            {
                idx += 1;
            }
        }

        // Timezone offset.
        let mut offset_secs = 0i64;
        match b.get(idx) {
            Some(&b'Z') | Some(&b'z') => idx += 1,
            Some(&b'+') | Some(&b'-') => {
                let sign = if b[idx] == b'+' { 1 } else { -1 };
                let hour = digit(b, idx + 1)? * 10 + digit(b, idx + 2)?;
                if !tag(b, idx + 3, b':') {
                    return None;
                }
                let minute = digit(b, idx + 4)? * 10 + digit(b, idx + 5)?;
                offset_secs = sign * (hour * 3600 + minute * 60);
                idx += 6;
            }
            _ => return None,
        }

        Some((
            year,
            month,
            day,
            hour,
            minute,
            second,
            millis,
            offset_secs,
            idx,
        ))
    })()
    .ok_or_else(|| fail(raw, "malformed timestamp"))?;

    if index_out_of_range(year, month, day, hour, minute, second) {
        return Err(fail(raw, "field out of range"));
    }
    if end != b.len() {
        return Err(fail(raw, "trailing characters after timestamp"));
    }

    let days = days_from_civil(year, month, day);
    let unix_ms = days * 86_400_000 + hour * 3_600_000 + minute * 60_000 + second * 1000 + millis
        - offset_secs * 1000;
    Ok(Timestamp::from_unix_ms(unix_ms))
}

fn index_out_of_range(
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
) -> bool {
    !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || !(0..=23).contains(&hour)
        || !(0..=59).contains(&minute)
        || !(0..=60).contains(&second)
        || year < 0
}

/// Days since 1970-01-01 from a proleptic Gregorian calendar date.
///
/// Uses Howard Hinnant's `days_from_civil` algorithm.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}
