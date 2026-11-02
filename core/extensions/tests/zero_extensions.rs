//! ADR-0009: the free core builds and runs with zero extensions, and no core crate depends on
//! an add-on. CI runs this with `cargo test --workspace`.

use std::fs;
use std::path::{Path, PathBuf};

use cadence_asr::MockAsr;
use cadence_cleanup::{Guarded, RuleCleanup};
use cadence_extensions::{FinishedDictation, Registry};
use cadence_ipc::{Mode, ProcessingPolicy};
use cadence_orchestrator::{CollectSink, Pipeline};

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

    // Handing the result to an empty registry changes nothing.
    registry.dictation_finished(&FinishedDictation {
        text: &text,
        language: Some("en"),
        inserted: report.inserted,
    });
    assert_eq!(sink.inserted, vec![text]);
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap()
}

/// Members listed in the workspace Cargo.toml.
fn members(root: &Path) -> Vec<String> {
    let manifest = fs::read_to_string(root.join("Cargo.toml")).unwrap();
    let block = manifest
        .split("members = [")
        .nth(1)
        .unwrap()
        .split(']')
        .next()
        .unwrap();
    block
        .split(',')
        .map(|m| m.trim().trim_matches('"').to_string())
        .filter(|m| !m.is_empty())
        .collect()
}

#[test]
fn no_core_crate_depends_on_an_add_on() {
    let root = repo_root();
    let members = members(&root);
    assert!(
        members.iter().any(|m| m == "core/extensions"),
        "the extensions crate is in the workspace"
    );
    for member in &members {
        let dir = root.join(member);
        let manifest = fs::read_to_string(dir.join("Cargo.toml")).unwrap();
        for line in manifest
            .lines()
            .map(str::trim)
            .filter(|l| !l.starts_with('#'))
        {
            // Add-ons live in another repository; pulling one in would need a git or an outside path dependency.
            assert!(!line.contains("git ="), "{member}: git dependency `{line}`");
            if let Some(rest) = line.split("path = \"").nth(1) {
                let target = dir
                    .join(rest.split('"').next().unwrap())
                    .canonicalize()
                    .unwrap_or_else(|_| {
                        panic!("{member}: path dependency `{line}` does not exist")
                    });
                assert!(
                    target.starts_with(&root),
                    "{member}: path dependency outside the repo `{line}`"
                );
            }
        }
    }
}
