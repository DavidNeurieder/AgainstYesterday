// Copyright (C) 2026 David Neurieder
// SPDX-License-Identifier: AGPL-3.0-or-later

//! Prints the deterministic GPS quality baseline against synthetic truth.
//!
//! ```text
//! cargo run --example quality_benchmark
//! cargo run --example quality_benchmark -- --json baseline.json
//! ```

use gps_engine::quality_metrics::{QualityReport, benchmark_scenarios};

fn main() {
    let mut json_path = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--json" => json_path = Some(args.next().expect("--json needs a path")),
            other => panic!("unknown argument: {other}"),
        }
    }

    let report = QualityReport::from_scenarios(&benchmark_scenarios());
    print!("{}", report.report());
    if let Some(path) = json_path {
        std::fs::write(&path, report.to_json()).expect("write quality baseline");
        println!("wrote {path}");
    }
}
