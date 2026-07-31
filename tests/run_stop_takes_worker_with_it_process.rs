//! Stopping `yardlet run` must take its worker with it (issue #107).
//!
//! The counterpart to #52, not a reversal of it. A worker leads its own process
//! group so it survives the TERMINAL closing — an operator quitting the host app
//! mid-review should not lose the reasoning pass. But that same isolation means
//! no signal the operator sends can reach the worker: not the shell's, which
//! goes to its own foreground group, and not a test harness's, which has no
//! handle on a group it did not create.
//!
//! Yardlet holds the only handle. Before this, it never used it on the stop
//! path: `terminate_worker_tree` existed and nothing called it when the
//! orchestrator was asked to stop, so interrupting a run killed the parent and
//! left the worker holding the run directory. That is the most likely source of
//! the four `yardlet` processes found alive 26 hours later in #64.
//!
//! Here Yardlet is signalled DIRECTLY — not its group — so nothing but Yardlet's
//! own teardown can explain the worker's death.

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

/// A worker that reports its pid and then outlives any reasonable test, so its
/// death can only be something else killing it.
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
         printf '%s\\n' \"$$\" >\"$ids\"\n\
         sleep 300\n\
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

fn wait_until_gone(pid: i32, within: Duration) -> bool {
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if !alive(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    !alive(pid)
}

#[test]
fn stopping_yardlet_takes_the_worker_it_started_with_it() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let workspace = common::WorkspaceGuard::create(
        std::env::temp_dir().join(format!("yardlet-run-stop-{}-{nonce}", std::process::id())),
    );
    let root = workspace.path().to_path_buf();
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
    let ids = root.join("worker-pid");

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-stop\nsummary: run stop fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-stop\nintent_id: intent-stop\ntasks:\n  - id: YARD-001\n    title: run stop fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [stopping yardlet stops the worker]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 10\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            worker.display(),
            ids.display()
        ),
    )
    .unwrap();

    // Its own group, so the signal below can target Yardlet alone and cannot
    // reach the worker by accident — the worker's death has to come from
    // Yardlet's teardown or not at all.
    let yardlet = Command::new(&binary)
        .args(["run", "--task", "YARD-001", "--execute"])
        .current_dir(&root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(
            fs::File::create(root.join("yardlet.err")).unwrap(),
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
    let worker_pid: i32 = fs::read_to_string(&ids)
        .unwrap()
        .trim()
        .parse()
        .expect("numeric worker pid");
    assert!(alive(worker_pid), "the fixture worker never started");

    // Exactly what Ctrl-C delivers, to Yardlet only.
    assert_eq!(
        unsafe { libc::kill(yardlet_pid, libc::SIGINT) },
        0,
        "could not signal Yardlet"
    );

    assert!(
        wait_until_gone(worker_pid, Duration::from_secs(30)),
        "the worker outlived the Yardlet that started it: nothing else can reach \
         it, because it leads its own process group by design (#52), so it would \
         have run to its own completion holding the run directory"
    );
    yardlet.shutdown(Duration::from_secs(15), || {});

    // The stop must not be recorded as the task finishing.
    let queue = fs::read_to_string(root.join(".agents/work-queue.yaml")).unwrap_or_default();
    assert!(
        !queue.contains("state: done"),
        "an interrupted run reported its task as done:\n{queue}"
    );
}
