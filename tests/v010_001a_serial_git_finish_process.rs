#[cfg(unix)]
#[test]
fn yardlet_serial_chain_and_crash_recovery_converge_without_manual_git_finish() {
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let script = manifest.join("tests/fixtures/v010_001a_serial_git_finish/scripts/run.sh");
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    let evidence = std::env::temp_dir().join(format!(
        "yardlet-v010-001a-process-{}-{nonce}",
        std::process::id()
    ));
    std::fs::create_dir_all(&evidence).expect("create V010-001A evidence directory");

    let ambient_home = evidence.join("ambient-home");
    let ambient_system_config = evidence.join("ambient-system.gitconfig");
    let escaped_remote = evidence.join("ambient-escape/capture.git");
    let ambient_probe = evidence.join("ambient-probe");
    let benign_remote = evidence.join("ambient-benign.git");
    std::fs::create_dir_all(&ambient_home).expect("create malicious ambient HOME");
    std::fs::create_dir_all(escaped_remote.parent().expect("escaped remote parent"))
        .expect("create escaped remote parent");
    let init_remote = Command::new("git")
        .args(["init", "--bare", "--quiet"])
        .arg(&escaped_remote)
        .status()
        .expect("create local escaped bare remote");
    assert!(init_remote.success(), "create local escaped bare remote");
    std::fs::write(
        ambient_home.join(".gitconfig"),
        format!(
            "[remote \"origin\"]\n\tpushurl = {}\n",
            escaped_remote.display()
        ),
    )
    .expect("write malicious global Git config");
    std::fs::write(
        &ambient_system_config,
        format!(
            "[url \"file://{}/\"]\n\tpushInsteadOf = ambient://\n",
            escaped_remote
                .parent()
                .expect("escaped remote parent")
                .display()
        ),
    )
    .expect("write malicious system Git config");

    let init_probe = Command::new("git")
        .args(["init", "--quiet"])
        .arg(&ambient_probe)
        .status()
        .expect("create ambient config probe repository");
    assert!(
        init_probe.success(),
        "create ambient config probe repository"
    );
    let add_origin = Command::new("git")
        .arg("-C")
        .arg(&ambient_probe)
        .args(["remote", "add", "origin"])
        .arg(&benign_remote)
        .status()
        .expect("add ambient pushurl probe remote");
    assert!(add_origin.success(), "add ambient pushurl probe remote");
    let add_rewrite = Command::new("git")
        .arg("-C")
        .arg(&ambient_probe)
        .args(["remote", "add", "rewrite", "ambient://capture.git"])
        .status()
        .expect("add ambient pushInsteadOf probe remote");
    assert!(
        add_rewrite.success(),
        "add ambient pushInsteadOf probe remote"
    );

    let ambient_command = |remote: &str| {
        let mut command = Command::new("git");
        command
            .arg("-C")
            .arg(&ambient_probe)
            .args(["remote", "get-url", "--push", remote])
            .env("HOME", &ambient_home)
            .env("XDG_CONFIG_HOME", ambient_home.join("xdg"))
            .env("GIT_CONFIG_SYSTEM", &ambient_system_config)
            .env_remove("GIT_CONFIG")
            .env_remove("GIT_CONFIG_GLOBAL")
            .env_remove("GIT_CONFIG_NOSYSTEM")
            .env_remove("GIT_CONFIG_COUNT")
            .env_remove("GIT_CONFIG_PARAMETERS");
        command
    };
    let pushurl_resolution = ambient_command("origin")
        .output()
        .expect("resolve malicious ambient remote.pushurl");
    assert!(
        pushurl_resolution.status.success(),
        "resolve malicious ambient remote.pushurl"
    );
    assert_eq!(
        String::from_utf8_lossy(&pushurl_resolution.stdout).trim(),
        escaped_remote.to_string_lossy(),
        "RED proof: ambient remote.pushurl must retarget the benign remote"
    );
    let rewrite_resolution = ambient_command("rewrite")
        .output()
        .expect("resolve malicious ambient pushInsteadOf");
    assert!(
        rewrite_resolution.status.success(),
        "resolve malicious ambient pushInsteadOf"
    );
    assert_eq!(
        String::from_utf8_lossy(&rewrite_resolution.stdout).trim(),
        format!("file://{}", escaped_remote.display()),
        "RED proof: ambient pushInsteadOf must retarget the pseudo-local remote"
    );

    let fixture_command = |exit_trap_probe: bool| {
        let mut command = Command::new("bash");
        command
            .arg(&script)
            .arg(env!("CARGO_BIN_EXE_yardlet"))
            .arg(&evidence)
            .env("HOME", &ambient_home)
            .env("GIT_CONFIG_SYSTEM", &ambient_system_config)
            .env_remove("GIT_CONFIG")
            .env_remove("GIT_CONFIG_GLOBAL")
            .env_remove("GIT_CONFIG_NOSYSTEM")
            .env_remove("GIT_CONFIG_COUNT")
            .env_remove("GIT_CONFIG_PARAMETERS");
        if exit_trap_probe {
            command.env("YARDLET_FIXTURE_EXIT_TRAP_PROBE", "1");
        }
        command
    };

    let trap_output = fixture_command(true)
        .output()
        .expect("run V010-001A EXIT trap probe");
    assert!(
        !trap_output.status.success(),
        "EXIT trap probe must terminate through an intentional fixture failure"
    );
    let trap_proof = std::fs::read_to_string(evidence.join("exit-trap-cleanup.json"))
        .expect("EXIT trap probe must leave cleanup evidence");
    assert!(
        trap_proof.contains("\"process_group_absent\": true"),
        "{trap_proof}"
    );
    let trap_pgid = trap_proof
        .lines()
        .find_map(|line| line.trim().strip_prefix("\"pgid\": "))
        .and_then(|value| value.trim_end_matches(',').parse::<u32>().ok())
        .expect("EXIT trap proof PGID");
    let process_groups = Command::new("ps")
        .args(["-axo", "pgid="])
        .output()
        .expect("list process groups after EXIT trap probe");
    assert!(process_groups.status.success(), "list process groups");
    assert!(
        !String::from_utf8_lossy(&process_groups.stdout)
            .lines()
            .any(|line| line.trim() == trap_pgid.to_string()),
        "EXIT trap left process group {trap_pgid} alive"
    );

    let output = fixture_command(false)
        .output()
        .expect("run V010-001A process fixture");

    if !output.status.success() {
        panic!(
            "V010-001A process fixture failed; evidence kept at {}\nstdout:\n{}\nstderr:\n{}",
            evidence.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let summary = std::fs::read_to_string(evidence.join("summary.json"))
        .expect("fixture must leave structured summary evidence");
    assert!(summary.contains("\"status\": \"passed\""), "{summary}");
    assert!(summary.contains("\"scenarios_passed\": 6"), "{summary}");
    assert!(summary.contains("\"crash_windows_passed\": 5"), "{summary}");
    assert!(
        summary.contains("\"public_remote_commands\": 0"),
        "{summary}"
    );
    assert!(
        summary.contains("\"manual_finish_commands\": 0"),
        "{summary}"
    );
    assert!(
        summary.contains("\"ambient_git_config_ignored\": true"),
        "{summary}"
    );
    assert!(
        summary.contains("\"wrapper_escape_rejections\": 3"),
        "{summary}"
    );
    assert!(
        summary.contains("\"exit_trap_process_groups\": 1"),
        "{summary}"
    );
    assert!(
        !escaped_remote.join("refs/heads/main").exists(),
        "malicious ambient Git config received a push"
    );

    std::fs::remove_dir_all(&evidence).expect("remove successful fixture evidence");
}
