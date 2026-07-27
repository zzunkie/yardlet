//! The PTY tests' leak backstop (issue #64).
//!
//! `std::process::Child` does not kill on drop, so before this guard existed a
//! failing assertion unwound straight past a test's own cleanup and abandoned a
//! live process — seven orphaned `yardlet` processes accumulated over a day of
//! PTY work. This pins the property that mattered: when a test panics, the
//! child it spawned is dead by the time the panic leaves the scope.

#![cfg(unix)]

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

mod common;

/// Is `pid` still a live (or zombie) process? `kill(pid, 0)` reports
/// permission-checked existence without sending a signal.
fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

fn spawn_long_lived() -> std::process::Child {
    Command::new("sleep")
        .arg("120")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn sleep")
}

/// Wait out the reap so the assertion is not racing `Drop`'s own `wait`.
fn wait_until_gone(pid: u32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    !alive(pid)
}

#[test]
fn a_panicking_assertion_does_not_leak_the_spawned_child() {
    let pid = std::cell::Cell::new(0_u32);
    let result = catch_unwind(AssertUnwindSafe(|| {
        let guard = common::ChildGuard::new(spawn_long_lived());
        pid.set(guard.id());
        assert!(alive(guard.id()), "the fixture child never started");
        // Exactly the shape the issue describes: an assertion fires before the
        // test reaches its own clean-quit path.
        panic!("simulated assertion failure");
    }));
    assert!(result.is_err(), "the fixture panic did not propagate");
    let pid = pid.get();
    assert_ne!(pid, 0, "the child was never spawned");
    assert!(
        wait_until_gone(pid, Duration::from_secs(5)),
        "child {pid} survived a panicking assertion"
    );
}

#[test]
fn a_clean_shutdown_reaps_without_killing_and_the_guard_stays_idempotent() {
    let mut guard = common::ChildGuard::new(
        Command::new("true")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn true"),
    );
    let pid = guard.id();
    let mut ticks = 0;
    guard.shutdown(Duration::from_secs(5), || ticks += 1);
    assert!(
        wait_until_gone(pid, Duration::from_secs(5)),
        "child {pid} was not reaped by a clean shutdown"
    );
    // Dropping after shutdown must not panic or try to kill a reaped pid.
    drop(guard);
}

#[test]
fn shutdown_kills_a_child_that_never_exits_on_its_own() {
    let mut guard = common::ChildGuard::new(spawn_long_lived());
    let pid = guard.id();
    let mut ticks = 0;
    guard.shutdown(Duration::from_millis(200), || ticks += 1);
    assert!(
        ticks > 0,
        "shutdown never ran its tick, so a PTY-blocked child would deadlock"
    );
    assert!(
        wait_until_gone(pid, Duration::from_secs(5)),
        "child {pid} outlived a shutdown deadline"
    );
}
