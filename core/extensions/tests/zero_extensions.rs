//! ADR-0009: the free core builds and runs with zero extensions, and no core crate depends on
//! an add-on. CI runs this with `cargo test --workspace`.

use std::path::Path;
use std::process::Command;

use cadence_asr::MockAsr;
use cadence_cleanup::{Guarded, RuleCleanup};
use cadence_extensions::{FinishedDictation, Registry};
use cadence_ipc::{Mode, ProcessingPolicy};
use cadence_orchestrator::{CollectSink, Pipeline};
use serde_json::Value;

fn tone(samples: usize) -> Vec<i16> {
    (0..samples)
        .map(|i| ((i as f32 * 0.1).sin() * 8000.0) as i16)
        .collect()
}

#[test]
fn a_full_dictation_runs_with_zero_extensions() {
    let mut registry = Registry::default();
    assert!(registry.is_empty(), "the free build ships no extensions");

    let mut asr = MockAsr {
        refined: "um so the launch email goes out thursday".into(),
    };
    let cleanup = Guarded::new(RuleCleanup::default());
    let mut sink = CollectSink::default();
    let pcm = tone(16_000 * 2);
    let mut pipeline = Pipeline::new(pcm.len(), &mut asr, &cleanup, &mut sink);
    let report = pipeline.run_utterance(&pcm, Mode::Dictation, ProcessingPolicy::LocalOnly);

    assert!(report.inserted);
    let text = report
        .final_text
        .clone()
        .expect("the core produced text on its own");
    assert!(!text.is_empty());
    assert_eq!(sink.inserted, vec![text.clone()]);
    assert!(!report.privacy.expect("privacy record").data_left_device);
    // The registry is not wired into the pipeline yet (ADR-0009); until it is, this pins that the
    // core alone delivers the text and that an empty registry reports no failures.
    let failed = registry.dictation_finished(&FinishedDictation::new(&text, None, report.inserted));
    assert!(failed.is_empty());
    assert_eq!(sink.inserted, vec![text]);
}

/// Every package in the resolved dependency graph (`cargo metadata`, so `[workspace.dependencies]`,
/// `[patch]`, git, alternate registries and any TOML spelling are all covered) must be either a
/// path crate inside this repo or a crates.io crate. A private add-on would be neither.
#[test]
fn no_core_crate_depends_on_an_add_on() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    let out = Command::new(env!("CARGO"))
        .args(["metadata", "--format-version", "1", "--locked"])
        .current_dir(&root)
        .output()
        .expect("cargo metadata runs");
    assert!(
        out.status.success(),
        "cargo metadata: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let meta: Value = serde_json::from_slice(&out.stdout).unwrap();
    let packages = meta["packages"].as_array().unwrap();
    assert!(
        packages.iter().any(|p| p["name"] == "cadence-extensions"),
        "the extensions crate is in the workspace"
    );
    for p in packages {
        let name = p["name"].as_str().unwrap();
        match p["source"].as_str() {
            None => {
                let manifest = Path::new(p["manifest_path"].as_str().unwrap())
                    .canonicalize()
                    .unwrap();
                assert!(
                    manifest.starts_with(&root),
                    "{name}: path crate outside the repo ({})",
                    manifest.display()
                );
            }
            Some(source) => assert!(
                source == "registry+https://github.com/rust-lang/crates.io-index"
                    || source.starts_with("sparse+https://index.crates.io/"),
                "{name}: comes from {source}, not crates.io or this repo"
            ),
        }
    }
}
