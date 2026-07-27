//! End-to-end PTY integration for planning re-entry across a process boundary
//! (issue #65).
//!
//! Every existing planning test drives the whole flow inside ONE process:
//! plan -> review -> accept -> confirm. That is exactly why the reported dead
//! end was invisible — the review screen had a single production entry point
//! ("a planning job just finished in THIS process"), so an accepted but
//! unconfirmed draft became unreachable the moment the TUI restarted.
//!
//! This test therefore uses two separate `yardlet` processes over real
//! pseudo-terminals against the same workspace:
//!
//!   1. Process one plans and accepts a draft, then quits WITHOUT confirming.
//!      The session is left `lifecycle: open`, `current_head` set,
//!      `confirmation_id: null` — the exact on-disk state from the report.
//!   2. Process two starts fresh. Home must say a plan is waiting (the queue is
//!      legitimately empty here, so without that row it looks like no work at
//!      all), advertise the key, and open the review screen when it is pressed.
//!
//! The planner is a deterministic shell fixture on the workspace's own path, so
//! nothing here needs a real worker CLI or network.

#![cfg(unix)]

use std::fs::{self, File};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

fn test_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "yard-tui-planning-reentry-{}-{nonce}",
        std::process::id()
    ))
}

/// A deterministic planning worker: one valid single-task proposal per turn.
fn write_planner(path: &Path) {
    fs::write(
        path,
        "#!/usr/bin/env bash\n\
         set -euo pipefail\n\
         if [[ \"${1:-}\" == \"--version\" ]]; then\n\
         \x20 printf 'fixture-planner 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         cat >/dev/null\n\
         mkdir -p \"$run_dir\"\n\
         cat >\"$run_dir/planning-result.json\" <<'EOF'\n\
         {\n\
         \x20 \"summary\": \"reentry fixture slice\",\n\
         \x20 \"rationale\": \"deterministic reentry fixture\",\n\
         \x20 \"allowed_scope\": [\"tests/\"],\n\
         \x20 \"out_of_scope\": [\"src/ui/**\"],\n\
         \x20 \"acceptance\": [{\"id\": \"AC-001\", \"statement\": \"reentry fixture proposal\"}],\n\
         \x20 \"ambiguity\": {\"score\": \"low\", \"open_questions\": []},\n\
         \x20 \"tasks\": [{\n\
         \x20 \x20 \"id\": \"YARD-001\",\n\
         \x20 \x20 \"title\": \"reentry fixture task\",\n\
         \x20 \x20 \"kind\": \"implementation\",\n\
         \x20 \x20 \"risk\": \"low\",\n\
         \x20 \x20 \"preferred_worker\": \"fixture-planner\",\n\
         \x20 \x20 \"model\": \"auto\",\n\
         \x20 \x20 \"effort\": \"auto\",\n\
         \x20 \x20 \"depends_on\": [],\n\
         \x20 \x20 \"skills\": [],\n\
         \x20 \x20 \"required_capabilities\": [],\n\
         \x20 \x20 \"allowed_scope\": [\"tests/\"],\n\
         \x20 \x20 \"acceptance\": [\"reentry fixture proposal\"],\n\
         \x20 \x20 \"worker_rationale\": \"deterministic fixture\"\n\
         \x20 }],\n\
         \x20 \"questions_for_user\": []\n\
         }\n\
         EOF\n\
         printf 'fixture planning turn\\n'\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn open_pty() -> (File, File) {
    let mut master = -1;
    let mut slave = -1;
    let mut size = libc::winsize {
        ws_row: 40,
        ws_col: 140,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut size as *mut libc::winsize,
        )
    };
    assert_eq!(rc, 0, "openpty failed: {}", std::io::Error::last_os_error());
    let master = unsafe { File::from_raw_fd(master) };
    let slave = unsafe { File::from_raw_fd(slave) };
    let flags = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    let rc = unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) };
    assert_eq!(rc, 0);
    (master, slave)
}

/// Drain everything currently readable. Draining continuously is mandatory: a
/// full PTY buffer blocks the child on its next render.
fn drain(master: &mut File, sink: &mut Vec<u8>) {
    let mut buffer = [0_u8; 8192];
    loop {
        match master.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => sink.extend_from_slice(&buffer[..count]),
            Err(error) if error.kind() == ErrorKind::WouldBlock => break,
            Err(error) => panic!("PTY read failed: {error}"),
        }
    }
}

/// Ratatui positions every wide (CJK) cell with its own cursor-move escape, so
/// a Korean word is not a contiguous byte run until the escapes are stripped.
fn strip_ansi(bytes: &[u8]) -> String {
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == 0x1b {
            match bytes.get(i + 1) {
                Some(b'[') => {
                    i += 2;
                    while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                        i += 1;
                    }
                    i += usize::from(i < bytes.len());
                }
                Some(b']') => {
                    i += 2;
                    while i < bytes.len() {
                        if bytes[i] == 0x07 {
                            i += 1;
                            break;
                        }
                        if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'\\') {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                }
                Some(_) => i += 2,
                None => break,
            }
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Whitespace between cells is emitted as cursor motion too, so compare the
/// visible text with all whitespace removed.
fn norm(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace()).collect()
}

fn seen(sink: &[u8], marker: &str) -> bool {
    norm(&strip_ansi(sink)).contains(&norm(marker))
}

fn recent(sink: &[u8]) -> String {
    let text = strip_ansi(sink);
    let chars: Vec<char> = text.chars().collect();
    let start = chars.len().saturating_sub(800);
    chars[start..].iter().collect()
}

fn wait_for_marker(master: &mut File, sink: &mut Vec<u8>, marker: &str, within: Duration) {
    let deadline = Instant::now() + within;
    loop {
        drain(master, sink);
        if seen(sink, marker) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "marker {marker:?} not seen within {within:?}; recent output:\n{}",
            recent(sink)
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Poll a workspace predicate while still draining the PTY, so the child never
/// blocks on render while we wait for its side effect.
fn wait_until(
    master: &mut File,
    sink: &mut Vec<u8>,
    label: &str,
    within: Duration,
    ready: impl Fn() -> bool,
) {
    let deadline = Instant::now() + within;
    loop {
        drain(master, sink);
        if ready() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{label} did not happen within {within:?}; recent output:\n{}",
            recent(sink)
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn spawn_tui(binary: &Path, root: &Path) -> (common::ChildGuard, File, Vec<u8>) {
    let (master, slave) = open_pty();
    let stdin = Stdio::from(slave.try_clone().unwrap());
    let stdout = Stdio::from(slave.try_clone().unwrap());
    let stderr = Stdio::from(slave);
    let child = Command::new(binary)
        .current_dir(root)
        .env("TERM", "xterm-256color")
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .unwrap();
    // Killed and reaped even if an assertion unwinds past the clean quit
    // (issue #64).
    (common::ChildGuard::new(child), master, Vec::new())
}

fn quit_tui(child: &mut common::ChildGuard, master: &mut File, sink: &mut Vec<u8>) {
    std::thread::sleep(Duration::from_millis(200));
    let _ = master.write_all(b"q");
    std::thread::sleep(Duration::from_millis(150));
    let _ = master.write_all(b"q");
    child.shutdown(Duration::from_secs(5), || drain(master, sink));
}

/// The single open session's record, read straight off disk.
fn session_yaml(root: &Path) -> String {
    let sessions = root.join(".agents/planning-sessions");
    let latest = fs::read_to_string(sessions.join("latest")).unwrap();
    fs::read_to_string(sessions.join(latest.trim()).join("session.yaml")).unwrap()
}

fn accepted_but_unconfirmed(root: &Path) -> bool {
    let sessions = root.join(".agents/planning-sessions");
    let Ok(latest) = fs::read_to_string(sessions.join("latest")) else {
        return false;
    };
    let Ok(record) = fs::read_to_string(sessions.join(latest.trim()).join("session.yaml")) else {
        return false;
    };
    record.contains("lifecycle: open")
        && record.contains("current_head: drv_")
        && !record.contains("confirmation_id: cnf")
}

#[test]
fn an_accepted_unconfirmed_plan_is_reachable_from_home_after_a_restart() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let root = test_root();
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();

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
        .replace("language: auto", "language: ko");
    fs::write(&config_path, config).unwrap();

    let planner = root.join("fixture-planner.sh");
    write_planner(&planner);
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\n\
             workers:\n\
             \x20 - id: fixture-planner\n\
             \x20 \x20 kind: cli_worker\n\
             \x20 \x20 best_for: deterministic planning fixture\n\
             \x20 \x20 billing:\n\
             \x20 \x20 \x20 mode: subscription_backed_only\n\
             \x20 \x20 invocation:\n\
             \x20 \x20 \x20 command: {}\n\
             \x20 \x20 \x20 supports_noninteractive: true\n\
             \x20 \x20 \x20 output_contract: files\n\
             \x20 \x20 \x20 args: [\"{{run_dir}}\"]\n\
             \x20 \x20 limits:\n\
             \x20 \x20 \x20 max_wall_minutes: 1\n\
             \x20 \x20 \x20 max_retries: 0\n\
             routing:\n\
             \x20 default_worker: fixture-planner\n\
             \x20 fallback_order: [fixture-planner]\n\
             \x20 planning_gate:\n\
             \x20 \x20 primary: fixture-planner\n\
             \x20 \x20 fallback: \"\"\n",
            planner.display()
        ),
    )
    .unwrap();

    // ---- process one: plan, accept, quit without confirming ---------------
    let (mut first, mut master, mut sink) = spawn_tui(&binary, &root);
    wait_for_marker(&mut master, &mut sink, "새작업", Duration::from_secs(20));
    master.write_all(b"n").unwrap();
    wait_for_marker(
        &mut master,
        &mut sink,
        "작업을 몇 문장으로",
        Duration::from_secs(5),
    );
    master.write_all("REENTRY-PLAN-REQUEST".as_bytes()).unwrap();
    master.write_all(b"\x13").unwrap(); // Ctrl+S submit
    wait_for_marker(&mut master, &mut sink, "플랜 검토", Duration::from_secs(20));
    wait_for_marker(&mut master, &mut sink, "a 수락", Duration::from_secs(10));
    master.write_all(b"a").unwrap(); // accept, but never `c` confirm
    {
        let root = root.clone();
        wait_until(
            &mut master,
            &mut sink,
            "draft acceptance",
            Duration::from_secs(15),
            move || accepted_but_unconfirmed(&root),
        );
    }
    quit_tui(&mut first, &mut master, &mut sink);

    // The reported on-disk state: a whole plan waiting, and no queue.
    let record = session_yaml(&root);
    assert!(
        record.contains("lifecycle: open") && record.contains("current_head: drv_"),
        "process one did not leave an open session with an accepted head:\n{record}"
    );
    assert!(
        !record.contains("confirmation_id: cnf"),
        "process one confirmed the draft; the re-entry state was never reached:\n{record}"
    );
    let queue = fs::read_to_string(root.join(".agents/work-queue.yaml")).unwrap();
    assert!(
        !queue.contains("YARD-001"),
        "an unconfirmed draft must not have produced a queue:\n{queue}"
    );

    // ---- process two: the restart the operator actually did ---------------
    let (mut second, mut master, mut sink) = spawn_tui(&binary, &root);
    // A frame is drawn top to bottom, so wait on the LAST thing the re-entry
    // state adds — the footer key. Reaching it means the whole Home frame,
    // queue row included, has been emitted. (Timing out here is itself the
    // "key is not advertised" failure, reported with the rendered tail.)
    wait_for_marker(
        &mut master,
        &mut sink,
        "o 플랜 검토",
        Duration::from_secs(20),
    );
    assert!(
        seen(&sink, "수락된 플랜이 큐 확정을 기다리는 중"),
        "Home did not say a plan is waiting, so an empty queue is all the operator sees;\n{}",
        recent(&sink)
    );

    master.write_all(b"o").unwrap();
    wait_for_marker(&mut master, &mut sink, "플랜 검토", Duration::from_secs(10));
    wait_for_marker(&mut master, &mut sink, "c 확정", Duration::from_secs(10));
    assert!(
        seen(&sink, "reentry fixture slice"),
        "the review screen opened without the accepted draft's content;\n{}",
        recent(&sink)
    );

    quit_tui(&mut second, &mut master, &mut sink);
    let _ = fs::remove_dir_all(&root);
}
