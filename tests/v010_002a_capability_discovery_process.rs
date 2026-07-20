#[cfg(unix)]
mod unix {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn run_scenario(scenario: &str) {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let script = manifest.join("tests/fixtures/v010_002a_capability_discovery/scripts/run.sh");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before Unix epoch")
            .as_nanos();
        let evidence = std::env::temp_dir().join(format!(
            "yardlet-v010-002a-{scenario}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&evidence).expect("create V010-002A capability evidence directory");

        let output = Command::new("bash")
            .arg(&script)
            .arg(env!("CARGO_BIN_EXE_yardlet"))
            .arg(&evidence)
            .arg(scenario)
            .output()
            .expect("run V010-002A capability process fixture");

        if !output.status.success() {
            panic!(
                "V010-002A scenario {scenario} failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
                evidence.display(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let summary = std::fs::read_to_string(evidence.join("summary.json"))
            .expect("fixture must leave structured summary evidence");
        assert!(summary.contains("\"status\": \"passed\""), "{summary}");
        assert!(
            summary.contains(&format!("\"scenario\": \"{scenario}\"")),
            "{summary}"
        );
        std::fs::remove_dir_all(&evidence).expect("remove successful fixture evidence");
    }

    #[test]
    fn hard_and_soft_trigger_matrix_matches_the_typed_core() {
        run_scenario("trigger_matrix");
    }

    #[test]
    fn scout_is_bounded_ordered_deduplicated_cached_and_authority_closed() {
        run_scenario("scout_policy");
    }

    #[test]
    fn restart_after_scout_preserves_evidence_without_duplicates() {
        run_scenario("restart_after_scout");
    }

    #[test]
    fn restart_before_confirm_preserves_pending_decision_without_duplicates() {
        run_scenario("restart_before_confirm");
    }

    #[test]
    fn malicious_scout_cannot_mutate_active_state() {
        run_scenario("active_state_isolation");
    }

    #[test]
    fn missing_nondeterministic_capability_stops_at_one_visible_disposition() {
        run_scenario("missing_capability_dogfood");
    }
}
