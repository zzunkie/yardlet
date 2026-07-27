//! Helpers shared by the PTY integration tests.
//!
//! Compiled into each test binary that declares `mod common;`, so a helper only
//! some of them need still looks unused to the rest.
#![allow(dead_code)]

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
