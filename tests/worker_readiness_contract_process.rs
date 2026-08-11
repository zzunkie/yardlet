#![cfg(unix)]

//! Extended readiness contract, exercised against real subprocesses.
//!
//! Each fixture installs a fake CLI that echoes exactly what the profile asks
//! it to echo, so one script can play "a different product under the same
//! command name", "an out-of-date build", and "a logged-out CLI". The three
//! states must reach the operator (routing refusal + `worker status`) and must
//! block the worker spawn, and every probe attempt must run with the
//! AI-billing environment already scrubbed.

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
            "yardlet-readiness-contract-{label}-{}-{nonce}",
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

    fn configure(&self, invocation: &str) {
        fs::write(
            self.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      supports_noninteractive: true\n      output_contract: files\n      args: [execute, '{{run_dir}}']\n      sandbox_args: ['--fixture-sandbox']\n{}    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n  allow_preferred_worker_failover: false\n",
                self.worker.display(),
                invocation
            ),
        )
        .unwrap();
        fs::write(
            self.root.join(".agents/billing-policy.yaml"),
            "schema_version: 1\nmode: zero_key_subscription_workers\nworker_invocation:\n  ai_billing_env_policy: scrub_or_block\nblocked_worker_env_names: [YARD_READINESS_CONTRACT_SECRET]\n",
        )
        .unwrap();
    }

    fn run_with_secret(&self, args: &[&str]) -> Output {
        Command::new(&self.binary)
            .args(args)
            .current_dir(&self.root)
            .env("YARD_READINESS_CONTRACT_SECRET", "must-not-reach-worker")
            .output()
            .unwrap()
    }

    /// The recorded billing-env posture of one probe attempt. Reading a missing
    /// capture file panics, so the assertion cannot pass vacuously.
    fn probe_secret(&self, branch: &str) -> String {
        let path = self.capture.join(format!("{branch}-secret"));
        fs::read_to_string(&path).unwrap_or_else(|error| {
            panic!("no {branch} probe attempt recorded at {path:?}: {error}")
        })
    }

    fn attempted(&self, branch: &str) -> bool {
        self.capture.join(format!("{branch}-argv")).exists()
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
        "schema_version: 1\nid: intent-readiness-contract\nsummary: readiness contract fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-readiness-contract\nintent_id: intent-readiness-contract\ntasks:\n  - id: YARD-001\n    title: readiness contract fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [worker spawns only when readiness allows it]\n",
    )
    .unwrap();
}

/// A fake CLI whose probe branches echo their second argument, so each test
/// declares the exact probe output in `.agents/workers.yaml`.
fn write_worker(path: &Path, capture: &Path) {
    let script = format!(
        r#"#!/bin/sh
set -eu
capture={capture:?}
printf '%s\0' "$@" > "$capture/last-argv"
if [ "${{YARD_READINESS_CONTRACT_SECRET+x}}" = x ]; then
  printf present > "$capture/last-secret"
else
  printf absent > "$capture/last-secret"
fi
case "${{1:-}}" in
  identity|version|auth)
    cp "$capture/last-argv" "$capture/$1-argv"
    cp "$capture/last-secret" "$capture/$1-secret"
    printf '%s\n' "${{2:-}}"
    exit 0
    ;;
esac
printf invoked > "$capture/invoked"
run_dir="$2"
run_id="$(basename "$run_dir")"
cat > "$capture/stdin"
cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "compact_summary": "readiness fixture complete"
}}
EOF
printf '# Readiness fixture handoff\n' > "$run_dir/handoff.md"
"#,
        capture = capture.display()
    );
    fs::write(path, script).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

fn combined(output: &Output) -> String {
    format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[test]
fn a_different_product_under_the_same_command_name_is_rejected_before_the_worker_spawn() {
    let fixture = Fixture::new("wrong-product");
    fixture.configure(
        "      version_args: [version, 'other-product 3.1.0']\n      identity_probe:\n        args: [identity, 'other-product 3.1.0 (not the worker)']\n        expected_signature: fixture-worker\n",
    );

    let run = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(!run.status.success(), "a wrong binary unexpectedly routed");
    let routing = combined(&run);
    assert!(
        routing.contains("different product is installed under the command name"),
        "{routing}"
    );
    assert!(routing.contains("other-product 3.1.0"), "{routing}");
    assert!(
        !fixture.capture.join("invoked").exists(),
        "a wrong binary must never be invoked as the worker"
    );
    // Identity is gated before the version probe, so the later gate never runs.
    assert!(
        fixture.attempted("identity"),
        "the identity probe never ran"
    );
    assert!(
        !fixture.attempted("version"),
        "the version probe ran after a failed identity gate"
    );
    assert_eq!(
        fixture.probe_secret("identity"),
        "absent",
        "identity probes must use the worker billing-env sanitation boundary"
    );

    let status = fixture.run_with_secret(&["worker", "status"]);
    let text = combined(&status);
    assert!(text.contains("fixture [wrong product]"), "{text}");
    assert!(text.contains("set an explicit `command:` path"), "{text}");
    assert!(
        text.contains("[ FAIL] identity"),
        "the staged checklist must name the identity gate: {text}"
    );
}

#[test]
fn a_logged_out_worker_cli_is_rejected_before_the_worker_spawn() {
    let fixture = Fixture::new("unauthenticated");
    fixture.configure(
        "      version_args: [version, 'fixture-worker 1.4.0']\n      auth_probe:\n        args: [auth, 'account: you are not logged in']\n        ready_patterns: ['logged in as']\n        unauthenticated_patterns: ['not logged in']\n",
    );

    let run = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        !run.status.success(),
        "a logged-out worker unexpectedly routed"
    );
    let routing = combined(&run);
    assert!(routing.contains("NOT logged in"), "{routing}");
    assert!(
        !fixture.capture.join("invoked").exists(),
        "a logged-out worker must never be invoked"
    );
    assert!(fixture.attempted("auth"), "the auth probe never ran");
    assert_eq!(
        fixture.probe_secret("auth"),
        "absent",
        "auth probes must use the worker billing-env sanitation boundary"
    );

    let status = fixture.run_with_secret(&["worker", "status"]);
    let text = combined(&status);
    assert!(text.contains("fixture [unauthenticated]"), "{text}");
    assert!(text.contains("fix: sign in with"), "{text}");
    assert!(
        text.contains("[ FAIL] auth"),
        "the staged checklist must fail the auth gate: {text}"
    );
    assert!(
        text.contains("never asks for an API key"),
        "a logged-out worker must be pointed at its own login, not at an API key: {text}"
    );
}

#[test]
fn a_worker_cli_below_min_version_is_rejected_with_upgrade_guidance() {
    let fixture = Fixture::new("unsupported-version");
    fixture.configure(
        "      version_args: [version, 'fixture-worker 0.9.9']\n      min_version: '1.2.0'\n      auth_probe:\n        args: [auth, 'logged in as fixture']\n        ready_patterns: ['logged in as']\n",
    );

    let run = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        !run.status.success(),
        "an out-of-date worker unexpectedly routed"
    );
    let routing = combined(&run);
    assert!(routing.contains("upgrade to >= 1.2.0"), "{routing}");
    assert!(routing.contains("fixture-worker 0.9.9"), "{routing}");
    assert!(
        !fixture.capture.join("invoked").exists(),
        "an out-of-date worker must never be invoked"
    );
    // The version gate runs before auth, and stops it.
    assert!(fixture.attempted("version"), "the version probe never ran");
    assert!(
        !fixture.attempted("auth"),
        "the auth probe ran after a failed version gate"
    );
    assert_eq!(
        fixture.probe_secret("version"),
        "absent",
        "version probes must use the worker billing-env sanitation boundary"
    );

    let status = fixture.run_with_secret(&["worker", "status"]);
    let text = combined(&status);
    assert!(text.contains("fixture [unsupported version]"), "{text}");
    assert!(text.contains("fix: upgrade"), "{text}");
    assert!(text.contains(">= 1.2.0"), "{text}");
}

#[test]
fn a_matching_up_to_date_logged_in_worker_stays_invocable() {
    let fixture = Fixture::new("all-gates-pass");
    fixture.configure(
        "      version_args: [version, 'fixture-worker 1.4.0']\n      min_version: '1.2.0'\n      identity_probe:\n        args: [identity, 'fixture-worker 1.4.0']\n        expected_signature: fixture-worker\n      auth_probe:\n        args: [auth, 'logged in as fixture']\n        ready_patterns: ['logged in as']\n        unauthenticated_patterns: ['not logged in']\n",
    );

    let run = fixture.run_with_secret(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        run.status.success(),
        "every gate passed but the run failed:\n{}",
        combined(&run)
    );
    assert!(
        fixture.capture.join("invoked").exists(),
        "the worker was never invoked despite passing every gate"
    );
    for branch in ["identity", "version", "auth"] {
        assert!(fixture.attempted(branch), "the {branch} probe never ran");
        assert_eq!(
            fixture.probe_secret(branch),
            "absent",
            "{branch} probes must use the worker billing-env sanitation boundary"
        );
    }

    let status = fixture.run_with_secret(&["worker", "status"]);
    let text = combined(&status);
    assert!(text.contains("fixture [invocable]"), "{text}");
    assert!(text.contains("[   ok] identity"), "{text}");
    assert!(
        text.contains("[   ok] auth"),
        "a declared auth probe that reports a login must show it: {text}"
    );
}
