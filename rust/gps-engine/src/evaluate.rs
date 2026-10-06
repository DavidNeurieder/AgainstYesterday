// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Standard processing pipeline and labeled-corpus evaluation (§33, §38–§40).
//!
//! [`standard_pipeline`] is the single processing recipe used everywhere
//! (CLI, matching tests, the evaluator): filter, simplify, then resample.
//!
//! The evaluation side turns route matching into a measurable engineering
//! problem: a labeled corpus of every track pair, one machine-readable
//! "same"/"different" expectation per pair, and a confusion matrix with
//! precision/recall/F1/false-positive-rate (§39–§40).

use std::collections::HashMap;

use crate::Track;
use crate::route::matching::{MatchConfig, compare_either_direction};
use crate::units::Distance;

/// One labeled pair from a ground-truth manifest.
#[derive(Debug, Clone, PartialEq)]
pub struct LabeledPair {
    /// Relative path (or file name) of the first track.
    pub a: String,
    /// Relative path (or file name) of the second track.
    pub b: String,
    /// Ground truth: whether `a` and `b` are the same route.
    pub expected: bool,
}

/// 2×2 classification table over labeled track pairs.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ConfusionMatrix {
    /// Same route, correctly classified as same.
    pub true_positives: usize,
    /// Different route, wrongly classified as same.
    pub false_positives: usize,
    /// Different route, correctly classified as different.
    pub true_negatives: usize,
    /// Same route, wrongly classified as different.
    pub false_negatives: usize,
}

impl ConfusionMatrix {
    /// Adds another confusion matrix into `self`.
    pub fn merge(&mut self, other: ConfusionMatrix) {
        self.true_positives += other.true_positives;
        self.false_positives += other.false_positives;
        self.true_negatives += other.true_negatives;
        self.false_negatives += other.false_negatives;
    }

    /// Precision: of everything classified "same", how much was right.
    /// `None` when nothing was classified "same".
    pub fn precision(&self) -> Option<f64> {
        let predicted_same = self.true_positives + self.false_positives;
        if predicted_same == 0 {
            None
        } else {
            Some(self.true_positives as f64 / predicted_same as f64)
        }
    }

    /// Recall: of everything that truly was the same route, how much was found.
    /// `None` when there were no positive examples.
    pub fn recall(&self) -> Option<f64> {
        let actual_same = self.true_positives + self.false_negatives;
        if actual_same == 0 {
            None
        } else {
            Some(self.true_positives as f64 / actual_same as f64)
        }
    }

    /// False-positive rate across all negative pairs.
    /// `None` when there were no negative examples.
    pub fn false_positive_rate(&self) -> Option<f64> {
        let actual_different = self.false_positives + self.true_negatives;
        if actual_different == 0 {
            None
        } else {
            Some(self.false_positives as f64 / actual_different as f64)
        }
    }

    /// Harmonic mean of precision and recall. `None` when either is undefined.
    pub fn f1(&self) -> Option<f64> {
        match (self.precision(), self.recall()) {
            (Some(p), Some(r)) if p + r > 0.0 => Some(2.0 * p * r / (p + r)),
            _ => None,
        }
    }

    /// Fixed-width human-readable report (for diagnostics and example output).
    pub fn report(&self) -> String {
        let fmt = |v: Option<f64>| match v {
            Some(x) => format!("{x:.3}"),
            None => "    n/a".to_string(),
        };
        format!(
            "true positives:    {:>4}\n\
             false positives:   {:>4}\n\
             true negatives:    {:>4}\n\
             false negatives:   {:>4}\n\
             \n\
             precision:         {}\n\
             recall:            {}\n\
             F1:                {}\n\
             false-positive rate: {}",
            self.true_positives,
            self.false_positives,
            self.true_negatives,
            self.false_negatives,
            fmt(self.precision()),
            fmt(self.recall()),
            fmt(self.f1()),
            fmt(self.false_positive_rate()),
        )
    }
}

/// Standard processing recipe: [`crate::filter`], [`crate::simplify`], then
/// resample to a 25 m cadence. Used by the CLI and the evaluator so matching
/// always sees comparable geometry.
pub fn standard_pipeline(track: &Track) -> Track {
    let (filtered, _report) = crate::filter(track, &crate::FilterConfig::default());
    let simplified = crate::simplify(&filtered, &crate::SimplifyConfig::default());
    simplified
        .resample_by_distance(Distance::from_meters(25.0))
        .expect("resampling a processed track keeps it valid")
}

/// Classifies every labeled pair by comparing them under `config` in either
/// direction (reversed recordings still count as the same route).
pub fn evaluate(
    pairs: &[LabeledPair],
    tracks: &HashMap<String, Track>,
    config: &MatchConfig,
) -> ConfusionMatrix {
    let mut matrix = ConfusionMatrix::default();
    for pair in pairs {
        let (Some(a), Some(b)) = (tracks.get(&pair.a), tracks.get(&pair.b)) else {
            continue;
        };
        let predicted_same = compare_either_direction(a, b, config).is_some();
        match (pair.expected, predicted_same) {
            (true, true) => matrix.true_positives += 1,
            (true, false) => matrix.false_negatives += 1,
            (false, true) => matrix.false_positives += 1,
            (false, false) => matrix.true_negatives += 1,
        }
    }
    matrix
}

/// Parses the §39 ground-truth manifest schema.
///
/// Reads exactly the documented shape — an object whose `matches` array holds
/// `{ "a": "../path", "b": "../path", "expected": "same"|"different" }` — and
/// nothing else. Keep the parser intentionally small: the manifest is written
/// by this repo's own generator, not by arbitrary tools.
pub fn parse_manifest(input: &str) -> Result<Vec<LabeledPair>, String> {
    let mut cursor = Cursor::new(input);

    cursor.expect(b'{')?;
    let key = cursor.expect_key()?;
    if key != "matches" {
        return Err(format!(
            "unsupported manifest key {key:?} (only \"matches\")"
        ));
    }
    cursor.expect(b':')?;
    cursor.expect(b'[')?;

    let mut pairs = Vec::new();
    loop {
        if cursor.peek(b']') {
            cursor.advance();
            break;
        }
        pairs.push(cursor.expect_pair()?);
        if cursor.peek(b',') {
            cursor.advance();
        } else if cursor.peek(b']') {
            cursor.advance();
            break;
        } else {
            return Err("expected ',' or ']' between manifest entries".to_string());
        }
    }

    cursor.expect(b'}')?;
    cursor.skip_ws();
    if !cursor.at_end() {
        return Err(format!(
            "trailing content after manifest: {:?}",
            cursor.remaining()
        ));
    }
    Ok(pairs)
}

/// A tiny byte cursor over an ASCII/UTF-8 manifest span.
struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            bytes: input.as_bytes(),
            pos: 0,
        }
    }

    fn at_end(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn remaining(&self) -> String {
        // The manifest is written by our own generator; a non-UTF-8 tail is
        // reported lossily (only used in error messages).
        String::from_utf8_lossy(&self.bytes[self.pos..]).into_owned()
    }

    fn peek(&mut self, byte: u8) -> bool {
        self.skip_ws();
        self.bytes.get(self.pos) == Some(&byte)
    }

    fn advance(&mut self) {
        self.skip_ws();
        self.pos += 1;
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        self.skip_ws();
        match self.bytes.get(self.pos) {
            Some(&found) if found == byte => {
                self.pos += 1;
                Ok(())
            }
            Some(&found) => Err(format!("expected {byte:?}, got {found:?}")),
            None => Err(format!("unexpected end of manifest, expected {byte:?}")),
        }
    }

    fn expect_key(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut key = String::new();
        loop {
            match self.bytes.get(self.pos) {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(key);
                }
                Some(&byte) => {
                    key.push(byte as char);
                    self.pos += 1;
                }
                None => return Err("unterminated key string".to_string()),
            }
        }
    }

    /// `"..."` JSON string; only `\\` and `\"` escapes are supported.
    fn expect_string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut value = String::new();
        loop {
            match self.bytes.get(self.pos) {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(value);
                }
                Some(b'\\') => match self.bytes.get(self.pos + 1) {
                    Some(b'"') => {
                        value.push('"');
                        self.pos += 2;
                    }
                    Some(b'\\') => {
                        value.push('\\');
                        self.pos += 2;
                    }
                    Some(&other) => return Err(format!("unsupported escape \\{}", other as char)),
                    None => return Err("trailing backslash in string".to_string()),
                },
                Some(&byte) => {
                    value.push(byte as char);
                    self.pos += 1;
                }
                None => return Err("unterminated string".to_string()),
            }
        }
    }

    /// `{ "a": ..., "b": ..., "expected": "same"|"different" }`.
    fn expect_pair(&mut self) -> Result<LabeledPair, String> {
        self.expect(b'{')?;
        let mut a = None;
        let mut b = None;
        let mut expected = None;
        loop {
            let key = self.expect_key()?;
            self.expect(b':')?;
            match key.as_str() {
                "a" => a = Some(self.expect_string()?),
                "b" => b = Some(self.expect_string()?),
                "expected" => {
                    let value = self.expect_string()?;
                    expected = Some(match value.as_str() {
                        "same" => true,
                        "different" => false,
                        other => {
                            return Err(format!(
                                "expected must be \"same\" or \"different\", got {other:?}"
                            ));
                        }
                    });
                }
                other => return Err(format!("unsupported pair key {other:?}")),
            }
            if self.peek(b',') {
                self.advance();
            } else {
                break;
            }
        }
        self.expect(b'}')?;
        let (Some(a), Some(b), Some(expected)) = (a, b, expected) else {
            return Err("manifest pair must have a, b, expected".to_string());
        };
        Ok(LabeledPair { a, b, expected })
    }

    fn skip_ws(&mut self) {
        while let Some(&byte) = self.bytes.get(self.pos) {
            if matches!(byte, b' ' | b'\t' | b'\n' | b'\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_parse_round_trip() {
        let json = "{\n  \"matches\": [\n    {\"a\": \"run/01.gpx\", \"b\": \"run/02.gpx\", \"expected\": \"same\"},\n    {\"a\": \"run/01.gpx\", \"b\": \"other.gpx\", \"expected\": \"different\"}\n  ]\n}";
        let pairs = parse_manifest(json).unwrap();
        assert_eq!(
            pairs,
            vec![
                LabeledPair {
                    a: "run/01.gpx".into(),
                    b: "run/02.gpx".into(),
                    expected: true
                },
                LabeledPair {
                    a: "run/01.gpx".into(),
                    b: "other.gpx".into(),
                    expected: false
                },
            ]
        );
    }

    #[test]
    fn manifest_rejects_bad_labels() {
        let json = r#"{"matches":[{"a":"x","b":"y","expected":"maybe"}]}"#;
        assert!(parse_manifest(json).is_err());
    }

    #[test]
    fn confusion_matrix_metrics() {
        let m = ConfusionMatrix {
            true_positives: 9,
            false_positives: 1,
            true_negatives: 8,
            false_negatives: 2,
        };
        assert_eq!(m.precision().unwrap(), 0.9);
        assert!((m.recall().unwrap() - 9.0 / 11.0).abs() < 1e-12);
        assert!((m.false_positive_rate().unwrap() - 1.0 / 9.0).abs() < 1e-12);
        let f1 = m.f1().unwrap();
        assert!((f1 - 2.0 * 0.9 * (9.0 / 11.0) / (0.9 + 9.0 / 11.0)).abs() < 1e-12);
    }

    #[test]
    fn empty_matrix_reports_none() {
        let m = ConfusionMatrix::default();
        assert_eq!(m.precision(), None);
        assert_eq!(m.recall(), None);
        assert_eq!(m.f1(), None);
        assert_eq!(m.false_positive_rate(), None);
    }

    #[test]
    fn standard_pipeline_keeps_track_valid() {
        let route = [
            crate::Coordinate::new(52.500, 13.400).unwrap(),
            crate::Coordinate::new(52.520, 13.400).unwrap(),
        ];
        let track =
            crate::synthetic::generate(&route, &crate::synthetic::SyntheticConfig::noisy(1, 8.0));
        let processed = standard_pipeline(&track);
        assert!(processed.points().len() >= 2);
        assert!(processed.start().is_some());
    }
}
