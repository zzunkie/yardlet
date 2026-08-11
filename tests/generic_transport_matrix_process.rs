//! Prompt-transport fixture matrix for the generic worker adapter.
//!
//! Closes the three gaps the existing generic contract fixtures leave open:
//!   (a) `prompt_transport: file` must carry a real task through the same
//!       task -> result -> continuation path a stdin worker takes;
//!   (b) a stdin worker that never reads the packet must still complete from
//!       its result files, because packet delivery is best-effort by contract;
//!   (c) a worker that exits 0 with an unparseable `result.json` must be
//!       recorded as a typed failure whose raw attempt streams survive.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

const SESSION_CONTRACT: &str =
    "      session:\n        capture:\n          stream: stdout\n          prefix: 'SESSION_REF='\n";

struct Fixture {
    root: PathBuf,
    binary: PathBuf,
    worker: PathBuf,
}

impl Fixture {
    fn new(label: &str, acceptance: &str) -> Self {
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "yardlet-transport-matrix-{label}-{}-{nonce}",
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
        fs::copy(
            manifest.join("tests/fixtures/generic_transport_matrix/worker.sh"),
            &worker,
        )
        .unwrap();
        let mut permissions = fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&worker, permissions).unwrap();

        fs::write(
            root.join(".agents/intent-contract.yaml"),
            "schema_version: 1\nid: intent-transport-matrix\nsummary: transport matrix fixture\nstatus: accepted\n",
        )
        .unwrap();
        fs::write(
            root.join(".agents/work-queue.yaml"),
            format!(
                "schema_version: 1\nqueue_id: queue-transport-matrix\nintent_id: intent-transport-matrix\ntasks:\n  - id: YARD-001\n    title: transport matrix fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    fallback_enabled: false\n    acceptance: ['{acceptance}']\n"
            ),
        )
        .unwrap();

        Self {
            root,
            binary,
            worker,
        }
    }

    fn configure(&self, invocation: &str) {
        fs::write(
            self.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n{}    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n  allow_preferred_worker_failover: false\n",
                self.worker.display(),
                invocation
            ),
        )
        .unwrap();
    }

    fn yardlet(&self, args: &[&str]) -> Output {
        command(&self.root, &self.binary, args)
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

    fn task_state(&self) -> String {
        yaml(&self.root.join(".agents/work-queue.yaml"))["tasks"][0]["state"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn channel_records(&self, segment: &str) -> Vec<serde_yaml_ng::Value> {
        let mut records = files_below(&self.root.join(".agents/task-channels"), ".yaml")
            .into_iter()
            .filter(|path| path.to_string_lossy().contains(segment))
            .map(|path| yaml(&path))
            .collect::<Vec<_>>();
        records.sort_by_key(|record| {
            record
                .get("attempt_id")
                .and_then(serde_yaml_ng::Value::as_str)
                .unwrap_or_default()
                .to_string()
        });
        records
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn command(root: &Path, program: &Path, args: &[&str]) -> Output {
    Command::new(program)
        .args(args)
        .current_dir(root)
        .output()
        .unwrap_or_else(|error| panic!("failed to run {}: {error}", program.display()))
}

fn must_succeed(root: &Path, program: &Path, args: &[&str]) -> Output {
    let output = command(root, program, args);
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

fn yaml(path: &Path) -> serde_yaml_ng::Value {
    serde_yaml_ng::from_str(&fs::read_to_string(path).unwrap()).unwrap()
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

/// The transport-independent shape of a full question -> answer cycle. Two
/// transports that produce the same value delivered the same work.
#[derive(Debug, PartialEq, Eq)]
struct Cycle {
    first_state: String,
    final_state: String,
    continuations: Vec<String>,
    session_refs: Vec<String>,
    summaries: Vec<String>,
}

fn drive_question_and_answer(fixture: &Fixture, action_id: &str) -> (PathBuf, PathBuf, Cycle) {
    must_succeed(
        &fixture.root,
        &fixture.binary,
        &["run", "--task", "YARD-001", "--execute"],
    );
    let first_run = fixture.latest_run();
    let first_state = fixture.task_state();

    must_succeed(
        &fixture.root,
        &fixture.binary,
        &[
            "answer",
            "transport matrix answer",
            "--task",
            "YARD-001",
            "--action-id",
            action_id,
        ],
    );
    let resume_run = fixture.latest_run();
    assert_ne!(
        first_run, resume_run,
        "the answer must run in its own run directory"
    );

    let attempts = fixture.channel_records("/attempts/");
    // Attempt ids are not chronologically ordered across run directories, so
    // compare the multiset of what each transport produced, not its order.
    let mut continuations = attempts
        .iter()
        .map(|attempt| attempt["continuation"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    continuations.sort();
    let mut session_refs = attempts
        .iter()
        .filter_map(|attempt| attempt.get("worker_session_ref"))
        .filter_map(|value| value.as_str().map(str::to_string))
        .collect::<Vec<_>>();
    session_refs.sort();
    let cycle = Cycle {
        first_state,
        final_state: fixture.task_state(),
        continuations,
        session_refs,
        summaries: [&first_run, &resume_run]
            .into_iter()
            .map(|run| {
                let result: serde_json::Value =
                    serde_json::from_str(&fs::read_to_string(run.join("result.json")).unwrap())
                        .unwrap();
                result["compact_summary"].as_str().unwrap().to_string()
            })
            .collect(),
    };
    (first_run, resume_run, cycle)
}

// (a) Dogfood proof: a file-transport profile must be interchangeable with a
// stdin one for a real task, not merely valid on paper.
#[test]
fn file_prompt_transport_matches_stdin_transport_across_task_result_and_continuation() {
    let on_stdin = Fixture::new("stdin", "packet delivered exactly once");
    on_stdin.configure(&format!(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe]\n      sandbox_args: ['--fixture-sandbox']\n      args: [stdin, '{{run_dir}}']\n{SESSION_CONTRACT}        resume_args: [stdin-resume, '{{run_dir}}', '{{session}}']\n"
    ));
    let (stdin_first, stdin_resume, stdin_cycle) =
        drive_question_and_answer(&on_stdin, "act-transport-matrix-stdin");

    let in_file = Fixture::new("file", "packet delivered exactly once");
    in_file.configure(&format!(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe]\n      sandbox_args: ['--fixture-sandbox']\n      prompt_transport: file\n      args: [file, '{{run_dir}}', '{{prompt_file}}']\n{SESSION_CONTRACT}        resume_args: [file-resume, '{{run_dir}}', '{{prompt_file}}', '{{session}}']\n"
    ));
    let (file_first, file_resume, file_cycle) =
        drive_question_and_answer(&in_file, "act-transport-matrix-file");

    assert_eq!(
        file_cycle, stdin_cycle,
        "file transport must deliver the same task, result, and continuation as stdin"
    );
    assert_eq!(file_cycle.first_state, "needs_user");
    assert_eq!(file_cycle.final_state, "done");
    assert_eq!(file_cycle.continuations, ["fresh", "native_resume"]);
    assert_eq!(
        stdin_first.join("seen-packet-body").is_file(),
        file_first.join("seen-packet-body").is_file()
    );

    // The packet lives in the run directory Yardlet already owns, so nothing
    // else has to clean it up, and the worker read exactly that file.
    for (run, seen_path, seen_body, seen_stdin) in [
        (
            &file_first,
            "seen-packet-path",
            "seen-packet-body",
            "seen-stdin",
        ),
        (
            &file_resume,
            "seen-resume-packet-path",
            "seen-resume-packet-body",
            "seen-resume-stdin",
        ),
    ] {
        let packet = fs::read_to_string(run.join("task-packet.md")).unwrap();
        let prompt_file = run.join("packet-prompt.txt");
        assert!(
            prompt_file.is_file(),
            "the packet file must stay inside {}",
            run.display()
        );
        assert_eq!(fs::read_to_string(&prompt_file).unwrap(), packet);
        assert_eq!(
            fs::metadata(&prompt_file).unwrap().permissions().mode() & 0o777,
            0o600,
            "the packet file must not be readable by other users"
        );
        // The worker is handed the packet inside the run directory it was given
        // (an execute run stages that directory inside its serial worktree, so
        // the path is that run's staged copy, never a temp file elsewhere).
        let received = fs::read_to_string(run.join(seen_path)).unwrap();
        let received = Path::new(&received);
        assert!(
            received.is_absolute(),
            "the worker must be handed an absolute packet path, got {}",
            received.display()
        );
        assert_eq!(received.file_name().unwrap(), "packet-prompt.txt");
        assert_eq!(
            received.parent().unwrap().file_name().unwrap(),
            run.file_name().unwrap(),
            "the packet must live in this run's directory"
        );
        assert_eq!(fs::read_to_string(run.join(seen_body)).unwrap(), packet);
        assert!(
            fs::read(run.join(seen_stdin)).unwrap().is_empty(),
            "file transport must not also write the packet to stdin"
        );
    }

    // The continuation packet is a different document, so the file transport
    // must have replaced it rather than left the fresh packet behind.
    assert_ne!(
        fs::read_to_string(file_first.join("packet-prompt.txt")).unwrap(),
        fs::read_to_string(file_resume.join("packet-prompt.txt")).unwrap()
    );
    assert!(!stdin_first.join("packet-prompt.txt").exists());
    assert!(!stdin_resume.join("packet-prompt.txt").exists());
}

// (b) The packet write is best-effort by contract (`let _ = write_all`). A
// worker that closes stdin unread makes that write fail with EPIPE, and the run
// must still converge on the worker's result files.
#[test]
fn stdin_transport_tolerates_a_worker_that_closes_stdin_unread() {
    // Large enough that the packet cannot be absorbed by any pipe buffer, so
    // the orchestrator provably hits the closed read end instead of silently
    // fitting the whole packet into the kernel.
    let bulk = "packet body that cannot fit in a pipe buffer ".repeat(8_000);
    let fixture = Fixture::new("ignored-stdin", &bulk);
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe]\n      sandbox_args: ['--fixture-sandbox']\n      args: [ignored-stdin, '{run_dir}']\n",
    );

    let output = fixture.yardlet(&["run", "--task", "YARD-001", "--execute"]);
    assert!(
        output.status.success(),
        "an unread stdin must not fail the run\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let run = fixture.latest_run();
    let packet = fs::read_to_string(run.join("task-packet.md")).unwrap();
    assert!(
        packet.len() > 256 * 1024,
        "packet is only {} bytes, so a buffered write could have succeeded",
        packet.len()
    );
    assert_eq!(fixture.task_state(), "done");
    assert!(run.join("result.json").is_file());
    assert!(!run.join("seen-packet-body").exists());

    let completed = fixture
        .channel_records("/events/")
        .into_iter()
        .find(|event| event["type"].as_str() == Some("worker.completed"))
        .expect("the attempt completed");
    assert_eq!(completed["payload"]["result"].as_str(), Some("succeeded"));
    assert_eq!(completed["payload"]["exit_code"].as_i64(), Some(0));
}

// (c) Exit 0 plus an unparseable result.json is a failure, not a success. The
// typed record must say so and the raw attempt streams must survive as the
// evidence for it.
#[test]
fn unparseable_result_is_recorded_as_a_typed_failure_with_raw_streams_preserved() {
    let fixture = Fixture::new("broken-result", "result parses against the schema");
    fixture.configure(
        "      supports_noninteractive: true\n      output_contract: files\n      version_args: [probe]\n      sandbox_args: ['--fixture-sandbox']\n      args: [broken-result, '{run_dir}']\n",
    );

    let _ = fixture.yardlet(&["run", "--task", "YARD-001", "--execute"]);
    let run = fixture.latest_run();

    assert_ne!(
        fixture.task_state(),
        "done",
        "an unparseable result must never reach done"
    );
    assert!(
        serde_json::from_str::<serde_json::Value>(
            &fs::read_to_string(run.join("result.json")).unwrap()
        )
        .is_err(),
        "the fixture must have written an unparseable result"
    );

    let evaluation: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(run.join("evaluation.json")).unwrap()).unwrap();
    let schema_check = evaluation["checks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|check| check["name"] == "result_schema_valid")
        .expect("the evaluator judges the result schema");
    assert_eq!(schema_check["passed"], false);
    assert_eq!(schema_check["fatal"], true);

    let attempts = fixture.channel_records("/attempts/");
    assert_eq!(attempts.len(), 1);
    let attempt = &attempts[0];
    let attempt_id = attempt["attempt_id"].as_str().unwrap();
    let stdout_ref = attempt["raw_stdout_ref"].as_str().unwrap();
    let stderr_ref = attempt["raw_stderr_ref"].as_str().unwrap();
    assert_eq!(
        fs::canonicalize(stdout_ref).unwrap(),
        fs::canonicalize(run.join("attempts").join(attempt_id).join("stdout.log")).unwrap()
    );
    assert_eq!(
        fs::read_to_string(stdout_ref).unwrap(),
        "transport matrix broken-result stdout\n"
    );
    assert_eq!(
        fs::read_to_string(stderr_ref).unwrap(),
        "transport matrix broken-result stderr\n"
    );

    let completed = fixture
        .channel_records("/events/")
        .into_iter()
        .find(|event| {
            event["type"].as_str() == Some("worker.completed")
                && event["attempt_id"].as_str() == Some(attempt_id)
        })
        .expect("the attempt completed");
    let payload = &completed["payload"];
    assert_eq!(
        payload["result"].as_str(),
        Some("failed"),
        "a zero exit must not launder an unreadable result into success"
    );
    assert_eq!(payload["exit_code"].as_i64(), Some(0));
    assert_eq!(payload["exit_ok"].as_bool(), Some(true));
    assert_eq!(payload["raw_stdout_ref"].as_str(), Some(stdout_ref));
    assert_eq!(payload["raw_stderr_ref"].as_str(), Some(stderr_ref));
}
