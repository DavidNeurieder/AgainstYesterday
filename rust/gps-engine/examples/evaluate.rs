// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Labeled-corpus evaluation (§38–§40): measures route-matching quality.
//!
//! ```text
//! cargo run --example evaluate
//! ```
//!
//! Loads every committed track under `testdata/synthetic/`, runs them through
//! the [`standard_pipeline`], compares every pair listed in `manifest.json`
//! under the default [`MatchConfig`], and reports the confusion matrix with
//! precision / recall / F1 / false-positive rate.
//!
//! The manifest carries ground truth (which pairs *are* the same route), so
//! route matching becomes a measurable engineering problem: per the plan,
//! precision is optimized first (fewer false positives is better than missing
//! a hard case).

use std::collections::HashMap;
use std::path::Path;

use gps_engine::{
    ConfusionMatrix, LabeledPair, MatchConfig, evaluate, parse_manifest, read_gpx_file,
    standard_pipeline,
};

const CORPUS_DIR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/testdata/synthetic");

fn main() {
    let manifest_path = Path::new(CORPUS_DIR).join("manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path)
        .expect("corpus manifest exists (run the generate_corpus example)");
    let labels: Vec<LabeledPair> = parse_manifest(&manifest_text).expect("valid manifest");

    let mut tracks: HashMap<String, gps_engine::Track> = HashMap::new();
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

    println!(
        "labeled pairs: {} over {} tracks",
        labels.len(),
        tracks.len()
    );
    println!();
    let matrix = evaluate(&labels, &tracks, &MatchConfig::default());
    println!("{}", matrix.report());
}

/// Exposed for the integration test to share the exact evaluation above.
pub fn run() -> ConfusionMatrix {
    let manifest_path = Path::new(CORPUS_DIR).join("manifest.json");
    let manifest_text = std::fs::read_to_string(&manifest_path).expect("corpus manifest exists");
    let labels = parse_manifest(&manifest_text).expect("valid manifest");

    let mut tracks: HashMap<String, gps_engine::Track> = HashMap::new();
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
    evaluate(&labels, &tracks, &MatchConfig::default())
}
