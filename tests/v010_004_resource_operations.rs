#[cfg(unix)]
mod unix {
    use serde_json::Value;
    use serde_yaml_ng::Value as YamlValue;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Output};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    struct Fixture {
        root: PathBuf,
        binary: PathBuf,
        owned_pids: Vec<u32>,
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
                "yardlet-v010-004-operations-{label}-{}-{nonce}",
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
            let config_path = root.join(".agents/yardlet.yaml");
            let config = fs::read_to_string(&config_path)
                .unwrap()
                .replace("auto_commit: false", "auto_commit: true");
            fs::write(&config_path, config).unwrap();
            let worker = root.join("resource-worker.sh");
            fs::copy(
                manifest.join("tests/fixtures/v010_004_resource_model/worker.sh"),
                &worker,
            )
            .unwrap();
            if label == "spawn-before-recovery" {
                let restart_helper = root.join("restart-once.sh");
                let spawn_log = root.join("restart-spawns.log");
                fs::write(
                    &restart_helper,
                    format!(
                        "#!/usr/bin/env bash\nset -euo pipefail\nprintf '%s\\n' \"$$\" >> \"{}\"\nexec /bin/sleep 15\n",
                        spawn_log.display()
                    ),
                )
                .unwrap();
                let mut helper_permissions = fs::metadata(&restart_helper).unwrap().permissions();
                helper_permissions.set_mode(0o755);
                fs::set_permissions(&restart_helper, helper_permissions).unwrap();

                let source = fs::read_to_string(&worker).unwrap();
                let needle =
                    "\"command\":[\"/bin/sleep\",\"90\"]}},\n    {\"proposal_id\":\"ops-cleanup\"";
                let replacement = format!(
                    "\"command\":[\"{}\"]}}}},\n    {{\"proposal_id\":\"ops-cleanup\"",
                    restart_helper.display()
                );
                let updated = source.replacen(needle, &replacement, 1);
                assert_ne!(source, updated, "restart command fixture marker changed");
                fs::write(&worker, updated).unwrap();
            }
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
                "schema_version: 1\nid: intent-resource-operations\nsummary: resource operations\nstatus: accepted\n",
            )
            .unwrap();
            fs::write(
                root.join(".agents/work-queue.yaml"),
                "schema_version: 1\nqueue_id: queue-resource-operations\nintent_id: intent-resource-operations\ntasks:\n  - {id: YARD-OPS, title: exercise operations, state: queued, priority: 10, preferred_worker: fixture}\n",
            )
            .unwrap();
            must_succeed(&root, &binary, &["run", "--task", "YARD-OPS", "--execute"]);
            let owned_pids = fs::read_to_string(root.join("ops-pids.txt"))
                .unwrap()
                .lines()
                .map(|line| line.parse().unwrap())
                .collect();
            Self {
                root,
                binary,
                owned_pids,
            }
        }

        fn receipt(&self, args: &[&str]) -> Value {
            let output = must_succeed(&self.root, &self.binary, args);
            serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
                panic!(
                    "invalid JSON receipt: {error}\nstdout:\n{}",
                    String::from_utf8_lossy(&output.stdout)
                )
            })
        }

        fn command_with_fault(&self, args: &[&str], fault: &str) -> Output {
            Command::new(&self.binary)
                .args(args)
                .current_dir(&self.root)
                .env("YARDLET_TEST_RESOURCE_ACTION_FAULT", fault)
                .output()
                .unwrap_or_else(|error| panic!("failed to run yardlet with {fault}: {error}"))
        }

        fn command_with_fault_trace(&self, args: &[&str], fault: &str, trace: &Path) -> Output {
            Command::new(&self.binary)
                .args(args)
                .current_dir(&self.root)
                .env("YARDLET_TEST_RESOURCE_ACTION_FAULT", fault)
                .env("YARDLET_TEST_RESOURCE_ACTION_TRACE", trace)
                .output()
                .unwrap_or_else(|error| panic!("failed to run yardlet with {fault}: {error}"))
        }

        fn discover(&self) -> Value {
            self.receipt(&[
                "resource",
                "discover",
                "--intent",
                "intent-resource-operations",
                "--task",
                "YARD-OPS",
                "--action-id",
                "act-ops-discover",
                "--json",
            ])
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for pid in &self.owned_pids {
                let _ = Command::new("kill")
                    .arg(pid.to_string())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }
            if std::thread::panicking() {
                eprintln!(
                    "V010-004 resource operations evidence kept at {}",
                    self.root.display()
                );
                return;
            }
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

    fn process_alive(pid: u32) -> bool {
        Command::new("kill")
            .args(["-0", &pid.to_string()])
            .status()
            .is_ok_and(|status| status.success())
    }

    fn wait_for_nonempty_spawn_log(path: &Path) -> Vec<u8> {
        const TIMEOUT: Duration = Duration::from_secs(5);
        const POLL_INTERVAL: Duration = Duration::from_millis(10);

        let started = Instant::now();
        loop {
            let last_observation = match fs::read(path) {
                Ok(contents) if !contents.is_empty() => return contents,
                Ok(_) => "empty",
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => "missing",
                Err(error) => panic!(
                    "failed to inspect restart spawn log {} while waiting for publication: {error}",
                    path.display()
                ),
            };

            assert!(
                started.elapsed() < TIMEOUT,
                "timed out after {TIMEOUT:?} waiting for restart spawn log {} to become non-empty \
                 (last observation: {last_observation}); the helper writes its PID before its \
                 15-second sleep, so this bound permits delayed scheduling under 8-way parallel \
                 load while still failing before the helper exits",
                path.display()
            );
            std::thread::sleep(POLL_INTERVAL);
        }
    }

    fn resource_id(discover: &Value, proposal_id: &str) -> String {
        discover["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["resource"]["proposal_id"] == proposal_id)
            .unwrap_or_else(|| panic!("missing resource proposal {proposal_id}"))["resource"]
            ["resource_id"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn artifact_id(discover: &Value, proposal_id: &str) -> String {
        discover["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["artifact"]["proposal_id"] == proposal_id)
            .unwrap()["artifact"]["artifact_id"]
            .as_str()
            .unwrap()
            .to_string()
    }

    fn assert_receipt(receipt: &Value, operation: &str, status: &str) {
        assert_eq!(receipt["operation"], operation);
        assert_eq!(receipt["status"], status);
        assert_eq!(receipt["result_event_ids"].as_array().unwrap().len(), 2);
    }

    fn channel_event(root: &Path, event_id: &str) -> YamlValue {
        let channels = root.join(".agents/task-channels");
        for channel in fs::read_dir(channels).unwrap().flatten() {
            let events = channel.path().join("events");
            if !events.is_dir() {
                continue;
            }
            for path in fs::read_dir(events).unwrap().flatten() {
                let path = path.path();
                let event: YamlValue =
                    serde_yaml_ng::from_str(&fs::read_to_string(path).unwrap()).unwrap();
                if event["event_id"].as_str() == Some(event_id) {
                    return event;
                }
            }
        }
        panic!("missing canonical event {event_id}");
    }

    fn resource_pid(discover: &Value, proposal_id: &str) -> u32 {
        discover["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["resource"]["proposal_id"] == proposal_id)
            .unwrap_or_else(|| panic!("missing resource proposal {proposal_id}"))["resource"]
            ["target"]["pid"]
            .as_u64()
            .unwrap() as u32
    }

    #[test]
    fn all_nine_operations_share_receipts_and_minimum_cli_open_targets() {
        let fixture = Fixture::new("all-operations");
        let discover = fixture.discover();
        assert_receipt(&discover, "discover", "completed");
        let file = artifact_id(&discover, "ops-file");
        let terminal = resource_id(&discover, "ops-detach");
        let service = resource_id(&discover, "ops-service");
        let restart = resource_id(&discover, "ops-restart");
        let cleanup = resource_id(&discover, "ops-cleanup");

        let inspect = fixture.receipt(&[
            "resource",
            "inspect",
            &file,
            "--action-id",
            "act-ops-inspect",
            "--json",
        ]);
        assert_receipt(&inspect, "inspect", "completed");
        assert_eq!(inspect["result"]["entries"][0]["status"], "available");
        let open_file = fixture.receipt(&[
            "resource",
            "open",
            &file,
            "--action-id",
            "act-ops-open-file",
            "--json",
        ]);
        assert_receipt(&open_file, "open", "completed");
        assert_eq!(open_file["result"]["open_target"]["target_type"], "file");
        let open_service = fixture.receipt(&[
            "resource",
            "open",
            &service,
            "--action-id",
            "act-ops-open-url",
            "--json",
        ]);
        assert_eq!(open_service["result"]["open_target"]["target_type"], "url");
        let attach = fixture.receipt(&[
            "resource",
            "attach",
            &terminal,
            "--action-id",
            "act-ops-attach",
            "--json",
        ]);
        assert_receipt(&attach, "attach", "completed");
        assert_eq!(
            attach["result"]["open_target"]["target_type"],
            "terminal_session"
        );

        let reconcile = fixture.receipt(&[
            "resource",
            "reconcile",
            &restart,
            "--expected-status",
            "live",
            "--action-id",
            "act-ops-reconcile",
            "--json",
        ]);
        assert_receipt(&reconcile, "reconcile", "completed");
        assert_eq!(reconcile["result"]["observation"]["status"], "live");
        assert_eq!(reconcile["result"]["observation"]["current"], true);
        let after_restart_inspect = fixture.receipt(&[
            "resource",
            "inspect",
            &restart,
            "--action-id",
            "act-ops-inspect-last-observed",
            "--json",
        ]);
        assert_eq!(
            after_restart_inspect["result"]["entries"][0]["status"],
            "unknown"
        );
        assert_eq!(
            after_restart_inspect["result"]["entries"][0]["last_observation"]["status"],
            "live"
        );
        let restart_receipt = fixture.receipt(&[
            "resource",
            "restart",
            &restart,
            "--expected-status",
            "live",
            "--action-id",
            "act-ops-restart",
            "--json",
        ]);
        assert_receipt(&restart_receipt, "restart", "completed");
        let restarted_pid = restart_receipt["result"]["observation"]["pid"]
            .as_u64()
            .unwrap() as u32;
        assert!(process_alive(restarted_pid));

        let detach = fixture.receipt(&[
            "resource",
            "detach",
            &terminal,
            "--expected-status",
            "live",
            "--action-id",
            "act-ops-detach",
            "--json",
        ]);
        assert_receipt(&detach, "detach", "completed");
        assert_eq!(detach["result"]["observation"]["status"], "detached");

        let cleanup_receipt = fixture.receipt(&[
            "resource",
            "cleanup",
            &cleanup,
            "--expected-status",
            "live",
            "--action-id",
            "act-ops-cleanup",
            "--json",
        ]);
        assert_receipt(&cleanup_receipt, "cleanup", "completed");
        assert_eq!(cleanup_receipt["result"]["observation"]["status"], "dead");
        fixture.owned_pids.iter().for_each(|pid| {
            if *pid == restarted_pid {
                let _ = Command::new("kill")
                    .arg(pid.to_string())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
            }
        });
        let _ = Command::new("kill")
            .arg(restarted_pid.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }

    #[test]
    fn unsupported_operations_are_canonical_rejections_and_expected_state_is_required() {
        let fixture = Fixture::new("capability-rejections");
        let discover = fixture.discover();
        let file = artifact_id(&discover, "ops-file");
        let external = resource_id(&discover, "ops-external");
        let external_pid = discover["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["resource"]["proposal_id"] == "ops-external")
            .unwrap()["resource"]["target"]["pid"]
            .as_u64()
            .unwrap() as u32;

        let missing_expected = command(
            &fixture.root,
            &fixture.binary,
            &[
                "resource",
                "stop",
                &external,
                "--action-id",
                "act-missing-expected-state",
                "--json",
            ],
        );
        assert!(!missing_expected.status.success());
        assert!(String::from_utf8_lossy(&missing_expected.stderr).contains("--expected-status"));
        assert!(process_alive(external_pid));

        for (operation, expected_status) in [
            ("attach", None),
            ("stop", Some("available")),
            ("restart", Some("available")),
            ("detach", Some("available")),
            ("cleanup", Some("available")),
            ("reconcile", Some("available")),
        ] {
            let action_id = format!("act-unsupported-{operation}");
            let mut args = vec!["resource", operation, file.as_str()];
            if let Some(expected_status) = expected_status {
                args.extend(["--expected-status", expected_status]);
            }
            args.extend(["--action-id", action_id.as_str(), "--json"]);
            let receipt = fixture.receipt(&args);
            assert_receipt(&receipt, operation, "rejected");
            assert!(receipt["error"].as_str().unwrap().contains("unsupported"));
            let terminal_event_id = receipt["result_event_ids"][1].as_str().unwrap();
            let terminal_event = channel_event(&fixture.root, terminal_event_id);
            assert_eq!(terminal_event["type"].as_str(), Some("action.rejected"));
        }
    }

    #[test]
    fn fresh_probe_and_identity_ownership_gates_prevent_false_live_and_external_kill() {
        let fixture = Fixture::new("lifecycle-gates");
        let discover = fixture.discover();
        let stop = resource_id(&discover, "ops-stop");
        let external = resource_id(&discover, "ops-external");
        let unknown = resource_id(&discover, "ops-unknown");
        let mismatch = resource_id(&discover, "ops-mismatch");
        let dead = resource_id(&discover, "ops-dead");
        let service = resource_id(&discover, "ops-service");
        let browser = resource_id(&discover, "ops-browser");
        let unrecoverable = resource_id(&discover, "ops-unrecoverable");
        let external_pid = discover["result"]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["resource"]["proposal_id"] == "ops-external")
            .unwrap()["resource"]["target"]["pid"]
            .as_u64()
            .unwrap() as u32;

        let rejected = fixture.receipt(&[
            "resource",
            "stop",
            &external,
            "--expected-status",
            "live",
            "--action-id",
            "act-external-stop",
            "--json",
        ]);
        assert_receipt(&rejected, "stop", "rejected");
        assert!(rejected["error"].as_str().unwrap().contains("ownership"));
        assert!(process_alive(external_pid));
        let unknown_rejected = fixture.receipt(&[
            "resource",
            "cleanup",
            &unknown,
            "--expected-status",
            "live",
            "--action-id",
            "act-unknown-cleanup",
            "--json",
        ]);
        assert_eq!(unknown_rejected["status"], "rejected");
        assert!(unknown_rejected["error"]
            .as_str()
            .unwrap()
            .contains("ownership"));
        assert!(process_alive(external_pid));

        let mismatch_probe = fixture.receipt(&[
            "resource",
            "reconcile",
            &mismatch,
            "--expected-status",
            "orphaned",
            "--action-id",
            "act-mismatch-probe",
            "--json",
        ]);
        assert_eq!(
            mismatch_probe["result"]["observation"]["status"],
            "orphaned"
        );
        let mismatch_stop = fixture.receipt(&[
            "resource",
            "stop",
            &mismatch,
            "--expected-status",
            "orphaned",
            "--action-id",
            "act-mismatch-stop",
            "--json",
        ]);
        assert_eq!(mismatch_stop["status"], "rejected");
        assert!(process_alive(external_pid));

        for (target, action, status) in [
            (&dead, "act-dead-probe", "dead"),
            (&service, "act-service-probe", "unavailable"),
            (&browser, "act-browser-probe", "expired"),
            (&unrecoverable, "act-unrecoverable-probe", "unrecoverable"),
        ] {
            let receipt = fixture.receipt(&[
                "resource",
                "reconcile",
                target,
                "--expected-status",
                status,
                "--action-id",
                action,
                "--json",
            ]);
            assert_eq!(receipt["result"]["observation"]["status"], status);
        }

        let stop_receipt = fixture.receipt(&[
            "resource",
            "stop",
            &stop,
            "--expected-status",
            "live",
            "--action-id",
            "act-owned-stop",
            "--json",
        ]);
        assert_receipt(&stop_receipt, "stop", "completed");
        assert_eq!(stop_receipt["result"]["observation"]["status"], "dead");

        let file = artifact_id(&discover, "ops-file");
        fs::remove_file(fixture.root.join("ops-file.txt")).unwrap();
        let missing = fixture.receipt(&[
            "resource",
            "open",
            &file,
            "--action-id",
            "act-missing-open",
            "--json",
        ]);
        assert_eq!(missing["result"]["entries"][0]["status"], "unavailable");
        assert_eq!(
            missing["result"]["open_target"]["target_type"],
            "unavailable"
        );
    }

    #[test]
    fn requested_and_post_terminate_crashes_recover_without_duplicate_signal() {
        let fixture = Fixture::new("action-crash-recovery");
        let discover = fixture.discover();
        let cleanup = resource_id(&discover, "ops-cleanup");
        let cleanup_pid = resource_pid(&discover, "ops-cleanup");
        let cleanup_args = [
            "resource",
            "cleanup",
            cleanup.as_str(),
            "--expected-status",
            "live",
            "--action-id",
            "act-crash-after-requested",
            "--json",
        ];

        let requested_crash =
            fixture.command_with_fault(&cleanup_args, "act-crash-after-requested:after_requested");
        assert_eq!(requested_crash.status.code(), Some(86));
        assert!(
            process_alive(cleanup_pid),
            "requested-only crash must happen before cleanup mutation"
        );
        let cleanup_receipt = fixture.receipt(&cleanup_args);
        assert_receipt(&cleanup_receipt, "cleanup", "completed");
        assert!(!process_alive(cleanup_pid));
        assert_eq!(cleanup_receipt, fixture.receipt(&cleanup_args));

        let restart = resource_id(&discover, "ops-restart");
        let restart_pid = resource_pid(&discover, "ops-restart");
        let prepared_args = [
            "resource",
            "restart",
            restart.as_str(),
            "--expected-status",
            "live",
            "--action-id",
            "act-crash-after-prepared",
            "--json",
        ];
        let prepared_crash =
            fixture.command_with_fault(&prepared_args, "act-crash-after-prepared:after_prepared");
        assert_eq!(prepared_crash.status.code(), Some(86));
        assert!(process_alive(restart_pid));
        let prepared_receipt = fixture.receipt(&prepared_args);
        assert_receipt(&prepared_receipt, "restart", "rejected");
        assert!(prepared_receipt["error"]
            .as_str()
            .unwrap()
            .contains("prepared"));
        assert!(
            process_alive(restart_pid),
            "ambiguous prepared-only recovery must not signal or spawn"
        );
        assert_eq!(prepared_receipt, fixture.receipt(&prepared_args));

        let stop = resource_id(&discover, "ops-stop");
        let stop_pid = resource_pid(&discover, "ops-stop");
        let stop_args = [
            "resource",
            "stop",
            stop.as_str(),
            "--expected-status",
            "live",
            "--action-id",
            "act-crash-after-terminate",
            "--json",
        ];
        let terminated_crash =
            fixture.command_with_fault(&stop_args, "act-crash-after-terminate:after_terminate");
        assert_eq!(terminated_crash.status.code(), Some(86));
        assert!(!process_alive(stop_pid));
        let recovery_path = fixture
            .root
            .join(".agents/resources/actions/act-crash-after-terminate.recovery.yaml");
        let recovery: YamlValue =
            serde_yaml_ng::from_str(&fs::read_to_string(recovery_path).unwrap()).unwrap();
        assert_eq!(recovery["phase"].as_str(), Some("terminated"));

        let stop_receipt = fixture.receipt(&stop_args);
        assert_receipt(&stop_receipt, "stop", "completed");
        assert_eq!(stop_receipt["result"]["observation"]["status"], "dead");
        assert_eq!(stop_receipt, fixture.receipt(&stop_args));
    }

    #[test]
    fn lifecycle_failures_terminalize_as_immutable_rejections() {
        let fixture = Fixture::new("action-failure-receipts");
        let discover = fixture.discover();
        let cases = [
            (
                "reconcile",
                resource_id(&discover, "ops-stop"),
                "live",
                "act-fail-probe",
                "probe",
            ),
            (
                "stop",
                resource_id(&discover, "ops-cleanup"),
                "live",
                "act-fail-terminate",
                "terminate",
            ),
            (
                "restart",
                resource_id(&discover, "ops-restart"),
                "live",
                "act-fail-spawn",
                "spawn",
            ),
            (
                "detach",
                resource_id(&discover, "ops-detach"),
                "live",
                "act-fail-receipt",
                "receipt",
            ),
        ];

        for (operation, target, expected, action_id, point) in cases {
            let args = [
                "resource",
                operation,
                target.as_str(),
                "--expected-status",
                expected,
                "--action-id",
                action_id,
                "--json",
            ];
            let output = fixture.command_with_fault(&args, &format!("{action_id}:{point}"));
            assert!(
                output.status.success(),
                "{point} failure must return its rejected receipt\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            let receipt: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_receipt(&receipt, operation, "rejected");
            assert!(receipt["error"].as_str().unwrap().contains(point));
            let terminal_event = channel_event(
                &fixture.root,
                receipt["result_event_ids"][1].as_str().unwrap(),
            );
            assert_eq!(terminal_event["type"].as_str(), Some("action.rejected"));
            let terminal_path = fixture
                .root
                .join(format!(".agents/resources/actions/{action_id}.yaml"));
            let terminal_before = fs::read(&terminal_path).unwrap();
            assert_eq!(receipt, fixture.receipt(&args));
            assert_eq!(terminal_before, fs::read(terminal_path).unwrap());
        }
    }

    #[test]
    fn spawn_before_recovery_crash_rejects_without_a_second_spawn() {
        let mut fixture = Fixture::new("spawn-before-recovery");
        let discover = fixture.discover();
        let restart = resource_id(&discover, "ops-restart");
        let original_pid = resource_pid(&discover, "ops-restart");
        let args = [
            "resource",
            "restart",
            restart.as_str(),
            "--expected-status",
            "live",
            "--action-id",
            "act-crash-after-spawn-before-recovery",
            "--json",
        ];

        let spawn_trace = fixture.root.join("spawn-gap-pid.txt");
        let crashed = fixture.command_with_fault_trace(
            &args,
            "act-crash-after-spawn-before-recovery:after_spawn_before_recovery",
            &spawn_trace,
        );
        let spawned_pids: Vec<u32> = fs::read_to_string(&spawn_trace)
            .unwrap()
            .lines()
            .map(|line| line.parse().unwrap())
            .collect();
        fixture.owned_pids.extend(spawned_pids.iter().copied());
        let spawn_log = fixture.root.join("restart-spawns.log");
        let spawn_log_before_retry = wait_for_nonempty_spawn_log(&spawn_log);

        assert_eq!(crashed.status.code(), Some(86));
        assert!(!process_alive(original_pid));
        assert_eq!(spawned_pids.len(), 1, "the interrupted action spawned once");
        assert_eq!(
            String::from_utf8(spawn_log_before_retry.clone()).unwrap(),
            format!("{}\n", spawned_pids[0])
        );
        assert!(process_alive(spawned_pids[0]));
        let recovery_path = fixture
            .root
            .join(".agents/resources/actions/act-crash-after-spawn-before-recovery.recovery.yaml");
        let recovery: YamlValue =
            serde_yaml_ng::from_str(&fs::read_to_string(recovery_path).unwrap()).unwrap();
        assert_eq!(recovery["phase"].as_str(), Some("terminated"));

        let spawn_trace_before_retry = fs::read(&spawn_trace).unwrap();
        let receipt = fixture.receipt(&args);
        assert_receipt(&receipt, "restart", "rejected");
        assert_eq!(receipt["result"]["observation"]["status"], "unrecoverable");
        assert!(receipt["error"]
            .as_str()
            .unwrap()
            .contains("terminated restart recovery"));
        assert_eq!(spawn_trace_before_retry, fs::read(&spawn_trace).unwrap());
        assert_eq!(spawn_log_before_retry, fs::read(&spawn_log).unwrap());
        assert!(process_alive(spawned_pids[0]));
        assert_eq!(receipt, fixture.receipt(&args));
        assert_eq!(spawn_trace_before_retry, fs::read(&spawn_trace).unwrap());
        assert_eq!(spawn_log_before_retry, fs::read(&spawn_log).unwrap());

        let reconcile = fixture.receipt(&[
            "resource",
            "reconcile",
            restart.as_str(),
            "--expected-status",
            "unrecoverable",
            "--action-id",
            "act-reconcile-spawn-gap",
            "--json",
        ]);
        assert_receipt(&reconcile, "reconcile", "rejected");
        assert!(reconcile["result"]["observation"].is_null());
        let inspect = fixture.receipt(&[
            "resource",
            "inspect",
            restart.as_str(),
            "--action-id",
            "act-inspect-spawn-gap",
            "--json",
        ]);
        assert_eq!(
            inspect["result"]["entries"][0]["last_observation"]["status"],
            "unrecoverable"
        );
    }
}
