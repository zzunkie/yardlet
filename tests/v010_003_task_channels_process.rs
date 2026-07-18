#[cfg(unix)]
mod unix {
    use serde_yaml_ng::Value;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output, Stdio};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    struct FixtureWorkspace {
        root: PathBuf,
        binary: PathBuf,
    }

    impl FixtureWorkspace {
        fn new(label: &str) -> Self {
            let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "yardlet-v010-003-{label}-{}-{nonce}",
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
            fs::copy(manifest.join(".gitignore"), root.join(".gitignore")).unwrap();
            fs::write(
                root.join(".agents/intent-contract.yaml"),
                "schema_version: 1\nid: intent-channel-process\nsummary: durable channel fixture\nstatus: accepted\n",
            )
            .unwrap();

            let fixture_bin = root.join(".agents/fixture-bin");
            fs::create_dir_all(&fixture_bin).unwrap();
            let worker = fixture_bin.join("worker.sh");
            fs::copy(
                manifest.join("tests/fixtures/v010_003_task_channels/worker.sh"),
                &worker,
            )
            .unwrap();
            let mut permissions = fs::metadata(&worker).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&worker, permissions).unwrap();
            fs::write(
                root.join(".agents/workers.yaml"),
                format!(
                    "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fixture-ask\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fixture-drain\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: codex\n    invocation:\n      command: {0}\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
                    worker.display(),
                ),
            )
            .unwrap();

            Self { root, binary }
        }

        fn write_queue(&self, body: &str) {
            fs::write(
                self.root.join(".agents/work-queue.yaml"),
                format!(
                    "schema_version: 1\nqueue_id: queue-channel-process\nintent_id: intent-channel-process\ntasks:\n{body}"
                ),
            )
            .unwrap();
        }

        fn run(&self, args: &[&str]) -> Output {
            must_succeed(&self.root, &self.binary, args)
        }

        fn run_with_umask_022(&self, args: &[&str]) -> Output {
            let mut shell_args = vec!["-c", "umask 022; exec \"$@\"", "fixture"];
            let binary = self.binary.to_string_lossy().into_owned();
            shell_args.push(&binary);
            shell_args.extend_from_slice(args);
            must_succeed(&self.root, Path::new("sh"), &shell_args)
        }
    }

    impl Drop for FixtureWorkspace {
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

    fn files_below(root: &Path, suffix: &str) -> Vec<PathBuf> {
        fn walk(path: &Path, suffix: &str, out: &mut Vec<PathBuf>) {
            let Ok(entries) = fs::read_dir(path) else {
                return;
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    walk(&path, suffix, out);
                } else if path.to_string_lossy().ends_with(suffix) {
                    out.push(path);
                }
            }
        }
        let mut out = Vec::new();
        walk(root, suffix, &mut out);
        out.sort();
        out
    }

    fn read_yaml(path: &Path) -> Value {
        serde_yaml_ng::from_str(&fs::read_to_string(path).unwrap())
            .unwrap_or_else(|error| panic!("invalid fixture yaml {}: {error}", path.display()))
    }

    fn string<'a>(value: &'a Value, key: &str) -> &'a str {
        let field = if key == "event_type" && value["event_type"].is_null() {
            &value["type"]
        } else {
            &value[key]
        };
        field
            .as_str()
            .unwrap_or_else(|| panic!("missing string key {key}: {value:?}"))
    }

    fn number(value: &Value, key: &str) -> u64 {
        value[key]
            .as_u64()
            .unwrap_or_else(|| panic!("missing integer key {key}: {value:?}"))
    }

    fn channel_dir(root: &Path, task_id: &str) -> PathBuf {
        maybe_channel_dir(root, task_id)
            .unwrap_or_else(|| panic!("channel for {task_id} not found"))
    }

    fn maybe_channel_dir(root: &Path, task_id: &str) -> Option<PathBuf> {
        fs::read_dir(root.join(".agents/task-channels"))
            .ok()?
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.join("channel.yaml").is_file()
                    && string(&read_yaml(&path.join("channel.yaml")), "task_id") == task_id
            })
    }

    fn yaml_dir(path: &Path) -> Vec<Value> {
        files_below(path, ".yaml")
            .iter()
            .map(|path| read_yaml(path))
            .collect()
    }

    fn attempt_paths(root: &Path, channel: &Path) -> Vec<PathBuf> {
        yaml_dir(&channel.join("attempts"))
            .into_iter()
            .flat_map(|attempt| {
                ["raw_stdout_ref", "raw_stderr_ref"].map(|key| {
                    let path = PathBuf::from(string(&attempt, key));
                    if path.is_absolute() {
                        path
                    } else {
                        root.join(".agents").join(path)
                    }
                })
            })
            .collect()
    }

    fn task_state(root: &Path, task_id: &str) -> String {
        let queue = read_yaml(&root.join(".agents/work-queue.yaml"));
        queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| string(task, "id") == task_id)
            .map(|task| string(task, "state").to_string())
            .unwrap_or_else(|| panic!("task {task_id} not found"))
    }

    fn assert_actionable_needs_user(fixture: &FixtureWorkspace, task_id: &str) {
        assert_eq!(task_state(&fixture.root, task_id), "needs_user");
        let channel = channel_dir(&fixture.root, task_id);
        let questions = yaml_dir(&channel.join("questions"));
        assert_eq!(questions.len(), 1, "{task_id} must persist one question");
        let question = string(&questions[0], "text").trim();
        assert!(
            !question.is_empty(),
            "{task_id} persisted an empty question"
        );
        assert!(
            question.ends_with('?') || question.ends_with('？'),
            "{task_id} question is not actionable: {question:?}"
        );
        assert_eq!(string(&questions[0], "state"), "open");
        let shown = fixture.run(&["answer", "--task", task_id]);
        assert!(
            String::from_utf8_lossy(&shown.stdout).contains(question),
            "{task_id} question was stored but not retrievable"
        );
    }

    fn action_attempt_id(action_id: &str) -> String {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in action_id.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("att-action-{hash:016x}")
    }

    fn wait_until(timeout: Duration, mut predicate: impl FnMut() -> bool) -> bool {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if predicate() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        false
    }

    fn process_is_alive(pid: u32) -> bool {
        Command::new("kill")
            .args(["-0", &pid.to_string()])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    fn worker_path(fixture: &FixtureWorkspace) -> PathBuf {
        fixture.root.join(".agents/fixture-bin/worker.sh")
    }

    fn write_exact_codex_workers(fixture: &FixtureWorkspace, max_retries: u32) {
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: codex\n    model: gpt-5.6-sol\n    invocation:\n      command: {}\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: {}\nrouting:\n  default_worker: codex\n  fallback_order: [codex]\n  allow_preferred_worker_failover: false\n",
                worker_path(fixture).display(),
                max_retries
            ),
        )
        .unwrap();
    }

    fn confirm_exact_codex_task(fixture: &FixtureWorkspace) {
        let planner = fixture.root.join(".agents/fixture-bin/exact-planner.sh");
        fs::write(
            &planner,
            r##"#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'exact-planner 1.0\n'
  exit 0
fi
run_dir="$1"
mkdir -p "$run_dir"
cat >"$run_dir/planning-result.json" <<'JSON'
{
  "summary": "confirmed exact dispatch fixture",
  "rationale": "exercise resolved selection stamping after confirmation",
  "allowed_scope": ["src/run.rs"],
  "out_of_scope": [],
  "acceptance": [{"statement": "confirmed exact dispatch completes"}],
  "ambiguity": {"score": "low", "open_questions": []},
  "tasks": [{
    "id": "YARD-EXACT-CONFIRMED",
    "title": "exact lineage remediation from confirmed plan",
    "kind": "implementation",
    "risk": "low",
    "preferred_worker": "codex",
    "model": "auto",
    "fallback_enabled": false,
    "effort": "auto",
    "depends_on": [],
    "skills": [],
    "required_capabilities": [],
    "allowed_scope": ["src/run.rs"],
    "acceptance": ["confirmed exact dispatch completes"],
    "worker_rationale": "deterministic exact dispatch fixture"
  }],
  "questions_for_user": []
}
JSON
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&planner).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&planner, permissions).unwrap();
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture-planner\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture-planner\n  fallback_order: [fixture-planner]\n  planning_gate:\n    primary: fixture-planner\n    fallback: \"\"\n",
                planner.display()
            ),
        )
        .unwrap();

        fixture.run(&[
            "new",
            "confirmed exact dispatch fixture",
            "--worker",
            "fixture-planner",
        ]);
        let show = fixture.run(&["planning", "show", "--json"]);
        let projection: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
        let proposal = projection["pending_proposals"][0]["proposal_id"]
            .as_str()
            .unwrap();
        fixture.run(&[
            "planning",
            "accept",
            proposal,
            "--expected-head",
            "none",
            "--action-id",
            "act-exact-dispatch-accept",
        ]);
        let show = fixture.run(&["planning", "show", "--json"]);
        let projection: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
        let head = projection["session"]["current_head"].as_str().unwrap();
        fixture.run(&[
            "planning",
            "confirm",
            "--expected-head",
            head,
            "--action-id",
            "act-exact-dispatch-confirm",
        ]);
        write_exact_codex_workers(fixture, 0);
    }

    fn confirm_policy_failover_task(fixture: &FixtureWorkspace) {
        let planner = fixture.root.join(".agents/fixture-bin/failover-planner.sh");
        fs::write(
            &planner,
            r##"#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'failover-planner 1.0\n'
  exit 0
fi
run_dir="$1"
mkdir -p "$run_dir"
cat >"$run_dir/planning-result.json" <<'JSON'
{
  "summary": "confirmed policy failover fixture",
  "rationale": "exercise receipt-bound failover selection after confirmation",
  "allowed_scope": ["src/run.rs"],
  "out_of_scope": [],
  "acceptance": [{"statement": "policy-authorized failover completes"}],
  "ambiguity": {"score": "low", "open_questions": []},
  "tasks": [{
    "id": "YARD-FAILOVER",
    "title": "policy-authorized worker failover",
    "kind": "implementation",
    "risk": "low",
    "preferred_worker": "fixture-primary",
    "model": "auto",
    "effort": "auto",
    "depends_on": [],
    "skills": [],
    "required_capabilities": [],
    "allowed_scope": ["src/run.rs"],
    "acceptance": ["policy-authorized failover completes"],
    "worker_rationale": "deterministic failover fixture"
  }],
  "questions_for_user": []
}
JSON
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&planner).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&planner, permissions).unwrap();
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture-planner\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture-planner\n  fallback_order: [fixture-planner]\n  planning_gate:\n    primary: fixture-planner\n    fallback: \"\"\n",
                planner.display()
            ),
        )
        .unwrap();

        fixture.run(&[
            "new",
            "confirmed policy failover fixture",
            "--worker",
            "fixture-planner",
        ]);
        let show = fixture.run(&["planning", "show", "--json"]);
        let projection: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
        let proposal = projection["pending_proposals"][0]["proposal_id"]
            .as_str()
            .unwrap();
        fixture.run(&[
            "planning",
            "accept",
            proposal,
            "--expected-head",
            "none",
            "--action-id",
            "act-failover-accept",
        ]);
        let show = fixture.run(&["planning", "show", "--json"]);
        let projection: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
        let head = projection["session"]["current_head"].as_str().unwrap();
        fixture.run(&[
            "planning",
            "confirm",
            "--expected-head",
            head,
            "--action-id",
            "act-failover-confirm",
        ]);
    }

    fn write_policy_failover_workers(fixture: &FixtureWorkspace) {
        let primary = fixture.root.join(".agents/fixture-bin/no-result-worker.sh");
        fs::write(
            &primary,
            r##"#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'no-result-worker 1.0\n'
  exit 0
fi
cat >/dev/null
printf 'primary intentionally omitted result.json\n' >&2
"##,
        )
        .unwrap();
        let fallback = fixture.root.join(".agents/fixture-bin/done-worker.sh");
        fs::write(
            &fallback,
            r##"#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'done-worker 1.0\n'
  exit 0
fi
run_dir="${1:?run directory is required}"
cat >/dev/null
run_id="${run_dir##*/}"
task_id="$(sed -n 's/^task_id: //p' "$run_dir/run.yaml" | head -n 1)"
cat >"$run_dir/result.json" <<JSON
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "compact_summary": "policy-authorized failover completed"
}
JSON
printf '# Handoff\n\nPolicy-authorized failover completed.\n' >"$run_dir/handoff.md"
"##,
        )
        .unwrap();
        for worker in [&primary, &fallback] {
            let mut permissions = fs::metadata(worker).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(worker, permissions).unwrap();
        }
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture-primary\n    model: primary-model\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fixture-fallback\n    model: fallback-model\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture-primary\n  fallback_order: [fixture-fallback]\n  allow_preferred_worker_failover: true\n",
                primary.display(),
                fallback.display()
            ),
        )
        .unwrap();
    }

    fn run_dirs_for_task(root: &Path, task_id: &str) -> Vec<PathBuf> {
        files_below(&root.join(".agents/runs"), "/run.yaml")
            .into_iter()
            .filter_map(|path| {
                (string(&read_yaml(&path), "task_id") == task_id)
                    .then(|| path.parent().unwrap().to_path_buf())
            })
            .collect()
    }

    fn run_dir_for_task(root: &Path, task_id: &str) -> PathBuf {
        run_dirs_for_task(root, task_id)
            .into_iter()
            .max()
            .unwrap_or_else(|| panic!("run for {task_id} not found"))
    }

    fn assert_exact_receipt_pair(run_dir: &Path, governing_task_id: &str) {
        let run = read_yaml(&run_dir.join("run.yaml"));
        let process = read_yaml(&run_dir.join("worker-process.yaml"));
        assert_eq!(string(&run, "worker"), "codex");
        assert_eq!(string(&process, "worker_id"), "codex");
        for receipt in [&run, &process] {
            assert_eq!(string(receipt, "model"), "gpt-5.6-sol");
            assert_eq!(receipt["fallback_enabled"].as_bool(), Some(false));
            assert_eq!(
                string(&receipt["routing_provenance"], "governing_task_id"),
                governing_task_id
            );
        }
        assert_eq!(string(&process, "state"), "exited");
    }

    fn assert_exact_queue_task(root: &Path, task_id: &str, governing_task_id: &str) {
        let queue = read_yaml(&root.join(".agents/work-queue.yaml"));
        let task = queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| string(task, "id") == task_id)
            .unwrap_or_else(|| panic!("queue task {task_id} not found"));
        assert_eq!(string(task, "preferred_worker"), "codex");
        assert_eq!(string(task, "model"), "gpt-5.6-sol");
        assert_eq!(task["fallback_enabled"].as_bool(), Some(false));
        assert_eq!(
            string(&task["routing_provenance"], "governing_task_id"),
            governing_task_id
        );
    }

    fn assert_policy_failover_selection(root: &Path) {
        let queue = read_yaml(&root.join(".agents/work-queue.yaml"));
        let task = queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| string(task, "id") == "YARD-FAILOVER")
            .expect("failover task missing from queue");
        assert_eq!(string(task, "preferred_worker"), "fixture-fallback");
        assert_eq!(string(task, "model"), "fallback-model");
        assert_eq!(task["fallback_enabled"].as_bool(), Some(true));
        assert_eq!(
            string(&task["routing_provenance"], "worker_source"),
            "failover"
        );
        assert_eq!(
            string(&task["routing_provenance"], "fallback_source"),
            "workspace.routing.allow_preferred_worker_failover"
        );

        let run_dir = run_dir_for_task(root, "YARD-FAILOVER");
        let run = read_yaml(&run_dir.join("run.yaml"));
        let process = read_yaml(&run_dir.join("worker-process.yaml"));
        assert_eq!(string(&process, "state"), "exited");
        for receipt in [&run, &process] {
            let worker_key = if std::ptr::eq(receipt, &run) {
                "worker"
            } else {
                "worker_id"
            };
            assert_eq!(string(receipt, worker_key), "fixture-fallback");
            assert_eq!(string(receipt, "model"), "fallback-model");
            assert_eq!(receipt["fallback_enabled"].as_bool(), Some(true));
            assert_eq!(
                string(&receipt["routing_provenance"], "worker_source"),
                "failover"
            );
        }
    }

    fn mutate_queue_selection(root: &Path, task_id: &str, field: &str) {
        let path = root.join(".agents/work-queue.yaml");
        let mut queue = read_yaml(&path);
        let task = queue["tasks"]
            .as_sequence_mut()
            .unwrap()
            .iter_mut()
            .find(|task| string(task, "id") == task_id)
            .unwrap_or_else(|| panic!("queue task {task_id} not found"));
        match field {
            "worker" => task["preferred_worker"] = Value::String("claude-code".into()),
            "model" => task["model"] = Value::String("fable".into()),
            "fallback" => {
                task["fallback_enabled"] =
                    Value::Bool(!task["fallback_enabled"].as_bool().unwrap_or(false))
            }
            "provenance" => {
                task["routing_provenance"]["model_source"] = Value::String("manual".into())
            }
            _ => panic!("unknown selection field {field}"),
        }
        fs::write(path, serde_yaml_ng::to_string(&queue).unwrap()).unwrap();
    }

    #[test]
    fn confirmed_exact_dispatch_stamps_receipted_selection_and_completes() {
        let fixture = FixtureWorkspace::new("confirmed-exact-dispatch");
        confirm_exact_codex_task(&fixture);

        fixture.run(&["run", "--task", "YARD-EXACT-CONFIRMED", "--execute"]);

        assert_eq!(task_state(&fixture.root, "YARD-EXACT-CONFIRMED"), "done");
        assert_exact_queue_task(
            &fixture.root,
            "YARD-EXACT-CONFIRMED",
            "YARD-EXACT-CONFIRMED",
        );
        let run_dir = run_dir_for_task(&fixture.root, "YARD-EXACT-CONFIRMED");
        assert_exact_receipt_pair(&run_dir, "YARD-EXACT-CONFIRMED");
        let show = fixture.run(&["planning", "show", "--json"]);
        let projection: serde_json::Value = serde_json::from_slice(&show.stdout).unwrap();
        assert_eq!(projection["exact_active_parity"].as_bool(), Some(true));
    }

    #[test]
    fn policy_authorized_failover_serial_dispatch_is_receipted_and_mutations_fail_closed() {
        let fixture = FixtureWorkspace::new("confirmed-policy-failover");
        confirm_policy_failover_task(&fixture);
        write_policy_failover_workers(&fixture);

        let output = command(
            &fixture.root,
            &fixture.binary,
            &["run", "--task", "YARD-FAILOVER", "--execute"],
        );
        if !output.status.success() {
            let run_dir = run_dir_for_task(&fixture.root, "YARD-FAILOVER");
            panic!(
                "failover dispatch failed\nstderr:\n{}\nqueue:\n{}\nrun:\n{}\nprocess:\n{}",
                String::from_utf8_lossy(&output.stderr),
                fs::read_to_string(fixture.root.join(".agents/work-queue.yaml")).unwrap(),
                fs::read_to_string(run_dir.join("run.yaml")).unwrap(),
                fs::read_to_string(run_dir.join("worker-process.yaml")).unwrap(),
            );
        }

        assert_eq!(task_state(&fixture.root, "YARD-FAILOVER"), "done");
        assert_policy_failover_selection(&fixture.root);
        let queue_path = fixture.root.join(".agents/work-queue.yaml");
        let valid_queue = fs::read_to_string(&queue_path).unwrap();
        for field in ["worker", "model", "fallback", "provenance"] {
            fs::write(&queue_path, &valid_queue).unwrap();
            mutate_queue_selection(&fixture.root, "YARD-FAILOVER", field);
            let tampered = fs::read_to_string(&queue_path).unwrap();
            let output = command(&fixture.root, &fixture.binary, &["queue"]);
            assert!(
                !output.status.success(),
                "manual failover {field} mutation unexpectedly passed"
            );
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains("active_runtime_envelope_mismatch")
                    || stderr.contains("active_runtime_origin_mismatch"),
                "manual failover {field} mutation returned the wrong failure: {stderr}"
            );
            assert_eq!(
                fs::read_to_string(&queue_path).unwrap(),
                tampered,
                "manual failover {field} rejection changed canonical queue bytes"
            );
        }
        fs::write(queue_path, valid_queue).unwrap();
    }

    #[test]
    fn policy_authorized_failover_recover_finalizes_receipted_orphan() {
        let fixture = FixtureWorkspace::new("confirmed-policy-failover-recover");
        confirm_policy_failover_task(&fixture);
        write_policy_failover_workers(&fixture);
        let config_path = fixture.root.join(".agents/yardlet.yaml");
        let mut config = read_yaml(&config_path);
        config["auto_commit"] = Value::Bool(true);
        fs::write(config_path, serde_yaml_ng::to_string(&config).unwrap()).unwrap();
        let hooks = fixture.root.join(".agents/hooks/post-run.d");
        fs::create_dir_all(&hooks).unwrap();
        let hook = hooks.join("00-pause-before-finalize.sh");
        fs::write(
            &hook,
            r##"#!/usr/bin/env bash
set -euo pipefail
touch .agents/failover-hook-entered
for _ in $(seq 1 400); do
  if [[ -f .agents/failover-hook-release ]]; then
    touch .agents/failover-hook-exited
    exit 0
  fi
  sleep 0.05
done
exit 1
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&hook).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&hook, permissions).unwrap();

        let mut running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-FAILOVER", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        assert!(
            wait_until(Duration::from_secs(10), || {
                if !fixture.root.join(".agents/failover-hook-entered").is_file() {
                    return false;
                }
                let Some(run_dir) = run_dirs_for_task(&fixture.root, "YARD-FAILOVER")
                    .into_iter()
                    .max()
                else {
                    return false;
                };
                run_dir.join("result.json").is_file()
                    && run_dir.join("worker-process.yaml").is_file()
                    && string(&read_yaml(&run_dir.join("worker-process.yaml")), "state") == "exited"
                    && task_state(&fixture.root, "YARD-FAILOVER") == "running"
            }),
            "failover worker did not reach the receipted pre-finalize crash window"
        );
        running.kill().unwrap();
        running.wait().unwrap();
        fs::write(
            fixture.root.join(".agents/failover-hook-release"),
            "release\n",
        )
        .unwrap();
        assert!(wait_until(Duration::from_secs(3), || fixture
            .root
            .join(".agents/failover-hook-exited")
            .is_file()));

        let recovered = fixture.run(&["recover"]);

        assert!(
            !String::from_utf8_lossy(&recovered.stdout).contains("recovery finalize error"),
            "recover rejected the receipted failover selection: {}",
            String::from_utf8_lossy(&recovered.stdout)
        );
        let recovered_state = task_state(&fixture.root, "YARD-FAILOVER");
        if recovered_state != "done" {
            let run_dir = run_dir_for_task(&fixture.root, "YARD-FAILOVER");
            panic!(
                "recover left failover task {recovered_state}\nstdout:\n{}\npartial-reason:\n{}\nrun:\n{}",
                String::from_utf8_lossy(&recovered.stdout),
                fs::read_to_string(run_dir.join("partial-reason")).unwrap_or_default(),
                fs::read_to_string(run_dir.join("run.yaml")).unwrap(),
            );
        }
        assert_policy_failover_selection(&fixture.root);
    }

    #[test]
    fn confirmed_runtime_addition_stamps_the_same_receipted_exact_selection() {
        let fixture = FixtureWorkspace::new("confirmed-runtime-exact-dispatch");
        confirm_exact_codex_task(&fixture);
        fixture.run(&[
            "add",
            "exact lineage remediation runtime addition",
            "--worker",
            "codex",
            "--scope",
            "src/run.rs",
        ]);
        let queue = read_yaml(&fixture.root.join(".agents/work-queue.yaml"));
        let task_id = queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| string(task, "title") == "exact lineage remediation runtime addition")
            .map(|task| string(task, "id").to_string())
            .expect("runtime-added task must be materialized");

        fixture.run(&["run", "--task", &task_id, "--execute"]);

        assert_eq!(task_state(&fixture.root, &task_id), "done");
        assert_exact_queue_task(&fixture.root, &task_id, &task_id);
        let run_dir = run_dir_for_task(&fixture.root, &task_id);
        assert_exact_receipt_pair(&run_dir, &task_id);
    }

    #[test]
    fn manual_selection_mutations_remain_fail_closed_after_receipted_dispatch() {
        let fixture = FixtureWorkspace::new("confirmed-exact-dispatch-mutation");
        confirm_exact_codex_task(&fixture);
        fixture.run(&["run", "--task", "YARD-EXACT-CONFIRMED", "--execute"]);
        let queue_path = fixture.root.join(".agents/work-queue.yaml");
        let valid_queue = fs::read_to_string(&queue_path).unwrap();

        for field in ["worker", "model", "fallback", "provenance"] {
            fs::write(&queue_path, &valid_queue).unwrap();
            mutate_queue_selection(&fixture.root, "YARD-EXACT-CONFIRMED", field);
            let tampered = fs::read_to_string(&queue_path).unwrap();
            let output = command(&fixture.root, &fixture.binary, &["queue"]);
            assert!(
                !output.status.success(),
                "manual {field} mutation unexpectedly passed"
            );
            let stderr = String::from_utf8_lossy(&output.stderr);
            assert!(
                stderr.contains("active_runtime_envelope_mismatch")
                    || stderr.contains("active_runtime_origin_mismatch"),
                "manual {field} mutation returned the wrong failure: {stderr}"
            );
            assert_eq!(
                fs::read_to_string(&queue_path).unwrap(),
                tampered,
                "manual {field} rejection changed canonical queue bytes"
            );
        }
        fs::write(queue_path, valid_queue).unwrap();
    }

    #[test]
    fn worker_proposed_follow_ups_inherit_exact_model_and_expose_pre_dispatch_receipts() {
        let fixture = FixtureWorkspace::new("exact-model-follow-ups");
        write_exact_codex_workers(&fixture, 0);
        fixture.write_queue(
            "  - id: YARD-001\n    title: propose exact lineage follow-ups\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n    model: gpt-5.6-sol\n    fallback_enabled: false\n",
        );

        fixture.run(&["run", "--task", "YARD-001", "--execute"]);

        let queue = read_yaml(&fixture.root.join(".agents/work-queue.yaml"));
        let tasks = queue["tasks"].as_sequence().unwrap();
        assert_eq!(tasks.len(), 3, "fixture must materialize both follow-ups");
        for task in tasks.iter().filter(|task| string(task, "id") != "YARD-001") {
            assert_eq!(string(task, "preferred_worker"), "codex");
            assert_eq!(string(task, "model"), "gpt-5.6-sol");
            assert_eq!(task["fallback_enabled"].as_bool(), Some(false));
            assert_eq!(
                string(&task["routing_provenance"], "governing_task_id"),
                "YARD-001"
            );
        }

        fixture.run(&["run", "--task", "YARD-002", "--execute"]);
        fixture.run(&["run", "--task", "YARD-003", "--execute"]);
        assert_eq!(task_state(&fixture.root, "YARD-003"), "queued");
        let after_review = read_yaml(&fixture.root.join(".agents/work-queue.yaml"));
        let remediation = after_review["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| string(task, "id") == "YARD-004")
            .expect("failed review must materialize remediation");
        assert_eq!(string(remediation, "model"), "gpt-5.6-sol");
        assert_eq!(remediation["fallback_enabled"].as_bool(), Some(false));

        fixture.run(&["run", "--task", "YARD-004", "--execute"]);
        fixture.run(&["run", "--task", "YARD-003", "--execute"]);
        assert_eq!(task_state(&fixture.root, "YARD-003"), "done");

        for (task_id, expected_runs) in [
            ("YARD-001", 1),
            ("YARD-002", 1),
            ("YARD-003", 2),
            ("YARD-004", 1),
        ] {
            assert_exact_queue_task(&fixture.root, task_id, "YARD-001");
            let run_dirs = run_dirs_for_task(&fixture.root, task_id);
            assert_eq!(run_dirs.len(), expected_runs, "{task_id} run count");
            for run_dir in run_dirs {
                assert_exact_receipt_pair(&run_dir, "YARD-001");
            }
        }
        let final_review = run_dir_for_task(&fixture.root, "YARD-003");
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(
                &fs::read_to_string(final_review.join("result.json")).unwrap()
            )
            .unwrap()["compact_summary"],
            "pre-dispatch receipt parity observed"
        );
    }

    #[test]
    fn text_worker_answer_creates_a_new_attempt_and_preserves_both_raw_streams() {
        let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "yardlet-v010-003-process-{}-{nonce}",
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
            manifest.join("tests/fixtures/v010_003_task_channels/worker.sh"),
            &worker,
        )
        .unwrap();
        let mut permissions = fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&worker, permissions).unwrap();
        fs::write(
            root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
                worker.display()
            ),
        )
        .unwrap();
        fs::write(
            root.join(".agents/intent-contract.yaml"),
            "schema_version: 1\nid: intent-channel-process\nsummary: durable channel fixture\nstatus: accepted\n",
        )
        .unwrap();
        fs::write(
            root.join(".agents/work-queue.yaml"),
            "schema_version: 1\nqueue_id: queue-channel-process\nintent_id: intent-channel-process\ntasks:\n  - id: YARD-001\n    title: text worker asks then completes\n    state: queued\n    priority: 10\n    preferred_worker: fixture\n",
        )
        .unwrap();

        must_succeed(&root, &binary, &["run", "--task", "YARD-001", "--execute"]);
        let first_stdout = files_below(&root.join(".agents/runs"), "/stdout.log");
        let first_stderr = files_below(&root.join(".agents/runs"), "/stderr.log");
        assert_eq!(first_stdout.len(), 1);
        assert_eq!(first_stderr.len(), 1);
        assert_eq!(
            fs::read_to_string(&first_stdout[0]).unwrap(),
            "fixture first stdout\n"
        );
        assert_eq!(
            fs::read_to_string(&first_stderr[0]).unwrap(),
            "fixture first stderr\n"
        );

        must_succeed(
            &root,
            &binary,
            &[
                "answer",
                "A",
                "--task",
                "YARD-001",
                "--action-id",
                "act-fixture-answer",
            ],
        );

        let channels = root.join(".agents/task-channels");
        assert_eq!(files_below(&channels, ".terminal.yaml").len(), 1);
        let attempts = files_below(&channels, ".yaml")
            .into_iter()
            .filter(|path| path.to_string_lossy().contains("/attempts/"))
            .collect::<Vec<_>>();
        assert_eq!(attempts.len(), 2);
        let answers = files_below(&channels, ".yaml")
            .into_iter()
            .filter(|path| path.to_string_lossy().contains("/answers/"))
            .collect::<Vec<_>>();
        assert_eq!(answers.len(), 1);
        let channel = channel_dir(&root, "YARD-001");
        let channel_attempts = yaml_dir(&channel.join("attempts"));
        let first_attempt = channel_attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "fresh")
            .unwrap();
        let continued_attempt = channel_attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "explicit_packet")
            .unwrap();
        assert_eq!(string(first_attempt, "worker_id"), "fixture");
        assert_eq!(string(continued_attempt, "worker_id"), "fixture");
        assert!(first_attempt["worker_session_ref"].is_null());
        assert!(continued_attempt["worker_session_ref"].is_null());

        let questions = yaml_dir(&channel.join("questions"));
        assert_eq!(questions.len(), 1);
        let events = yaml_dir(&channel.join("events"));
        let asked = events
            .iter()
            .find(|event| string(event, "event_type") == "question.asked")
            .unwrap();
        assert_eq!(
            string(&questions[0], "asked_event_id"),
            string(asked, "event_id")
        );
        assert_eq!(number(&questions[0], "asked_seq"), number(asked, "seq"));
        assert_eq!(
            string(continued_attempt, "caused_by_event_id"),
            string(
                events
                    .iter()
                    .find(|event| string(event, "event_type") == "user.answered")
                    .unwrap(),
                "event_id",
            )
        );
        assert_eq!(
            string(continued_attempt, "caused_by_action_id"),
            "act-fixture-answer"
        );
        assert_eq!(
            fs::read_to_string(&first_stdout[0]).unwrap(),
            "fixture first stdout\n"
        );
        assert_eq!(
            fs::read_to_string(&first_stderr[0]).unwrap(),
            "fixture first stderr\n"
        );
        let packets = files_below(&root.join(".agents/runs"), "/task-packet.md");
        assert!(packets.iter().any(|path| {
            fs::read_to_string(path).is_ok_and(|text| text.contains("Explicit continuation packet"))
        }));
        must_succeed(&root, &binary, &["queue"]);

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn parallel_failover_rejects_tampered_worktree_receipt_before_spawn() {
        let fixture = FixtureWorkspace::new("parallel-cwd-attestation");
        // Every fixture worker needs a model: a model-less failover selection
        // stamps an incomplete governing provenance on the task, which fails
        // lineage validation on the drain's sequential retry.
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: fixture\n    model: fixture-model\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fixture-ask\n    model: fixture-model\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fixture-drain\n    model: fixture-model\n    invocation:\n      command: {0}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
                worker_path(&fixture).display(),
            ),
        )
        .unwrap();
        fixture.write_queue(
            "  - id: YARD-CWD-TAMPER\n    title: tampered parallel receipt fails closed\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n    fallback_enabled: true\n  - id: YARD-DRAIN\n    title: healthy sibling drains\n    state: queued\n    priority: 20\n    kind: implementation\n    preferred_worker: fixture-drain\n",
        );

        // No exit-status assertion: after the batch the drain retries the
        // tampered task sequentially and dies on an adjacent, pre-existing
        // lineage dead-end (the failover selection stamped on the task
        // conflicts with its governing worker). The attestation under test
        // has completed by then.
        let output = command(
            &fixture.root,
            &fixture.binary,
            &["run", "--auto", "--parallel", "2"],
        );
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains(
                "parallel batch: YARD-CWD-TAMPER via fixture, YARD-DRAIN via fixture-drain"
            ),
            "expected a two-task parallel batch:\n{stdout}"
        );
        assert!(
            stdout.contains("worker cwd attestation failed")
                && stdout.contains("run.yaml worktree")
                && stdout.contains("refusing to spawn"),
            "tampered parallel receipt did not fail closed with an actionable diagnostic:\n{stdout}"
        );
        assert!(
            !fixture
                .root
                .join(".agents/parallel-cwd-failover-ran")
                .exists(),
            "a failover worker spawned despite the tampered parallel receipt"
        );
        let tampered_state = task_state(&fixture.root, "YARD-CWD-TAMPER");
        assert!(
            tampered_state != "done" && tampered_state != "running",
            "tampered task must fail closed, got {tampered_state}"
        );
        assert_eq!(task_state(&fixture.root, "YARD-DRAIN"), "done");
    }

    #[test]
    fn parallel_independent_task_records_validation_completion() {
        let fixture = FixtureWorkspace::new("parallel-validation");
        fixture.write_queue(
            "  - id: YARD-ASK\n    title: ask in parallel\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture-ask\n  - id: YARD-DRAIN\n    title: independent validated drain\n    state: queued\n    priority: 20\n    kind: implementation\n    preferred_worker: fixture-drain\n    validation:\n      required: true\n      commands: [\"test -f drain-artifact.txt\"]\n",
        );

        let output = fixture.run(&["run", "--auto", "--parallel", "2"]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout
                .contains("parallel batch: YARD-ASK via fixture-ask, YARD-DRAIN via fixture-drain"),
            "configured validation removed YARD-DRAIN from the parallel batch:\n{stdout}"
        );
        assert_eq!(task_state(&fixture.root, "YARD-ASK"), "needs_user");
        assert_eq!(task_state(&fixture.root, "YARD-DRAIN"), "done");

        let ask_channel = channel_dir(&fixture.root, "YARD-ASK");
        let drain_channel = channel_dir(&fixture.root, "YARD-DRAIN");
        let ask_attempts = yaml_dir(&ask_channel.join("attempts"));
        let drain_attempts = yaml_dir(&drain_channel.join("attempts"));
        assert_eq!(ask_attempts.len(), 1);
        assert_eq!(drain_attempts.len(), 1);
        assert_eq!(string(&ask_attempts[0], "worker_id"), "fixture-ask");
        assert_eq!(string(&drain_attempts[0], "worker_id"), "fixture-drain");

        let drain_events = yaml_dir(&drain_channel.join("events"));
        for event_type in [
            "worker.started",
            "validation.started",
            "validation.completed",
            "completion.recorded",
        ] {
            assert!(
                drain_events
                    .iter()
                    .any(|event| string(event, "event_type") == event_type),
                "independent validated task has no {event_type} event"
            );
        }

        let questions = yaml_dir(&ask_channel.join("questions"));
        assert_eq!(questions.len(), 1);
        let ask_events = yaml_dir(&ask_channel.join("events"));
        let asked = ask_events
            .iter()
            .find(|event| string(event, "event_type") == "question.asked")
            .unwrap();
        assert_eq!(
            string(&questions[0], "asked_event_id"),
            string(asked, "event_id")
        );
        assert_eq!(number(&questions[0], "asked_seq"), number(asked, "seq"));
        assert!(number(&questions[0], "context_start_seq") <= number(asked, "seq"));
        assert!(ask_events.iter().any(|event| {
            number(event, "seq") >= number(&questions[0], "context_start_seq")
                && number(event, "seq") < number(asked, "seq")
                && event["payload"]["text"] == "ask worker public context before question"
        }));

        for path in attempt_paths(&fixture.root, &ask_channel) {
            let raw = fs::read_to_string(path).unwrap();
            assert!(raw.contains("ask worker"));
            assert!(!raw.contains("drain worker"));
        }
        for path in attempt_paths(&fixture.root, &drain_channel) {
            let raw = fs::read_to_string(path).unwrap();
            assert!(raw.contains("drain worker"));
            assert!(!raw.contains("ask worker"));
        }

        fixture.run(&["queue"]);
        let restarted = channel_dir(&fixture.root, "YARD-ASK");
        let restored_question = yaml_dir(&restarted.join("questions"));
        assert_eq!(restored_question, questions);
    }

    #[test]
    fn native_resume_preserves_session_ref_and_answer_causality() {
        let fixture = FixtureWorkspace::new("native-resume");
        write_exact_codex_workers(&fixture, 0);
        fixture.write_queue(
            "  - id: YARD-NATIVE\n    title: native worker asks then resumes\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n    model: gpt-5.6-sol\n    fallback_enabled: false\n",
        );

        fixture.run(&["run", "--task", "YARD-NATIVE", "--execute"]);
        assert_eq!(task_state(&fixture.root, "YARD-NATIVE"), "needs_user");
        fixture.run(&[
            "answer",
            "native answer",
            "--task",
            "YARD-NATIVE",
            "--action-id",
            "act-native-answer",
        ]);

        let channel = channel_dir(&fixture.root, "YARD-NATIVE");
        let attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(attempts.len(), 2);
        let first = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "fresh")
            .unwrap();
        let resumed = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "native_resume")
            .unwrap();
        let session_ref = "11111111-1111-4111-8111-111111111111";
        assert_eq!(string(first, "worker_id"), "codex");
        assert!(first["worker_session_ref"].is_null());
        assert_eq!(string(resumed, "worker_id"), "codex");
        assert_eq!(string(resumed, "worker_session_ref"), session_ref);
        assert_eq!(string(resumed, "caused_by_action_id"), "act-native-answer");

        let events = yaml_dir(&channel.join("events"));
        let answered = events
            .iter()
            .find(|event| string(event, "event_type") == "user.answered")
            .unwrap();
        let first_completed = events
            .iter()
            .find(|event| {
                string(event, "event_type") == "worker.completed"
                    && event["attempt_id"] == first["attempt_id"]
            })
            .unwrap();
        assert_eq!(
            string(&first_completed["payload"], "worker_session_ref"),
            session_ref
        );
        assert_eq!(
            string(resumed, "caused_by_event_id"),
            string(answered, "event_id")
        );
        let invocation = files_below(&fixture.root.join(".agents/runs"), "/native-args.txt");
        assert!(invocation.iter().any(|path| {
            fs::read_to_string(path).is_ok_and(|args| {
                args.contains("exec resume")
                    && args.contains(session_ref)
                    && args.trim().ends_with('-')
            })
        }));

        let raw = attempt_paths(&fixture.root, &channel)
            .into_iter()
            .map(|path| fs::read_to_string(path).unwrap())
            .collect::<Vec<_>>();
        assert!(raw.iter().any(|text| text.contains("native first stdout")));
        assert!(raw
            .iter()
            .any(|text| text.contains("native resumed stdout")));
        assert_eq!(task_state(&fixture.root, "YARD-NATIVE"), "done");
        assert_exact_queue_task(&fixture.root, "YARD-NATIVE", "YARD-NATIVE");
        let runs = run_dirs_for_task(&fixture.root, "YARD-NATIVE");
        assert_eq!(runs.len(), 2);
        for run_dir in runs {
            assert_exact_receipt_pair(&run_dir, "YARD-NATIVE");
        }
    }

    #[test]
    fn transient_retry_preserves_exact_model_in_both_receipts() {
        let fixture = FixtureWorkspace::new("exact-transient-retry");
        write_exact_codex_workers(&fixture, 1);
        fixture.write_queue(
            "  - id: YARD-TRANSIENT\n    title: transient retry exact lineage\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n    model: gpt-5.6-sol\n    fallback_enabled: false\n",
        );

        fixture.run(&["run", "--task", "YARD-TRANSIENT", "--execute"]);

        let run_dir = run_dir_for_task(&fixture.root, "YARD-TRANSIENT");
        let logs = files_below(&run_dir, ".log")
            .into_iter()
            .map(|path| {
                format!(
                    "{}:\n{}",
                    path.display(),
                    fs::read_to_string(&path).unwrap_or_default()
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(
            task_state(&fixture.root, "YARD-TRANSIENT"),
            "done",
            "evaluation:\n{}\nresult:\n{}\nrun:\n{}\nlogs:\n{}",
            fs::read_to_string(run_dir.join("evaluation.json")).unwrap_or_default(),
            fs::read_to_string(run_dir.join("result.json")).unwrap_or_default(),
            fs::read_to_string(run_dir.join("run.yaml")).unwrap_or_default(),
            logs
        );
        assert_exact_queue_task(&fixture.root, "YARD-TRANSIENT", "YARD-TRANSIENT");
        let channel = channel_dir(&fixture.root, "YARD-TRANSIENT");
        let attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(attempts.len(), 2);
        assert!(attempts
            .iter()
            .any(|attempt| string(attempt, "continuation") == "native_resume"));
        assert_exact_receipt_pair(&run_dir, "YARD-TRANSIENT");
        assert_eq!(
            string(
                &read_yaml(&run_dir.join("worker-process.yaml")),
                "attempt_id"
            ),
            string(
                attempts
                    .iter()
                    .find(|attempt| string(attempt, "continuation") == "native_resume")
                    .unwrap(),
                "attempt_id"
            )
        );
    }

    #[test]
    fn codex_resume_file_change_backpressure_completes_with_bounded_public_log() {
        let fixture = FixtureWorkspace::new("codex-resume-file-change-backpressure");
        fixture.write_queue(
            "  - id: YARD-CODEX-BACKPRESSURE\n    title: Codex resume file change backpressure\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n",
        );

        fixture.run(&["run", "--task", "YARD-CODEX-BACKPRESSURE", "--execute"]);
        assert_eq!(
            task_state(&fixture.root, "YARD-CODEX-BACKPRESSURE"),
            "needs_user"
        );

        let mut resumed = Command::new(&fixture.binary)
            .args([
                "answer",
                "resume",
                "--task",
                "YARD-CODEX-BACKPRESSURE",
                "--action-id",
                "act-codex-backpressure",
            ])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        assert!(
            wait_until(Duration::from_secs(10), || {
                files_below(&fixture.root.join(".agents/runs"), "/result.json")
                    .iter()
                    .any(|path| {
                        fs::read_to_string(path)
                            .is_ok_and(|raw| raw.contains("Codex resume backpressure fixture 완료"))
                    })
            }),
            "resume fixture never published its successful result"
        );
        let result_seen = Instant::now();
        let exited = wait_until(Duration::from_secs(10), || {
            resumed.try_wait().unwrap().is_some()
        });
        if !exited {
            let _ = resumed.kill();
        }
        let output = resumed.wait_with_output().unwrap();
        assert!(exited, "Yardlet parent exceeded the 10 second hard timeout");
        assert!(
            result_seen.elapsed() < Duration::from_secs(5),
            "Yardlet parent did not complete within 5 seconds of result.json"
        );
        assert!(
            output.status.success(),
            "backpressure fixture failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );

        let channel = channel_dir(&fixture.root, "YARD-CODEX-BACKPRESSURE");
        let attempts = yaml_dir(&channel.join("attempts"));
        let resumed_attempt = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "native_resume")
            .unwrap();
        let stdout_path = {
            let path = PathBuf::from(string(resumed_attempt, "raw_stdout_ref"));
            if path.is_absolute() {
                path
            } else {
                fixture.root.join(".agents").join(path)
            }
        };
        let raw = fs::read(&stdout_path).unwrap();
        let raw_lines = String::from_utf8_lossy(&raw)
            .lines()
            .map(str::to_string)
            .collect::<Vec<_>>();
        let file_change_values = raw_lines
            .iter()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(|value| value["item"]["type"] == "file_change")
            .collect::<Vec<_>>();
        assert_eq!(file_change_values.len(), 320);
        let final_change_bytes =
            serde_json::to_vec(&file_change_values.last().unwrap()["item"]["changes"])
                .unwrap()
                .len();
        let public_overhead_bound = file_change_values.len() * 128;
        let non_file_bytes = raw_lines
            .iter()
            .filter(|line| {
                serde_json::from_str::<serde_json::Value>(line)
                    .map(|value| value["item"]["type"] != "file_change")
                    .unwrap_or(true)
            })
            .map(|line| line.len() + 1)
            .sum::<usize>();
        let worker_output = files_below(&fixture.root.join(".agents/runs"), "/worker-output.log");
        assert_eq!(worker_output.len(), 2);
        let public_len = worker_output
            .iter()
            .map(|path| fs::metadata(path).unwrap().len() as usize)
            .sum::<usize>();
        let public_bound = final_change_bytes + public_overhead_bound + non_file_bytes + 1024;
        assert!(
            public_len <= public_bound,
            "cumulative file_change amplification: public={public_len} bound={public_bound}"
        );

        let events = yaml_dir(&channel.join("events"));
        let resumed_file_events = events
            .iter()
            .filter(|event| {
                matches!(
                    string(event, "event_type"),
                    "tool.started" | "tool.completed"
                ) && event["payload"]["name"] == "file_change"
                    && event["attempt_id"] == resumed_attempt["attempt_id"]
            })
            .collect::<Vec<_>>();
        assert!(
            !resumed_file_events.is_empty() && resumed_file_events.len() < file_change_values.len(),
            "fixture did not exercise bounded public-event queue backpressure"
        );
        let completed = events
            .iter()
            .find(|event| {
                string(event, "event_type") == "worker.completed"
                    && event["attempt_id"] == resumed_attempt["attempt_id"]
            })
            .expect("resumed worker.completed");
        assert_eq!(completed["payload"]["result"], "succeeded");
        assert_eq!(task_state(&fixture.root, "YARD-CODEX-BACKPRESSURE"), "done");
        for event in resumed_file_events {
            let start = number(&event["raw_ref"], "byte_start") as usize;
            let end = number(&event["raw_ref"], "byte_end") as usize;
            assert!(start < end && end <= raw.len());
            assert!(String::from_utf8_lossy(&raw[start..end]).contains("file_change"));
        }
    }

    #[test]
    fn codex_unsaturated_publisher_preserves_canonical_event_tail() {
        let fixture = FixtureWorkspace::new("codex-unsaturated-publisher-tail");
        fixture.write_queue(
            "  - id: YARD-CODEX-TAIL\n    title: Codex unsaturated publisher tail\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n",
        );

        fixture.run(&["run", "--task", "YARD-CODEX-TAIL", "--execute"]);

        let channel = channel_dir(&fixture.root, "YARD-CODEX-TAIL");
        let attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(attempts.len(), 1);
        let attempt_id = string(&attempts[0], "attempt_id");
        let events = yaml_dir(&channel.join("events"));
        let messages = events
            .iter()
            .filter(|event| {
                string(event, "event_type") == "worker.message" && event["attempt_id"] == attempt_id
            })
            .collect::<Vec<_>>();
        assert_eq!(messages.len(), 64, "canonical message tail was truncated");
        assert_eq!(
            string(&messages[63]["payload"], "text"),
            "canonical tail 64"
        );
        assert_eq!(task_state(&fixture.root, "YARD-CODEX-TAIL"), "done");
    }

    #[test]
    fn running_redirect_records_stop_checkpoint_guidance_and_restart_dedupe() {
        let fixture = FixtureWorkspace::new("running-redirect");
        fixture.write_queue(
            "  - id: YARD-REDIRECT\n    title: running worker is redirected\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );

        let mut running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-REDIRECT", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let started = wait_until(Duration::from_secs(10), || {
            task_state(&fixture.root, "YARD-REDIRECT") == "running"
                && !files_below(&fixture.root.join(".agents/runs"), "/worker.pid").is_empty()
                && files_below(&fixture.root.join(".agents/worktrees"), "/handoff.md")
                    .iter()
                    .any(|path| {
                        fs::read_to_string(path)
                            .is_ok_and(|text| text.contains("checkpoint before redirect"))
                    })
        });
        if !started {
            let _ = running.kill();
            let output = running.wait_with_output().unwrap();
            panic!(
                "redirect fixture never reached running with a checkpoint handoff\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        fixture.run(&[
            "redirect",
            "YARD-REDIRECT",
            "finish with redirected guidance",
            "--reason",
            "scope changed during execution",
            "--action-id",
            "act-running-redirect",
        ]);
        let original = running.wait_with_output().unwrap();
        assert!(original.status.success());

        let channel = channel_dir(&fixture.root, "YARD-REDIRECT");
        let attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(attempts.len(), 2);
        let redirected = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "redirect")
            .unwrap();
        assert_eq!(
            string(redirected, "caused_by_action_id"),
            "act-running-redirect"
        );
        let events = yaml_dir(&channel.join("events"));
        let requested = events
            .iter()
            .find(|event| {
                string(event, "event_type") == "action.requested"
                    && event["payload"]["action"] == "redirect"
            })
            .unwrap();
        assert_eq!(
            requested["payload"]["reason"],
            "scope changed during execution"
        );
        assert_eq!(
            requested["payload"]["guidance"],
            "finish with redirected guidance"
        );
        assert_eq!(requested["payload"]["observed_terminal_state"], "cancelled");
        assert_eq!(requested["payload"]["live_message_delivered"], false);
        let checkpoint = events
            .iter()
            .find(|event| string(event, "event_type") == "worker.checkpoint")
            .unwrap();
        assert_eq!(
            string(redirected, "caused_by_event_id"),
            string(checkpoint, "event_id")
        );
        assert_eq!(task_state(&fixture.root, "YARD-REDIRECT"), "done");

        let before_restart = yaml_dir(&channel.join("attempts"));
        let duplicate = command(
            &fixture.root,
            &fixture.binary,
            &[
                "redirect",
                "YARD-REDIRECT",
                "finish with redirected guidance",
                "--reason",
                "scope changed during execution",
                "--action-id",
                "act-running-redirect",
            ],
        );
        assert!(!duplicate.status.success());
        fixture.run(&["queue"]);
        assert_eq!(yaml_dir(&channel.join("attempts")), before_restart);
    }

    #[test]
    fn redirect_preserves_exact_model_in_queue_and_both_receipts() {
        let fixture = FixtureWorkspace::new("exact-model-redirect");
        write_exact_codex_workers(&fixture, 0);
        fixture.write_queue(
            "  - id: YARD-EXACT-REDIRECT\n    title: exact redirect lineage\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n    model: gpt-5.6-sol\n    fallback_enabled: false\n",
        );

        let mut running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-EXACT-REDIRECT", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let started = wait_until(Duration::from_secs(10), || {
            task_state(&fixture.root, "YARD-EXACT-REDIRECT") == "running"
                && !files_below(&fixture.root.join(".agents/runs"), "/worker.pid").is_empty()
                && files_below(&fixture.root.join(".agents/worktrees"), "/handoff.md")
                    .iter()
                    .any(|path| {
                        fs::read_to_string(path)
                            .is_ok_and(|text| text.contains("checkpoint before exact redirect"))
                    })
        });
        if !started {
            let _ = running.kill();
            let output = running.wait_with_output().unwrap();
            panic!(
                "exact redirect fixture never reached running\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        fixture.run(&[
            "redirect",
            "YARD-EXACT-REDIRECT",
            "finish exact redirect",
            "--action-id",
            "act-exact-model-redirect",
        ]);
        assert!(running.wait_with_output().unwrap().status.success());
        assert_eq!(task_state(&fixture.root, "YARD-EXACT-REDIRECT"), "done");
        assert_exact_queue_task(&fixture.root, "YARD-EXACT-REDIRECT", "YARD-EXACT-REDIRECT");
        let runs = run_dirs_for_task(&fixture.root, "YARD-EXACT-REDIRECT");
        assert_eq!(runs.len(), 2);
        for run_dir in runs {
            assert_exact_receipt_pair(&run_dir, "YARD-EXACT-REDIRECT");
        }
    }

    #[test]
    fn action_id_rejects_absolute_and_parent_paths_without_receipt_escape() {
        for kind in ["absolute", "parent"] {
            let fixture = FixtureWorkspace::new(&format!("unsafe-action-id-{kind}"));
            fixture.write_queue(
                "  - id: YARD-001\n    title: unsafe action id boundary\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
            );
            fixture.run(&["run", "--task", "YARD-001", "--execute"]);
            let channel = channel_dir(&fixture.root, "YARD-001");
            let (action_id, escaped_paths) = if kind == "absolute" {
                let base = fixture.root.join("escaped-absolute-action");
                (
                    base.display().to_string(),
                    vec![
                        PathBuf::from(format!("{}.prepared.yaml", base.display())),
                        PathBuf::from(format!("{}.terminal.yaml", base.display())),
                    ],
                )
            } else {
                (
                    "../escaped-parent-action".to_string(),
                    vec![
                        channel.join("escaped-parent-action.prepared.yaml"),
                        channel.join("escaped-parent-action.terminal.yaml"),
                    ],
                )
            };

            let output = command(
                &fixture.root,
                &fixture.binary,
                &[
                    "answer",
                    "A",
                    "--task",
                    "YARD-001",
                    "--action-id",
                    &action_id,
                ],
            );
            assert!(
                !output.status.success(),
                "unsafe {kind} action id unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                String::from_utf8_lossy(&output.stderr).contains("invalid action id"),
                "unsafe {kind} action id did not fail at validation: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                escaped_paths.iter().all(|path| !path.exists()),
                "unsafe {kind} action id created a receipt outside actions/: {escaped_paths:?}"
            );
            assert!(
                yaml_dir(&channel.join("actions")).is_empty(),
                "unsafe {kind} action id created a channel action receipt"
            );
        }
    }

    #[test]
    fn redirect_ignores_decoy_pid_and_signals_verified_worker() {
        let fixture = FixtureWorkspace::new("redirect-worker-provenance");
        fixture.write_queue(
            "  - id: YARD-REDIRECT\n    title: redirect verifies worker provenance\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );

        let mut running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-REDIRECT", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let started = wait_until(Duration::from_secs(10), || {
            task_state(&fixture.root, "YARD-REDIRECT") == "running"
                && !files_below(&fixture.root.join(".agents/runs"), "/worker.pid").is_empty()
        });
        if !started {
            let _ = running.kill();
            let output = running.wait_with_output().unwrap();
            panic!(
                "redirect provenance fixture never reached running\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }

        let pid_path = files_below(&fixture.root.join(".agents/runs"), "/worker.pid")
            .into_iter()
            .next()
            .unwrap();
        let worker_pid: u32 = fs::read_to_string(&pid_path)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        let run_dir = pid_path.parent().unwrap();
        let provenance_path = run_dir.join("worker-process.yaml");
        let provenance = read_yaml(&provenance_path);
        assert_eq!(
            fs::metadata(&provenance_path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(number(&provenance, "pid"), u64::from(worker_pid));
        assert_eq!(string(&provenance, "worker_id"), "fixture");
        assert_eq!(
            string(&provenance, "run_id"),
            run_dir.file_name().unwrap().to_str().unwrap()
        );
        assert_eq!(
            string(&provenance, "attempt_id"),
            fs::read_to_string(run_dir.join("latest-attempt"))
                .unwrap()
                .trim()
        );
        assert!(!string(&provenance, "process_start_marker").is_empty());

        let unsafe_redirect = command(
            &fixture.root,
            &fixture.binary,
            &[
                "redirect",
                "YARD-REDIRECT",
                "this guidance must not stop the worker",
                "--action-id",
                "../escaped-redirect-action",
            ],
        );
        assert!(!unsafe_redirect.status.success());
        assert!(String::from_utf8_lossy(&unsafe_redirect.stderr).contains("invalid action id"));
        assert!(
            process_is_alive(worker_pid),
            "invalid redirect action id stopped the worker before validation"
        );
        assert!(!run_dir.join("cancelled").exists());

        let mut decoy = Command::new("sleep").arg("60").spawn().unwrap();
        let decoy_pid = decoy.id();
        fs::write(&pid_path, decoy_pid.to_string()).unwrap();

        let redirect = command(
            &fixture.root,
            &fixture.binary,
            &[
                "redirect",
                "YARD-REDIRECT",
                "finish with verified worker guidance",
                "--reason",
                "verify run-owned worker provenance",
                "--action-id",
                "act-verified-worker-redirect",
            ],
        );
        let worker_was_still_alive = process_is_alive(worker_pid);
        let decoy_survived = decoy.try_wait().unwrap().is_none();

        if worker_was_still_alive {
            let _ = Command::new("kill").arg(worker_pid.to_string()).status();
        }
        let original = running.wait_with_output().unwrap();
        if decoy_survived {
            let _ = decoy.kill();
        }
        let _ = decoy.wait();

        assert!(
            redirect.status.success(),
            "redirect failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&redirect.stdout),
            String::from_utf8_lossy(&redirect.stderr)
        );
        assert!(
            original.status.success(),
            "original yardlet run failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&original.stdout),
            String::from_utf8_lossy(&original.stderr)
        );
        assert!(!worker_was_still_alive, "verified worker was not stopped");
        assert!(decoy_survived, "redirect signalled the decoy process");
        assert_eq!(task_state(&fixture.root, "YARD-REDIRECT"), "done");
    }

    #[test]
    fn deleted_derived_index_rebuilds_from_canonical_facts_with_bounded_tail() {
        let fixture = FixtureWorkspace::new("index-rebuild");
        fixture.write_queue(
            "  - id: YARD-INDEX\n    title: emit enough progress to compact the index\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );

        fixture.run(&["run", "--task", "YARD-INDEX", "--execute"]);
        let channel = channel_dir(&fixture.root, "YARD-INDEX");
        let index_path = channel.join("index.yaml");
        let before_events = files_below(&channel.join("events"), ".yaml")
            .into_iter()
            .map(|path| {
                let bytes = fs::read(&path).unwrap();
                (path, bytes)
            })
            .collect::<Vec<_>>();
        assert!(before_events.len() > 128);
        let first_raw = attempt_paths(&fixture.root, &channel)
            .into_iter()
            .map(|path| (path.clone(), fs::read(path).unwrap()))
            .collect::<Vec<_>>();
        fs::remove_file(&index_path).unwrap();

        fixture.run(&[
            "answer",
            "A",
            "--task",
            "YARD-INDEX",
            "--action-id",
            "act-index-answer",
        ]);
        assert!(index_path.is_file());
        for (path, bytes) in before_events {
            assert_eq!(
                fs::read(path).unwrap(),
                bytes,
                "canonical event was rewritten"
            );
        }
        for (path, bytes) in first_raw {
            assert_eq!(fs::read(path).unwrap(), bytes, "raw evidence was rewritten");
        }

        let rebuilt = read_yaml(&index_path);
        let events = yaml_dir(&channel.join("events"));
        assert_eq!(number(&rebuilt, "event_count") as usize, events.len());
        assert_eq!(
            number(&rebuilt, "highest_applied_seq"),
            events
                .iter()
                .map(|event| number(event, "seq"))
                .max()
                .unwrap()
        );
        let tail = rebuilt["tail_events"].as_sequence().unwrap();
        assert!(tail.len() <= 128);
        assert_eq!(
            number(&rebuilt, "retained_from_seq"),
            number(tail.first().unwrap(), "seq")
        );
        assert_eq!(task_state(&fixture.root, "YARD-INDEX"), "done");
    }

    #[test]
    fn task_channel_and_raw_evidence_are_git_ignored() {
        let fixture = FixtureWorkspace::new("raw-ignore");
        fixture.write_queue(
            "  - id: YARD-001\n    title: raw ignore boundary\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );
        fixture.run(&["run", "--task", "YARD-001", "--execute"]);

        let channel = channel_dir(&fixture.root, "YARD-001");
        let mut evidence_paths = vec![channel.join("channel.yaml")];
        evidence_paths.extend(attempt_paths(&fixture.root, &channel));
        evidence_paths.extend(files_below(
            &fixture.root.join(".agents/runs"),
            "/worker-output.log",
        ));
        let canonical_root = fs::canonicalize(&fixture.root).unwrap();
        for path in evidence_paths {
            let canonical = fs::canonicalize(&path).unwrap();
            let relative = canonical.strip_prefix(&canonical_root).unwrap();
            let output = command(
                &fixture.root,
                Path::new("git"),
                &["check-ignore", "--quiet", relative.to_str().unwrap()],
            );
            assert!(
                output.status.success(),
                "{} is not ignored and can be staged accidentally",
                relative.display()
            );
        }

        let harness_probe = fixture.root.join(".agents/skills/fixture-probe/SKILL.md");
        fs::create_dir_all(harness_probe.parent().unwrap()).unwrap();
        fs::write(&harness_probe, "# tracked harness probe\n").unwrap();
        let relative = harness_probe.strip_prefix(&fixture.root).unwrap();
        let output = command(
            &fixture.root,
            Path::new("git"),
            &["check-ignore", "--quiet", relative.to_str().unwrap()],
        );
        assert!(
            !output.status.success(),
            "allowed tracked harness path was over-ignored"
        );
    }

    #[test]
    fn task_channel_raw_evidence_files_are_private() {
        let fixture = FixtureWorkspace::new("raw-mode");
        fixture.write_queue(
            "  - id: YARD-001\n    title: raw mode boundary\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );
        fixture.run_with_umask_022(&["run", "--task", "YARD-001", "--execute"]);

        let channel = channel_dir(&fixture.root, "YARD-001");
        let mut evidence_paths = attempt_paths(&fixture.root, &channel);
        evidence_paths.extend(files_below(
            &fixture.root.join(".agents/runs"),
            "/worker-output.log",
        ));
        assert_eq!(evidence_paths.len(), 3, "expected stdout, stderr, combined");
        for path in evidence_paths {
            let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(
                mode,
                0o600,
                "{} has mode {mode:o}; raw and combined evidence must be 600",
                path.display()
            );
        }

        let action_id = "act-overwrite-regression";
        let overwrite_path = channel
            .join("attempts")
            .join(action_attempt_id(action_id))
            .join("stdout.log");
        fs::create_dir_all(overwrite_path.parent().unwrap()).unwrap();
        fs::write(&overwrite_path, b"do not overwrite\n").unwrap();
        let output = command(
            &fixture.root,
            &fixture.binary,
            &[
                "answer",
                "A",
                "--task",
                "YARD-001",
                "--action-id",
                action_id,
            ],
        );
        assert!(!output.status.success());
        assert!(
            String::from_utf8_lossy(&output.stderr).contains("attempt raw stream already exists")
        );
        assert_eq!(fs::read(&overwrite_path).unwrap(), b"do not overwrite\n");
    }

    #[test]
    fn provider_progress_is_canonical_while_worker_lives_and_artifacts_keep_attempt_provenance() {
        let fixture = FixtureWorkspace::new("live-progress-artifacts");
        fixture.write_queue(
            "  - id: YARD-LIVE\n    title: live provider progress and artifacts\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n",
        );

        let mut running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-LIVE", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();

        let live_events_visible = wait_until(Duration::from_secs(10), || {
            let Some(channel) = maybe_channel_dir(&fixture.root, "YARD-LIVE") else {
                return false;
            };
            let Some(pid_path) = files_below(&fixture.root.join(".agents/runs"), "/worker.pid")
                .into_iter()
                .next()
            else {
                return false;
            };
            let Some(pid) = fs::read_to_string(pid_path)
                .ok()
                .and_then(|text| text.trim().parse::<u32>().ok())
            else {
                return false;
            };
            if !process_is_alive(pid) {
                return false;
            }
            let events = yaml_dir(&channel.join("events"));
            events
                .iter()
                .any(|event| string(event, "event_type") == "worker.message")
                && events
                    .iter()
                    .any(|event| string(event, "event_type") == "tool.started")
                && events
                    .iter()
                    .any(|event| string(event, "event_type") == "tool.completed")
        });
        assert!(
            live_events_visible,
            "normalized events were not visible while the worker lived"
        );
        assert!(
            running.try_wait().unwrap().is_none(),
            "worker run exited before live channel observation"
        );

        let channel = channel_dir(&fixture.root, "YARD-LIVE");
        let live_events = yaml_dir(&channel.join("events"));
        let attempts = yaml_dir(&channel.join("attempts"));
        let attempt = attempts.first().unwrap();
        let stdout_path = {
            let path = PathBuf::from(string(attempt, "raw_stdout_ref"));
            if path.is_absolute() {
                path
            } else {
                fixture.root.join(".agents").join(path)
            }
        };
        let stdout = fs::read(&stdout_path).unwrap();
        for event in live_events.iter().filter(|event| {
            matches!(
                string(event, "event_type"),
                "worker.message" | "tool.started" | "tool.completed"
            )
        }) {
            assert_eq!(event["raw_ref"]["stream"], "stdout");
            let start = number(&event["raw_ref"], "byte_start") as usize;
            let end = number(&event["raw_ref"], "byte_end") as usize;
            assert!(start < end && end <= stdout.len());
            assert!(String::from_utf8_lossy(&stdout[start..end]).contains("item."));
        }
        assert!(live_events.iter().all(|event| {
            !serde_yaml_ng::to_string(&event["payload"])
                .unwrap()
                .contains("private fixture reasoning")
        }));

        let output = running.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "live fixture failed\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let events = yaml_dir(&channel.join("events"));
        let artifact_events = events
            .iter()
            .filter(|event| string(event, "event_type") == "artifact.created")
            .collect::<Vec<_>>();
        let roles = artifact_events
            .iter()
            .filter_map(|event| event["payload"]["role"].as_str())
            .collect::<std::collections::BTreeSet<_>>();
        for role in [
            "worker_result",
            "evaluation",
            "checkpoint",
            "handoff",
            "worker_declared",
        ] {
            assert!(
                roles.contains(role),
                "missing artifact role {role}: {roles:?}"
            );
        }
        assert!(artifact_events.iter().all(|event| {
            event["attempt_id"] == attempt["attempt_id"]
                && event["payload"]["producer_attempt_id"] == attempt["attempt_id"]
                && event["payload"]["content_digest"]
                    .as_str()
                    .is_some_and(|digest| !digest.is_empty())
        }));
    }

    #[test]
    fn redirect_closes_superseded_question_and_stale_answer_fails_without_mutation() {
        let fixture = FixtureWorkspace::new("redirect-question-close");
        fixture.write_queue(
            "  - id: YARD-REDIRECT-QUESTION\n    title: redirect closes prior question\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );
        fixture.run(&["run", "--task", "YARD-REDIRECT-QUESTION", "--execute"]);
        let channel = channel_dir(&fixture.root, "YARD-REDIRECT-QUESTION");
        let first_question = yaml_dir(&channel.join("questions"))
            .into_iter()
            .next()
            .unwrap();
        fixture.run(&[
            "redirect",
            "YARD-REDIRECT-QUESTION",
            "ask a current question",
            "--reason",
            "prior question superseded",
            "--action-id",
            "act-question-redirect",
        ]);
        fixture.run(&[
            "answer",
            "resolve current question",
            "--task",
            "YARD-REDIRECT-QUESTION",
            "--action-id",
            "act-current-answer",
        ]);
        assert_eq!(task_state(&fixture.root, "YARD-REDIRECT-QUESTION"), "done");

        let events = yaml_dir(&channel.join("events"));
        let closed = events
            .iter()
            .find(|event| {
                string(event, "event_type") == "question.closed"
                    && event["payload"]["question_id"] == first_question["question_id"]
            })
            .expect("redirect did not record a question.closed event");
        assert_eq!(string(closed, "action_id"), "act-question-redirect");

        let attempts_before = yaml_dir(&channel.join("attempts"));
        let events_before = yaml_dir(&channel.join("events"));
        let stale = command(
            &fixture.root,
            &fixture.binary,
            &[
                "answer",
                "stale answer",
                "--task",
                "YARD-REDIRECT-QUESTION",
                "--action-id",
                "act-stale-answer",
            ],
        );
        assert!(
            !stale.status.success(),
            "stale answer unexpectedly resumed work"
        );
        assert_eq!(yaml_dir(&channel.join("attempts")), attempts_before);
        assert_eq!(yaml_dir(&channel.join("events")), events_before);
        assert!(!channel
            .join("actions/act-stale-answer.terminal.yaml")
            .exists());
    }

    #[test]
    fn unavailable_question_producer_falls_back_to_selected_worker_with_explicit_packet() {
        let fixture = FixtureWorkspace::new("answer-fallback-worker");
        let worker = worker_path(&fixture);
        let workers_path = fixture.root.join(".agents/workers.yaml");
        let write_workers = |producer_command: &Path| {
            fs::write(
                &workers_path,
                format!(
                    "schema_version: 1\nworkers:\n  - id: fixture-fallback-a\n    invocation: {{ command: {}, args: [\"{{run_dir}}\"] }}\n    limits: {{ max_wall_minutes: 1, max_retries: 0 }}\n  - id: fixture-fallback-b\n    invocation: {{ command: {}, args: [\"{{run_dir}}\"] }}\n    limits: {{ max_wall_minutes: 1, max_retries: 0 }}\nrouting:\n  default_worker: fixture-fallback-a\n  fallback_order: [fixture-fallback-b]\n  allow_preferred_worker_failover: true\n",
                    producer_command.display(),
                    worker.display()
                ),
            )
            .unwrap();
        };
        write_workers(&worker);
        fixture.write_queue(
            "  - id: YARD-FALLBACK\n    title: fallback owns answer continuation\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture-fallback-a\n",
        );
        fixture.run(&["run", "--task", "YARD-FALLBACK", "--execute"]);
        write_workers(Path::new("yardlet-missing-question-producer"));

        fixture.run(&[
            "answer",
            "continue on fallback",
            "--task",
            "YARD-FALLBACK",
            "--action-id",
            "act-fallback-answer",
        ]);
        let channel = channel_dir(&fixture.root, "YARD-FALLBACK");
        let attempts = yaml_dir(&channel.join("attempts"));
        let continuation = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "explicit_packet")
            .unwrap();
        assert_eq!(string(continuation, "worker_id"), "fixture-fallback-b");
        assert_eq!(
            string(continuation, "caused_by_action_id"),
            "act-fallback-answer"
        );
        assert_eq!(task_state(&fixture.root, "YARD-FALLBACK"), "done");
        assert!(
            files_below(&fixture.root.join(".agents/runs"), "/task-packet.md")
                .iter()
                .any(|path| fs::read_to_string(path)
                    .is_ok_and(|packet| packet.contains("Explicit continuation packet")))
        );
    }

    #[test]
    fn redirect_receipt_crash_retries_same_action_and_runs_stored_attempt_once() {
        let fixture = FixtureWorkspace::new("redirect-receipt-crash");
        fixture.write_queue(
            "  - id: YARD-REDIRECT\n    title: redirect receipt crash recovery\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );
        let running = Command::new(&fixture.binary)
            .args(["run", "--task", "YARD-REDIRECT", "--execute"])
            .current_dir(&fixture.root)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        assert!(wait_until(Duration::from_secs(10), || {
            task_state(&fixture.root, "YARD-REDIRECT") == "running"
                && !files_below(&fixture.root.join(".agents/runs"), "/worker.pid").is_empty()
        }));

        let crashed = Command::new(&fixture.binary)
            .args([
                "redirect",
                "YARD-REDIRECT",
                "recover stored redirect guidance",
                "--reason",
                "inject receipt crash",
                "--action-id",
                "act-redirect-crash",
            ])
            .env("YARDLET_TEST_CRASH_AFTER_REDIRECT_RECEIPT", "1")
            .current_dir(&fixture.root)
            .output()
            .unwrap();
        assert!(
            !crashed.status.success(),
            "redirect did not stop after the terminal receipt"
        );
        let original = running.wait_with_output().unwrap();
        assert!(original.status.success());
        let channel = channel_dir(&fixture.root, "YARD-REDIRECT");
        let prepared_attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(prepared_attempts.len(), 2);
        assert!(channel
            .join("actions/act-redirect-crash.terminal.yaml")
            .is_file());

        fixture.run(&[
            "redirect",
            "YARD-REDIRECT",
            "recover stored redirect guidance",
            "--reason",
            "inject receipt crash",
            "--action-id",
            "act-redirect-crash",
        ]);
        let attempts = yaml_dir(&channel.join("attempts"));
        assert_eq!(
            attempts.len(),
            2,
            "restart created a duplicate redirect attempt"
        );
        let redirect_attempt = attempts
            .iter()
            .find(|attempt| string(attempt, "continuation") == "redirect")
            .unwrap();
        let events = yaml_dir(&channel.join("events"));
        let starts = events
            .iter()
            .filter(|event| {
                string(event, "event_type") == "worker.started"
                    && event["attempt_id"] == redirect_attempt["attempt_id"]
            })
            .count();
        assert_eq!(
            starts, 1,
            "stored redirect attempt did not execute exactly once"
        );
        assert_eq!(task_state(&fixture.root, "YARD-REDIRECT"), "done");
    }

    #[test]
    fn issue_23_empty_worker_question_is_replaced_before_needs_user() {
        let fixture = FixtureWorkspace::new("issue-23-empty-worker-question");
        fixture.write_queue(
            "  - id: YARD-EMPTY-QUESTION\n    title: empty worker question\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n",
        );

        fixture.run(&["run", "--task", "YARD-EMPTY-QUESTION", "--execute"]);

        assert_actionable_needs_user(&fixture, "YARD-EMPTY-QUESTION");
    }

    #[test]
    fn issue_23_feedback_exhaustion_persists_an_actionable_question() {
        let fixture = FixtureWorkspace::new("issue-23-feedback-question");
        fixture.write_queue(
            "  - id: YARD-FEEDBACK-EXHAUSTED\n    title: exhausted feedback\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n    acceptance: [validation passes]\n    goal:\n      condition: validation passes\n      max_feedback_cycles: 0\n      feedback_policy: inject_failed_checks\n",
        );

        fixture.run(&["run", "--task", "YARD-FEEDBACK-EXHAUSTED", "--execute"]);

        assert_actionable_needs_user(&fixture, "YARD-FEEDBACK-EXHAUSTED");
    }

    #[test]
    fn issue_23_review_retransition_persists_an_actionable_question() {
        let fixture = FixtureWorkspace::new("issue-23-review-question");
        fixture.write_queue(
            "  - id: YARD-REVIEW-FAIL\n    title: failed review without remediation\n    state: queued\n    priority: 10\n    kind: review\n    preferred_worker: fixture\n    acceptance: [criterion passes]\n    goal:\n      condition: criterion passes\n      max_feedback_cycles: 1\n      feedback_policy: inject_failed_checks\n",
        );

        fixture.run(&["run", "--task", "YARD-REVIEW-FAIL", "--execute"]);

        assert_actionable_needs_user(&fixture, "YARD-REVIEW-FAIL");
        let run_dir = run_dir_for_task(&fixture.root, "YARD-REVIEW-FAIL");
        let evaluation: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(run_dir.join("evaluation.json")).unwrap())
                .unwrap();
        assert!(evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|check| check["name"] == "review_criteria_pass" && check["passed"] == false));
        let questions = yaml_dir(&channel_dir(&fixture.root, "YARD-REVIEW-FAIL").join("questions"));
        let question = string(&questions[0], "text");
        assert!(question.contains("수정 작업을 큐에 추가"));
        assert!(question.contains("수동으로 확정"));
    }

    #[test]
    fn passing_review_with_auto_commit_off_stays_resolvable_partial() {
        let fixture = FixtureWorkspace::new("passing-review-manual-integration");
        fixture.write_queue(
            "  - id: YARD-REVIEW-PASS-MANUAL\n    title: passing review awaiting manual integration\n    state: queued\n    priority: 10\n    kind: review\n    preferred_worker: fixture\n    acceptance: [criterion passes]\n",
        );

        fixture.run(&["run", "--task", "YARD-REVIEW-PASS-MANUAL", "--execute"]);

        assert_eq!(
            task_state(&fixture.root, "YARD-REVIEW-PASS-MANUAL"),
            "partial"
        );
        let run_dir = run_dir_for_task(&fixture.root, "YARD-REVIEW-PASS-MANUAL");
        assert_eq!(
            fs::read_to_string(run_dir.join("partial-reason"))
                .unwrap()
                .trim(),
            "auto_commit_disabled"
        );
        let handoff = fs::read_to_string(run_dir.join("handoff.md")).unwrap();
        assert!(
            handoff.starts_with(
                "# Handoff\n\nWORKER-HANDOFF-MARKER-ISSUE-31-7E3C 통과한 review의 수동 통합 대기 fixture\n"
            ),
            "finalize must preserve the worker-authored handoff verbatim; got:\n{handoff}"
        );
        assert!(handoff.contains("Non-blocking follow-up notes"));
        assert!(handoff.contains("optional review documentation"));
        assert!(handoff.contains("Git integration paused"));
        let evaluator_summary = fs::read_to_string(run_dir.join("evaluator-summary.md")).unwrap();
        assert!(evaluator_summary.contains("Evaluator checks"));
        assert!(evaluator_summary.contains("review_criteria_pass"));
        let evaluation: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(run_dir.join("evaluation.json")).unwrap())
                .unwrap();
        assert!(evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|check| check["name"] == "review_criteria_pass" && check["passed"] == true));
        assert!(
            !channel_dir(&fixture.root, "YARD-REVIEW-PASS-MANUAL")
                .join("questions")
                .exists(),
            "passing review must not open a NeedsUser question"
        );

        let run = read_yaml(&run_dir.join("run.yaml"));
        let worktree = PathBuf::from(string(&run, "worktree"));
        fs::copy(
            worktree.join("review-change.txt"),
            fixture.root.join("review-change.txt"),
        )
        .unwrap();
        must_succeed(
            &fixture.root,
            Path::new("git"),
            &["add", "review-change.txt"],
        );
        must_succeed(
            &fixture.root,
            Path::new("git"),
            &["commit", "-qm", "manually integrate passing review"],
        );
        fixture.run(&["resolve", "YARD-REVIEW-PASS-MANUAL", "수동 통합 완료"]);
        assert_eq!(task_state(&fixture.root, "YARD-REVIEW-PASS-MANUAL"), "done");
    }

    #[test]
    fn issue_23_nested_domain_status_does_not_fail_a_passing_review() {
        let fixture = FixtureWorkspace::new("issue-23-nested-domain-status");
        fixture.write_queue(
            "  - id: YARD-REVIEW-PASS\n    title: passing review with unresolved domain state\n    state: queued\n    priority: 10\n    kind: review\n    preferred_worker: fixture\n    acceptance: [foundation passes]\n",
        );

        fixture.run(&["run", "--task", "YARD-REVIEW-PASS", "--execute"]);

        assert_eq!(task_state(&fixture.root, "YARD-REVIEW-PASS"), "done");
        let evaluation_paths = files_below(&fixture.root.join(".agents/runs"), "/evaluation.json");
        let evaluation = evaluation_paths
            .iter()
            .map(|path| {
                serde_json::from_str::<serde_json::Value>(&fs::read_to_string(path).unwrap())
                    .unwrap()
            })
            .find(|value| value["task_id"] == "YARD-REVIEW-PASS")
            .expect("review evaluation");
        assert!(evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .any(|check| { check["name"] == "review_criteria_pass" && check["passed"] == true }));
    }

    #[test]
    fn needs_user_question_precedes_worker_completed_and_is_its_cause() {
        let fixture = FixtureWorkspace::new("needs-user-ordering");
        fixture.write_queue(
            "  - id: YARD-ASK\n    title: question ordering\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture-ask\n",
        );
        fixture.run(&["run", "--task", "YARD-ASK", "--execute"]);
        let channel = channel_dir(&fixture.root, "YARD-ASK");
        let events = yaml_dir(&channel.join("events"));
        let asked = events
            .iter()
            .find(|event| string(event, "event_type") == "question.asked")
            .unwrap();
        let completed = events
            .iter()
            .find(|event| string(event, "event_type") == "worker.completed")
            .unwrap();
        assert!(number(asked, "seq") < number(completed, "seq"));
        assert_eq!(string(completed, "causation_id"), string(asked, "event_id"));
        assert_eq!(completed["payload"]["result"], "needs_user");
    }
}
