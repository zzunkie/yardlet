//! Helpers shared by the PTY integration tests.
//!
//! Compiled into each test binary that declares `mod common;`, so a helper only
//! some of them need still looks unused to the rest.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant};

// Re-exported for `use common::{...}` at the call sites. A test binary that needs
// only some of them still compiles this module whole, so the rest look unused.
#[cfg(unix)]
#[allow(unused_imports)]
pub use pty::{drain, norm, open_pty, recent, resize_pty, seen, strip_ansi, wait_for_marker};

/// The PTY harness the TUI process tests drive the app through.
///
/// This lived as four copy-pasted blocks, one per test file, which is how the
/// same defect could be fixed in one of them and stay open in the other three
/// (issue #92). One home means one place to fix.
#[cfg(unix)]
mod pty {
    use std::fs::File;
    use std::io::{ErrorKind, Read};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::time::{Duration, Instant};

    /// How much rendered tail a failure message carries.
    const RECENT_CHARS: usize = 900;

    /// Open a pseudo-terminal at an explicit size, with a non-blocking master.
    ///
    /// The size is the caller's contract, not a harness default: a screen that
    /// fits at 40 rows can hide a scrolling defect that a real 24-row terminal
    /// shows (issue #71, where a 40-row test hid the very key the issue was
    /// filed about).
    pub fn open_pty(rows: u16, cols: u16) -> (File, File) {
        let mut master = -1;
        let mut slave = -1;
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
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
        let rc =
            unsafe { libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK) };
        assert_eq!(rc, 0);
        (master, slave)
    }

    /// Resize, which also forces a full repaint.
    ///
    /// Ratatui writes only CHANGED cells, so a string on scrolled content can be
    /// missing any character whose cell already held it. A resize makes the next
    /// frame a complete one.
    pub fn resize_pty(master: &File, rows: u16, cols: u16) {
        let size = libc::winsize {
            ws_row: rows,
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

    /// Drain everything currently readable into `sink`.
    ///
    /// Draining continuously is mandatory: if the PTY buffer fills, the child
    /// blocks on its next render and the whole TUI event loop stalls.
    pub fn drain(master: &mut File, sink: &mut Vec<u8>) {
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

    /// Remove ANSI/VT control sequences so the visible glyphs collapse into
    /// reading order.
    ///
    /// Ratatui positions every wide (CJK) cell with its own cursor-move escape,
    /// so a Korean word is NOT a contiguous byte run in the raw stream —
    /// stripping the escapes is what makes it one again.
    pub fn strip_ansi(bytes: &[u8]) -> String {
        let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == 0x1b {
                match bytes.get(i + 1) {
                    Some(b'[') => {
                        // CSI: consume params/intermediates up to the final byte.
                        i += 2;
                        while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                            i += 1;
                        }
                        i += usize::from(i < bytes.len());
                    }
                    Some(b']') => {
                        // OSC: terminated by BEL or ST (ESC \).
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
                    Some(_) => i += 2, // other two-byte escapes
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
    pub fn norm(s: &str) -> String {
        s.chars().filter(|c| !c.is_whitespace()).collect()
    }

    /// Is `marker` in this slice of rendered output?
    ///
    /// Pass the slice the assertion is ABOUT. A cumulative sink holds every frame
    /// the session ever drew, so a marker matched against all of it says nothing
    /// about the screen under test — that is how removing `Esc` handling once left
    /// its test passing (issue #92).
    pub fn seen(sink: &[u8], marker: &str) -> bool {
        norm(&strip_ansi(sink)).contains(&norm(marker))
    }

    /// The rendered tail, for a failure message.
    pub fn recent(sink: &[u8]) -> String {
        let text = strip_ansi(sink);
        let chars: Vec<char> = text.chars().collect();
        let start = chars.len().saturating_sub(RECENT_CHARS);
        chars[start..].iter().collect()
    }

    /// Read (draining) until `marker` shows up in `sink`, or panic with the tail
    /// of what was actually rendered.
    pub fn wait_for_marker(master: &mut File, sink: &mut Vec<u8>, marker: &str, within: Duration) {
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
}

/// Kills and reaps a spawned child on drop.
///
/// `std::process::Child` does NOT kill on drop, so a failing assertion unwinds
/// straight past a test's own cleanup and abandons a live process. Every red
/// run during PTY work left one behind (issue #64: seven orphaned `yardlet`
/// processes after a day of it).
///
/// The clean-quit path stays in the tests — it exercises the app's own shutdown
/// and is worth asserting on — and this sits underneath it as the backstop.
///
/// # What it reaches, and what it does not
///
/// The DIRECT child, and only that. `kill` signals one pid, so a descendant is
/// not covered — an independent review demonstrated it with `sh -c 'sleep 30 &
/// wait'`, whose inner `sleep` outlived the guard.
///
/// A group-leader variant was tried and withdrawn. Putting the child in its own
/// process group does let a negative-pid signal reach the tree, but it also
/// removes the child from the test harness's group, so a developer's Ctrl-C no
/// longer reaches it — and signal termination does not run `Drop`, so nothing
/// else cleans up either. That trade only pays when the tree is actually
/// reachable, and at every site here it is not: a Yardlet worker regroups itself
/// on purpose (`src/workers/mod.rs` `process_group(0)`, issue #52) so it survives
/// the terminal, so it escapes a group kill regardless. The remaining sites spawn
/// leaves with no children at all.
///
/// So a killed `yardlet run` orphans its worker no matter what this helper does.
/// That gap is Yardlet's own teardown (issue #107), not a test helper's.
pub struct ChildGuard {
    child: Option<Child>,
}

impl ChildGuard {
    pub fn new(child: Child) -> Self {
        Self { child: Some(child) }
    }

    /// The live child, for a test that polls its own exit.
    pub fn as_mut(&mut self) -> &mut Child {
        self.child
            .as_mut()
            .expect("child guard used after shutdown")
    }

    /// The process id, so a test can assert the process really is gone.
    pub fn id(&self) -> u32 {
        self.child
            .as_ref()
            .expect("child guard used after shutdown")
            .id()
    }

    /// Hand the child back for `wait_with_output`, which consumes it.
    ///
    /// The guard is spent from here on, which is the point: it covered the window
    /// that actually leaked — every assertion between the spawn and the moment
    /// the test collects the output.
    pub fn into_inner(mut self) -> Child {
        self.child.take().expect("child guard used after shutdown")
    }

    /// Kill and reap now, for a test that deliberately cuts its child off
    /// mid-flight (a crash window, a decoy that must never finish).
    ///
    /// Idempotent, and safe before `Drop`: the drop sees an already-reaped child
    /// and does not signal a pid it no longer owns.
    pub fn kill_now(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// Wait out a clean exit, killing after `within` if it never comes.
    ///
    /// `tick` runs between polls so a test can keep draining its PTY: a child
    /// blocked writing into a full buffer would otherwise never reach its own
    /// shutdown and would always be killed here.
    pub fn shutdown(&mut self, within: Duration, mut tick: impl FnMut()) {
        let Some(child) = self.child.as_mut() else {
            return;
        };
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            match child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => {}
                Err(_) => break,
            }
            tick();
            std::thread::sleep(Duration::from_millis(20));
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else {
            return;
        };
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
        }
        let _ = child.wait();
    }
}

/// Wait until a fixture file exists AND says what the caller is about to assert,
/// returning those contents.
///
/// The predicate is the point. Waiting on `path.exists()` and then reading is a
/// race the harness loses on a loaded machine: the writer creates the file and
/// fills it in two steps, so the read lands between them and the assertion fails
/// on an EMPTY string. That is not a wrong value being caught, it is no value
/// having arrived — the wait predicate was weaker than what the assertion needed.
///
/// Observed on CI (a one-file `chore` commit that touches no code failed
/// `slow_startup_then_ko_review_then_multiline_revision_over_one_pty` with
/// `packet:` printed empty) and reproduced locally at 1 in 3 with a prebuilt
/// binary.
///
/// `tick` runs between polls so the caller keeps draining its PTY: a child
/// blocked writing into a full buffer would otherwise never finish the write
/// being waited on.
///
/// On timeout, `Err` carries what the file last held (or why it could not be
/// read) so the failure says which of the two it was.
pub fn wait_for_file_contents(
    path: &Path,
    within: Duration,
    mut tick: impl FnMut(),
    ready: impl Fn(&str) -> bool,
) -> Result<String, String> {
    let deadline = Instant::now() + within;
    let mut last = String::from("(file never appeared)");
    loop {
        tick();
        match std::fs::read_to_string(path) {
            Ok(text) => {
                if ready(&text) {
                    return Ok(text);
                }
                last = if text.is_empty() {
                    String::from("(file present but empty)")
                } else {
                    text
                };
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => last = format!("(unreadable: {error})"),
        }
        if Instant::now() >= deadline {
            return Err(last);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Kills a process the test has no `Child` for, identified by a pid file it wrote.
///
/// For a process a test causes but does not spawn: a post-run hook, a fixture
/// script started by the program under test. `ChildGuard` cannot cover those —
/// there is no handle — and an assertion that fires while one is mid-loop leaves
/// it running for the rest of its own timeout (the failover hook polls for 200
/// seconds).
///
/// Skips a hook that already finished: the pid file is removed on the hook's clean
/// exit, so a missing file means nothing to do rather than a pid to guess at. That
/// ordering is what keeps this from signalling a recycled pid.
#[cfg(unix)]
pub struct PidFileGuard {
    path: PathBuf,
}

#[cfg(unix)]
impl PidFileGuard {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

#[cfg(unix)]
impl Drop for PidFileGuard {
    fn drop(&mut self) {
        let Ok(raw) = std::fs::read_to_string(&self.path) else {
            return; // the process removed its own pid file: it is gone
        };
        if let Ok(pid) = raw.trim().parse::<libc::pid_t>() {
            if pid > 0 {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
            }
        }
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Removes one exact temp workspace on drop.
///
/// `ChildGuard` closed half of issue #64; this closes the other half. Every PTY
/// test ended with `fs::remove_dir_all(&root)` on the happy path ONLY, so a
/// failing assertion unwound past it and abandoned the workspace — two were
/// found in the system temp directory after a single reproduction run of the
/// `wait_for_file` race.
///
/// Owns exactly the path it was given and nothing else: no globbing over the
/// temp directory, no removal of workspaces other runs left behind. A
/// concurrent test's workspace is not this guard's business.
///
/// It also refuses to adopt a path that already exists. An earlier cut removed
/// the directory first, which meant two guards on the same root silently ate
/// each other's data — the second `create` wiped the first's files, and the
/// first's `drop` then removed the second's workspace. Since the guard now owns
/// deletion, taking a path it did not create is how it would delete work it does
/// not own. A collision is a broken test root, so it fails loudly instead.
pub struct WorkspaceGuard {
    root: PathBuf,
}

impl WorkspaceGuard {
    /// Create the workspace, and own it until the test's scope ends.
    ///
    /// Panics if the path already exists: this guard deletes what it owns, so
    /// adopting a directory someone else made is exactly the mistake to prevent.
    ///
    /// The check is the creation itself, not an `exists()` before it. `exists()`
    /// then `create_dir_all` is TOCTOU: an independent review ran five threads at
    /// one root through a barrier and got five guards that all believed they owned
    /// it, on the first round. `create_dir` fails with `AlreadyExists` in the
    /// kernel, so exactly one caller can win.
    pub fn create(root: PathBuf) -> Self {
        if let Some(parent) = root.parent() {
            std::fs::create_dir_all(parent).expect("create the test root's parent");
        }
        match std::fs::create_dir(&root) {
            Ok(()) => Self { root },
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => panic!(
                "test workspace {} already exists; a guard must not adopt (and later \
                 delete) a directory it did not create — give each test root a unique \
                 name",
                root.display()
            ),
            Err(error) => panic!("create test workspace {}: {error}", root.display()),
        }
    }

    pub fn path(&self) -> &Path {
        &self.root
    }

    /// Join a path inside the workspace.
    pub fn join(&self, tail: impl AsRef<Path>) -> PathBuf {
        self.root.join(tail)
    }

    /// Give up ownership without removing, for a test that wants the workspace
    /// left on disk for inspection.
    pub fn keep(mut self) -> PathBuf {
        std::mem::replace(&mut self.root, PathBuf::new())
    }
}

impl Drop for WorkspaceGuard {
    fn drop(&mut self) {
        if self.root.as_os_str().is_empty() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
