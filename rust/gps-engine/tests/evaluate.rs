// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Labeled-corpus evaluation against the committed synthetic corpus
//! (§38–§40). Route matching is a measurable engineering problem: precision
//! is prioritized, so the hard-note is the `outliers.gpx` family, whose
//! spikes keep it below the overlap floor (a documented false negative).

use std::collections::HashMap;
use std::path::Path;

use gps_engine::{
    ConfusionMatrix, LabeledPair, MatchConfig, evaluate, parse_manifest, read_gpx_file,
    standard_pipeline,
};

const CORPUS_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/synthetic");

fn load_labels() -> Vec<LabeledPair> {
    let text = std::fs::read_to_string(Path::new(CORPUS_DIR).join("manifest.json"))
        .expect("manifest.json exists; run `cargo run --example generate_corpus`");
    parse_manifest(&text).expect("manifest parses")
}

fn load_tracks() -> HashMap<String, gps_engine::Track> {
    let mut tracks = HashMap::new();
    for entry in std::fs::read_dir(CORPUS_DIR).expect("corpus directory") {
        let entry = entry.expect("entry");
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("gpx") {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let raw = read_gpx_file(&path).expect("corpus file parses");
        tracks.insert(name, standard_pipeline(&raw));
    }
    tracks
}

#[test]
fn manifest_has_45_pairs_and_both_labels() {
    let labels = load_labels();
    assert_eq!(
        labels.len(),
        45,
        "9 same-route tracks choose 2 + 9 vs other"
    );
    assert_eq!(labels.iter().filter(|p| p.expected).count(), 36);
    assert_eq!(labels.iter().filter(|p| !p.expected).count(), 9);
    // Every label references an actual corpus file.
    let names: Vec<String> = std::fs::read_dir(CORPUS_DIR)
        .expect("dir")
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".gpx"))
        .collect();
    for p in &labels {
        assert!(names.contains(&p.a), "{} missing", p.a);
        assert!(names.contains(&p.b), "{} missing", p.b);
    }
}

#[test]
fn matcher_meets_precision_first_floors() {
    let labels = load_labels();
    let tracks = load_tracks();
    let matrix = evaluate(&labels, &tracks, &MatchConfig::default());

    assert_eq!(
        matrix.false_positives,
        0,
        "every different route must be rejected: {}",
        matrix.report()
    );
    assert!(
        matrix.false_positives == 0,
        "false positives are the worst failure mode here"
    );

    assert!(
        matrix.precision().expect("some matches made") >= 0.99,
        "precision floor broken:\n{}",
        matrix.report()
    );
    assert!(
        matrix.recall().expect("positive examples present") >= 0.75,
        "recall floor broken (outliers is the known hard case):\n{}",
        matrix.report()
    );
    assert!(
        matrix.f1().expect("f1 defined") >= 0.85,
        "F1 floor broken:\n{}",
        matrix.report()
    );
}

#[test]
fn outliers_is_the_documented_false_negative() {
    // The spike-laden recordings are the only loop-family members expected to
    // miss the 0.6 overlap floor — everything else must recover.
    let labels = load_labels();
    let tracks = load_tracks();
    let matrix = evaluate(&labels, &tracks, &MatchConfig::default());

    let noisy_pair = labels
        .iter()
        .filter(|p| p.expected && (p.a.starts_with("outliers") || p.b.starts_with("outliers")))
        .count();
    assert_eq!(
        noisy_pair, 8,
        "outliers pairs with the eight other same-route tracks"
    );

    // All false negatives are the outliers family (8 pairs); the other ~all
    // same-route pairs are recovered. Asserting the exact total keeps the
    // corpus honest: 36 same-pairs, so 36 - fp... just check the shape.
    assert_eq!(matrix.false_negatives, noisy_pair);
    assert!(matrix.true_negatives >= 9);
}

#[test]
fn confusion_matrix_sums_match() {
    let mut empty = ConfusionMatrix::default();
    let a = ConfusionMatrix {
        true_positives: 1,
        false_positives: 2,
        true_negatives: 3,
        false_negatives: 4,
    };
    let b = ConfusionMatrix {
        true_positives: 5,
        false_positives: 6,
        true_negatives: 7,
        false_negatives: 8,
    };
    empty.merge(a);
    empty.merge(b);
    assert_eq!(empty.true_positives, 6);
    assert_eq!(empty.false_positives, 8);
    assert_eq!(empty.true_negatives, 10);
    assert_eq!(empty.false_negatives, 12);
}
