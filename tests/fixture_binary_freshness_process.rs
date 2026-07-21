#[cfg(unix)]
mod unix {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn run_scenario(scenario: &str) {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let script = manifest.join("tests/fixtures/fixture_binary_freshness/scripts/run.sh");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before Unix epoch")
            .as_nanos();
        let evidence = std::env::temp_dir().join(format!(
            "yardlet-fixture-binary-freshness-{scenario}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&evidence)
            .expect("create fixture binary freshness evidence directory");

        let output = Command::new("bash")
            .arg(&script)
            .arg(env!("CARGO_BIN_EXE_yardlet"))
            .arg(&evidence)
            .arg(scenario)
            .output()
            .expect("run fixture binary freshness process fixture");

        if !output.status.success() {
            panic!(
                "fixture binary freshness scenario {scenario} failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
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
    fn stale_binary_missing_one_required_id_stops_before_fixture_body() {
        run_scenario("stale_single");
    }

    #[test]
    fn stale_binary_missing_multiple_required_ids_reports_every_id() {
        run_scenario("stale_multiple");
    }

    #[test]
    fn fresh_binary_preserves_named_fixture_execution() {
        run_scenario("fresh");
    }
}
