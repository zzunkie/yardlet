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
