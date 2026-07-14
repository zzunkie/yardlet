#[cfg(unix)]
mod unix {
    use serde_json::Value;
    use std::collections::HashSet;
    use std::fs;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::os::unix::fs::PermissionsExt;
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Output, Stdio};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    const TASK_ID: &str = "YARD-LOCAL-APP";

    struct ExternalSentinel {
        child: Child,
        start_identity: String,
    }

    impl ExternalSentinel {
        fn spawn() -> Self {
            let child = Command::new("/bin/sleep")
                .arg("120")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn external sentinel");
            let start_identity = wait_for_identity(child.id());
            Self {
                child,
                start_identity,
            }
        }

        fn pid(&self) -> u32 {
            self.child.id()
        }

        fn is_alive(&self) -> bool {
            process_identity(self.pid()).as_deref() == Some(self.start_identity.as_str())
        }
    }

    impl Drop for ExternalSentinel {
        fn drop(&mut self) {
            if self.is_alive() {
                let _ = Command::new("kill").arg(self.pid().to_string()).status();
            }
            let _ = self.child.wait();
        }
    }

    struct Fixture {
        root: PathBuf,
        binary: PathBuf,
        owned_processes: Vec<(u32, String)>,
    }

    impl Fixture {
        fn new(sentinel: &ExternalSentinel) -> Self {
            let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
            let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock before Unix epoch")
                .as_nanos();
            let root = std::env::temp_dir().join(format!(
                "yardlet-v010-004-local-app-{}-{nonce}",
                std::process::id()
            ));
            fs::create_dir_all(&root).expect("create fixture workspace");

            must_succeed(&root, Path::new("git"), &["init", "-q"]);
            must_succeed(&root, Path::new("git"), &["config", "user.name", "fixture"]);
            must_succeed(
                &root,
                Path::new("git"),
                &["config", "user.email", "fixture@example.invalid"],
            );
            fs::write(root.join("README.md"), "local app fixture\n").unwrap();
            fs::write(root.join("app-state.txt"), "state=before\n").unwrap();
            fs::write(root.join("unrelated.txt"), "preserve me\n").unwrap();
            let port = reserve_local_port();
            let restart_healthy_port = reserve_local_port();
            let restart_unhealthy_port = reserve_local_port();
            fs::write(root.join("fixture-port.txt"), format!("{port}\n")).unwrap();
            fs::write(
                root.join("fixture-restart-healthy-port.txt"),
                format!("{restart_healthy_port}\n"),
            )
            .unwrap();
            fs::write(
                root.join("fixture-restart-unhealthy-port.txt"),
                format!("{restart_unhealthy_port}\n"),
            )
            .unwrap();
            fs::write(
                root.join("external-sentinel.meta"),
                format!("{}|{}\n", sentinel.pid(), sentinel.start_identity),
            )
            .unwrap();
            must_succeed(
                &root,
                Path::new("git"),
                &[
                    "add",
                    "README.md",
                    "app-state.txt",
                    "unrelated.txt",
                    "fixture-port.txt",
                    "fixture-restart-healthy-port.txt",
                    "fixture-restart-unhealthy-port.txt",
                    "external-sentinel.meta",
                ],
            );
            must_succeed(&root, Path::new("git"), &["commit", "-qm", "fixture"]);
            must_succeed(&root, &binary, &["init"]);

            let fixture_source = manifest.join("tests/fixtures/v010_004_local_app");
            let fixture_bin = root.join(".agents/fixture-bin");
            fs::create_dir_all(&fixture_bin).unwrap();
            let worker = copy_fixture(&fixture_source, &fixture_bin, "worker.sh");
            let app = copy_fixture(&fixture_source, &fixture_bin, "app.py");
            let capture = copy_fixture(&fixture_source, &fixture_bin, "capture_browser.py");
            let restart = copy_fixture(&fixture_source, &fixture_bin, "restart_app.sh");
            let mut permissions = fs::metadata(&worker).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&worker, permissions).unwrap();
            let mut permissions = fs::metadata(&restart).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(&restart, permissions).unwrap();

            let config_path = root.join(".agents/yardlet.yaml");
            let config = fs::read_to_string(&config_path)
                .unwrap()
                .replace("auto_commit: false", "auto_commit: true");
            fs::write(config_path, config).unwrap();
            fs::write(
                root.join(".agents/workers.yaml"),
                format!(
                    "schema_version: 1\nworkers:\n  - id: local-app-fixture\n    invocation:\n      command: \"{}\"\n      args: [\"{{run_dir}}\", \"{}\", \"{}\"]\n      supports_noninteractive: true\n      output_contract: files\n    limits:\n      max_wall_minutes: 2\n      max_retries: 0\nrouting:\n  default_worker: local-app-fixture\n  fallback_order: [local-app-fixture]\n",
                    worker.display(),
                    app.display(),
                    capture.display()
                ),
            )
            .unwrap();
            fs::write(
                root.join(".agents/intent-contract.yaml"),
                "schema_version: 1\nid: intent-local-app-dogfood\nsummary: local app resource dogfood\nstatus: accepted\n",
            )
            .unwrap();
            fs::write(
                root.join(".agents/work-queue.yaml"),
                "schema_version: 1\nqueue_id: queue-local-app-dogfood\nintent_id: intent-local-app-dogfood\ntasks:\n  - {id: YARD-LOCAL-APP, title: publish a real local app, state: queued, priority: 10, preferred_worker: local-app-fixture}\n",
            )
            .unwrap();

            Self {
                root,
                binary,
                owned_processes: Vec::new(),
            }
        }

        fn run_process(&self, args: &[&str]) -> (u32, Output) {
            let child = Command::new(&self.binary)
                .args(args)
                .current_dir(&self.root)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap_or_else(|error| panic!("failed to run yardlet {args:?}: {error}"));
            let pid = child.id();
            let output = child.wait_with_output().expect("wait for yardlet process");
            assert!(
                output.status.success(),
                "yardlet {args:?} failed\nstdout:\n{}\nstderr:\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            (pid, output)
        }

        fn json_process(&self, args: &[&str]) -> (u32, Value) {
            let (pid, output) = self.run_process(args);
            let value = serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
                panic!(
                    "invalid JSON from yardlet {args:?}: {error}\n{}",
                    String::from_utf8_lossy(&output.stdout)
                )
            });
            (pid, value)
        }

        fn run_process_with_fault(&self, args: &[&str], fault: &str) -> (u32, Output) {
            let child = Command::new(&self.binary)
                .args(args)
                .current_dir(&self.root)
                .env("YARDLET_TEST_RESOURCE_ACTION_FAULT", fault)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap_or_else(|error| panic!("failed to run yardlet with {fault}: {error}"));
            let pid = child.id();
            let output = child
                .wait_with_output()
                .expect("wait for faulted yardlet process");
            (pid, output)
        }

        fn remember_owned_process(&mut self, resource: &Value) {
            self.owned_processes.push((
                resource["target"]["pid"].as_u64().unwrap() as u32,
                resource["target"]["start_identity"]
                    .as_str()
                    .unwrap()
                    .to_string(),
            ));
        }

        fn remember_observation_process(&mut self, observation: &Value) {
            self.owned_processes.push((
                observation["pid"].as_u64().unwrap() as u32,
                observation["start_identity"].as_str().unwrap().to_string(),
            ));
        }

        fn diagnostic_logs(&self) -> String {
            let mut pending = vec![self.root.join(".agents")];
            let mut logs = String::new();
            while let Some(directory) = pending.pop() {
                let Ok(entries) = fs::read_dir(directory) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        pending.push(path);
                    } else if path.extension().and_then(|value| value.to_str()) == Some("log") {
                        logs.push_str(&format!("\n--- {} ---\n", path.display()));
                        logs.push_str(&fs::read_to_string(path).unwrap_or_default());
                    }
                }
            }
            logs
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            for (pid, identity) in &self.owned_processes {
                terminate_if_exact(*pid, identity);
            }
            if std::thread::panicking() {
                eprintln!(
                    "V010-004 local app evidence kept at {}",
                    self.root.display()
                );
                return;
            }
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn copy_fixture(source: &Path, target: &Path, name: &str) -> PathBuf {
        let destination = target.join(name);
        fs::copy(source.join(name), &destination)
            .unwrap_or_else(|error| panic!("copy fixture {name}: {error}"));
        destination
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
            "{} {args:?} failed\nstdout:\n{}\nstderr:\n{}",
            program.display(),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn reserve_local_port() -> u16 {
        TcpListener::bind(("127.0.0.1", 0))
            .expect("reserve local app port")
            .local_addr()
            .unwrap()
            .port()
    }

    fn process_identity(pid: u32) -> Option<String> {
        let output = Command::new("ps")
            .args(["-o", "lstart=", "-p", &pid.to_string()])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let identity = String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        (!identity.is_empty()).then_some(identity)
    }

    fn wait_for_identity(pid: u32) -> String {
        for _ in 0..50 {
            if let Some(identity) = process_identity(pid) {
                return identity;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("process {pid} never exposed a start identity");
    }

    fn process_group(pid: u32) -> Option<u32> {
        let output = Command::new("ps")
            .args(["-o", "pgid=", "-p", &pid.to_string()])
            .output()
            .ok()?;
        output.status.success().then(|| {
            String::from_utf8_lossy(&output.stdout)
                .trim()
                .parse()
                .expect("numeric process group")
        })
    }

    fn terminate_if_exact(pid: u32, identity: &str) {
        if process_identity(pid).as_deref() != Some(identity) {
            return;
        }
        let _ = Command::new("kill").arg(pid.to_string()).status();
        for _ in 0..50 {
            if process_identity(pid).is_none() {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn digest_bytes(bytes: &[u8]) -> String {
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("fnv1a64:{hash:016x}")
    }

    fn entry_by_proposal<'a>(receipt: &'a Value, proposal_id: &str) -> &'a Value {
        receipt["result"]["entries"]
            .as_array()
            .expect("discover entries")
            .iter()
            .find(|entry| {
                entry["artifact"]["proposal_id"].as_str() == Some(proposal_id)
                    || entry["resource"]["proposal_id"].as_str() == Some(proposal_id)
            })
            .unwrap_or_else(|| panic!("missing proposal {proposal_id}: {receipt}"))
    }

    fn artifact_id(entry: &Value) -> &str {
        entry["artifact"]["artifact_id"].as_str().unwrap()
    }

    fn resource_id(entry: &Value) -> &str {
        entry["resource"]["resource_id"].as_str().unwrap()
    }

    fn assert_core_record(
        entry: &Value,
        proposal_id: &str,
        attempt_id: &mut Option<String>,
    ) -> String {
        let record = entry.get("artifact").unwrap_or(&entry["resource"]);
        assert_eq!(record["proposal_id"], proposal_id);
        assert_eq!(record["task_id"], TASK_ID);
        assert_eq!(record["producer"]["worker_id"], "local-app-fixture");
        let actual_attempt = record["attempt_id"].as_str().unwrap();
        assert!(!actual_attempt.is_empty());
        let causation_id = record["causation_id"].as_str().unwrap();
        assert!(causation_id.starts_with("evt_"));
        assert_ne!(causation_id, actual_attempt);
        if let Some(expected) = attempt_id {
            assert_eq!(actual_attempt, expected);
        } else {
            *attempt_id = Some(actual_attempt.to_string());
        }
        let canonical_id = record["artifact_id"]
            .as_str()
            .or_else(|| record["resource_id"].as_str())
            .unwrap();
        assert!(!canonical_id.is_empty());
        assert_ne!(canonical_id, proposal_id);
        assert!(!record["created_event_id"].as_str().unwrap().is_empty());
        canonical_id.to_string()
    }

    fn reconcile(
        fixture: &Fixture,
        target_id: &str,
        expected_status: &str,
        action_id: &str,
    ) -> Value {
        fixture
            .json_process(&[
                "resource",
                "reconcile",
                target_id,
                "--expected-status",
                expected_status,
                "--action-id",
                action_id,
                "--json",
            ])
            .1
    }

    fn http_get(url: &str) -> String {
        let authority = url
            .strip_prefix("http://")
            .expect("fixture URL must use HTTP")
            .split('/')
            .next()
            .unwrap();
        let mut stream = TcpStream::connect(authority).expect("connect to local app");
        stream
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        response
    }

    #[test]
    fn real_local_app_publication_survives_restart_and_expires_honestly() {
        let sentinel = ExternalSentinel::spawn();
        let mut fixture = Fixture::new(&sentinel);

        let (publisher_pid, publisher) =
            fixture.run_process(&["run", "--task", TASK_ID, "--execute"]);
        let publisher_output = String::from_utf8_lossy(&publisher.stdout);
        assert!(
            publisher_output.contains("evaluation status: done"),
            "local app worker did not pass evaluation\nstdout:\n{publisher_output}\nstderr:\n{}\nlogs:{}",
            String::from_utf8_lossy(&publisher.stderr),
            fixture.diagnostic_logs()
        );
        let (discover_pid, discover) = fixture.json_process(&[
            "resource",
            "discover",
            "--intent",
            "intent-local-app-dogfood",
            "--task",
            TASK_ID,
            "--action-id",
            "act-local-app-discover-after-restart",
            "--json",
        ]);
        assert_ne!(
            publisher_pid, discover_pid,
            "query must run after process restart"
        );
        assert_eq!(discover["status"], "completed");

        let proposals = [
            "local-terminal",
            "local-process",
            "local-service",
            "local-unhealthy-service",
            "local-restart-service",
            "local-unhealthy-restart-service",
            "local-open-only-browser",
            "local-browser",
            "local-live-browser",
            "local-stale-browser",
            "local-external",
            "local-screenshot",
            "local-diff",
            "local-validation",
        ];
        let mut attempt_id = None;
        let mut canonical_ids = HashSet::new();
        for proposal in proposals {
            let canonical_id = assert_core_record(
                entry_by_proposal(&discover, proposal),
                proposal,
                &mut attempt_id,
            );
            assert!(canonical_ids.insert(canonical_id));
        }
        assert_eq!(canonical_ids.len(), proposals.len());

        let screenshot = entry_by_proposal(&discover, "local-screenshot");
        assert_eq!(screenshot["status"], "available");
        assert_eq!(screenshot["artifact"]["role"], "screenshot");
        assert_eq!(screenshot["artifact"]["media_type"], "image/png");
        let screenshot_path = PathBuf::from(
            screenshot["open_target"]["path"]
                .as_str()
                .expect("retained screenshot path"),
        );
        let screenshot_bytes = fs::read(&screenshot_path).expect("read retained screenshot");
        assert!(screenshot_bytes.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert!(
            screenshot_bytes.len() > 1_000,
            "screenshot must contain rendered pixels"
        );
        assert_eq!(
            screenshot["artifact"]["digest"],
            digest_bytes(&screenshot_bytes)
        );

        let diff = entry_by_proposal(&discover, "local-diff");
        assert_eq!(diff["status"], "available");
        assert_eq!(diff["artifact"]["role"], "git_diff");
        let diff_bytes = fs::read(diff["open_target"]["path"].as_str().unwrap()).unwrap();
        assert!(String::from_utf8_lossy(&diff_bytes).contains("+state=after"));
        assert_eq!(diff["artifact"]["digest"], digest_bytes(&diff_bytes));

        let process = entry_by_proposal(&discover, "local-process");
        let service = entry_by_proposal(&discover, "local-service");
        let unhealthy_service = entry_by_proposal(&discover, "local-unhealthy-service");
        let restart_service = entry_by_proposal(&discover, "local-restart-service");
        let unhealthy_restart_service =
            entry_by_proposal(&discover, "local-unhealthy-restart-service");
        let open_only_browser = entry_by_proposal(&discover, "local-open-only-browser");
        let browser = entry_by_proposal(&discover, "local-browser");
        let live_browser = entry_by_proposal(&discover, "local-live-browser");
        let stale_browser = entry_by_proposal(&discover, "local-stale-browser");
        let terminal = entry_by_proposal(&discover, "local-terminal");
        let external = entry_by_proposal(&discover, "local-external");
        assert_eq!(process["resource"]["target"]["kind"], "process");
        assert_eq!(service["resource"]["target"]["kind"], "service");
        assert_eq!(browser["resource"]["target"]["kind"], "browser");
        assert_eq!(terminal["resource"]["target"]["kind"], "terminal");
        for entry in [
            process,
            service,
            unhealthy_service,
            restart_service,
            unhealthy_restart_service,
            open_only_browser,
            browser,
            live_browser,
            stale_browser,
        ] {
            assert!(
                !entry["resource"]["capabilities"]
                    .as_array()
                    .expect("typed resource capabilities")
                    .is_empty(),
                "runtime declaration must record typed capabilities: {entry}"
            );
        }
        fixture.remember_owned_process(&process["resource"]);
        fixture.remember_owned_process(&restart_service["resource"]);
        fixture.remember_owned_process(&unhealthy_restart_service["resource"]);
        let service_url = service["resource"]["target"]["url"].as_str().unwrap();
        assert!(http_get(service_url).contains("yardlet-local-app"));

        let live_process = reconcile(
            &fixture,
            resource_id(process),
            "live",
            "act-local-app-reconcile-process-live",
        );
        assert_eq!(live_process["result"]["observation"]["status"], "live");
        assert_eq!(live_process["result"]["observation"]["current"], true);
        let live_service = reconcile(
            &fixture,
            resource_id(service),
            "live",
            "act-local-app-reconcile-service-live",
        );
        assert_eq!(live_service["result"]["observation"]["status"], "live");
        let expired_browser = reconcile(
            &fixture,
            resource_id(browser),
            "expired",
            "act-local-app-reconcile-browser-expired",
        );
        assert_eq!(
            expired_browser["result"]["observation"]["status"],
            "expired"
        );
        let live_browser_receipt = reconcile(
            &fixture,
            resource_id(live_browser),
            "live",
            "act-local-app-reconcile-browser-live-session",
        );
        assert_eq!(
            live_browser_receipt["result"]["observation"]["status"],
            "live"
        );
        let stale_browser_receipt = reconcile(
            &fixture,
            resource_id(stale_browser),
            "expired",
            "act-local-app-reconcile-browser-stale-session",
        );
        assert_eq!(
            stale_browser_receipt["result"]["observation"]["status"],
            "expired"
        );
        let unhealthy_service_receipt = reconcile(
            &fixture,
            resource_id(unhealthy_service),
            "unavailable",
            "act-local-app-reconcile-service-unhealthy",
        );
        assert_eq!(
            unhealthy_service_receipt["result"]["observation"]["status"], "unavailable",
            "an open port with a failing declared health URL is not live"
        );

        let healthy_restart_args = [
            "resource",
            "restart",
            resource_id(restart_service),
            "--expected-status",
            "live",
            "--action-id",
            "act-local-app-restart-crash-after-spawn",
            "--json",
        ];
        let (_, healthy_restart_crash) = fixture.run_process_with_fault(
            &healthy_restart_args,
            "act-local-app-restart-crash-after-spawn:after_spawn",
        );
        assert_eq!(healthy_restart_crash.status.code(), Some(86));
        let restart_recovery: Value = serde_yaml_ng::from_str(
            &fs::read_to_string(fixture.root.join(
                ".agents/resources/actions/act-local-app-restart-crash-after-spawn.recovery.yaml",
            ))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(restart_recovery["phase"], "spawned");
        let spawned_pid = restart_recovery["effect_pid"].as_u64().unwrap() as u32;
        let spawned_identity = restart_recovery["effect_start_identity"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(
            process_group(spawned_pid),
            Some(spawned_pid),
            "restarted resources must survive orchestrator process-group exit"
        );
        fixture
            .owned_processes
            .push((spawned_pid, spawned_identity.clone()));
        let (_, healthy_restart) = fixture.json_process(&healthy_restart_args);
        assert_eq!(
            healthy_restart["status"],
            "completed",
            "unexpected restart recovery receipt: {healthy_restart}\nlogs:{}",
            fixture.diagnostic_logs()
        );
        assert_eq!(healthy_restart["result"]["observation"]["status"], "live");
        assert_eq!(
            healthy_restart["result"]["observation"]["pid"], spawned_pid,
            "recovery must not spawn a second service process"
        );
        assert_eq!(
            healthy_restart,
            fixture.json_process(&healthy_restart_args).1
        );

        let unhealthy_restart_args = [
            "resource",
            "restart",
            resource_id(unhealthy_restart_service),
            "--expected-status",
            "unavailable",
            "--action-id",
            "act-local-app-unhealthy-restart-terminal-crash",
            "--json",
        ];
        let (_, unhealthy_terminal_crash) = fixture.run_process_with_fault(
            &unhealthy_restart_args,
            "act-local-app-unhealthy-restart-terminal-crash:after_terminal_event",
        );
        assert_eq!(unhealthy_terminal_crash.status.code(), Some(86));
        let (_, unhealthy_restart) = fixture.json_process(&unhealthy_restart_args);
        assert_eq!(unhealthy_restart["status"], "rejected");
        assert_eq!(
            unhealthy_restart["result"]["observation"]["status"], "unavailable",
            "a restarted process is not live until its declared health URL is 2xx"
        );
        let unhealthy_spawned_pid = unhealthy_restart["result"]["observation"]["pid"]
            .as_u64()
            .unwrap() as u32;
        fixture.remember_observation_process(&unhealthy_restart["result"]["observation"]);
        let unhealthy_reconcile = reconcile(
            &fixture,
            resource_id(unhealthy_restart_service),
            "unavailable",
            "act-local-app-reconcile-unhealthy-restart",
        );
        assert_eq!(unhealthy_reconcile["status"], "completed");
        assert_eq!(
            unhealthy_reconcile["result"]["observation"]["status"],
            "unavailable"
        );
        assert_eq!(
            unhealthy_reconcile["result"]["observation"]["pid"], unhealthy_spawned_pid,
            "reconcile must retain the restarted process identity even when health is unavailable"
        );
        let (_, unhealthy_cleanup) = fixture.json_process(&[
            "resource",
            "cleanup",
            resource_id(unhealthy_restart_service),
            "--expected-status",
            "unavailable",
            "--action-id",
            "act-local-app-cleanup-unhealthy-restart",
            "--json",
        ]);
        assert_eq!(unhealthy_cleanup["status"], "completed");
        assert_eq!(unhealthy_cleanup["result"]["observation"]["status"], "dead");
        assert_eq!(
            unhealthy_cleanup["result"]["observation"]["pid"],
            unhealthy_spawned_pid
        );
        assert!(
            process_identity(unhealthy_spawned_pid).is_none(),
            "cleanup must signal the current unhealthy restart process"
        );
        for (operation, action_id) in [
            ("stop", "act-local-app-reject-pidless-service-stop"),
            ("cleanup", "act-local-app-reject-pidless-service-cleanup"),
        ] {
            let (_, rejected) = fixture.json_process(&[
                "resource",
                operation,
                resource_id(unhealthy_service),
                "--expected-status",
                "unavailable",
                "--action-id",
                action_id,
                "--json",
            ]);
            assert_eq!(rejected["status"], "rejected");
            assert!(rejected["error"].as_str().unwrap().contains("unsupported"));
        }
        for operation in [
            "attach",
            "stop",
            "restart",
            "detach",
            "cleanup",
            "reconcile",
        ] {
            let action_id = format!("act-local-app-reject-open-only-{operation}");
            let mut args = vec!["resource", operation, resource_id(open_only_browser)];
            if operation != "attach" {
                args.extend(["--expected-status", "expired"]);
            }
            args.extend(["--action-id", action_id.as_str(), "--json"]);
            let (_, rejected) = fixture.json_process(&args);
            assert_eq!(rejected["status"], "rejected");
            assert!(rejected["error"].as_str().unwrap().contains("unsupported"));
        }
        let dead_terminal = reconcile(
            &fixture,
            resource_id(terminal),
            "dead",
            "act-local-app-reconcile-terminal-dead",
        );
        assert_eq!(dead_terminal["result"]["observation"]["status"], "dead");

        let (_, inspect_after_probe) = fixture.json_process(&[
            "resource",
            "inspect",
            resource_id(process),
            "--action-id",
            "act-local-app-inspect-last-observed",
            "--json",
        ]);
        assert_eq!(
            inspect_after_probe["result"]["entries"][0]["status"],
            "unknown"
        );
        assert_eq!(
            inspect_after_probe["result"]["entries"][0]["last_observation"]["status"],
            "live"
        );

        let validation = entry_by_proposal(&discover, "local-validation");
        let validation_path = PathBuf::from(validation["open_target"]["path"].as_str().unwrap());
        let validation_bytes = fs::read(&validation_path).unwrap();
        let validation_json: Value = serde_json::from_slice(&validation_bytes).unwrap();
        assert_eq!(validation_json["page_status"], 200);
        assert_eq!(validation_json["health_status"], 200);
        assert_eq!(validation_json["marker"], "yardlet-local-app");
        assert_eq!(
            validation["artifact"]["digest"],
            digest_bytes(&validation_bytes)
        );
        fs::remove_file(&validation_path).expect("remove exact validation artifact");
        let (_, missing_validation) = fixture.json_process(&[
            "resource",
            "open",
            artifact_id(validation),
            "--action-id",
            "act-local-app-open-missing-validation",
            "--json",
        ]);
        assert_eq!(
            missing_validation["result"]["entries"][0]["status"],
            "unavailable"
        );
        assert_eq!(
            missing_validation["result"]["open_target"]["target_type"],
            "unavailable"
        );

        let (_, rejected_external_cleanup) = fixture.json_process(&[
            "resource",
            "cleanup",
            resource_id(external),
            "--expected-status",
            "live",
            "--action-id",
            "act-local-app-reject-external-cleanup",
            "--json",
        ]);
        assert_eq!(rejected_external_cleanup["status"], "rejected");
        assert!(rejected_external_cleanup["error"]
            .as_str()
            .unwrap()
            .contains("ownership"));
        assert!(
            sentinel.is_alive(),
            "external process must not be signalled"
        );

        let (_, cleanup) = fixture.json_process(&[
            "resource",
            "cleanup",
            resource_id(process),
            "--expected-status",
            "live",
            "--action-id",
            "act-local-app-cleanup-owned-process",
            "--json",
        ]);
        assert_eq!(cleanup["status"], "completed");
        assert_eq!(cleanup["result"]["observation"]["status"], "dead");
        let unavailable_service = reconcile(
            &fixture,
            resource_id(service),
            "unavailable",
            "act-local-app-reconcile-service-unavailable",
        );
        assert_eq!(
            unavailable_service["result"]["observation"]["status"],
            "unavailable"
        );
        assert_eq!(
            fs::read_to_string(fixture.root.join("unrelated.txt")).unwrap(),
            "preserve me\n"
        );
        assert!(sentinel.is_alive());

        drop(fixture);
        assert!(
            sentinel.is_alive(),
            "fixture teardown must preserve external sentinel"
        );
    }
}
