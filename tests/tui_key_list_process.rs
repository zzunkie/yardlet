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

fn test_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("yard-tui-key-list-{}-{nonce}", std::process::id()))
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
    let mut child = Command::new(&binary)
        .current_dir(&root)
        .env("TERM", "xterm-256color")
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .unwrap();

    let mut sink: Vec<u8> = Vec::new();

    // The key list is the LAST footer fragment, so seeing it means the whole
    // idle Home frame has been drawn.
    wait_for_marker(&mut master, &mut sink, "? keys", Duration::from_secs(20));

    master.write_all(b"?").unwrap();
    wait_for_marker(&mut master, &mut sink, "Home keys", Duration::from_secs(10));

    // The always-valid globals the issue named: each present with its meaning,
    // on a surface the operator can reach without already knowing the key.
    for (glyph, doc) in [
        ("g", "reload the workspace"),
        ("s", "open settings"),
        ("f", "toggle the worker access level"),
        ("l", "switch language"),
        ("i", "show the intent contract"),
        ("R", "reports and past intents"),
    ] {
        wait_for_marker(&mut master, &mut sink, doc, Duration::from_secs(10));
        assert!(
            seen(&sink, glyph),
            "key list is missing the {glyph:?} glyph;\n{}",
            recent(&sink)
        );
    }

    // Esc returns to Home rather than dead-ending on the list.
    master.write_all(b"\x1b").unwrap();
    wait_for_marker(&mut master, &mut sink, "? keys", Duration::from_secs(10));

    std::thread::sleep(Duration::from_millis(200));
    let _ = master.write_all(b"q");
    let exit_deadline = Instant::now() + Duration::from_secs(5);
    while child.try_wait().unwrap().is_none() && Instant::now() < exit_deadline {
        drain(&mut master, &mut sink);
        std::thread::sleep(Duration::from_millis(20));
    }
    if child.try_wait().unwrap().is_none() {
        child.kill().unwrap();
        child.wait().unwrap();
    }
    let _ = fs::remove_dir_all(&root);
}
