//! Worker engines.
//!
//! Workers are interchangeable CLI engines behind one contract:
//!
//! ```text
//! task packet in -> worker subprocess -> structured result files out
//! ```
//!
//! Yard treats Codex CLI and Claude Code CLI as hidden, subscription-backed
//! workers. The exact CLI flags are adapter-owned here so business logic does
//! not hard-code brittle host assumptions.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::schemas::WorkerProfile;

/// How a given worker turns a packet file into a subprocess command.
///
/// NOTE: these argument shapes are a first, unverified mapping of the Codex and
/// Claude Code non-interactive CLIs. They are intentionally isolated here so a
/// single adapter edit fixes flag drift without touching orchestration. Verify
/// against the installed CLI versions before relying on a live round trip.
pub fn build_command(profile: &WorkerProfile, packet_path: &Path, cwd: &Path) -> Command {
    let bin = &profile.invocation.command;
    let mut cmd = Command::new(bin);
    match profile.id.as_str() {
        "codex" => {
            // codex exec runs non-interactively; the prompt is read from stdin.
            cmd.arg("exec");
        }
        "claude-code" => {
            // claude -p prints a single non-interactive response.
            cmd.arg("-p");
        }
        _ => {}
    }
    cmd.current_dir(cwd);
    cmd.env_clear();
    let _ = packet_path; // packet is fed via stdin by the caller
    cmd
}

#[derive(Debug, Clone)]
pub struct WorkerOutcome {
    pub exit_ok: bool,
    pub timed_out: bool,
    pub note: String,
}

/// Spawn a worker with a sanitized environment, feeding the packet on stdin and
/// capturing all output to `output_log`. Enforces a wall-clock timeout.
///
/// This is the only place Yard launches a worker. It uses the env produced by
/// the zero-key guard; it never injects an AI provider API key.
pub fn spawn(
    profile: &WorkerProfile,
    packet: &str,
    cwd: &Path,
    env: &[(String, String)],
    output_log: &Path,
    timeout: Duration,
) -> Result<WorkerOutcome> {
    use std::io::Write;

    let packet_path = output_log.with_file_name("task-packet.md");
    let mut cmd = build_command(profile, &packet_path, cwd);
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawning worker '{}'", profile.invocation.command))?;

    if let Some(mut stdin) = child.stdin.take() {
        // Best-effort: a worker that ignores stdin will simply not receive it.
        let _ = stdin.write_all(packet.as_bytes());
    }

    let start = Instant::now();
    let mut timed_out = false;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            timed_out = true;
            break child.wait()?;
        }
        thread::sleep(Duration::from_millis(200));
    };

    // Capture whatever the worker emitted.
    let mut log = String::new();
    if let Some(mut out) = child.stdout.take() {
        use std::io::Read;
        let _ = out.read_to_string(&mut log);
    }
    if let Some(mut err) = child.stderr.take() {
        use std::io::Read;
        let mut e = String::new();
        let _ = err.read_to_string(&mut e);
        if !e.is_empty() {
            log.push_str("\n--- stderr ---\n");
            log.push_str(&e);
        }
    }
    std::fs::write(output_log, &log).ok();

    Ok(WorkerOutcome {
        exit_ok: status.success() && !timed_out,
        timed_out,
        note: if timed_out {
            "worker exceeded wall-clock limit and was stopped".to_string()
        } else {
            format!("worker exited (success={})", status.success())
        },
    })
}

/// The packet file path inside a run directory.
pub fn packet_path(run_dir: &Path) -> PathBuf {
    run_dir.join("task-packet.md")
}
