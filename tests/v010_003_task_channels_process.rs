#[cfg(unix)]
mod unix {
    use serde_yaml_ng::Value;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::time::{SystemTime, UNIX_EPOCH};

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
                    "schema_version: 1\nworkers:\n  - id: fixture\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\nrouting:\n  default_worker: fixture\n  fallback_order: [fixture]\n",
                    worker.display()
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
            "  - id: YARD-ASK\n    title: ask in parallel\n    state: queued\n    priority: 10\n    kind: implementation\n    preferred_worker: fixture\n  - id: YARD-DRAIN\n    title: independent validated drain\n    state: queued\n    priority: 20\n    kind: implementation\n    preferred_worker: fixture\n    validation:\n      required: true\n      commands: [\"test -f drain-artifact.txt\"]\n",
        );

        let output = fixture.run(&["run", "--auto", "--parallel", "2"]);
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("parallel batch: YARD-ASK via fixture, YARD-DRAIN via fixture"),
            "configured validation removed YARD-DRAIN from the parallel batch:\n{stdout}"
        );
        let drain_channel = channel_dir(&fixture.root, "YARD-DRAIN");
        assert!(
            yaml_dir(&drain_channel.join("events"))
                .iter()
                .any(|event| string(event, "event_type") == "validation.completed"),
            "independent validated task has no validation.completed event"
        );
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
    }
}
