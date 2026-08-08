//! End-to-end PTY integration for the TUI planning flow (YARD-014).
//!
//! A single isolated `yardlet` process, driven over a real pseudo-terminal,
//! must reproduce the whole intended shape in one run:
//!
//!   1. A slow recovery + worker `--version` probe keeps the first frames on the
//!      safe loading screen, and only *after* that slow startup does the app
//!      settle on the Home screen (we prove the startup was genuinely slow by
//!      timing the transition, not by trusting the loading text alone).
//!   2. A planning request is submitted from the multi-line New Work input with
//!      Ctrl+S; when the (fixture) planner finishes, the app transitions to the
//!      planning review screen on its own.
//!   3. With `language: ko` every Yardlet-owned label on that review screen is
//!      Korean.
//!   4. A multi-line revision is edited on the review screen with Enter=newline
//!      and submitted with Ctrl+S; the verbatim two-line request (newline and
//!      all) reaches the planner, proving Enter inserted a newline rather than
//!      submitting and that Ctrl+S — not a literal `s` — sent the revision.
//!
//! The planner is a deterministic shell fixture on a private PATH, so nothing
//! here needs a real worker CLI or network. Everything the fixture captures is
//! written under the workspace root (its own CWD), which the test inspects after
//! the process exits.

#![cfg(unix)]

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

mod common;

use common::{drain, open_pty, recent, seen, wait_for_marker};

/// Slow-recovery injection (debug + `YARDLET_PROCESS_FIXTURE=1` only). Big enough
/// that the loading screen is unmistakably shown before Home, small enough to
/// keep the test quick.
const RECOVERY_DELAY_MS: u64 = 800;

fn test_root() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before Unix epoch")
        .as_nanos();
    std::env::temp_dir().join(format!(
        "yard-tui-review-revision-{}-{nonce}",
        std::process::id()
    ))
}

/// A deterministic planning worker. `--version` sleeps briefly so the startup
/// probe is observably slow too; a planning turn records the verbatim packet it
/// received (keyed by an incrementing turn counter, both under the workspace
/// CWD) and emits a minimal valid planning result.
fn write_planner(path: &Path) {
    fs::write(
        path,
        "#!/usr/bin/env bash\n\
         set -euo pipefail\n\
         if [[ \"${1:-}\" == \"--version\" ]]; then\n\
         \x20 sleep 0.2\n\
         \x20 printf 'fixture-planner 1.0\\n'\n\
         \x20 exit 0\n\
         fi\n\
         run_dir=\"$1\"\n\
         packet=\"$(cat)\"\n\
         workspace=\"$(pwd)\"\n\
         counter=\"$workspace/.fixture-planning-turn\"\n\
         turn=0\n\
         [[ -f \"$counter\" ]] && turn=\"$(cat \"$counter\")\"\n\
         turn=$((turn + 1))\n\
         printf '%s' \"$turn\" >\"$counter\"\n\
         capture=\"$workspace/.fixture-capture\"\n\
         mkdir -p \"$capture\"\n\
         printf '%s' \"$packet\" >\"$capture/turn-$turn.md\"\n\
         mkdir -p \"$run_dir\"\n\
         cat >\"$run_dir/planning-result.json\" <<EOF\n\
         {\n\
         \x20 \"summary\": \"fixture turn $turn slice\",\n\
         \x20 \"rationale\": \"deterministic fixture turn $turn rationale\",\n\
         \x20 \"allowed_scope\": [\"tests/\"],\n\
         \x20 \"out_of_scope\": [\"src/ui/**\"],\n\
         \x20 \"acceptance\": [{\"id\": \"AC-001\", \"statement\": \"fixture proposal turn $turn\"}],\n\
         \x20 \"ambiguity\": {\"score\": \"low\", \"open_questions\": []},\n\
         \x20 \"tasks\": [{\n\
         \x20 \x20 \"id\": \"YARD-001\",\n\
         \x20 \x20 \"title\": \"fixture planning task turn $turn\",\n\
         \x20 \x20 \"kind\": \"implementation\",\n\
         \x20 \x20 \"risk\": \"low\",\n\
         \x20 \x20 \"preferred_worker\": \"fixture-planner\",\n\
         \x20 \x20 \"model\": \"auto\",\n\
         \x20 \x20 \"effort\": \"auto\",\n\
         \x20 \x20 \"depends_on\": [],\n\
         \x20 \x20 \"skills\": [],\n\
         \x20 \x20 \"required_capabilities\": [],\n\
         \x20 \x20 \"allowed_scope\": [\"tests/\"],\n\
         \x20 \x20 \"acceptance\": [\"fixture proposal turn $turn\"],\n\
         \x20 \x20 \"worker_rationale\": \"deterministic fixture\"\n\
         \x20 }],\n\
         \x20 \"questions_for_user\": []\n\
         }\n\
         EOF\n\
         printf 'fixture planning turn %s\\n' \"$turn\"\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(path).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).unwrap();
}

#[test]
fn slow_startup_then_ko_review_then_multiline_revision_over_one_pty() {
    let binary = PathBuf::from(env!("CARGO_BIN_EXE_yardlet"));
    // Removed even if an assertion below unwinds past the clean exit — the other
    // half of issue #64.
    let workspace = common::WorkspaceGuard::create(test_root());
    let root = workspace.path().to_path_buf();

    // Canonical workspace init, then pin the UI to Korean.
    let init = Command::new(&binary)
        .arg("init")
        .current_dir(&root)
        .output()
        .unwrap();
    assert!(
        init.status.success(),
        "yardlet init failed: {}",
        String::from_utf8_lossy(&init.stderr)
    );
    let config_path = root.join(".agents/yardlet.yaml");
    let config = fs::read_to_string(&config_path)
        .unwrap()
        .replace("language: auto", "language: ko");
    assert!(
        config.contains("language: ko"),
        "init config did not expose an editable language field"
    );
    fs::write(&config_path, config).unwrap();

    // Route planning at the deterministic fixture worker.
    let planner = root.join("fixture-planner.sh");
    write_planner(&planner);
    fs::write(
        root.join(".agents/workers.yaml"),
        format!(
            "schema_version: 1\n\
             workers:\n\
             \x20 - id: fixture-planner\n\
             \x20 \x20 kind: cli_worker\n\
             \x20 \x20 best_for: deterministic planning fixture\n\
             \x20 \x20 billing:\n\
             \x20 \x20 \x20 mode: subscription_backed_only\n\
             \x20 \x20 invocation:\n\
             \x20 \x20 \x20 command: {}\n\
             \x20 \x20 \x20 supports_noninteractive: true\n\
             \x20 \x20 \x20 output_contract: files\n\
             \x20 \x20 \x20 sandbox_args: ['--fixture-sandbox']\n\
             \x20 \x20 \x20 args: [\"{{run_dir}}\"]\n\
             \x20 \x20 limits:\n\
             \x20 \x20 \x20 max_wall_minutes: 1\n\
             \x20 \x20 \x20 max_retries: 0\n\
             routing:\n\
             \x20 default_worker: fixture-planner\n\
             \x20 fallback_order: [fixture-planner]\n\
             \x20 planning_gate:\n\
             \x20 \x20 primary: fixture-planner\n\
             \x20 \x20 fallback: \"\"\n",
            planner.display()
        ),
    )
    .unwrap();

    let (mut master, slave) = open_pty(40, 140);
    let stdin = Stdio::from(slave.try_clone().unwrap());
    let stdout = Stdio::from(slave.try_clone().unwrap());
    let stderr = Stdio::from(slave);
    let started = Instant::now();
    let child = Command::new(&binary)
        .current_dir(&root)
        .env("TERM", "xterm-256color")
        .env("YARDLET_PROCESS_FIXTURE", "1")
        .env(
            "YARDLET_FIXTURE_RECOVERY_DELAY_MS",
            RECOVERY_DELAY_MS.to_string(),
        )
        .stdin(stdin)
        .stdout(stdout)
        .stderr(stderr)
        .spawn()
        .unwrap();
    // Killed and reaped even if an assertion below unwinds past the clean quit
    // (issue #64).
    let mut child = common::ChildGuard::new(child);

    let mut sink: Vec<u8> = Vec::new();

    // 1) The safe loading screen is shown first (slow probe/recovery in flight).
    wait_for_marker(
        &mut master,
        &mut sink,
        "Yardlet 안전 시작 중",
        Duration::from_secs(3),
    );

    // 2) Only after the slow startup does the app land on Home. Timing the Home
    //    marker proves the transition really waited on recovery/probe.
    wait_for_marker(&mut master, &mut sink, "새작업", Duration::from_secs(20));
    let time_to_home = started.elapsed();
    assert!(
        time_to_home >= Duration::from_millis(600),
        "reached Home in {}ms — startup was not slowed by recovery/probe",
        time_to_home.as_millis()
    );

    // 3) Open New Work and submit an initial planning request with Ctrl+S.
    master.write_all(b"n").unwrap();
    wait_for_marker(
        &mut master,
        &mut sink,
        "작업을 몇 문장으로",
        Duration::from_secs(5),
    );
    master.write_all("INITIAL-PLAN-REQUEST".as_bytes()).unwrap();
    master.write_all(b"\x13").unwrap(); // Ctrl+S submit

    // 4) The finished planner transitions the app to the review screen on its
    //    own. Wait for a review-only footer key so the whole frame (content +
    //    footer) has been rendered, not just the title.
    wait_for_marker(&mut master, &mut sink, "플랜 검토", Duration::from_secs(20));
    wait_for_marker(&mut master, &mut sink, "e 수정", Duration::from_secs(10));

    // 5) Korean labels own the review chrome, content sections, and footer.
    for label in [
        "플랜 검토",      // bordered title
        "세션",           // session section
        "대화",           // conversation section
        "검토 대기 제안", // pending-proposal section
        "a 수락",         // footer: accept
        "s 시작",         // footer: singleton start
        "r 거절",         // footer: reject
        "e 수정",         // footer: revise
        "Esc/q 뒤로",     // footer: back
    ] {
        assert!(
            seen(&sink, label),
            "Korean review label {label:?} not visible; recent output:\n{}",
            recent(&sink)
        );
    }

    // 6) Enter revision edit mode and confirm the multi-line submit contract is
    //    what is offered (Enter=newline / Ctrl+S=send).
    master.write_all(b"e").unwrap();
    wait_for_marker(
        &mut master,
        &mut sink,
        "Ctrl+S 수정 요청 전송",
        Duration::from_secs(5),
    );

    // Type two lines separated by Enter, then submit with Ctrl+S. Both lines must
    // render on the review edit box (proving Enter produced a newline, not a
    // submit).
    master.write_all(b"REVLINE-TOP").unwrap();
    master.write_all(b"\r").unwrap(); // Enter = newline
    master.write_all(b"REVLINE-BOTTOM").unwrap();
    wait_for_marker(
        &mut master,
        &mut sink,
        "REVLINE-BOTTOM",
        Duration::from_secs(5),
    );
    assert!(
        seen(&sink, "REVLINE-TOP"),
        "first revision line vanished before submit — Enter did not insert a newline;\n{}",
        recent(&sink)
    );
    master.write_all(b"\x13").unwrap(); // Ctrl+S submit revision

    // 7) The verbatim two-line revision must reach the planner as a second turn.
    //
    // Wait on the CONTENT, not on the path existing: the fixture creates the file
    // and writes it in two steps, so an existence-only wait reads an empty string
    // and the assertion fails having observed nothing at all.
    let turn_two = root.join(".fixture-capture/turn-2.md");
    let verbatim = "REVLINE-TOP\nREVLINE-BOTTOM";
    if let Err(last) = common::wait_for_file_contents(
        &turn_two,
        Duration::from_secs(20),
        || drain(&mut master, &mut sink),
        |packet| packet.contains(verbatim),
    ) {
        panic!(
            "second planner packet did not carry the verbatim multi-line revision \
             within 20s;\nlast contents of {}:\n{last}\nrecent output:\n{}",
            turn_two.display(),
            recent(&sink)
        );
    }
    let turns = fs::read_to_string(root.join(".fixture-planning-turn")).unwrap();
    assert_eq!(
        turns.trim(),
        "2",
        "planner should have been invoked exactly twice (initial + revision)"
    );

    // Quit cleanly; fall back to a kill so a stuck child never hangs the suite.
    std::thread::sleep(Duration::from_millis(200));
    let _ = master.write_all(b"q");
    std::thread::sleep(Duration::from_millis(150));
    let _ = master.write_all(b"q");
    child.shutdown(Duration::from_secs(5), || drain(&mut master, &mut sink));
    // `workspace` removes the root on drop, on this path and on a panicking one.
}
