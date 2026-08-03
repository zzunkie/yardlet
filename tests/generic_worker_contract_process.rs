#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture {
    root: PathBuf,
    capture: PathBuf,
    binary: PathBuf,
    worker: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let stem = format!(
            "yardlet-generic-contract-{label}-{}-{nonce}",
            std::process::id()
        );
        let root = std::env::temp_dir().join(&stem);
        let capture = std::env::temp_dir().join(format!("{stem}-capture"));
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&capture).unwrap();
        let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));

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
        write_worker(&worker, &capture);
        must_succeed(&root, Path::new("git"), &["add", "fixture-worker.sh"]);
        must_succeed(
            &root,
            Path::new("git"),
            &["commit", "-qm", "fixture worker"],
        );
        write_task(&root);

        Self {
            root,
            capture,
            binary,
            worker,
        }
    }

    fn configure(&self, invocation: &str, billing_policy: &str) {
        fs::write(
            self.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n{}    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n  allow_preferred_worker_failover: false\n",
                self.worker.display(), invocation
            ),
        )
        .unwrap();
        fs::write(
            self.root.join(".agents/billing-policy.yaml"),
            format!(
                "schema_version: 1\nmode: zero_key_subscription_workers\nworker_invocation:\n  ai_billing_env_policy: {billing_policy}\nblocked_worker_env_names: [YARD_GENERIC_CONTRACT_SECRET]\n"
            ),
        )
        .unwrap();
    }

    fn run_with_secret(&self, args: &[&str]) -> Output {
        Command::new(&self.binary)
            .args(args)
            .current_dir(&self.root)
            .env("YARD_GENERIC_CONTRACT_SECRET", "must-not-reach-worker")
            .output()
            .unwrap()
    }

    fn latest_run(&self) -> PathBuf {
        let mut runs = fs::read_dir(self.root.join(".agents/runs"))
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.join("task-packet.md").is_file())
            .collect::<Vec<_>>();
        runs.sort();
        runs.pop().expect("fixture run exists")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
        let _ = fs::remove_dir_all(&self.capture);
    }
}

fn must_succeed(root: &Path, program: &Path, args: &[&str]) -> Output {
    let output = Command::new(program)
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("failed to run {}: {error}", program.display()));
    assert!(
        output.status.success(),
        "{} {:?} failed\nstdout:\n{}\nstderr:\n{}",
        program.display(),
        args,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn write_task(root: &Path) {
    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-generic-contract\nsummary: generic contract fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-generic-contract\nintent_id: intent-generic-contract\ntasks:\n  - id: YARD-001\n    title: generic contract fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [packet delivered exactly once]\n",
    )
    .unwrap();
}

fn write_worker(path: &Path, capture: &Path) {
    let script = format!(
        r#"#!/bin/sh
set -eu
capture={capture:?}
printf '%s\0' "$@" > "$capture/last-argv"
if [ "${{YARD_GENERIC_CONTRACT_SECRET+x}}" = x ]; then
  printf present > "$capture/last-secret"
else
  printf absent > "$capture/last-secret"
fi
if [ "${{1:-}}" = probe ] && [ "${{2:-}}" = offline ]; then
  cp "$capture/last-argv" "$capture/probe-argv"
  cp "$capture/last-secret" "$capture/probe-secret"
  printf 'fixture-worker 1.0\n'
  exit 0
fi
if [ "${{1:-}}" = probe ] && [ "${{2:-}}" = fail ]; then
  cp "$capture/last-argv" "$capture/probe-argv"
  cp "$capture/last-secret" "$capture/probe-secret"
  exit 42
fi
if [ "${{1:-}}" = --version ]; then
  cp "$capture/last-argv" "$capture/probe-argv"
  cp "$capture/last-secret" "$capture/probe-secret"
  printf 'fixture-worker legacy-probe\n'
  exit 0
fi
printf invoked > "$capture/invoked"
run_dir="$2"
run_id="$(basename "$run_dir")"
if [ "${{1:-}}" = ask ]; then
  cp "$capture/last-argv" "$capture/fresh-argv"
  printf '%s' "${{3:-}}" > "$capture/prompt-argument"
  cat > "$capture/stdin"
  printf 'SESSION_REF=fixture session ref\n'
  cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "needs_user",
  "intent_adherence": {{"drift_detected": false, "notes": ""}},
  "changes": {{"files_modified": [], "files_created": [], "files_deleted": []}},
  "validation": {{"commands_run": [], "passed": true, "failures": []}},
  "question_for_user": "Continue in the same generic session?",
  "compact_summary": "generic fixture needs an answer",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}}
EOF
  printf '# Generic worker question\n' > "$run_dir/handoff.md"
  exit 0
fi
if [ "${{1:-}}" = ask-without-session ]; then
  printf '%s' "${{3:-}}" > "$capture/prompt-argument"
  cat > "$capture/stdin"
  if grep -q 'Explicit continuation packet' "$capture/prompt-argument"; then
    cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "compact_summary": "generic explicit fallback complete"
}}
EOF
    printf '# Generic worker explicit fallback\n' > "$run_dir/handoff.md"
  else
    cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "needs_user",
  "question_for_user": "Continue without a captured session ref?",
  "compact_summary": "generic fixture omitted its session ref"
}}
EOF
    printf '# Generic worker omitted session ref\n' > "$run_dir/handoff.md"
  fi
  exit 0
fi
if [ "${{1:-}}" = resume ]; then
  cp "$capture/last-argv" "$capture/resume-argv"
  printf '%s' "${{4:-}}" > "$capture/resume-prompt"
  cat > "$capture/resume-stdin"
  if [ "${{3:-}}" != 'fixture session ref' ]; then
    printf 'wrong session ref: %s\n' "${{3:-}}" >&2
    exit 64
  fi
  cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {{"drift_detected": false, "notes": ""}},
  "changes": {{"files_modified": [], "files_created": [], "files_deleted": []}},
  "validation": {{"commands_run": [], "passed": true, "failures": []}},
  "question_for_user": null,
  "compact_summary": "generic native resume complete",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}}
EOF
  printf '# Generic worker resumed\n' > "$run_dir/handoff.md"
  exit 0
fi
printf '%s' "${{3:-}}" > "$capture/prompt-argument"
cat > "$capture/stdin"
cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {{"drift_detected": false, "notes": ""}},
  "changes": {{"files_modified": [], "files_created": [], "files_deleted": []}},
  "validation": {{"commands_run": [], "passed": true, "failures": []}},
  "question_for_user": null,
  "compact_summary": "generic fixture complete",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}}
EOF
printf '# Generic worker handoff\n' > "$run_dir/handoff.md"
"#,
        capture = capture.display()
    );
    fs::write(path, script).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn argv(path: &Path) -> Vec<String> {
    fs::read(path)
        .unwrap()
        .split(|byte| *byte == 0)
        .filter(|arg| !arg.is_empty())
        .map(|arg| String::from_utf8(arg.to_vec()).unwrap())
        .collect()
}

#[test]
fn generic_argument_transport_preserves_argv_boundaries_and_delivers_the_packet_once() {
    let fixture = Fixture::new("argument");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe, offline]\n      prompt_transport: argument\n      args: [execute, '{run_dir}', '{prompt}', 'literal with spaces']\n",
        "scrub_or_block",
    );

    let output = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let run = fixture.latest_run();
    let packet = fs::read_to_string(run.join("task-packet.md")).unwrap();
    let received = fs::read_to_string(fixture.capture.join("prompt-argument")).unwrap();
    assert_eq!(
        received, packet,
        "the complete packet must occupy one argv slot"
    );
    assert!(
        fs::read(fixture.capture.join("stdin")).unwrap().is_empty(),
        "argument transport must not duplicate the packet on stdin"
    );
    let received_argv = argv(&fixture.capture.join("last-argv"));
    assert_eq!(received_argv[0], "execute");
    assert_eq!(received_argv[2], packet);
    assert_eq!(received_argv[3], "literal with spaces");
    assert_eq!(
        argv(&fixture.capture.join("probe-argv")),
        ["probe", "offline"]
    );
    assert_eq!(
        fs::read_to_string(fixture.capture.join("probe-secret")).unwrap(),
        "absent",
        "offline probes must use the worker billing-env sanitation boundary"
    );
    assert_eq!(
        fs::read_to_string(fixture.capture.join("last-secret")).unwrap(),
        "absent"
    );
    assert!(run.join("result.json").is_file());
}

#[test]
fn legacy_stdin_transport_and_default_offline_probe_remain_invocable() {
    let fixture = Fixture::new("stdin");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      args: [execute, '{run_dir}']\n",
        "scrub_or_block",
    );

    let output = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let run = fixture.latest_run();
    let packet = fs::read_to_string(run.join("task-packet.md")).unwrap();
    assert_eq!(
        fs::read_to_string(fixture.capture.join("stdin")).unwrap(),
        packet
    );
    assert!(fs::read_to_string(fixture.capture.join("prompt-argument"))
        .unwrap()
        .is_empty());
    assert_eq!(argv(&fixture.capture.join("probe-argv")), ["--version"]);
    assert_eq!(
        fs::read_to_string(fixture.capture.join("last-secret")).unwrap(),
        "absent"
    );
}

#[test]
fn invalid_contract_and_strict_billing_are_rejected_before_probe_or_worker_spawn() {
    for (label, invocation, billing, expected) in [
        (
            "noninteractive",
            "      supports_noninteractive: false\n      output_contract: files\n      args: [execute, '{run_dir}']\n",
            "scrub_or_block",
            "supports_noninteractive",
        ),
        (
            "output-contract",
            "      supports_noninteractive: true\n      output_contract: stdout_json\n      args: [execute, '{run_dir}']\n",
            "scrub_or_block",
            "output_contract",
        ),
        (
            "prompt-transport",
            "      supports_noninteractive: true\n      output_contract: files\n      prompt_transport: shell\n      args: [execute, '{run_dir}']\n",
            "scrub_or_block",
            "prompt_transport",
        ),
        (
            "prompt-placeholder",
            "      supports_noninteractive: true\n      output_contract: files\n      prompt_transport: argument\n      args: [execute, '{run_dir}']\n",
            "scrub_or_block",
            "exactly one {prompt}",
        ),
        (
            "session-capture",
            "      supports_noninteractive: true\n      output_contract: files\n      args: [execute, '{run_dir}']\n      session:\n        capture: {}\n        resume_args: ['{run_dir}', '{session}']\n",
            "scrub_or_block",
            "session capture stream",
        ),
        (
            "session-resume-ref",
            "      supports_noninteractive: true\n      output_contract: files\n      args: [execute, '{run_dir}']\n      session:\n        capture: {stream: stdout, prefix: 'SESSION_REF='}\n        resume_args: ['{run_dir}']\n",
            "scrub_or_block",
            "exactly one {session}",
        ),
        (
            "session-resume-prompt",
            "      supports_noninteractive: true\n      output_contract: files\n      prompt_transport: argument\n      args: [execute, '{run_dir}', '{prompt}']\n      session:\n        capture: {stream: stdout, prefix: 'SESSION_REF='}\n        resume_args: ['{run_dir}', '{session}']\n",
            "scrub_or_block",
            "exactly one {prompt}",
        ),
        (
            "strict-billing",
            "      supports_noninteractive: true\n      output_contract: files\n      args: [execute, '{run_dir}']\n",
            "block",
            "strict billing policy",
        ),
    ] {
        let fixture = Fixture::new(label);
        fixture.configure(invocation, billing);
        let output = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
        assert!(!output.status.success(), "{label} unexpectedly ran");
        let combined = format!(
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(combined.contains(expected), "{label}: {combined}");
        assert!(
            !fixture.capture.join("last-argv").exists(),
            "{label} spawned a probe or worker before rejecting the profile"
        );
        assert!(!fixture.capture.join("invoked").exists());
    }
}

#[test]
fn failed_offline_probe_rejects_routing_before_the_worker_invocation() {
    let fixture = Fixture::new("failed-probe");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe, fail]\n      args: [execute, '{run_dir}']\n",
        "scrub_or_block",
    );

    let output = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(!output.status.success(), "failed probe unexpectedly routed");
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        combined.contains("configured offline version probe failed"),
        "{combined}"
    );
    assert_eq!(argv(&fixture.capture.join("probe-argv")), ["probe", "fail"]);
    assert!(
        !fixture.capture.join("invoked").exists(),
        "the failed probe must not fall through to the worker invocation"
    );
}

#[test]
fn generic_answer_uses_captured_session_ref_and_declared_native_resume_template() {
    let fixture = Fixture::new("native-resume");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe, offline]\n      prompt_transport: argument\n      args: [ask, '{run_dir}', '{prompt}']\n      session:\n        capture:\n          stream: stdout\n          prefix: 'SESSION_REF='\n        resume_args: [resume, '{run_dir}', '{session}', '{prompt}', 'literal with spaces']\n",
        "scrub_or_block",
    );

    let first = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        first.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&first.stdout),
        String::from_utf8_lossy(&first.stderr)
    );
    let answer = fixture.run_with_secret(&[
        "answer",
        "native answer with spaces",
        "--task",
        "YARD-001",
        "--action-id",
        "act-generic-native-answer",
    ]);
    assert!(
        answer.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&answer.stdout),
        String::from_utf8_lossy(&answer.stderr)
    );

    let resume_argv = argv(&fixture.capture.join("resume-argv"));
    assert_eq!(resume_argv[0], "resume");
    assert_eq!(resume_argv[2], "fixture session ref");
    assert_eq!(resume_argv[4], "literal with spaces");
    let resume_prompt = fs::read_to_string(fixture.capture.join("resume-prompt")).unwrap();
    assert_eq!(
        resume_prompt.matches("native answer with spaces").count(),
        1
    );
    assert!(
        fs::read(fixture.capture.join("resume-stdin"))
            .unwrap()
            .is_empty(),
        "argument resume transport must not duplicate the prompt on stdin"
    );

    let channel_root = fixture.root.join(".agents/task-channels");
    let attempt_records = files_below(&channel_root, ".yaml")
        .into_iter()
        .filter(|path| path.to_string_lossy().contains("/attempts/"))
        .map(|path| fs::read_to_string(path).unwrap())
        .collect::<Vec<_>>();
    assert!(attempt_records.iter().any(|record| {
        record.contains("continuation: native_resume")
            && record.contains("worker_session_ref: fixture session ref")
    }));
    let event_records = files_below(&channel_root, ".yaml")
        .into_iter()
        .filter(|path| path.to_string_lossy().contains("/events/"))
        .map(|path| fs::read_to_string(path).unwrap())
        .collect::<Vec<_>>();
    assert!(
        event_records.iter().any(|record| {
            record.contains("type: worker.completed")
                && record.contains("worker_session_ref: fixture session ref")
        }),
        "worker.completed did not retain the generic session ref: {event_records:#?}"
    );
    let latest_packet = fs::read_to_string(fixture.latest_run().join("task-packet.md")).unwrap();
    assert!(!latest_packet.contains("Explicit continuation packet"));
}

#[test]
fn generic_answer_without_a_captured_session_ref_uses_explicit_packet_fallback() {
    let fixture = Fixture::new("missing-session-ref");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe, offline]\n      prompt_transport: argument\n      args: [ask-without-session, '{run_dir}', '{prompt}']\n      session:\n        capture:\n          stream: stdout\n          prefix: 'SESSION_REF='\n        resume_args: [resume, '{run_dir}', '{session}', '{prompt}']\n",
        "scrub_or_block",
    );

    must_succeed(
        &fixture.root,
        &fixture.binary,
        &["run", "--task", "YARD-001", "--execute"],
    );
    must_succeed(
        &fixture.root,
        &fixture.binary,
        &[
            "answer",
            "fallback answer",
            "--task",
            "YARD-001",
            "--action-id",
            "act-generic-fallback-answer",
        ],
    );

    assert!(!fixture.capture.join("resume-argv").exists());
    let packet = fs::read_to_string(fixture.latest_run().join("task-packet.md")).unwrap();
    assert!(packet.contains("Explicit continuation packet"));
    let attempt_records = files_below(&fixture.root.join(".agents/task-channels"), ".yaml")
        .into_iter()
        .filter(|path| path.to_string_lossy().contains("/attempts/"))
        .map(|path| fs::read_to_string(path).unwrap())
        .collect::<Vec<_>>();
    assert!(attempt_records
        .iter()
        .any(|record| record.contains("continuation: explicit_packet")));
}

fn files_below(root: &Path, suffix: &str) -> Vec<PathBuf> {
    let mut files = Vec::new();
    if let Ok(entries) = fs::read_dir(root) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                files.extend(files_below(&path, suffix));
            } else if path.to_string_lossy().ends_with(suffix) {
                files.push(path);
            }
        }
    }
    files.sort();
    files
}
