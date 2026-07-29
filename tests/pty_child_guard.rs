//! What the shared PTY harness itself guarantees (issues #64 and #92).
//!
//! Three properties, each filed after it failed in real use:
//!
//! - **Processes.** `std::process::Child` does not kill on drop, so a failing
//!   assertion unwound past a test's own cleanup and abandoned a live process —
//!   seven orphaned `yardlet` processes accumulated over a day of PTY work
//!   (#64).
//! - **Workspaces.** Every PTY test removed its temp root on the happy path
//!   only, so the same unwind abandoned the workspace too. That half of #64 was
//!   still open, and two leaked roots were collected from a single reproduction
//!   run.
//! - **Waiting.** A wait predicate weaker than the assertion it guards turns a
//!   race into a failure that observed nothing. Waiting on a path existing and
//!   then reading it caught an empty file on CI (#92).
//!
//! These tests pin the properties, not the implementations: a panic leaves no
//! child and no workspace behind, and a content wait does not return on a
//! created-but-unwritten file.

#![cfg(unix)]

use std::io::Write;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

/// Is `pid` still a live (or zombie) process? `kill(pid, 0)` reports
/// permission-checked existence without sending a signal.
fn alive(pid: u32) -> bool {
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// A path no other test or run shares, so a guard's removal can only be judged
/// against work this test itself created.
fn scratch(name: &str) -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "yard-harness-{name}-{}-{nonce}",
        std::process::id()
    ))
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
fn a_panicking_assertion_does_not_leak_the_temp_workspace() {
    let root = scratch("panic-workspace");
    let result = catch_unwind(AssertUnwindSafe(|| {
        let workspace = common::WorkspaceGuard::create(root.clone());
        std::fs::write(workspace.join("marker"), "x").expect("write into the workspace");
        // The shape the leak had: an assertion fires before the test reaches the
        // `remove_dir_all` on its happy path.
        panic!("simulated assertion failure");
    }));
    assert!(result.is_err(), "the fixture panic did not propagate");
    assert!(
        !root.exists(),
        "workspace {} survived a panicking assertion",
        root.display()
    );
}

#[test]
fn the_workspace_guard_removes_its_own_root_and_nothing_else() {
    let root = scratch("own-root");
    let neighbour = scratch("neighbour");
    std::fs::create_dir_all(&neighbour).expect("create the neighbour");
    std::fs::write(neighbour.join("keep-me"), "x").expect("write into the neighbour");

    {
        let workspace = common::WorkspaceGuard::create(root.clone());
        std::fs::write(workspace.join("marker"), "x").expect("write into the workspace");
        assert!(root.exists());
    }

    assert!(!root.exists(), "the guard did not remove its own root");
    assert!(
        neighbour.join("keep-me").exists(),
        "the guard reached outside its own root — a parallel session's workspace \
         is not its business"
    );
    let _ = std::fs::remove_dir_all(&neighbour);
}

#[test]
fn the_file_wait_does_not_return_on_a_created_but_unwritten_file() {
    let workspace = common::WorkspaceGuard::create(scratch("file-wait"));
    let path = workspace.join("turn-2.md");
    let verbatim = "REVLINE-TOP\nREVLINE-BOTTOM";

    // Exactly what `printf '%s' "$packet" >"$file"` does in the planner fixture:
    // create (truncating) first, write second. The gap is the race window.
    let writing = path.clone();
    let writer = std::thread::spawn(move || {
        let mut file = std::fs::File::create(&writing).expect("create the fixture file");
        std::thread::sleep(Duration::from_millis(300));
        file.write_all(b"REVLINE-TOP\nREVLINE-BOTTOM\n")
            .expect("write the fixture file");
    });

    // The predicate the harness used to wait on. It is satisfied while the file
    // still holds nothing, which is how the assertion came to fail having
    // observed no value at all.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut on_existence = None;
    while Instant::now() < deadline {
        if path.exists() {
            on_existence = Some(std::fs::read_to_string(&path).expect("read the fixture file"));
            break;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    let on_existence = on_existence.expect("the fixture file never appeared");
    assert!(
        !on_existence.contains(verbatim),
        "the race window never opened, so this test cannot prove the difference"
    );

    // The content wait sees the whole value instead.
    let text = common::wait_for_file_contents(
        &path,
        Duration::from_secs(5),
        || {},
        |text| text.contains(verbatim),
    )
    .expect("the content wait timed out on a file that was written");
    assert!(text.contains(verbatim));
    writer.join().expect("the writer thread panicked");
}

#[test]
fn the_file_wait_reports_what_it_actually_found_on_timeout() {
    let workspace = common::WorkspaceGuard::create(scratch("file-wait-diagnostics"));
    let brief = Duration::from_millis(120);

    let missing = workspace.join("never-written.md");
    let error = common::wait_for_file_contents(&missing, brief, || {}, |_| true)
        .expect_err("a missing file must not satisfy the wait");
    assert!(
        error.contains("never appeared"),
        "a missing file was not reported as missing: {error}"
    );

    let empty = workspace.join("empty.md");
    std::fs::File::create(&empty).expect("create the empty file");
    let error = common::wait_for_file_contents(&empty, brief, || {}, |text| text.contains("value"))
        .expect_err("an empty file must not satisfy a content predicate");
    assert!(
        error.contains("empty"),
        "an empty file was not reported as empty: {error}"
    );

    let wrong = workspace.join("wrong.md");
    std::fs::write(&wrong, "some other contents entirely").expect("write the wrong contents");
    let error = common::wait_for_file_contents(&wrong, brief, || {}, |text| text.contains("value"))
        .expect_err("contents that do not match the predicate must not satisfy the wait");
    assert_eq!(
        error, "some other contents entirely",
        "the timeout did not report the contents it actually read"
    );
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
