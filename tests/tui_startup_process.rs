#![cfg(unix)]

use std::fs;
use std::io::{ErrorKind, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

use common::open_pty;

fn test_root(name: &str) -> PathBuf {
    // Unique per run: WorkspaceGuard refuses to adopt an existing directory, so a
    // pid alone (which the OS recycles) is not a safe root name.
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "yard-tui-startup-{name}-{}-{nonce}",
        std::process::id()
    ))
}

fn write_worker(path: &Path, sentinel: &Path) {
    fs::write(
        path,
        format!(
            "#!/bin/sh\n\
             if [ \"${{1:-}}\" = \"--version\" ]; then\n\
             \x20 sleep 11\n\
             \x20 printf '%s\\n' 'slow-worker 1.0'\n\
             \x20 exit 0\n\
             fi\n\
             printf '%s\\n' invoked > '{}'\n",
            sentinel.display()
        ),
    )
    .unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

#[test]
fn slow_probe_and_recovery_do_not_block_first_safe_tui_frame() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    // Removed even if an assertion below unwinds past the clean exit — the other
    // half of issue #64.
    let workspace = common::WorkspaceGuard::create(test_root("first-frame"));
    let root = workspace.path().to_path_buf();

    let init = Command::new(&binary)
        .arg("init")
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(
        init.status.success(),
        "yardlet init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );
    let config_path = root.join(".agents/yardlet.yaml");
    let config = fs::read_to_string(&config_path)
        .unwrap()
        .replace("language: auto", "language: en");
    fs::write(config_path, config).unwrap();

    let bin_dir = root.join("fixture-bin");
    fs::create_dir_all(&bin_dir).unwrap();
    let sentinel = root.join("worker-invoked");
    write_worker(&bin_dir.join("codex"), &sentinel);
    write_worker(&bin_dir.join("claude"), &sentinel);

    let (mut master, slave) = open_pty(30, 120);
    let stdin = Stdio::from(slave.try_clone().unwrap());
    let stdout = Stdio::from(slave.try_clone().unwrap());
    let stderr = Stdio::from(slave);
    let path = format!(
        "{}:{}",
        bin_dir.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    let started = Instant::now();
    let child = Command::new(&binary)
        .current_dir(&root)
        .env("PATH", path)
        .env("TERM", "xterm-256color")
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .env("YARDLET_FIXTURE_RECOVERY_DELAY_MS", "11000")
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .unwrap();
    // Killed and reaped even if an assertion below unwinds past the clean quit
    // (issue #64).
    let mut child = common::ChildGuard::new(child);

    let marker = b"Starting Yardlet safely";
    let deadline = started + Duration::from_secs(3);
    let mut output = Vec::new();
    let first_frame = loop {
        let mut buffer = [0_u8; 8192];
        match master.read(&mut buffer) {
            Ok(0) => panic!("TUI exited before its first frame"),
            Ok(count) => {
                output.extend_from_slice(&buffer[..count]);
                if output.windows(marker.len()).any(|window| window == marker) {
                    break started.elapsed();
                }
            }
            Err(error) if error.kind() == ErrorKind::WouldBlock => {}
            Err(error) => panic!("PTY read failed: {error}"),
        }
        assert!(
            Instant::now() < deadline,
            "no safe first frame within 3s; output={}",
            String::from_utf8_lossy(&output)
        );
        std::thread::sleep(Duration::from_millis(10));
    };

    assert!(
        first_frame <= Duration::from_millis(1000),
        "first safe frame took {}ms",
        first_frame.as_millis()
    );
    println!("first_safe_frame_ms={}", first_frame.as_millis());

    master.write_all(b"r").unwrap();
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        !sentinel.exists(),
        "queue execution key reached a worker while startup was incomplete"
    );
    master.write_all(b"q").unwrap();

    child.shutdown(Duration::from_secs(3), || {});
    // `workspace` removes the root on drop, on this path and on a panicking one.
}
