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
/// Argument shapes are isolated here so a single adapter edit fixes flag drift
/// without touching orchestration. Verified against:
///   - Codex CLI 0.136 (`codex exec`, prompt read from stdin)
///   - Claude Code 2.1 (`claude -p`, prompt read from stdin)
///
/// Both are non-interactive and need write permission to produce the required
/// result/handoff artifacts:
///   - codex: `--sandbox workspace-write` bounds writes to the workspace.
///   - claude: `--permission-mode acceptEdits` allows edits without prompts.
#[allow(clippy::too_many_arguments)]
pub fn build_command(
    worker_id: &str,
    bin: &Path,
    run_dir: &Path,
    cwd: &Path,
    full_access: bool,
    model: &str,
    effort: &str,
    images: &[String],
) -> Command {
    let mut cmd = Command::new(bin);
    // The worker must be able to write its artifacts into the run directory.
    // Codex's workspace-write sandbox treats the hidden `.agents/` tree as
    // read-only, so the run dir is added as an explicit writable root.
    //
    // `full_access` is the explicit, opt-in escalation: it drops the sandbox so
    // the worker can reach the network, install packages, etc. Off by default.
    match worker_id {
        "codex" => {
            let sandbox = if full_access {
                "danger-full-access"
            } else {
                "workspace-write"
            };
            cmd.arg("exec")
                .arg("--sandbox")
                .arg(sandbox)
                .arg("--skip-git-repo-check");
            if !model.is_empty() {
                cmd.arg("-m").arg(model);
            }
            if !effort.is_empty() {
                cmd.arg("-c")
                    .arg(format!("model_reasoning_effort=\"{effort}\""));
            }
            // Attach images natively (codex vision), so Yard does not lose it.
            for img in images {
                cmd.arg("-i").arg(img);
            }
            cmd.arg("--add-dir").arg(run_dir);
        }
        "claude-code" => {
            if full_access {
                cmd.arg("-p").arg("--dangerously-skip-permissions");
            } else {
                cmd.arg("-p").arg("--permission-mode").arg("acceptEdits");
            }
            if !model.is_empty() {
                cmd.arg("--model").arg(model);
            }
            if !effort.is_empty() {
                cmd.arg("--effort").arg(effort);
            }
            cmd.arg("--add-dir").arg(run_dir);
        }
        _ => {}
    }
    cmd.current_dir(cwd);
    cmd.env_clear();
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
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    profile: &WorkerProfile,
    bin: &Path,
    packet: &str,
    cwd: &Path,
    env: &[(String, String)],
    output_log: &Path,
    timeout: Duration,
    full_access: bool,
    images: &[String],
) -> Result<WorkerOutcome> {
    use std::io::Write;

    let run_dir = output_log.parent().unwrap_or(cwd);
    let mut cmd = build_command(
        &profile.id,
        bin,
        run_dir,
        cwd,
        full_access,
        &profile.model,
        &profile.effort,
        images,
    );
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawning worker '{}'", bin.display()))?;

    if let Some(mut stdin) = child.stdin.take() {
        // Best-effort: a worker that ignores stdin will simply not receive it.
        let _ = stdin.write_all(packet.as_bytes());
    }

    // Stream stdout to the log file as it arrives so a Run Monitor can tail it
    // live, instead of capturing everything only after the worker exits.
    let stdout = child.stdout.take();
    let log_path = output_log.to_path_buf();
    let reader = thread::spawn(move || {
        use std::io::Read;
        let mut file = std::fs::File::create(&log_path).ok();
        if let Some(mut out) = stdout {
            let mut buf = [0u8; 4096];
            loop {
                match out.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if let Some(f) = file.as_mut() {
                            let _ = f.write_all(&buf[..n]);
                            let _ = f.flush();
                        }
                    }
                }
            }
        }
    });

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
    let _ = reader.join();

    // Append stderr (usually small / errors) once the worker has exited.
    if let Some(mut err) = child.stderr.take() {
        use std::io::Read;
        let mut e = String::new();
        let _ = err.read_to_string(&mut e);
        if !e.is_empty() {
            if let Ok(mut f) = std::fs::OpenOptions::new().append(true).open(output_log) {
                let _ = write!(f, "\n--- stderr ---\n{e}");
            }
        }
    }

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

#[cfg(test)]
mod tests {
    use super::*;

    fn args_of(cmd: &Command) -> Vec<String> {
        cmd.get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn codex_sandbox_toggles_with_full_access() {
        let (bin, run, cwd) = (Path::new("codex"), Path::new("/tmp/r"), Path::new("/tmp"));
        let safe = args_of(&build_command("codex", bin, run, cwd, false, "", "", &[]));
        assert!(safe.iter().any(|a| a == "workspace-write"));
        assert!(!safe.iter().any(|a| a == "danger-full-access"));
        let full = args_of(&build_command("codex", bin, run, cwd, true, "", "", &[]));
        assert!(full.iter().any(|a| a == "danger-full-access"));
    }

    #[test]
    fn claude_permission_toggles_with_full_access() {
        let (bin, run, cwd) = (Path::new("claude"), Path::new("/tmp/r"), Path::new("/tmp"));
        let safe = args_of(&build_command(
            "claude-code",
            bin,
            run,
            cwd,
            false,
            "",
            "",
            &[],
        ));
        assert!(safe.iter().any(|a| a == "acceptEdits"));
        let full = args_of(&build_command(
            "claude-code",
            bin,
            run,
            cwd,
            true,
            "",
            "",
            &[],
        ));
        assert!(full.iter().any(|a| a == "--dangerously-skip-permissions"));
    }

    #[test]
    fn model_and_effort_flags_passed() {
        let (bin, run, cwd) = (Path::new("x"), Path::new("/tmp/r"), Path::new("/tmp"));
        let cx = args_of(&build_command(
            "codex",
            bin,
            run,
            cwd,
            false,
            "gpt-5",
            "high",
            &[],
        ));
        assert!(cx.windows(2).any(|w| w[0] == "-m" && w[1] == "gpt-5"));
        assert!(cx
            .iter()
            .any(|a| a.contains("model_reasoning_effort=\"high\"")));
        let cl = args_of(&build_command(
            "claude-code",
            bin,
            run,
            cwd,
            false,
            "opus",
            "high",
            &[],
        ));
        assert!(cl.windows(2).any(|w| w[0] == "--model" && w[1] == "opus"));
        assert!(cl.windows(2).any(|w| w[0] == "--effort" && w[1] == "high"));
    }

    #[test]
    fn codex_attaches_images() {
        let (bin, run, cwd) = (Path::new("codex"), Path::new("/tmp/r"), Path::new("/tmp"));
        let imgs = vec!["a.png".to_string(), "b.jpg".to_string()];
        let cx = args_of(&build_command("codex", bin, run, cwd, false, "", "", &imgs));
        assert!(cx.windows(2).any(|w| w[0] == "-i" && w[1] == "a.png"));
        assert!(cx.windows(2).any(|w| w[0] == "-i" && w[1] == "b.jpg"));
    }
}
