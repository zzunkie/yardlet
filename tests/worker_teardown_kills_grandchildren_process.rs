//! Stopping a worker must take down what it spawned (issue #52 follow-through).
//!
//! Workers now lead their own process group so they survive the terminal. The
//! other half of that is teardown: a worker profile whose invocation is a
//! launcher — `bash wrapper.sh`, `npx`, `sh -c`, the shape this repo's own
//! fixtures use — keeps the real agent CLI in a grandchild. Killing only the
//! direct child leaves it running, and billing, after the task has already been
//! requeued; it also still holds the inherited pipe write ends, which is enough
//! to hang the reader joins on the timeout path.
//!
//! `kill_validation_child` has group-killed since validation children were first
//! put in their own group. This pins the same guarantee for workers.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn must_succeed(cwd: &Path, program: &Path, args: &[&str]) {
    let output = Command::new(program)
        .args(args)
        .current_dir(cwd)
        .output()
        .unwrap_or_else(|error| panic!("running {program:?} {args:?}: {error}"));
    assert!(
        output.status.success(),
        "{program:?} {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// A launcher that backgrounds a long-lived grandchild — the agent CLI's stand
/// in — records its pid, and then waits. Killing the launcher alone leaves the
/// grandchild behind.
///
/// `yardlet redirect` runs the replacement attempt synchronously, so the second
/// invocation returns a finished result immediately instead of making the test
/// wait out another 120s sleep.
fn write_launcher(path: &Path) {
    fs::write(
        path,
        "#!/bin/sh\n\
         set -eu\n\
         if [ \"${1:-}\" = \"--version\" ]; then\n\
         \x20 printf 'fixture-launcher 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         ids=\"$2\"\n\
         cat >/dev/null\n\
         if [ -f \"$ids.done\" ]; then\n\
         \x20 run_id=$(basename \"$run_dir\")\n\
         \x20 task_id=YARD-001\n\
         \x20 printf '# retry handoff\\n' >\"$run_dir/handoff.md\"\n\
         \x20 printf '{\"schema_version\":1,\"run_id\":\"%s\",\"task_id\":\"%s\",\"status\":\"done\",\"intent_adherence\":{\"drift_detected\":false,\"notes\":\"\"},\"changes\":{\"files_modified\":[],\"files_created\":[],\"files_deleted\":[]},\"validation\":{\"commands_run\":[],\"passed\":true,\"failures\":[]},\"question_for_user\":null,\"compact_summary\":\"retry\",\"verdict\":[],\"harness_suggestions\":[],\"follow_up_tasks\":[]}' \"$run_id\" \"$task_id\" >\"$run_dir/result.json\"\n\
         \x20 exit 0\n\
         fi\n\
         : >\"$ids.done\"\n\
         sleep 120 &\n\
         grandchild=$!\n\
         printf '%s %s\\n' \"$$\" \"$grandchild\" >\"$ids\"\n\
         wait \"$grandchild\"\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn wait_for(path: &Path, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if path.is_file() && fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn wait_until_gone(pid: i32, within: Duration) -> bool {
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
fn stopping_a_worker_takes_down_the_cli_it_launched() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "yardlet-worker-teardown-{}-{nonce}",
        std::process::id()
    ));
    let _cleanup = TempRoot(root.clone());
    fs::create_dir_all(&root).unwrap();
    must_succeed(&root, Path::new("git"), &["init", "-q"]);
    must_succeed(&root, Path::new("git"), &["config", "user.name", "fixture"]);
    must_succeed(
        &root,
        Path::new("git"),
        &["config", "user.email", "fixture@example.invalid"],
    );
    fs::write(root.join("README.md"), "fixture\n").unwrap();
    must_succeed(&root, Path::new("git"), &["add", "README.md"]);
    must_succeed(&root, Path::new("git"), &["commit", "-qm", "fixture"]);
    must_succeed(&root, &binary, &["init"]);

    let launcher = root.join("fixture-launcher.sh");
    write_launcher(&launcher);
    let ids = root.join("worker-ids");

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-teardown\nsummary: worker teardown fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-teardown\nintent_id: intent-teardown\ntasks:\n  - id: YARD-001\n    title: worker teardown fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [teardown reaches the whole tree]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 2\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            launcher.display(),
            ids.display()
        ),
    )
    .unwrap();

    let yardlet = Command::new(&binary)
        .args(["run", "--task", "YARD-001", "--execute"])
        .current_dir(&root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(
            std::fs::File::create(root.join("yardlet.err")).unwrap(),
        ))
        .spawn()
        .unwrap();
    let mut yardlet = common::ChildGuard::new(yardlet);

    assert!(
        wait_for(&ids, Duration::from_secs(60)),
        "the fixture launcher never started; yardlet said:\n{}",
        fs::read_to_string(root.join("yardlet.err")).unwrap_or_default()
    );
    let recorded = fs::read_to_string(&ids).unwrap();
    let mut parts = recorded.split_whitespace();
    let launcher_pid: i32 = parts.next().unwrap().parse().unwrap();
    let grandchild_pid: i32 = parts.next().unwrap().parse().unwrap();
    assert!(
        alive(grandchild_pid),
        "the fixture grandchild never started"
    );

    let run_dir = fs::read_dir(root.join(".agents/runs"))
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .find(|path| path.join("worker.pid").is_file())
        .expect("the run recorded a worker pid");
    let pid: i32 = fs::read_to_string(run_dir.join("worker.pid"))
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    assert_eq!(
        pid, launcher_pid,
        "worker.pid names the launcher, not the CLI it spawned"
    );

    // Drive a REAL production stop rather than sending the signal ourselves.
    // `yardlet redirect` verifies the worker's process identity and then calls
    // the shared `terminate_worker_tree`; the TUI's stop key reaches the same
    // helper through its own verification.
    let redirect = Command::new(&binary)
        .args(["redirect", "YARD-001", "try", "again"])
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(
        redirect.status.success(),
        "yardlet redirect failed: {}{}",
        String::from_utf8_lossy(&redirect.stdout),
        String::from_utf8_lossy(&redirect.stderr)
    );

    assert!(
        wait_until_gone(grandchild_pid, Duration::from_secs(10)),
        "the CLI the worker launched outlived the stop"
    );
    assert!(
        wait_until_gone(launcher_pid, Duration::from_secs(10)),
        "the worker itself outlived the stop"
    );

    yardlet.shutdown(Duration::from_secs(10), || {});
}

/// The wall-clock timeout is the most destructive of the three paths: before
/// this change the surviving grandchild still held the inherited stdout/stderr
/// pipes, so the reader joins after the kill never saw EOF and a 60s timeout
/// became an unbounded hang.
#[test]
fn a_wall_clock_timeout_does_not_hang_on_a_grandchild_holding_the_pipes() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "yardlet-worker-timeout-{}-{nonce}",
        std::process::id()
    ));
    let _cleanup = TempRoot(root.clone());
    fs::create_dir_all(&root).unwrap();
    must_succeed(&root, Path::new("git"), &["init", "-q"]);
    must_succeed(&root, Path::new("git"), &["config", "user.name", "fixture"]);
    must_succeed(
        &root,
        Path::new("git"),
        &["config", "user.email", "fixture@example.invalid"],
    );
    fs::write(root.join("README.md"), "fixture\n").unwrap();
    must_succeed(&root, Path::new("git"), &["add", "README.md"]);
    must_succeed(&root, Path::new("git"), &["commit", "-qm", "fixture"]);
    must_succeed(&root, &binary, &["init"]);

    let launcher = root.join("fixture-launcher.sh");
    write_launcher(&launcher);
    let ids = root.join("worker-ids");

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-timeout\nsummary: worker timeout fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-timeout\nintent_id: intent-timeout\ntasks:\n  - id: YARD-001\n    title: worker timeout fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [timeout does not hang]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            launcher.display(),
            ids.display()
        ),
    )
    .unwrap();

    // The shortest expressible budget is a minute; the fixture seam shortens it
    // so this regression is seconds rather than a minute of CI.
    let started = Instant::now();
    let run = Command::new(&binary)
        .args(["run", "--task", "YARD-001", "--execute"])
        .current_dir(&root)
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .env("YARDLET_FIXTURE_WALL_MS", "3000")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut run = common::ChildGuard::new(run);

    // Generous versus the 3s budget, tight versus the 120s sleep the grandchild
    // is holding: only a group kill can land inside this window.
    let deadline = Instant::now() + Duration::from_secs(45);
    while run.as_mut().try_wait().unwrap().is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        run.as_mut().try_wait().unwrap().is_some(),
        "the run never finished: a grandchild still holding the worker's pipes \
         turned a {:?} wall-clock budget into an unbounded wait",
        Duration::from_secs(3)
    );
    assert!(
        started.elapsed() < Duration::from_secs(45),
        "the timeout took {:?}",
        started.elapsed()
    );

    if let Ok(recorded) = fs::read_to_string(&ids) {
        let mut parts = recorded.split_whitespace();
        let _launcher: i32 = parts.next().unwrap().parse().unwrap();
        let grandchild: i32 = parts.next().unwrap().parse().unwrap();
        assert!(
            wait_until_gone(grandchild, Duration::from_secs(10)),
            "the CLI the worker launched outlived the wall-clock timeout"
        );
    }
}

/// Removes the fixture workspace even when an assertion unwinds, so a red run
/// does not leave one behind (issue #64's other half).
struct TempRoot(PathBuf);

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
