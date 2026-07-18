#[cfg(unix)]
mod unix {
    use serde_json::Value;
    use serde_yaml_ng::Value as YamlValue;
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
        fn new(label: &str) -> Self {
            let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "yardlet-v010-004-{label}-{}-{nonce}",
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

            let worker = root.join("resource-worker.sh");
            fs::copy(
                manifest.join("tests/fixtures/v010_004_resource_model/worker.sh"),
                &worker,
            )
            .unwrap();
            let mut permissions = fs::metadata(&worker).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&worker, permissions).unwrap();
            fs::write(
                root.join(".agents/workers.yaml"),
                format!(
                    "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 2\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
                    worker.display()
                ),
            )
            .unwrap();
            fs::write(
                root.join(".agents/intent-contract.yaml"),
                "schema_version: 1\nid: intent-resource-fixture\nsummary: resource fixture\nstatus: accepted\n",
            )
            .unwrap();
            fs::write(
                root.join(".agents/work-queue.yaml"),
                "schema_version: 1\nqueue_id: queue-resource-fixture\nintent_id: intent-resource-fixture\ntasks:\n  - {id: YARD-001, title: publish typed resources, state: queued, priority: 10, preferred_worker: fixture}\n  - {id: YARD-CAP, title: publish bounded artifacts, state: queued, priority: 20, preferred_worker: fixture}\n  - {id: YARD-BAD, title: reject unowned evidence, state: queued, priority: 30, preferred_worker: fixture}\n  - {id: YARD-CAUSE, title: reject forged causation, state: queued, priority: 40, preferred_worker: fixture}\n",
            )
            .unwrap();
            Self { root, binary }
        }

        fn run(&self, args: &[&str]) -> Output {
            command(&self.root, &self.binary, args)
        }

        fn must_run(&self, args: &[&str]) -> Output {
            let output = self.run(args);
            assert_success(&self.binary, args, &output);
            output
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

    fn assert_success(program: &Path, args: &[&str], output: &Output) {
        assert!(
            output.status.success(),
            "{} {:?} failed\nstdout:\n{}\nstderr:\n{}",
            program.display(),
            args,
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }

    fn must_succeed(root: &Path, program: &Path, args: &[&str]) -> Output {
        let output = command(root, program, args);
        assert_success(program, args, &output);
        output
    }

    fn yaml_files(path: &Path) -> Vec<PathBuf> {
        if !path.is_dir() {
            return Vec::new();
        }
        let mut files = fs::read_dir(path)
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.extension().and_then(|value| value.to_str()) == Some("yaml"))
            .collect::<Vec<_>>();
        files.sort();
        files
    }

    fn read_yaml(path: &Path) -> YamlValue {
        serde_yaml_ng::from_str(&fs::read_to_string(path).unwrap()).unwrap()
    }

    fn task_channel_events(root: &Path) -> Vec<YamlValue> {
        let channels = root.join(".agents/task-channels");
        if !channels.is_dir() {
            return Vec::new();
        }
        let mut events = Vec::new();
        for channel in fs::read_dir(channels).unwrap().flatten() {
            events.extend(
                yaml_files(&channel.path().join("events"))
                    .iter()
                    .map(|path| read_yaml(path)),
            );
        }
        events
    }

    fn canonical_bytes(root: &Path) -> Vec<(String, Vec<u8>)> {
        let base = root.join(".agents/resources");
        let mut out = Vec::new();
        for directory in ["artifacts", "runtime", "observations"] {
            let directory = base.join(directory);
            if !directory.is_dir() {
                continue;
            }
            let mut stack = vec![directory];
            while let Some(path) = stack.pop() {
                for entry in fs::read_dir(path).unwrap().flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        stack.push(path);
                    } else {
                        out.push((
                            path.strip_prefix(&base).unwrap().display().to_string(),
                            fs::read(&path).unwrap(),
                        ));
                    }
                }
            }
        }
        out.sort_by(|left, right| left.0.cmp(&right.0));
        out
    }

    fn copy_tree(source: &Path, destination: &Path) {
        if !source.is_dir() {
            return;
        }
        fs::create_dir_all(destination).unwrap();
        for entry in fs::read_dir(source).unwrap().flatten() {
            let source_path = entry.path();
            let destination_path = destination.join(entry.file_name());
            if source_path.is_dir() {
                copy_tree(&source_path, &destination_path);
            } else {
                fs::copy(source_path, destination_path).unwrap();
            }
        }
    }

    #[test]
    fn publishes_every_typed_kind_and_role_with_exact_attempt_provenance() {
        let fixture = Fixture::new("round-trip");
        fixture.must_run(&["run", "--task", "YARD-001", "--execute"]);

        let output = fixture.must_run(&[
            "resource",
            "discover",
            "--intent",
            "intent-resource-fixture",
            "--task",
            "YARD-001",
            "--action-id",
            "act-discover-round-trip",
            "--json",
        ]);
        let receipt: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(receipt["status"], "completed");
        let entries = receipt["result"]["entries"].as_array().unwrap();

        let mut roles = entries
            .iter()
            .filter(|entry| entry["entry_type"] == "artifact")
            .filter_map(|entry| entry["artifact"]["role"].as_str())
            .collect::<Vec<_>>();
        roles.sort_unstable();
        roles.dedup();
        for role in [
            "file",
            "screenshot",
            "git_diff",
            "validation_output",
            "review_report",
            "handoff",
        ] {
            assert!(
                roles.contains(&role),
                "missing artifact role {role}: {roles:?}"
            );
        }

        let mut kinds = entries
            .iter()
            .filter(|entry| entry["entry_type"] == "runtime_resource")
            .filter_map(|entry| entry["resource"]["target"]["kind"].as_str())
            .collect::<Vec<_>>();
        kinds.sort_unstable();
        assert_eq!(kinds, ["browser", "process", "service", "terminal"]);
        for entry in entries
            .iter()
            .filter(|entry| entry["entry_type"] == "runtime_resource")
        {
            assert!(
                !entry["resource"]["capabilities"]
                    .as_array()
                    .expect("typed runtime capabilities")
                    .is_empty(),
                "canonical runtime declaration must record capabilities: {entry}"
            );
        }

        let events = task_channel_events(&fixture.root);
        for entry in entries {
            let record = entry.get("artifact").unwrap_or(&entry["resource"]);
            assert_eq!(record["task_id"], "YARD-001");
            assert!(!record["attempt_id"].as_str().unwrap().is_empty());
            assert_eq!(record["producer"]["worker_id"], "fixture");
            assert!(!record["created_event_id"].as_str().unwrap().is_empty());
            if record["proposal_id"]
                .as_str()
                .is_some_and(|proposal_id| proposal_id.starts_with("proposal-"))
            {
                let causation_id = record["causation_id"].as_str().unwrap();
                assert_ne!(causation_id, record["attempt_id"].as_str().unwrap());
                let cause = events
                    .iter()
                    .find(|event| event["event_id"].as_str() == Some(causation_id))
                    .expect("canonical publication causation event");
                assert_eq!(cause["attempt_id"].as_str(), record["attempt_id"].as_str());
            }
        }

        for (index, entry) in entries.iter().enumerate() {
            let (id, expected_target) = if entry["entry_type"] == "artifact" {
                let expected = if entry["status"] == "available" {
                    "file"
                } else {
                    "unavailable"
                };
                if entry["artifact"]["proposal_id"]
                    .as_str()
                    .is_some_and(|proposal_id| proposal_id.starts_with("proposal-"))
                {
                    assert_eq!(entry["status"], "available", "explicit artifact {entry:?}");
                }
                (entry["artifact"]["artifact_id"].as_str().unwrap(), expected)
            } else {
                let expected = match entry["resource"]["target"]["kind"].as_str().unwrap() {
                    "terminal" => "terminal_session",
                    "process" => "process_monitor",
                    "service" | "browser" => "url",
                    other => panic!("unexpected resource kind {other}"),
                };
                (entry["resource"]["resource_id"].as_str().unwrap(), expected)
            };
            let action_id = format!("act-open-round-trip-{index}");
            let opened =
                fixture.must_run(&["resource", "open", id, "--action-id", &action_id, "--json"]);
            let opened: Value = serde_json::from_slice(&opened.stdout).unwrap();
            assert_eq!(opened["status"], "completed");
            assert_eq!(
                opened["result"]["open_target"]["target_type"], expected_target,
                "entry {entry:?} opened as {opened:?}"
            );
        }

        let artifact_records = yaml_files(&fixture.root.join(".agents/resources/artifacts"));
        let duplicate_count = artifact_records
            .iter()
            .map(|path| read_yaml(path))
            .filter(|record| record["proposal_id"].as_str() == Some("proposal-file"))
            .count();
        assert_eq!(duplicate_count, 1, "same proposal must publish once");
    }

    #[test]
    fn result_json_artifact_proposals_are_stamped_worker_authored() {
        let fixture = Fixture::new("authorship-stamp");
        fixture.must_run(&["run", "--task", "YARD-001", "--execute"]);

        // The fixture's result.json proposals omit `worker_authored`, exactly
        // like a worker predating the field: authorship must come from the
        // ingest stamp, never from trusting the proposal.
        let records = yaml_files(&fixture.root.join(".agents/resources/artifacts"))
            .iter()
            .map(|path| read_yaml(path))
            .filter(|record| {
                record["proposal_id"]
                    .as_str()
                    .is_some_and(|proposal_id| proposal_id.starts_with("proposal-"))
            })
            .collect::<Vec<_>>();
        assert!(
            !records.is_empty(),
            "fixture must publish result.json artifact proposals"
        );
        for record in &records {
            assert_eq!(
                record["worker_authored"].as_bool(),
                Some(true),
                "canonical record must stamp worker_authored=true: {record:?}"
            );
        }

        let created = task_channel_events(&fixture.root)
            .into_iter()
            .filter(|event| event["type"].as_str() == Some("artifact.created"))
            .filter(|event| {
                event["payload"]["proposal_id"]
                    .as_str()
                    .is_some_and(|proposal_id| proposal_id.starts_with("proposal-"))
            })
            .collect::<Vec<_>>();
        assert!(
            !created.is_empty(),
            "artifact.created events for result.json proposals must exist"
        );
        for event in &created {
            assert_eq!(
                event["payload"]["worker_authored"].as_bool(),
                Some(true),
                "artifact.created payload must stamp worker_authored=true: {event:?}"
            );
        }
    }

    #[test]
    fn derived_index_rebuild_is_bounded_and_never_changes_canonical_bytes() {
        let fixture = Fixture::new("bounded-index");
        fixture.must_run(&["run", "--task", "YARD-CAP", "--execute"]);
        let canonical_before = canonical_bytes(&fixture.root);
        let index_path = fixture.root.join(".agents/resources/index.yaml");
        assert!(index_path.is_file());
        fs::remove_file(&index_path).unwrap();

        let discovered = fixture.must_run(&[
            "resource",
            "discover",
            "--intent",
            "intent-resource-fixture",
            "--task",
            "YARD-CAP",
            "--action-id",
            "act-index-missing",
            "--json",
        ]);
        let discovered: Value = serde_json::from_slice(&discovered.stdout).unwrap();
        let discovered_cap_artifacts = discovered["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|entry| {
                entry["artifact"]["proposal_id"]
                    .as_str()
                    .is_some_and(|proposal_id| proposal_id.starts_with("cap-"))
            })
            .count();
        assert_eq!(
            discovered_cap_artifacts, 140,
            "bounded index must fall back to canonical task facts"
        );
        let rebuilt = read_yaml(&index_path);
        assert!(rebuilt["artifacts"].as_sequence().unwrap().len() <= 128);
        let task_index = rebuilt["tasks"]
            .as_sequence()
            .expect("resource index must carry bounded task projections")
            .iter()
            .find(|entry| entry["task_id"].as_str() == Some("YARD-CAP"))
            .expect("YARD-CAP task projection");
        assert!(task_index["artifacts"].as_sequence().unwrap().len() <= 128);
        assert_eq!(task_index["resources"].as_sequence().unwrap().len(), 0);
        assert_eq!(task_index["attempts"].as_sequence().unwrap().len(), 1);
        assert_eq!(task_index["truncated"].as_bool(), Some(true));
        fs::write(&index_path, "malformed: [\n").unwrap();
        fixture.must_run(&[
            "resource",
            "discover",
            "--intent",
            "intent-resource-fixture",
            "--task",
            "YARD-CAP",
            "--action-id",
            "act-index-malformed",
            "--json",
        ]);
        assert!(
            read_yaml(&index_path)["artifacts"]
                .as_sequence()
                .unwrap()
                .len()
                <= 128
        );
        assert_eq!(canonical_before, canonical_bytes(&fixture.root));
        let cap_records = yaml_files(&fixture.root.join(".agents/resources/artifacts"))
            .iter()
            .map(|path| read_yaml(path))
            .filter(|record| {
                record["proposal_id"]
                    .as_str()
                    .is_some_and(|proposal_id| proposal_id.starts_with("cap-"))
            })
            .count();
        assert_eq!(cap_records, 140);
    }

    #[test]
    fn resource_index_and_discover_use_exact_intent_task_namespace() {
        let first = Fixture::new("namespace-first");
        first.must_run(&["run", "--task", "YARD-001", "--execute"]);

        let second = Fixture::new("namespace-second");
        fs::write(
            second.root.join(".agents/intent-contract.yaml"),
            "schema_version: 1\nid: intent-resource-fixture-two\nsummary: second resource fixture\nstatus: accepted\n",
        )
        .unwrap();
        fs::write(
            second.root.join(".agents/work-queue.yaml"),
            "schema_version: 1\nqueue_id: queue-resource-fixture-two\nintent_id: intent-resource-fixture-two\ntasks:\n  - {id: YARD-001, title: publish typed resources again, state: queued, priority: 10, preferred_worker: fixture}\n",
        )
        .unwrap();
        second.must_run(&["run", "--task", "YARD-001", "--execute"]);

        let first_resources = first.root.join(".agents/resources");
        let second_resources = second.root.join(".agents/resources");
        for directory in ["artifacts", "runtime", "observations"] {
            copy_tree(
                &second_resources.join(directory),
                &first_resources.join(directory),
            );
        }
        let _ = fs::remove_file(first_resources.join("index.yaml"));

        let discover = |intent: &str, action: &str| {
            let output = first.must_run(&[
                "resource",
                "discover",
                "--intent",
                intent,
                "--task",
                "YARD-001",
                "--action-id",
                action,
                "--json",
            ]);
            serde_json::from_slice::<Value>(&output.stdout).unwrap()
        };
        let first_projection = discover("intent-resource-fixture", "act-namespace-first");
        let second_projection = discover("intent-resource-fixture-two", "act-namespace-second");
        assert_eq!(first_projection["intent_id"], "intent-resource-fixture");
        assert_eq!(
            second_projection["intent_id"],
            "intent-resource-fixture-two"
        );

        let projection_attempts = |receipt: &Value, intent: &str| {
            receipt["result"]["entries"]
                .as_array()
                .unwrap()
                .iter()
                .map(|entry| entry.get("artifact").unwrap_or(&entry["resource"]))
                .map(|record| {
                    assert_eq!(record["intent_id"], intent);
                    record["attempt_id"].as_str().unwrap().to_string()
                })
                .collect::<std::collections::BTreeSet<_>>()
        };
        let first_attempts = projection_attempts(&first_projection, "intent-resource-fixture");
        let second_attempts =
            projection_attempts(&second_projection, "intent-resource-fixture-two");
        assert!(!first_attempts.is_empty());
        assert!(!second_attempts.is_empty());
        assert!(first_attempts.is_disjoint(&second_attempts));

        let index = read_yaml(&first_resources.join("index.yaml"));
        let namespaces = index["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .filter(|entry| entry["task_id"].as_str() == Some("YARD-001"))
            .map(|entry| entry["intent_id"].as_str().unwrap())
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            namespaces,
            std::collections::BTreeSet::from([
                "intent-resource-fixture",
                "intent-resource-fixture-two"
            ])
        );
    }

    #[test]
    fn evidence_without_exact_attempt_provenance_cannot_complete() {
        let fixture = Fixture::new("invalid-provenance");
        let output = fixture.run(&["run", "--task", "YARD-BAD", "--execute"]);
        assert!(
            output.status.success(),
            "the orchestrator should record a failed task cleanly: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let queue = read_yaml(&fixture.root.join(".agents/work-queue.yaml"));
        let state = queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| task["id"].as_str() == Some("YARD-BAD"))
            .unwrap()["state"]
            .as_str()
            .unwrap();
        assert_ne!(state, "done");
        let evaluation_path = fs::read_dir(fixture.root.join(".agents/runs"))
            .unwrap()
            .flatten()
            .map(|entry| entry.path().join("evaluation.json"))
            .find(|path| path.is_file())
            .expect("evaluation record");
        let evaluation: Value =
            serde_json::from_str(&fs::read_to_string(evaluation_path).unwrap()).unwrap();
        let provenance_check = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "resource_provenance_valid")
            .expect("evaluator must record an independent resource provenance check");
        assert_eq!(provenance_check["passed"], false);
        assert_eq!(provenance_check["fatal"], true);
        assert!(
            !fixture.root.join(".agents/resources/artifacts").is_dir()
                || yaml_files(&fixture.root.join(".agents/resources/artifacts"))
                    .iter()
                    .map(|path| read_yaml(path))
                    .all(|record| record["proposal_id"].as_str() != Some("bad"))
        );
    }

    #[test]
    fn evidence_with_forged_attempt_causation_cannot_complete() {
        let fixture = Fixture::new("invalid-causation");
        let output = fixture.run(&["run", "--task", "YARD-CAUSE", "--execute"]);
        assert!(
            output.status.success(),
            "the orchestrator should record rejected evidence cleanly: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let queue = read_yaml(&fixture.root.join(".agents/work-queue.yaml"));
        let state = queue["tasks"]
            .as_sequence()
            .unwrap()
            .iter()
            .find(|task| task["id"].as_str() == Some("YARD-CAUSE"))
            .unwrap()["state"]
            .as_str()
            .unwrap();
        assert_ne!(state, "done");
        let evaluation_path = fs::read_dir(fixture.root.join(".agents/runs"))
            .unwrap()
            .flatten()
            .map(|entry| entry.path().join("evaluation.json"))
            .find(|path| path.is_file())
            .expect("evaluation record");
        let evaluation: Value =
            serde_json::from_str(&fs::read_to_string(evaluation_path).unwrap()).unwrap();
        let provenance_check = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "resource_provenance_valid")
            .expect("causation must be part of the exact provenance gate");
        assert_eq!(provenance_check["passed"], false);
        assert_eq!(provenance_check["fatal"], true);
        assert!(
            !fixture.root.join(".agents/resources/artifacts").is_dir()
                || yaml_files(&fixture.root.join(".agents/resources/artifacts"))
                    .iter()
                    .map(|path| read_yaml(path))
                    .all(|record| record["proposal_id"].as_str() != Some("forged-cause"))
        );
    }
}
