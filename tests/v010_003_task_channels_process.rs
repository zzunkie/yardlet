#[cfg(unix)]
mod unix {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::time::{SystemTime, UNIX_EPOCH};

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
}
