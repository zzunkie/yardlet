//! End-to-end PTY proof that the always-valid Home keys are discoverable
//! (issue #71).
//!
//! The idle footer advertises only the keys with something to act on right now,
//! which is correct for content-dependent keys but left `g`, `s`, `f`, `l`, `i`
//! and `R` working while appearing on no idle surface. The unit tests pin the
//! classifier to the key list; this pins the part a user actually does — press
//! the advertised key and read the list.

#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

use common::{drain, open_pty, recent, resize_pty, seen, wait_for_marker};

fn test_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("yard-tui-key-list-{}-{nonce}", std::process::id()))
}

/// A realistic default terminal. The list is 27 rows plus chrome, so at this
/// height the tail of it — including `g`, the key issue #71 was filed about —
/// is below the fold and only reachable by scrolling. The original test used 40
/// rows, which fit the whole list and hid that the screen could not scroll.
const ROWS: u16 = 24;

#[test]
fn the_idle_footer_leads_to_a_list_of_every_working_home_key() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    // Removed even if an assertion below unwinds past the clean exit — the other
    // half of issue #64.
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

    // The key list is the LAST footer fragment, so seeing it means the whole
    // idle Home frame has been drawn.
    wait_for_marker(&mut master, &mut sink, "? keys", Duration::from_secs(20));

    master.write_all(b"?").unwrap();
    wait_for_marker(&mut master, &mut sink, "Home keys", Duration::from_secs(10));

    // The list opens at the top, so the tail is genuinely below the fold at this
    // height. Assert that BEFORE scrolling, otherwise "it scrolled" proves
    // nothing.
    assert!(
        !seen(&sink, "reload the workspace"),
        "`g` was already visible at {ROWS} rows, so this test cannot prove scrolling;\n{}",
        recent(&sink)
    );

    // Page down to the end. Without a scroll clamp for this screen the offset is
    // forced back to 0 on every keypress and nothing below the fold ever
    // appears — which is how `g`, the key the issue is about, stayed
    // unreachable on a default terminal.
    for _ in 0..8 {
        master.write_all(b"\x1b[6~").unwrap();
        std::thread::sleep(Duration::from_millis(40));
        drain(&mut master, &mut sink);
    }

    // Force a full repaint by resizing to a width the app is not already at.
    // Ratatui writes only CHANGED cells, so on scrolled content a doc that
    // shares a leading prefix with the row it replaced is emitted in pieces and
    // is never a contiguous byte run; a genuine size change resets the buffer so
    // the next frame re-emits every visible cell in reading order. The width
    // must actually change: resizing back to the current 140 would coalesce into
    // one SIGWINCH at an unchanged size and force no repaint at all. 139 does not
    // wrap any doc line, so the scroll position is preserved and the tail keys
    // stay in view.
    resize_pty(&master, ROWS, 139);

    // The always-valid globals the issue named: each present with its meaning,
    // on a surface the operator can reach without already knowing the key. Poll
    // each phrase to a deadline exactly like `wait_for_marker`, rather than
    // reading one partial frame after a fixed sleep. A longer key doc grows the
    // bytes per repaint, so a single drain can catch the tail row mid-emission
    // and miss it; the old fixed-sleep capture went flaky once a key doc was
    // lengthened. Polling the first phrase also lets the 139 repaint land before
    // the width is restored below. The pre-scroll assertion already proved the
    // tail was below the fold, so a phrase arriving after the scroll is proof it
    // came into view.
    for doc in [
        "reload the workspace",
        "open settings",
        "toggle the worker access level",
        "switch language",
        "show the intent contract",
        "reports and past intents",
    ] {
        wait_for_marker(&mut master, &mut sink, doc, Duration::from_secs(10));
    }

    // Back to the contract width now that every phrase has been observed.
    resize_pty(&master, ROWS, 140);

    // Esc returns to Home rather than dead-ending on the list. Match only what
    // arrives AFTER the keypress: the cumulative sink already holds every
    // marker this session has ever rendered.
    let before_escape = sink.len();
    master.write_all(b"\x1b").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        drain(&mut master, &mut sink);
        if seen(&sink[before_escape..], "A auto") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Esc did not return to Home;\n{}",
            recent(&sink)
        );
        std::thread::sleep(Duration::from_millis(10));
    }

    std::thread::sleep(Duration::from_millis(200));
    let _ = master.write_all(b"q");
    child.shutdown(Duration::from_secs(5), || drain(&mut master, &mut sink));
    // `workspace` removes the root on drop, on this path and on a panicking one.
}
