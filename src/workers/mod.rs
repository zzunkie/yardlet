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

/// A model/effort value counts as explicit only when it is set and is not the
/// "auto" sentinel. Empty or "auto" means: omit the flag and let the worker CLI
/// choose (its own default / automatic selection).
fn explicit(v: &str) -> bool {
    !v.trim().is_empty() && !v.eq_ignore_ascii_case("auto")
}

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
                .arg("--skip-git-repo-check")
                .arg("--json"); // stream events as JSONL for the live monitor
            if explicit(model) {
                cmd.arg("-m").arg(model);
            }
            if explicit(effort) {
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
            // Stream events as JSONL so the live monitor shows progress.
            cmd.arg("--output-format")
                .arg("stream-json")
                .arg("--verbose");
            if explicit(model) {
                cmd.arg("--model").arg(model);
            }
            if explicit(effort) {
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

/// Build the command to RESUME an existing worker session (continue, not redo).
/// claude: `-p --resume <id>`; codex: `exec resume <id> -` (prompt on stdin).
/// Note: codex `resume` has no `--sandbox`/`--add-dir`; full-access bypasses the
/// sandbox, and a sandboxed session inherits its original writable roots.
#[allow(clippy::too_many_arguments)]
fn build_resume_command(
    worker_id: &str,
    bin: &Path,
    run_dir: &Path,
    cwd: &Path,
    full_access: bool,
    model: &str,
    images: &[String],
    session: Option<&str>,
) -> Command {
    let mut cmd = Command::new(bin);
    match worker_id {
        "codex" => {
            cmd.arg("exec").arg("resume");
            if full_access {
                cmd.arg("--dangerously-bypass-approvals-and-sandbox");
            }
            cmd.arg("--skip-git-repo-check");
            if explicit(model) {
                cmd.arg("-m").arg(model);
            }
            for img in images {
                cmd.arg("-i").arg(img);
            }
            if let Some(id) = session {
                cmd.arg(id);
            }
            cmd.arg("-"); // continuation prompt on stdin
        }
        "claude-code" => {
            if full_access {
                cmd.arg("-p").arg("--dangerously-skip-permissions");
            } else {
                cmd.arg("-p").arg("--permission-mode").arg("acceptEdits");
            }
            if let Some(id) = session {
                cmd.arg("--resume").arg(id);
            }
            if explicit(model) {
                cmd.arg("--model").arg(model);
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
    session: Option<&str>,
    resume: bool,
) -> Result<WorkerOutcome> {
    use std::io::{Read, Write};

    let run_dir = output_log.parent().unwrap_or(cwd);
    let mut cmd = if resume {
        build_resume_command(
            &profile.id,
            bin,
            run_dir,
            cwd,
            full_access,
            &profile.model,
            images,
            session,
        )
    } else {
        let mut c = build_command(
            &profile.id,
            bin,
            run_dir,
            cwd,
            full_access,
            &profile.model,
            &profile.effort,
            images,
        );
        // Set a stable session id on a fresh claude run so a transient failure
        // can resume the same conversation instead of redoing the work.
        if profile.id == "claude-code" {
            if let Some(id) = session {
                c.arg("--session-id").arg(id);
            }
        }
        c
    };
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawning worker '{}'", bin.display()))?;

    // Record the worker PID so the TUI can stop it (Esc) by killing the process.
    let pid_path = run_dir.join("worker.pid");
    let _ = std::fs::write(&pid_path, child.id().to_string());

    if let Some(mut stdin) = child.stdin.take() {
        // Best-effort: a worker that ignores stdin will simply not receive it.
        let _ = stdin.write_all(packet.as_bytes());
    }

    // Stream BOTH stdout and stderr to the log as they arrive, so a Run Monitor
    // can tail the worker live. Worker CLIs often route progress to stderr or
    // block-buffer stdout on a pipe, so capturing stderr live (not only after
    // exit) is what keeps the monitor non-empty during a run.
    let log_file = std::sync::Arc::new(std::sync::Mutex::new(
        std::fs::File::create(output_log).ok(),
    ));
    let mut sources: Vec<Box<dyn Read + Send>> = Vec::new();
    if let Some(o) = child.stdout.take() {
        sources.push(Box::new(o));
    }
    if let Some(e) = child.stderr.take() {
        sources.push(Box::new(e));
    }
    let readers: Vec<_> = sources
        .into_iter()
        .map(|mut src| {
            let log = std::sync::Arc::clone(&log_file);
            thread::spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    match src.read(&mut buf) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if let Ok(mut guard) = log.lock() {
                                if let Some(f) = guard.as_mut() {
                                    let _ = f.write_all(&buf[..n]);
                                    let _ = f.flush();
                                }
                            }
                        }
                    }
                }
            })
        })
        .collect();

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
    for r in readers {
        let _ = r.join();
    }
    let _ = std::fs::remove_file(&pid_path);

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

/// Claude Code model choices: the CLI's documented aliases ("" = CLI default).
/// Full model ids are accepted too — these are just the Space-cycle presets.
pub fn known_claude_models() -> Vec<String> {
    ["", "fable", "opus", "sonnet", "haiku"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// Codex model choices, discovered from the machine itself: the configured
/// default in ~/.codex/config.toml plus model ids seen in recent codex
/// session rollouts. There is no non-interactive `codex models` listing, and
/// hardcoding ids would rot — the local history is the freshest source.
pub fn known_codex_models() -> Vec<String> {
    let mut out: Vec<String> = vec![String::new()]; // "" = CLI default
    let home = std::env::var_os("HOME").map(PathBuf::from);

    // The configured default first.
    if let Some(h) = &home {
        if let Ok(cfg) = std::fs::read_to_string(h.join(".codex/config.toml")) {
            if let Some(m) = cfg.lines().find_map(|l| {
                l.trim()
                    .strip_prefix("model")
                    .and_then(|r| r.trim_start().strip_prefix('='))
                    .map(|v| v.trim().trim_matches('"').to_string())
            }) {
                if !m.is_empty() && !out.contains(&m) {
                    out.push(m);
                }
            }
        }
    }

    // Then ids seen in the most recent session rollouts (newest first).
    if let Some(h) = &home {
        let mut files: Vec<(std::time::SystemTime, PathBuf)> = Vec::new();
        fn walk(dir: &Path, files: &mut Vec<(std::time::SystemTime, PathBuf)>) {
            let Ok(rd) = std::fs::read_dir(dir) else {
                return;
            };
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    walk(&p, files);
                } else if p.extension().is_some_and(|x| x == "jsonl") {
                    if let Ok(mt) = e.metadata().and_then(|m| m.modified()) {
                        files.push((mt, p));
                    }
                }
            }
        }
        walk(&h.join(".codex/sessions"), &mut files);
        files.sort_by_key(|(mt, _)| std::cmp::Reverse(*mt));
        for (_, p) in files.into_iter().take(100) {
            let Ok(head) = read_head(&p, 32 * 1024) else {
                continue;
            };
            for m in extract_models(&head) {
                if !out.contains(&m) {
                    out.push(m);
                }
            }
            if out.len() > 8 {
                break; // plenty of presets; free text covers the rest
            }
        }
    }
    out
}

fn read_head(path: &Path, max: usize) -> std::io::Result<String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)?;
    let mut buf = vec![0u8; max];
    let n = f.read(&mut buf)?;
    buf.truncate(n);
    Ok(String::from_utf8_lossy(&buf).into_owned())
}

/// Pull every `"model":"<id>"` value out of a JSONL fragment.
fn extract_models(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let needle = "\"model\":\"";
    let mut rest = text;
    while let Some(i) = rest.find(needle) {
        rest = &rest[i + needle.len()..];
        if let Some(end) = rest.find('"') {
            let id = &rest[..end];
            if !id.is_empty() && id.len() < 64 && !out.iter().any(|o| o == id) {
                out.push(id.to_string());
            }
        }
    }
    out
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

    #[test]
    fn resume_commands_target_the_session() {
        let (bin, run, cwd) = (Path::new("x"), Path::new("/tmp/r"), Path::new("/tmp"));
        let cx = args_of(&build_resume_command(
            "codex",
            bin,
            run,
            cwd,
            true,
            "",
            &[],
            Some("SID"),
        ));
        assert!(cx.windows(2).any(|w| w[0] == "exec" && w[1] == "resume"));
        assert!(cx.iter().any(|a| a == "SID"));
        assert!(cx
            .iter()
            .any(|a| a == "--dangerously-bypass-approvals-and-sandbox"));
        let cl = args_of(&build_resume_command(
            "claude-code",
            bin,
            run,
            cwd,
            false,
            "opus",
            &[],
            Some("SID"),
        ));
        assert!(cl.windows(2).any(|w| w[0] == "--resume" && w[1] == "SID"));
        assert!(cl.windows(2).any(|w| w[0] == "--model" && w[1] == "opus"));
    }

    #[test]
    fn auto_and_empty_omit_model_effort_flags() {
        // "auto" (any case) and empty both mean: let the CLI choose — no flag.
        let (bin, run, cwd) = (Path::new("x"), Path::new("/tmp/r"), Path::new("/tmp"));
        for (model, effort) in [("auto", "auto"), ("", ""), ("AUTO", "Auto")] {
            let cx = args_of(&build_command(
                "codex",
                bin,
                run,
                cwd,
                false,
                model,
                effort,
                &[],
            ));
            assert!(
                !cx.iter().any(|a| a == "-m"),
                "codex -m omitted for {model:?}"
            );
            assert!(
                !cx.iter().any(|a| a.contains("model_reasoning_effort")),
                "codex effort omitted for {effort:?}"
            );
            let cl = args_of(&build_command(
                "claude-code",
                bin,
                run,
                cwd,
                false,
                model,
                effort,
                &[],
            ));
            assert!(
                !cl.iter().any(|a| a == "--model"),
                "claude --model omitted for {model:?}"
            );
            assert!(
                !cl.iter().any(|a| a == "--effort"),
                "claude --effort omitted for {effort:?}"
            );
        }
    }
}
