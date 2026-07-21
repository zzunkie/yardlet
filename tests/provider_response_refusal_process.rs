#[cfg(unix)]
mod unix {
    use serde_yaml_ng::Value;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::time::{SystemTime, UNIX_EPOCH};

    struct Fixture {
        root: PathBuf,
        binary: PathBuf,
    }

    impl Fixture {
        fn new(label: &str, scenario: &str) -> Self {
            let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "yardlet-provider-refusal-{label}-{}-{nonce}",
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
                manifest.join("tests/fixtures/provider_response_refusal/worker.sh"),
                &worker,
            )
            .unwrap();
            let mut permissions = fs::metadata(&worker).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&worker, permissions).unwrap();

            fs::write(
                root.join(".agents/intent-contract.yaml"),
                "schema_version: 1\nid: intent-provider-refusal\nsummary: provider refusal fixture\nstatus: accepted\n",
            )
            .unwrap();
            fs::write(
                root.join(".agents/work-queue.yaml"),
                "schema_version: 1\nqueue_id: queue-provider-refusal\nintent_id: intent-provider-refusal\ntasks:\n  - id: YARD-001\n    title: provider refusal fixture\n    state: queued\n    priority: 10\n    risk: low\n    kind: implementation\n    preferred_worker: fixture\n    model: fixture-model\n    fallback_enabled: false\n    acceptance: [result converges]\n",
            )
            .unwrap();
            fs::write(
                root.join(".agents/workers.yaml"),
                format!(
                    "schema_version: 1\nworkers:\n  - id: fixture\n    model: fixture-model\n    provider_response_refusal_patterns: ['provider declined response']\n    invocation:\n      command: {}\n      args: ['{{run_dir}}', '{}', 'YARD-001']\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 3\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n  allow_preferred_worker_failover: false\n",
                    worker.display(),
                    scenario
                ),
            )
            .unwrap();
            Self { root, binary }
        }

        fn latest_run(&self) -> PathBuf {
            let mut runs = fs::read_dir(self.root.join(".agents/runs"))
                .unwrap()
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.join("run.yaml").is_file())
                .collect::<Vec<_>>();
            runs.sort();
            runs.pop().expect("fixture run exists")
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

    fn yaml(path: &Path) -> Value {
        serde_yaml_ng::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn task_state(root: &Path) -> String {
        yaml(&root.join(".agents/work-queue.yaml"))["tasks"][0]["state"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn attempts(root: &Path) -> Vec<Value> {
        let channel = fs::read_dir(root.join(".agents/task-channels"))
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| path.join("channel.yaml").is_file())
            .unwrap();
        let mut attempts = fs::read_dir(channel.join("attempts"))
            .unwrap()
            .flatten()
            .map(|entry| yaml(&entry.path()))
            .collect::<Vec<_>>();
        attempts.sort_by_key(|attempt| attempt["attempt_id"].as_str().unwrap().to_string());
        attempts
    }

    #[test]
    fn configured_refusal_runs_same_worker_recovery_once_then_succeeds() {
        let fixture = Fixture::new("success", "success");
        must_succeed(
            &fixture.root,
            &fixture.binary,
            &["run", "--task", "YARD-001", "--execute"],
        );
        let run = fixture.latest_run();
        assert_eq!(task_state(&fixture.root), "done");
        assert_eq!(
            fs::read_to_string(run.join("fixture-attempt-count"))
                .unwrap()
                .trim(),
            "2"
        );
        let attempts = attempts(&fixture.root);
        assert_eq!(attempts.len(), 2);
        assert!(attempts
            .iter()
            .all(|attempt| attempt["worker_id"] == "fixture"));
        assert_eq!(attempts[1]["continuation"], "retry");
        let record = yaml(&run.join("run.yaml"));
        let incident = &record["output_contract_incident"];
        assert_eq!(incident["cause"], "provider_response_refused");
        assert_eq!(incident["worker_id"], "fixture");
        assert_eq!(incident["recovery_consumed"], true);
        assert!(incident["terminal_attempt_id"].is_null());
        assert!(!run.join("failover.json").exists());
        let handoff = fs::read_to_string(run.join("handoff.md")).unwrap();
        assert!(handoff.contains("provider_response_refused"), "{handoff}");
    }

    #[test]
    fn configured_refusal_exhaustion_is_typed_needs_user_without_third_attempt() {
        let fixture = Fixture::new("exhausted", "exhausted");
        must_succeed(
            &fixture.root,
            &fixture.binary,
            &["run", "--task", "YARD-001", "--execute"],
        );
        let run = fixture.latest_run();
        assert_eq!(task_state(&fixture.root), "needs_user");
        assert_eq!(
            fs::read_to_string(run.join("fixture-attempt-count"))
                .unwrap()
                .trim(),
            "2"
        );
        assert_eq!(attempts(&fixture.root).len(), 2);
        assert!(!run.join("result.json").exists());
        let record = yaml(&run.join("run.yaml"));
        assert_eq!(record["state"], "needs_user");
        assert_eq!(
            record["output_contract_incident"]["cause"],
            "provider_response_refused"
        );
        assert_eq!(
            record["output_contract_incident"]["terminal_attempt_id"],
            format!("{}-attempt-2", run.file_name().unwrap().to_string_lossy())
        );
        let handoff = fs::read_to_string(run.join("handoff.md")).unwrap();
        assert!(handoff.contains("provider_response_refused"), "{handoff}");
        must_succeed(&fixture.root, &fixture.binary, &["recover"]);
        assert_eq!(
            fs::read_to_string(run.join("fixture-attempt-count"))
                .unwrap()
                .trim(),
            "2"
        );
        assert_eq!(task_state(&fixture.root), "needs_user");
    }

    #[test]
    fn consumed_recovery_survives_orphan_replay_without_requeue_or_third_attempt() {
        let fixture = Fixture::new("crash-replay", "exhausted");
        must_succeed(
            &fixture.root,
            &fixture.binary,
            &["run", "--task", "YARD-001", "--execute"],
        );
        let run = fixture.latest_run();

        let mut record = yaml(&run.join("run.yaml"));
        record["state"] = Value::String("running".into());
        record["completed_at"] = Value::Null;
        record["output_contract_incident"]["terminal_attempt_id"] = Value::Null;
        fs::write(
            run.join("run.yaml"),
            serde_yaml_ng::to_string(&record).unwrap(),
        )
        .unwrap();
        let mut queue = yaml(&fixture.root.join(".agents/work-queue.yaml"));
        queue["tasks"][0]["state"] = Value::String("running".into());
        fs::write(
            fixture.root.join(".agents/work-queue.yaml"),
            serde_yaml_ng::to_string(&queue).unwrap(),
        )
        .unwrap();

        must_succeed(&fixture.root, &fixture.binary, &["recover"]);
        assert_eq!(task_state(&fixture.root), "needs_user");
        assert_eq!(
            fs::read_to_string(run.join("fixture-attempt-count"))
                .unwrap()
                .trim(),
            "2"
        );
        let recovered = yaml(&run.join("run.yaml"));
        assert_eq!(recovered["state"], "needs_user");
        assert_eq!(
            recovered["output_contract_incident"]["cause"],
            "provider_response_refused"
        );
    }

    #[test]
    fn unclassified_resultless_attempt_keeps_existing_opted_in_failover() {
        let fixture = Fixture::new("unclassified-failover", "unclassified");
        let worker = fixture.root.join("fixture-worker.sh");
        fs::write(
            fixture.root.join(".agents/workers.yaml"),
            format!(
                "schema_version: 1\nworkers:\n  - id: primary\n    model: fixture-model\n    provider_response_refusal_patterns: ['provider declined response']\n    invocation:\n      command: {0}\n      args: ['{{run_dir}}', 'unclassified', 'YARD-001']\n      supports_noninteractive: true\n      output_contract: files\n    limits: {{max_wall_minutes: 1, max_retries: 0}}\n  - id: alternate\n    model: fixture-model\n    provider_response_refusal_patterns: ['provider declined response']\n    invocation:\n      command: {0}\n      args: ['{{run_dir}}', 'alternate_success', 'YARD-001']\n      supports_noninteractive: true\n      output_contract: files\n    limits: {{max_wall_minutes: 1, max_retries: 0}}\nrouting:\n  default_worker: primary\n  fallback_order: [primary, alternate]\n  allow_preferred_worker_failover: true\n",
                worker.display()
            ),
        )
        .unwrap();
        let mut queue = yaml(&fixture.root.join(".agents/work-queue.yaml"));
        queue["tasks"][0]["preferred_worker"] = Value::String("primary".into());
        queue["tasks"][0]["fallback_enabled"] = Value::Bool(true);
        fs::write(
            fixture.root.join(".agents/work-queue.yaml"),
            serde_yaml_ng::to_string(&queue).unwrap(),
        )
        .unwrap();

        must_succeed(
            &fixture.root,
            &fixture.binary,
            &["run", "--task", "YARD-001", "--execute"],
        );
        let run = fixture.latest_run();
        assert_eq!(task_state(&fixture.root), "done");
        let attempts = attempts(&fixture.root);
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0]["worker_id"], "primary");
        assert_eq!(attempts[1]["worker_id"], "alternate");
        let record = yaml(&run.join("run.yaml"));
        assert!(record["output_contract_incident"].is_null());
        let failover = fs::read_to_string(run.join("failover.json")).unwrap();
        assert!(failover.contains("\"from\": \"primary\""), "{failover}");
        assert!(failover.contains("\"to\": \"alternate\""), "{failover}");
    }
}
