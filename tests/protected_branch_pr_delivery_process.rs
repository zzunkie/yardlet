#[cfg(unix)]
#[test]
fn protected_branch_delivery_and_crash_recovery_are_process_safe() {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script = manifest.join("tests/fixtures/protected_branch_pr_delivery/scripts/run.sh");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    let evidence = std::env::temp_dir().join(format!(
        "yardlet-protected-branch-pr-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&evidence).expect("create fixture evidence directory");

    let output = Command::new("bash")
        .arg(&script)
        .arg(env!("CARGO_BIN_EXE_yardlet"))
        .arg(&evidence)
        .output()
        .expect("run protected branch PR delivery fixture");

    if !output.status.success() {
        panic!(
            "protected branch fixture failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
            evidence.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let summary = std::fs::read_to_string(evidence.join("summary.json"))
        .expect("fixture must leave structured summary evidence");
    for expected in [
        "\"fixture_completed\": true",
        "\"public_remote_commands\": 0",
        "\"direct_base_pushes\": 1",
        "\"protected_base_pushes\": 0",
        "\"protected_head_pushes\": 1",
        "\"crash_windows_passed\": 4",
        "\"worker_invocations\": 0",
        "\"failure_projections_converged\": true",
        "\"ambient_host_ignored\": true",
        "\"enterprise_host_supported\": true",
    ] {
        assert!(summary.contains(expected), "missing {expected}: {summary}");
    }

    std::fs::remove_dir_all(&evidence).expect("remove successful fixture evidence");
}
