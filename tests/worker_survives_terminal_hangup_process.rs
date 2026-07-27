//! A worker must outlive the terminal that started it (issue #52).
//!
//! Yardlet's contract is that quitting the orchestrator does not kill workers —
//! the next start adopts a live one. That held for `q`, but not for the window
//! closing: a plain spawn inherits Yardlet's process group, which is the
//! controlling pty's foreground group, so pty teardown SIGHUPs the worker too.
//! An operator quitting the host app mid-review lost the entire reasoning pass.
//!
//! This reproduces the shape without a terminal: the `yardlet` child is put in
//! its own process group (as it is when it leads a pty's foreground group), its
//! worker is allowed to start, and then SIGHUP is delivered to **that group**.
//! The worker must still be alive afterwards.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

fn pgid_of(pid: i32) -> i32 {
    unsafe { libc::getpgid(pid) }
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

/// A worker that records its own pid and process group, then stays alive long
/// enough for the test to signal Yardlet's group and check on it.
fn write_worker(path: &Path) {
    fs::write(
        path,
        "#!/bin/sh\n\
         set -eu\n\
         if [ \"${1:-}\" = \"--version\" ]; then\n\
         \x20 printf 'fixture-worker 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         ids=\"$2\"\n\
         cat >/dev/null\n\
         printf '%s %s\\n' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\" >\"$ids\"\n\
         sleep 30\n\
         printf '{}' >\"$run_dir/result.json\"\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn wait_for(path: &Path, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    path.exists()
}

#[test]
fn a_worker_survives_a_hangup_delivered_to_yardlets_process_group() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "yardlet-worker-hangup-{}-{nonce}",
        std::process::id()
    ));
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

    let worker = root.join("fixture-worker.sh");
    write_worker(&worker);
    let ids = root.join("worker-ids");

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-hangup\nsummary: worker hangup fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-hangup\nintent_id: intent-hangup\ntasks:\n  - id: YARD-001\n    title: worker hangup fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [worker outlives the terminal]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 2\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            worker.display(),
            ids.display()
        ),
    )
    .unwrap();

    // Yardlet leads its own process group, exactly as it does as a terminal's
    // foreground process group leader. SIGHUP below then targets that group and
    // nothing else — including not this test harness.
    let yardlet = Command::new(&binary)
        .args(["run", "--task", "YARD-001", "--execute"])
        .current_dir(&root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(
            std::fs::File::create(root.join("yardlet.err")).unwrap(),
        ))
        .process_group(0)
        .spawn()
        .unwrap();
    let yardlet_pid = yardlet.id() as i32;
    let mut yardlet = common::ChildGuard::new(yardlet);

    assert!(
        wait_for(&ids, Duration::from_secs(60)),
        "the fixture worker never started; yardlet said:\n{}",
        fs::read_to_string(root.join("yardlet.err")).unwrap_or_default()
    );
    let recorded = fs::read_to_string(&ids).unwrap();
    let mut parts = recorded.split_whitespace();
    let worker_pid: i32 = parts.next().unwrap().parse().unwrap();
    let worker_pgid: i32 = parts.next().unwrap().parse().unwrap();

    let yardlet_pgid = pgid_of(yardlet_pid);

    // The observable property first, so a regression reports what the operator
    // would live through rather than an implementation detail: hang up
    // Yardlet's whole process group, exactly as pty teardown does.
    assert_eq!(
        unsafe { libc::kill(-yardlet_pgid, libc::SIGHUP) },
        0,
        "could not signal Yardlet's process group"
    );
    yardlet.shutdown(Duration::from_secs(5), || {});
    assert!(
        alive(worker_pid),
        "the worker died with the terminal that started it"
    );

    // And the reason it survived: it leads its own group instead of sitting in
    // the one the hangup targets.
    assert_eq!(
        worker_pgid, worker_pid,
        "the worker is not its own process group leader"
    );
    assert_ne!(
        worker_pgid, yardlet_pgid,
        "the worker shares Yardlet's process group, so pty teardown would take it down"
    );

    unsafe {
        libc::kill(worker_pid, libc::SIGKILL);
    }
    drop(yardlet);
    let _ = fs::remove_dir_all(&root);
}
