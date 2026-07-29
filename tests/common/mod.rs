//! Helpers shared by the PTY integration tests.
//!
//! Compiled into each test binary that declares `mod common;`, so a helper only
//! some of them need still looks unused to the rest.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Child;
use std::time::{Duration, Instant};

/// Kills and reaps a spawned child on drop.
///
/// `std::process::Child` does NOT kill on drop, so a failing assertion unwinds
/// straight past a test's own cleanup and abandons a live process. Every red
/// run during PTY work left one behind (issue #64: seven orphaned `yardlet`
/// processes after a day of it).
///
/// The clean-quit path stays in the tests — it exercises the app's own shutdown
/// and is worth asserting on — and this sits underneath it as the backstop.
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
pub struct WorkspaceGuard {
    root: PathBuf,
}

impl WorkspaceGuard {
    /// Create the workspace fresh, and own it until the test's scope ends.
    pub fn create(root: PathBuf) -> Self {
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create test workspace");
        Self { root }
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
