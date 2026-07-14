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
        fs::read_dir(root.join(".agents/task-channels"))
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .find(|path| {
                path.join("channel.yaml").is_file()
                    && string(&read_yaml(&path.join("channel.yaml")), "task_id") == task_id
            })
            .unwrap_or_else(|| panic!("channel for {task_id} not found"))
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
        fixture.write_queue(
            "  - id: YARD-NATIVE\n    title: native worker asks then resumes\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: codex\n",
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
        });
        if !started {
            let _ = running.kill();
            let output = running.wait_with_output().unwrap();
            panic!(
                "redirect fixture never reached running\nstdout:\n{}\nstderr:\n{}",
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
}
