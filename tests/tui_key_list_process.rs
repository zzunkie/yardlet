//! End-to-end PTY proof that the always-valid Home keys are discoverable
//! (issue #71).
//!
//! The idle footer advertises only the keys with something to act on right now,
//! which is correct for content-dependent keys but left `g`, `s`, `f`, `l`, `i`
//! and `R` working while appearing on no idle surface. The unit tests pin the
//! classifier to the key list; this pins the part a user actually does — press
//! the advertised key and read the list.

#![cfg(unix)]

use std::fs::{self, File};
use std::io::{ErrorKind, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

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

fn open_pty() -> (File, File) {
    let mut master = -1;
    let mut slave = -1;
    let mut size = libc::winsize {
        ws_row: ROWS,
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

/// Force a full repaint.
///
/// Ratatui writes only CHANGED cells, so after scrolling a string can lose any
/// character whose cell happened to already hold it — exact matching on
/// scrolled content is unreliable. A resize makes the next frame a complete
/// one. The column change is cosmetic and preserves the scroll offset, so what
/// is on screen is still what scrolling brought there.
fn force_repaint(master: &File, cols: u16) {
    let size = libc::winsize {
        ws_row: ROWS,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(master.as_raw_fd(), libc::TIOCSWINSZ, &size) };
    assert_eq!(
        rc,
        0,
        "TIOCSWINSZ failed: {}",
        std::io::Error::last_os_error()
    );
}

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

fn norm(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace()).collect()
}

fn seen(sink: &[u8], marker: &str) -> bool {
    norm(&strip_ansi(sink)).contains(&norm(marker))
}

fn recent(sink: &[u8]) -> String {
    let text = strip_ansi(sink);
    let chars: Vec<char> = text.chars().collect();
    let start = chars.len().saturating_sub(900);
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

#[test]
fn the_idle_footer_leads_to_a_list_of_every_working_home_key() {
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
        .replace("language: auto", "language: en");
    fs::write(&config_path, config).unwrap();

    let (mut master, slave) = open_pty();
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

    force_repaint(&master, 139);
    std::thread::sleep(Duration::from_millis(300));
    drain(&mut master, &mut sink);
    let after_repaint = sink.len();
    force_repaint(&master, 140);
    std::thread::sleep(Duration::from_millis(300));
    drain(&mut master, &mut sink);

    // The always-valid globals the issue named: each present with its meaning,
    // on a surface the operator can reach without already knowing the key.
    for doc in [
        "reload the workspace",
        "open settings",
        "toggle the worker access level",
        "switch language",
        "show the intent contract",
        "reports and past intents",
    ] {
        assert!(
            seen(&sink[after_repaint..], doc),
            "{doc:?} never came into view after scrolling at {ROWS} rows;\n{}",
            recent(&sink)
        );
    }

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
    let _ = fs::remove_dir_all(&root);
}
