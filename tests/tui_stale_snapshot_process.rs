//! End-to-end PTY proof that a failed state reload is visible (issue #138).
//!
//! During the #138 incident the workspace wedged while the TUI kept serving the
//! last snapshot it had loaded: `Snapshot::load` failures in the reload paths
//! were dropped on the floor, so Home stayed stale-but-plausible and the only
//! feedback was an unrelated-sounding confirm error. Keeping the last good
//! projection is the right call — a blank Home is worse — so what this pins is
//! the other half: pressing the advertised refresh key on a wedged workspace
//! has to put the failure on screen, and leave the rest of Home readable.

#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

use common::{drain, open_pty, recent, resize_pty, seen, wait_for_marker};

/// A queue that names an intent and demands activation, with no intent contract
/// beside it: the shape the post-tidy scaffold wedge left behind. The shared
/// activation gate fails closed on it, so every `Snapshot::load` errors.
const WEDGED_QUEUE: &str = "schema_version: 1\n\
                            queue_id: queue-wedged\n\
                            intent_id: int-wedged\n\
                            activation_required: true\n\
                            tasks: []\n";

const ROWS: u16 = 24;

fn test_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("yard-tui-stale-{}-{nonce}", std::process::id()))
}

#[test]
fn a_wedged_workspace_shows_a_stale_banner_instead_of_a_silently_frozen_home() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    // Removed even if an assertion below unwinds past the clean exit (issue #64).
    let workspace = common::WorkspaceGuard::create(test_root());
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
    fs::write(&config_path, config).unwrap();

    let (mut master, slave) = open_pty(ROWS, 140);
    let stdin = Stdio::from(slave.try_clone().unwrap());
    let stdout = Stdio::from(slave.try_clone().unwrap());
    let stderr = Stdio::from(slave);
    let child = Command::new(&binary)
        .current_dir(&root)
        .env("TERM", "xterm-256color")
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .unwrap();
    // Killed and reaped even if an assertion below unwinds past the clean quit
    // (issue #64).
    let mut child = common::ChildGuard::new(child);

    let mut sink: Vec<u8> = Vec::new();

    // The key list is the LAST footer fragment, so seeing it means a whole idle
    // Home frame has been drawn from a workspace that loaded cleanly.
    wait_for_marker(&mut master, &mut sink, "? keys", Duration::from_secs(20));
    assert!(
        !seen(&sink, "state reload failed"),
        "a healthy workspace must not claim a stale screen;\n{}",
        recent(&sink)
    );

    // Wedge the canonical state under the running TUI. Home is idle, so nothing
    // reloads on its own — the banner can only come from the refresh key.
    fs::write(root.join(".agents/work-queue.yaml"), WEDGED_QUEUE).unwrap();
    assert!(!root.join(".agents/intent-contract.yaml").exists());

    let before_refresh = sink.len();
    master.write_all(b"g").unwrap();

    // Force a full repaint at a width the app is not already at. Ratatui writes
    // only CHANGED cells, so a row that shares a prefix with the row it replaced
    // is emitted in pieces and is never a contiguous byte run; a genuine size
    // change resets the buffer so the next frame re-emits every visible cell in
    // reading order. Resizing back to 140 would coalesce into one SIGWINCH at an
    // unchanged size and force no repaint at all.
    resize_pty(&master, ROWS, 139);

    wait_for_marker(
        &mut master,
        &mut sink,
        "state reload failed",
        Duration::from_secs(10),
    );

    // Match only what arrived AFTER the keypress: the cumulative sink holds
    // every marker this session ever rendered (issue #92).
    let after_refresh = &sink[before_refresh..];
    assert!(
        seen(after_refresh, "active intent is missing"),
        "the banner must name the load failure;\n{}",
        recent(&sink)
    );
    assert!(
        seen(after_refresh, "press g to retry"),
        "the banner must name the retry key;\n{}",
        recent(&sink)
    );
    // The last good projection stays on screen underneath it. The banner is
    // above the footer in reading order, so the repaint that carried the banner
    // has not necessarily reached the footer yet — poll to a deadline instead of
    // judging the one partial frame the marker arrived in.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        drain(&mut master, &mut sink);
        if seen(&sink[before_refresh..], "? keys") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the stale frame must still be a usable Home;\n{}",
            recent(&sink)
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    // Back to the contract width now that the banner has been observed.
    resize_pty(&master, ROWS, 140);

    std::thread::sleep(Duration::from_millis(200));
    let _ = master.write_all(b"q");
    child.shutdown(Duration::from_secs(5), || drain(&mut master, &mut sink));
    // `workspace` removes the root on drop, on this path and on a panicking one.
}
