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
    let has_numeric_contents = || {
        fs::read_to_string(path)
            .ok()
            .and_then(|contents| contents.trim().parse::<i32>().ok())
            .is_some()
    };
    let deadline = Instant::now() + within;
    while Instant::now() < deadline {
        if has_numeric_contents() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    has_numeric_contents()
}

#[test]
fn pid_file_is_ready_only_with_numeric_contents() {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let workspace = common::WorkspaceGuard::create(std::env::temp_dir().join(format!(
        "yardlet-run-stop-pid-ready-{}-{nonce}",
        std::process::id()
    )));
    let pid_file = workspace.path().join("worker-pid");

    fs::write(&pid_file, "").unwrap();
    assert!(!wait_for(&pid_file, Duration::ZERO));

    fs::write(&pid_file, "not-a-pid\n").unwrap();
    assert!(!wait_for(&pid_file, Duration::ZERO));

    fs::write(&pid_file, "1234\n").unwrap();
    assert!(wait_for(&pid_file, Duration::ZERO));
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
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 10\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
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

    // The stop must not be recorded as the task finishing — and "not done" is too
    // weak on its own, because a stopped run that fell through to failover lands
    // Failed, which also is not done and which `run --auto` then RETRIES. An
    // independent review caught exactly that. The task has to be back where it
    // can be picked up deliberately, not driven onward.
    let queue = fs::read_to_string(root.join(".agents/work-queue.yaml")).unwrap_or_default();
    assert!(
        !queue.contains("state: done"),
        "an interrupted run reported its task as done:\n{queue}"
    );
    assert!(
        !queue.contains("state: failed"),
        "an interrupted run was recorded as a failure, which `run --auto` treats \
         as transient and retries — the stop would start another worker:\n{queue}"
    );

    // And nothing may have been started in its place.
    let runs = fs::read_dir(root.join(".agents/runs"))
        .map(|entries| entries.filter_map(Result::ok).count())
        .unwrap_or(0);
    assert_eq!(
        runs, 1,
        "a stop must not fail over to a replacement worker; {runs} runs exist"
    );
}

/// The stop path has to reach the whole tree, not just the process Yardlet
/// spawned. A launcher that handles SIGTERM exits while the agent CLI it started
/// ignores it and keeps the inherited pipes open: the grandchild survives, and
/// Yardlet blocks forever waiting for an EOF that cannot come. Same shape as #52,
/// reached through the stop path.
#[test]
fn stopping_reaches_a_grandchild_whose_launcher_exits_first() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let workspace = common::WorkspaceGuard::create(std::env::temp_dir().join(format!(
        "yardlet-run-stop-tree-{}-{nonce}",
        std::process::id()
    )));
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

    // The launcher dies on SIGTERM; the grandchild ignores it and holds the pipes.
    let worker = root.join("fixture-launcher.sh");
    let ids = root.join("grandchild-pid");
    fs::write(
        &worker,
        format!(
            "#!/bin/sh\n\
             set -eu\n\
             if [ \"${{1:-}}\" = \"--version\" ]; then\n\
             \x20 printf 'fixture-launcher 1.0\\n'\n\
             \x20 exit 0\n\
             fi\n\
             cat >/dev/null\n\
             sh -c 'trap \"\" TERM; printf \"%s\\n\" \"$$\" >\"{}\"; while :; do sleep 1; done' &\n\
             wait\n",
            ids.display()
        ),
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&worker, permissions).unwrap();

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-tree\nsummary: stop tree fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-tree\nintent_id: intent-tree\ntasks:\n  - id: YARD-001\n    title: stop tree fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [stopping reaches the whole tree]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 10\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            worker.display()
        ),
    )
    .unwrap();

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
        "the grandchild never started; yardlet said:\n{}",
        fs::read_to_string(root.join("yardlet.err")).unwrap_or_default()
    );
    let grandchild: i32 = fs::read_to_string(&ids)
        .unwrap()
        .trim()
        .parse()
        .expect("numeric grandchild pid");

    assert_eq!(
        unsafe { libc::kill(yardlet_pid, libc::SIGINT) },
        0,
        "could not signal Yardlet"
    );

    assert!(
        wait_until_gone(grandchild, Duration::from_secs(30)),
        "the grandchild ignored SIGTERM and was never escalated to, so it still \
         holds Yardlet's pipes"
    );
    // `kill(pid, 0)` is NOT the check: Yardlet is this test's child, so once it
    // exits it stays a reapable zombie and a liveness probe keeps succeeding.
    // `try_wait` distinguishes "still running" from "exited". (Third time this
    // trap was walked into on this branch — it is why the guard tests assert on
    // status rather than liveness.)
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut exited = false;
    while Instant::now() < deadline {
        if matches!(yardlet.as_mut().try_wait(), Ok(Some(_))) {
            exited = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        exited,
        "Yardlet is still waiting on a stream its grandchild never closed; it said:\n{}",
        fs::read_to_string(root.join("yardlet.err")).unwrap_or_default()
    );
}

/// A worker that already wrote a valid result, then kept working, must not have
/// that result finalized as a completed task when the operator interrupts. An
/// independent review reproduced exactly this: the attempt was recorded stopped
/// while the queue landed `done`, so the Ctrl-C looked like it finished the work.
#[test]
fn a_result_written_before_the_interrupt_does_not_finish_the_task() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let workspace = common::WorkspaceGuard::create(std::env::temp_dir().join(format!(
        "yardlet-run-stop-result-{}-{nonce}",
        std::process::id()
    )));
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

    // Writes a complete, valid result FIRST, announces itself, then keeps going.
    let worker = root.join("fixture-early-result.sh");
    let ids = root.join("worker-pid");
    fs::write(
        &worker,
        "#!/bin/sh\n\
         set -eu\n\
         if [ \"${1:-}\" = \"--version\" ]; then\n\
         \x20 printf 'fixture-early 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         ids=\"$2\"\n\
         cat >/dev/null\n\
         run_id=\"$(basename \"$run_dir\")\"\n\
         printf 'fixture handoff\\n' >\"$run_dir/handoff.md\"\n\
         printf '{\"schema_version\":1,\"run_id\":\"%s\",\"task_id\":\"YARD-001\",\"status\":\"done\",\"compact_summary\":\"fixture finished early\"}' \"$run_id\" >\"$run_dir/result.json\"\n\
         printf '%s\\n' \"$$\" >\"$ids\"\n\
         sleep 300\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&worker, permissions).unwrap();

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-early\nsummary: early result fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-early\nintent_id: intent-early\ntasks:\n  - id: YARD-001\n    title: early result fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [an interrupted run is not a finished one]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 10\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            worker.display(),
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
    assert!(
        root.join(".agents/runs").exists(),
        "no run directory was created"
    );

    assert_eq!(
        unsafe { libc::kill(yardlet_pid, libc::SIGINT) },
        0,
        "could not signal Yardlet"
    );

    let deadline = Instant::now() + Duration::from_secs(40);
    let mut exited = false;
    while Instant::now() < deadline {
        if matches!(yardlet.as_mut().try_wait(), Ok(Some(_))) {
            exited = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        exited,
        "Yardlet never finished after the interrupt; it said:\n{}",
        fs::read_to_string(root.join("yardlet.err")).unwrap_or_default()
    );

    let queue = fs::read_to_string(root.join(".agents/work-queue.yaml")).unwrap_or_default();
    assert!(
        !queue.contains("state: done"),
        "a result written before the interrupt was finalized as a finished task, \
         so the Ctrl-C looks like it completed the work:\n{queue}"
    );
}

/// Issue #110: a stopped run that reaches finalization in a LATER process must
/// not be recorded finished. Review reproduced the shape — interrupt after Done
/// evidence exists, let the queue save fail, restore the durable `running`
/// queue, and a fresh `yardlet recover` reported `YARD-001 -> done` with no
/// marker anywhere, because the decision lived only in the process that made it.
#[test]
fn recover_in_a_fresh_process_honours_the_interruption() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let workspace = common::WorkspaceGuard::create(std::env::temp_dir().join(format!(
        "yardlet-stop-recover-{}-{nonce}",
        std::process::id()
    )));
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

    // A worker that writes PASSING evidence, then keeps going so it can be cut off.
    let worker = root.join("fixture-worker.sh");
    let ids = root.join("worker-pid");
    fs::write(
        &worker,
        "#!/bin/sh\n\
         set -eu\n\
         if [ \"${1:-}\" = \"--version\" ]; then\n\
         \x20 printf 'fixture 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         ids=\"$2\"\n\
         run_id=\"$(basename \"$run_dir\")\"\n\
         cat >/dev/null\n\
         printf 'handoff\\n' >\"$run_dir/handoff.md\"\n\
         printf '{\"schema_version\":1,\"run_id\":\"%s\",\"task_id\":\"YARD-001\",\"status\":\"done\",\"compact_summary\":\"ok\"}' \"$run_id\" >\"$run_dir/result.json\"\n\
         printf '%s\\n' \"$$\" >\"$ids\"\n\
         sleep 300\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&worker).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&worker, permissions).unwrap();

    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-recover\nsummary: stopped run recovery\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-recover\nintent_id: intent-recover\ntasks:\n  - id: YARD-001\n    title: stopped run recovery\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [a stopped run is not finished by a later process]\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}']\n      supports_noninteractive: true\n      output_contract: files\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 10\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
            worker.display(),
            ids.display()
        ),
    )
    .unwrap();

    let yardlet = Command::new(&binary)
        .args(["run", "--task", "YARD-001", "--execute"])
        .current_dir(&root)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let yardlet_pid = yardlet.id() as i32;
    let mut yardlet = common::ChildGuard::new(yardlet);
    assert!(
        wait_for(&ids, Duration::from_secs(60)),
        "worker never started"
    );
    assert_eq!(unsafe { libc::kill(yardlet_pid, libc::SIGINT) }, 0);
    yardlet.shutdown(Duration::from_secs(30), || {});

    // The interrupted process recorded its verdict in core-owned state, outside
    // the run directory a worker can write.
    let run_id = fs::read_dir(root.join(".agents/runs"))
        .unwrap()
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .find(|name| name.starts_with("run-"))
        .expect("a run directory");
    fs::create_dir_all(root.join(".agents/stopped-runs")).unwrap();
    fs::write(
        root.join(".agents/stopped-runs").join(&run_id),
        "operator_interrupt\n",
    )
    .unwrap();

    // The queue save is what failed in the reported case, so the durable queue
    // still says Running and a later process has to settle it.
    let queue_path = root.join(".agents/work-queue.yaml");
    let queue = fs::read_to_string(&queue_path).unwrap();
    fs::write(
        &queue_path,
        queue.replace("state: queued", "state: running"),
    )
    .unwrap();

    // A FRESH process. The stop flag it would have consulted is gone.
    let recovered = Command::new(&binary)
        .arg("recover")
        .current_dir(&root)
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&recovered.stdout).into_owned();
    let queue = fs::read_to_string(&queue_path).unwrap();
    assert!(
        !queue.contains("state: done"),
        "a later process finished a run the operator had stopped:\n{said}\n{queue}"
    );
    assert!(
        said.contains("interrupted"),
        "recovery must say why it refused to finish it: {said}"
    );
}
