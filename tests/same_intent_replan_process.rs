#[cfg(unix)]
mod unix {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn run_scenario(scenario: &str) {
        let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let script = manifest.join("tests/fixtures/same_intent_replan/scripts/run.sh");
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock before Unix epoch")
            .as_nanos();
        let evidence = std::env::temp_dir().join(format!(
            "yardlet-replan-{scenario}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&evidence).expect("create same-intent replan evidence directory");

        let output = Command::new("bash")
            .arg(&script)
            .arg(env!("CARGO_BIN_EXE_yardlet"))
            .arg(&evidence)
            .arg(scenario)
            .output()
            .expect("run same-intent replan process fixture");

        if !output.status.success() {
            panic!(
                "same-intent replan scenario {scenario} failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
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
    fn failed_confirmed_intent_replans_under_the_same_intent_id_with_typed_failure_audit() {
        run_scenario("same_intent_replan");
    }

    #[test]
    fn feedback_cap_exhaustion_types_the_hold_and_unlocks_replan_while_worker_questions_stay_answer_only(
    ) {
        run_scenario("goal_feedback_exhausted_replan");
    }

    #[test]
    fn mixed_worker_question_and_partial_queue_stays_answer_only() {
        run_scenario("mixed_worker_question_replan");
    }
}
