//! V010-006: a generic worker declares the SHAPE of its stdout
//! (`invocation.output_format`) and Yardlet normalizes against that
//! declaration instead of a hard-coded worker id.
//!
//! What only a real process can prove, and what this file is for:
//!
//! * a `json` worker that wrote no result FILE still gets its result read out
//!   of captured stdout, and the recovery is stamped with its provenance so it
//!   can never read back as "the worker wrote result.json";
//! * the same worker with a BROKEN document keeps today's typed failure and
//!   its exact raw evidence;
//! * a `stream-json` worker's mixed stream normalizes tolerantly, and the live
//!   publisher and the end-of-attempt replay agree on every raw span (they
//!   record into the same channel, so disagreement is a run-failing error).

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

struct Fixture {
    root: PathBuf,
    binary: PathBuf,
    worker: PathBuf,
}

impl Fixture {
    fn new(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "yardlet-output-format-{label}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
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
        write_worker(&worker);
        must_succeed(&root, Path::new("git"), &["add", "fixture-worker.sh"]);
        must_succeed(
            &root,
            Path::new("git"),
            &["commit", "-qm", "fixture worker"],
        );
        write_task(&root);

        Self {
            root,
            binary,
            worker,
        }
    }

    fn configure(&self, mode: &str, output_format: &str) {
        fs::write(
            self.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      supports_noninteractive: true\n      output_contract: files\n      output_format: {output_format}\n      version_args: [probe, offline]\n      args: [{mode}, '{{run_dir}}']\n      sandbox_args: ['--fixture-sandbox']\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n  allow_preferred_worker_failover: false\n",
                self.worker.display()
            ),
        )
        .unwrap();
    }

    fn run(&self) -> Output {
        Command::new(&self.binary)
            .args(["run", "--task", "YARD-001", "--execute"])
            .current_dir(&self.root)
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

    fn run_record(&self) -> serde_yaml_ng::Value {
        serde_yaml_ng::from_str(&fs::read_to_string(self.latest_run().join("run.yaml")).unwrap())
            .unwrap()
    }

    fn attempt_stdout(&self) -> Vec<u8> {
        let run = self.latest_run();
        let attempt = fs::read_to_string(run.join("latest-attempt")).unwrap();
        fs::read(run.join("attempts").join(attempt.trim()).join("stdout.log")).unwrap()
    }

    fn channel_events(&self) -> Vec<serde_yaml_ng::Value> {
        files_below(&self.root.join(".agents/task-channels"), ".yaml")
            .into_iter()
            .filter(|path| path.to_string_lossy().contains("/events/"))
            .filter_map(|path| {
                serde_yaml_ng::from_str::<serde_yaml_ng::Value>(&fs::read_to_string(path).ok()?)
                    .ok()
            })
            .collect()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
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

fn write_task(root: &Path) {
    fs::write(
        root.join(".agents/intent-contract.yaml"),
        "schema_version: 1\nid: intent-output-format\nsummary: declared output format fixture\nstatus: accepted\n",
    )
    .unwrap();
    fs::write(
        root.join(".agents/work-queue.yaml"),
        "schema_version: 1\nqueue_id: queue-output-format\nintent_id: intent-output-format\ntasks:\n  - id: YARD-001\n    title: declared output format fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [result reaches the core]\n",
    )
    .unwrap();
}

/// The fixture worker. Each mode writes a different STDOUT shape; only the
/// stream-json mode writes the result file the packet asks for.
fn write_worker(path: &Path) {
    let script = r#"#!/bin/sh
set -eu
if [ "${1:-}" = probe ] && [ "${2:-}" = offline ]; then
  printf 'fixture-worker 1.0\n'
  exit 0
fi
run_dir="$2"
run_id="$(basename "$run_dir")"
if [ "${1:-}" = json-result ]; then
  cat
  printf 'reading the packet {\n'
  printf 'superseded run: {"schema_version": 1, "run_id": "stale", "task_id": "YARD-001", "status": "failed"}\n'
  cat <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": "on scope"},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "compact_summary": "document worker answered on stdout"
}
EOF
  printf '# Generic json worker handoff\n' > "$run_dir/handoff.md"
  exit 0
fi
if [ "${1:-}" = json-broken ]; then
  cat
  printf 'starting the document\n'
  printf '{\n  "schema_version": 1,\n  "run_id": "%s",\n  "task_id": "YARD-001",\n  "status": "do\n' "$run_id"
  printf 'stream ended mid-document\n' >&2
  exit 0
fi
if [ "${1:-}" = stream-json ]; then
  cat
  printf 'plain progress line\n'
  printf '{"text":"structured public update","phase":"build"}\n'
  printf '{"phase":"verify","checks":2}\n'
  printf 'not { valid } json\n'
  cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": {"drift_detected": false, "notes": ""},
  "changes": {"files_modified": [], "files_created": [], "files_deleted": []},
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "compact_summary": "stream worker wrote its own result file"
}
EOF
  printf '# Generic stream-json worker handoff\n' > "$run_dir/handoff.md"
  exit 0
fi
printf 'unknown mode %s\n' "${1:-}" >&2
exit 64
"#;
    fs::write(path, script).unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

/// (a) A declared `json` worker that never wrote result.json: Yardlet recovers
/// the LAST result-shaped document from its captured stdout, keeps the worker's
/// exact bytes, and stamps the recovery everywhere the run is read.
#[test]
fn declared_json_worker_result_is_recovered_from_stdout_with_its_provenance() {
    let fixture = Fixture::new("json-recovered");
    fixture.configure("json-result", "json");

    let output = fixture.run();
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.status.success(), "{combined}");

    let run = fixture.latest_run();
    let stdout = fixture.attempt_stdout();
    let result = fs::read_to_string(run.join("result.json")).unwrap();
    assert!(
        result.contains("document worker answered on stdout"),
        "{result}"
    );
    // The LAST result-shaped document wins: the superseded one printed earlier
    // in the same stream must not be the one that reaches the core.
    assert!(!result.contains("\"run_id\": \"stale\""), "{result}");

    let record = fixture.run_record();
    let marker = record
        .get("result_recovered_from_stdout")
        .unwrap_or_else(|| panic!("run.yaml carries no recovery marker: {record:#?}"));
    assert_eq!(
        marker.get("stream").and_then(serde_yaml_ng::Value::as_str),
        Some("stdout")
    );
    assert_eq!(
        marker
            .get("output_format")
            .and_then(serde_yaml_ng::Value::as_str),
        Some("json")
    );
    assert_eq!(
        marker
            .get("attempt_id")
            .and_then(serde_yaml_ng::Value::as_str),
        Some(
            fs::read_to_string(run.join("latest-attempt"))
                .unwrap()
                .trim()
        )
    );
    // The marker points at the exact bytes it took, and those bytes ARE the
    // result file: a recovery relocates the worker's own output, never a
    // re-serialization of it.
    let start = marker
        .get("byte_start")
        .and_then(serde_yaml_ng::Value::as_u64)
        .unwrap() as usize;
    let end = marker
        .get("byte_end")
        .and_then(serde_yaml_ng::Value::as_u64)
        .unwrap() as usize;
    assert_eq!(String::from_utf8_lossy(&stdout[start..end]), result);

    assert!(
        combined.contains("result_recovered_from_stdout"),
        "the run report must say the result did not come from the file: {combined}"
    );
    // Raw evidence is untouched by the recovery.
    assert!(String::from_utf8_lossy(&stdout).contains("reading the packet {"));
}

/// (b) The same declared worker with a BROKEN document: no result is invented,
/// today's typed failure stands, and the raw stream survives intact.
#[test]
fn declared_json_worker_with_a_broken_document_keeps_the_typed_failure_and_raw_log() {
    let fixture = Fixture::new("json-broken");
    fixture.configure("json-broken", "json");

    let output = fixture.run();
    let combined = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !combined.contains("result_recovered_from_stdout"),
        "an unparseable stream must not report a recovery: {combined}"
    );
    assert!(
        !combined.contains("next task state: ✓ done"),
        "a broken document must not finish the task: {combined}"
    );

    let run = fixture.latest_run();
    assert!(
        !run.join("result.json").exists(),
        "an unparseable stream must not produce a result file"
    );
    let record = fixture.run_record();
    assert!(
        record.get("result_recovered_from_stdout").is_none(),
        "a failed recovery must leave no provenance marker: {record:#?}"
    );

    let stdout = String::from_utf8(fixture.attempt_stdout()).unwrap();
    assert!(stdout.contains("starting the document"), "{stdout}");
    assert!(stdout.contains("\"status\": \"do"), "{stdout}");
    let attempt_id = fs::read_to_string(run.join("latest-attempt")).unwrap();
    let stderr = fs::read_to_string(
        run.join("attempts")
            .join(attempt_id.trim())
            .join("stderr.log"),
    )
    .unwrap();
    assert_eq!(stderr, "stream ended mid-document\n");

    let completed = fixture
        .channel_events()
        .into_iter()
        .find(|event| {
            event.get("type").and_then(serde_yaml_ng::Value::as_str) == Some("worker.completed")
        })
        .expect("worker.completed recorded");
    assert_eq!(
        completed
            .get("payload")
            .and_then(|payload| payload.get("result"))
            .and_then(serde_yaml_ng::Value::as_str),
        Some("failed")
    );
}

/// (c) A declared `stream-json` worker's mixed stream: JSON lines become
/// structured events, unparseable lines degrade to text, and nothing in the
/// stream can fail the run.
#[test]
fn declared_stream_json_worker_normalizes_a_mixed_stream_tolerantly() {
    let fixture = Fixture::new("stream-json");
    fixture.configure("stream-json", "stream-json");

    let output = fixture.run();
    assert!(
        output.status.success(),
        "stdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let run = fixture.latest_run();
    assert!(fs::read_to_string(run.join("result.json"))
        .unwrap()
        .contains("stream worker wrote its own result file"));
    let record = fixture.run_record();
    assert!(
        record.get("result_recovered_from_stdout").is_none(),
        "a worker that wrote its own result must not be marked as recovered"
    );

    let messages = fixture
        .channel_events()
        .into_iter()
        .filter(|event| {
            event.get("type").and_then(serde_yaml_ng::Value::as_str) == Some("worker.message")
        })
        .map(|event| event.get("payload").cloned().unwrap_or_default())
        .collect::<Vec<_>>();
    let text_of = |payload: &serde_yaml_ng::Value| {
        payload
            .get("text")
            .and_then(serde_yaml_ng::Value::as_str)
            .unwrap_or_default()
            .to_string()
    };

    let structured = messages
        .iter()
        .find(|payload| text_of(payload) == "structured public update")
        .unwrap_or_else(|| panic!("no structured message event: {messages:#?}"));
    assert_eq!(
        structured
            .get("json")
            .and_then(|json| json.get("phase"))
            .and_then(serde_yaml_ng::Value::as_str),
        Some("build"),
        "a structured event must keep the parsed object, not only its prose"
    );
    // An object with no renderable text keeps its structure and says so verbatim.
    assert!(
        messages.iter().any(|payload| {
            payload
                .get("json")
                .and_then(|json| json.get("checks"))
                .and_then(serde_yaml_ng::Value::as_u64)
                == Some(2)
        }),
        "{messages:#?}"
    );
    // The unparseable line degrades to text instead of failing the stream.
    assert!(
        messages
            .iter()
            .any(|payload| text_of(payload) == "not { valid } json"),
        "{messages:#?}"
    );
    assert!(
        messages
            .iter()
            .any(|payload| text_of(payload) == "plain progress line"),
        "{messages:#?}"
    );
}
