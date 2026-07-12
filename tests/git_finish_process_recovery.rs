#[cfg(unix)]
#[test]
fn actual_process_crashes_and_concurrent_recovery_converge_once() {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script = manifest.join("tests/fixtures/git_finish_process_recovery/scripts/run.sh");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    let evidence = std::env::temp_dir().join(format!(
        "yardlet-git-finish-process-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&evidence).expect("create fixture evidence directory");

    let output = Command::new("bash")
        .arg(&script)
        .arg(env!("CARGO_BIN_EXE_yardlet"))
        .arg(&evidence)
        .output()
        .expect("run process recovery fixture");

    if !output.status.success() {
        panic!(
            "process recovery fixture failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
            evidence.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let summary = std::fs::read_to_string(evidence.join("summary.json"))
        .expect("fixture must leave structured summary evidence");
    assert!(
        summary.contains("\"status\": \"passed\""),
        "unexpected fixture summary: {summary}"
    );
    assert!(summary.contains("\"public_remote_commands\": 0"));
    assert!(summary.contains("\"worker_invocations\": 0"));

    std::fs::remove_dir_all(&evidence).expect("remove successful fixture evidence");
}
