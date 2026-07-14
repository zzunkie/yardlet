//! Worker engines.
//!
//! Workers are interchangeable CLI engines behind one contract:
//!
//! ```text
//! task packet in -> worker subprocess -> structured result files out
//! ```
//!
//! Yardlet treats Codex CLI and Claude Code CLI as hidden, subscription-backed
//! workers. The exact CLI flags are adapter-owned here so business logic does
//! not hard-code brittle host assumptions.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::schemas::{ChannelEventType, Invocation, RawEventRef, WorkerProfile};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RawStreamKind {
    Stdout,
    Stderr,
}

impl RawStreamKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Stdout => "stdout",
            Self::Stderr => "stderr",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NormalizedWorkerEvent {
    pub event_type: ChannelEventType,
    pub payload: serde_json::Value,
    pub raw_ref: RawEventRef,
}

#[derive(Debug, Clone)]
pub struct AttemptCapture {
    pub combined_log: PathBuf,
    pub stdout_log: PathBuf,
    pub stderr_log: PathBuf,
}

fn normalized_event(
    event_type: ChannelEventType,
    payload: serde_json::Value,
    artifact_id: &str,
    stream: RawStreamKind,
    byte_start: usize,
    byte_end: usize,
) -> NormalizedWorkerEvent {
    NormalizedWorkerEvent {
        event_type,
        payload,
        raw_ref: RawEventRef {
            artifact_id: artifact_id.to_string(),
            stream: stream.as_str().to_string(),
            byte_start: byte_start as u64,
            byte_end: byte_end as u64,
        },
    }
}

fn text_event(
    text: &str,
    artifact_id: &str,
    stream: RawStreamKind,
    start: usize,
    end: usize,
) -> Option<NormalizedWorkerEvent> {
    let text = text.trim();
    (!text.is_empty()).then(|| {
        normalized_event(
            ChannelEventType::WorkerMessage,
            serde_json::json!({"text": text}),
            artifact_id,
            stream,
            start,
            end,
        )
    })
}

fn normalize_codex_json(
    value: &serde_json::Value,
    artifact_id: &str,
    stream: RawStreamKind,
    start: usize,
    end: usize,
) -> Vec<NormalizedWorkerEvent> {
    let Some(kind) = value.get("type").and_then(|value| value.as_str()) else {
        return Vec::new();
    };
    let item = value.get("item").unwrap_or(value);
    let item_type = item.get("type").and_then(|value| value.as_str());
    if matches!(item_type, Some("reasoning" | "thinking" | "analysis")) {
        return Vec::new();
    }
    match (kind, item_type) {
        ("item.started", Some("command_execution" | "tool_call")) => vec![normalized_event(
            ChannelEventType::ToolStarted,
            serde_json::json!({
                "name": item.get("name").and_then(|value| value.as_str()).unwrap_or("command"),
                "command": item.get("command").and_then(|value| value.as_str()).unwrap_or("")
            }),
            artifact_id,
            stream,
            start,
            end,
        )],
        ("item.completed", Some("command_execution" | "tool_call")) => {
            vec![normalized_event(
                ChannelEventType::ToolCompleted,
                serde_json::json!({
                    "name": item.get("name").and_then(|value| value.as_str()).unwrap_or("command"),
                    "command": item.get("command").and_then(|value| value.as_str()).unwrap_or(""),
                    "exit_code": item.get("exit_code").cloned().unwrap_or(serde_json::Value::Null)
                }),
                artifact_id,
                stream,
                start,
                end,
            )]
        }
        ("item.completed", Some("agent_message" | "message")) => item
            .get("text")
            .and_then(|value| value.as_str())
            .and_then(|text| text_event(text, artifact_id, stream, start, end))
            .into_iter()
            .collect(),
        _ => Vec::new(),
    }
}

fn normalize_claude_json(
    value: &serde_json::Value,
    artifact_id: &str,
    stream: RawStreamKind,
    start: usize,
    end: usize,
) -> Vec<NormalizedWorkerEvent> {
    let mut out = Vec::new();
    if value.get("type").and_then(|value| value.as_str()) == Some("content_block_start") {
        let block = &value["content_block"];
        if block.get("type").and_then(|value| value.as_str()) == Some("tool_use") {
            out.push(normalized_event(
                ChannelEventType::ToolStarted,
                serde_json::json!({
                    "name": block.get("name").and_then(|value| value.as_str()).unwrap_or("tool")
                }),
                artifact_id,
                stream,
                start,
                end,
            ));
        }
        return out;
    }
    let content = value
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(|content| content.as_array());
    if let Some(content) = content {
        for block in content {
            match block.get("type").and_then(|value| value.as_str()) {
                Some("text") => {
                    if let Some(event) = block
                        .get("text")
                        .and_then(|value| value.as_str())
                        .and_then(|text| text_event(text, artifact_id, stream, start, end))
                    {
                        out.push(event);
                    }
                }
                Some("tool_use") => out.push(normalized_event(
                    ChannelEventType::ToolStarted,
                    serde_json::json!({
                        "name": block.get("name").and_then(|value| value.as_str()).unwrap_or("tool")
                    }),
                    artifact_id,
                    stream,
                    start,
                    end,
                )),
                Some("thinking" | "reasoning" | "analysis") => {}
                _ => {}
            }
        }
    } else if value.get("type").and_then(|value| value.as_str()) == Some("result") {
        if let Some(event) = value
            .get("result")
            .and_then(|value| value.as_str())
            .and_then(|text| text_event(text, artifact_id, stream, start, end))
        {
            out.push(event);
        }
    }
    out
}

/// Normalize only provider-exposed public messages/tool activity. Raw bytes
/// remain the source of truth and every emitted event points at its exact line.
pub fn normalize_worker_output(
    worker_id: &str,
    stream: RawStreamKind,
    raw: &[u8],
    artifact_id: &str,
) -> Vec<NormalizedWorkerEvent> {
    let mut events = Vec::new();
    let mut start = 0_usize;
    while start < raw.len() {
        let end = raw[start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map_or(raw.len(), |offset| start + offset + 1);
        let line = String::from_utf8_lossy(&raw[start..end]);
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            match serde_json::from_str::<serde_json::Value>(trimmed) {
                Ok(value) if worker_id == "codex" => {
                    events.extend(normalize_codex_json(
                        &value,
                        artifact_id,
                        stream,
                        start,
                        end,
                    ));
                }
                Ok(value) if worker_id == "claude-code" => {
                    events.extend(normalize_claude_json(
                        &value,
                        artifact_id,
                        stream,
                        start,
                        end,
                    ));
                }
                Ok(_) | Err(_) => {
                    if let Some(event) = text_event(trimmed, artifact_id, stream, start, end) {
                        events.push(event);
                    }
                }
            }
        }
        start = end;
    }
    events
}

/// A model/effort value counts as explicit only when it is set and is not the
/// "auto" sentinel. Empty or "auto" means: omit the flag and let the worker CLI
/// choose (its own default / automatic selection).
fn explicit(v: &str) -> bool {
    !v.trim().is_empty() && !v.eq_ignore_ascii_case("auto")
}

pub fn supports_native_resume(worker_id: &str) -> bool {
    matches!(worker_id, "codex" | "claude-code")
}

/// The profile a task actually runs with. A per-task `model`/`effort` overrides
/// the worker profile only when EXPLICIT (set and not the "auto" sentinel);
/// "auto"/empty keeps the profile's pinned value. This makes model/effort a
/// consistent cascade task -> profile -> CLI default: a worker-level model pin
/// is honored, and build_command falls back to the CLI's own default only when
/// the profile itself is empty/auto. (Without this, a task's `model: auto` would
/// clobber the profile pin and resolve straight to the CLI default.)
pub fn effective_profile(
    profile: &WorkerProfile,
    task_model: &str,
    task_effort: &str,
) -> WorkerProfile {
    let mut p = profile.clone();
    if explicit(task_model) {
        p.model = task_model.to_string();
    }
    if explicit(task_effort) {
        p.effort = task_effort.to_string();
    }
    p
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
            // Attach images natively (codex vision), so Yardlet does not lose it.
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

/// Build the command for a worker WITHOUT a built-in adapter, from the
/// invocation template in its workers.yaml profile. This is what makes a
/// third worker a pure-config addition: packet on stdin, args from the
/// template, placeholders expanded.
#[allow(clippy::too_many_arguments)]
pub fn build_generic_command(
    inv: &Invocation,
    bin: &Path,
    run_dir: &Path,
    cwd: &Path,
    full_access: bool,
    model: &str,
    effort: &str,
    images: &[String],
) -> Command {
    let expand = |arg: &str, image: &str| -> String {
        arg.replace("{run_dir}", &run_dir.display().to_string())
            .replace("{model}", model)
            .replace("{effort}", effort)
            .replace("{image}", image)
    };
    let mut cmd = Command::new(bin);
    for a in &inv.args {
        cmd.arg(expand(a, ""));
    }
    let access = if full_access {
        &inv.full_access_args
    } else {
        &inv.sandbox_args
    };
    for a in access {
        cmd.arg(expand(a, ""));
    }
    if explicit(model) {
        for a in &inv.model_args {
            cmd.arg(expand(a, ""));
        }
    }
    if explicit(effort) {
        for a in &inv.effort_args {
            cmd.arg(expand(a, ""));
        }
    }
    for img in images {
        for a in &inv.image_args {
            cmd.arg(expand(a, img));
        }
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
            // Keep the live monitor working on resumed/chained sessions too.
            cmd.arg("--output-format")
                .arg("stream-json")
                .arg("--verbose");
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
    /// Exact Codex thread created by this child process. Captured only from
    /// that child's JSONL stdout; never inferred from global session files.
    pub session_id: Option<String>,
}

fn valid_codex_thread_id(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => byte == b'-',
            _ => byte.is_ascii_hexdigit(),
        })
}

fn codex_thread_id_from_json_line(line: &[u8]) -> Option<String> {
    let event: serde_json::Value = serde_json::from_slice(line).ok()?;
    if event.get("type").and_then(|value| value.as_str()) != Some("thread.started") {
        return None;
    }
    event
        .get("thread_id")
        .and_then(|value| value.as_str())
        .filter(|id| valid_codex_thread_id(id))
        .map(str::to_string)
}

fn capture_codex_thread_id(
    pending: &mut Vec<u8>,
    chunk: &[u8],
    captured: &std::sync::Arc<std::sync::Mutex<Option<String>>>,
) {
    if captured.lock().is_ok_and(|guard| guard.is_some()) {
        return;
    }
    pending.extend_from_slice(chunk);
    while let Some(newline) = pending.iter().position(|byte| *byte == b'\n') {
        let line: Vec<u8> = pending.drain(..=newline).collect();
        if let Some(id) = codex_thread_id_from_json_line(&line) {
            if let Ok(mut guard) = captured.lock() {
                *guard = Some(id);
            }
            pending.clear();
            return;
        }
    }
    // `thread.started` is a small leading event. Fail closed instead of
    // retaining unbounded non-JSON output while waiting for it.
    if pending.len() > 64 * 1024 {
        pending.clear();
    }
}

/// Spawn a worker with a sanitized environment, feeding the packet on stdin and
/// capturing all output to `output_log`. Enforces a wall-clock timeout.
///
/// This is the only place Yardlet launches a worker. It uses the env produced by
/// the zero-key guard; it never injects an AI provider API key.
#[allow(clippy::too_many_arguments)]
pub fn spawn(
    profile: &WorkerProfile,
    bin: &Path,
    packet: &str,
    worker_run_dir: &Path,
    cwd: &Path,
    env: &[(String, String)],
    output_log: &Path,
    timeout: Duration,
    full_access: bool,
    images: &[String],
    session: Option<&str>,
    resume: bool,
) -> Result<WorkerOutcome> {
    spawn_internal(
        profile,
        bin,
        packet,
        worker_run_dir,
        cwd,
        env,
        output_log,
        None,
        timeout,
        full_access,
        images,
        session,
        resume,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn spawn_attempt(
    profile: &WorkerProfile,
    bin: &Path,
    packet: &str,
    worker_run_dir: &Path,
    cwd: &Path,
    env: &[(String, String)],
    capture: &AttemptCapture,
    timeout: Duration,
    full_access: bool,
    images: &[String],
    session: Option<&str>,
    resume: bool,
) -> Result<WorkerOutcome> {
    spawn_internal(
        profile,
        bin,
        packet,
        worker_run_dir,
        cwd,
        env,
        &capture.combined_log,
        Some(capture),
        timeout,
        full_access,
        images,
        session,
        resume,
    )
}

#[allow(clippy::too_many_arguments)]
fn spawn_internal(
    profile: &WorkerProfile,
    bin: &Path,
    packet: &str,
    worker_run_dir: &Path,
    cwd: &Path,
    env: &[(String, String)],
    output_log: &Path,
    attempt_capture: Option<&AttemptCapture>,
    timeout: Duration,
    full_access: bool,
    images: &[String],
    session: Option<&str>,
    resume: bool,
) -> Result<WorkerOutcome> {
    use std::io::{Read, Write};

    // `worker_run_dir` may be a staging directory inside an isolated worktree,
    // while `output_log` and worker.pid remain owned by the main Yardlet
    // process in the canonical run directory.
    let control_run_dir = output_log.parent().unwrap_or(cwd);
    let mut cmd = if resume {
        build_resume_command(
            &profile.id,
            bin,
            worker_run_dir,
            cwd,
            full_access,
            &profile.model,
            images,
            session,
        )
    } else {
        let mut c = match profile.id.as_str() {
            // Built-in adapters with verified flags.
            "codex" | "claude-code" => build_command(
                &profile.id,
                bin,
                worker_run_dir,
                cwd,
                full_access,
                &profile.model,
                &profile.effort,
                images,
            ),
            // Anything else: the profile's own invocation template.
            _ => build_generic_command(
                &profile.invocation,
                bin,
                worker_run_dir,
                cwd,
                full_access,
                &profile.model,
                &profile.effort,
                images,
            ),
        };
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

    let attempt_raw_files = if let Some(capture) = attempt_capture {
        for path in [&capture.stdout_log, &capture.stderr_log] {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("creating {}", parent.display()))?;
            }
            if path.exists() {
                anyhow::bail!("attempt raw stream already exists: {}", path.display());
            }
        }
        let stdout = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&capture.stdout_log)
            .with_context(|| format!("creating {}", capture.stdout_log.display()))?;
        let stderr = match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&capture.stderr_log)
        {
            Ok(file) => file,
            Err(error) => {
                let _ = std::fs::remove_file(&capture.stdout_log);
                return Err(error)
                    .with_context(|| format!("creating {}", capture.stderr_log.display()));
            }
        };
        Some((stdout, stderr))
    } else {
        None
    };

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawning worker '{}'", bin.display()))?;

    // Record the worker PID so the TUI can stop it (Esc) by killing the process.
    let pid_path = control_run_dir.join("worker.pid");
    let _ = std::fs::write(&pid_path, child.id().to_string());

    if let Some(mut stdin) = child.stdin.take() {
        // Best-effort: a worker that ignores stdin will simply not receive it.
        let _ = stdin.write_all(packet.as_bytes());
    }

    // Stream BOTH stdout and stderr to the log as they arrive, so a Run Monitor
    // can tail the worker live. Worker CLIs often route progress to stderr or
    // block-buffer stdout on a pipe, so capturing stderr live (not only after
    // exit) is what keeps the monitor non-empty during a run.
    let combined = if attempt_capture.is_some() {
        if let Some(parent) = output_log.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        Some(
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(output_log)
                .with_context(|| format!("opening {}", output_log.display()))?,
        )
    } else {
        std::fs::File::create(output_log).ok()
    };
    let log_file = std::sync::Arc::new(std::sync::Mutex::new(combined));
    let captured_session = std::sync::Arc::new(std::sync::Mutex::new(None));
    let (stdout_raw, stderr_raw) = match attempt_raw_files {
        Some((stdout, stderr)) => (
            Some(std::sync::Arc::new(std::sync::Mutex::new(stdout))),
            Some(std::sync::Arc::new(std::sync::Mutex::new(stderr))),
        ),
        None => (None, None),
    };
    type RawSink = Option<std::sync::Arc<std::sync::Mutex<std::fs::File>>>;
    let mut sources: Vec<(Box<dyn Read + Send>, bool, RawSink)> = Vec::new();
    if let Some(o) = child.stdout.take() {
        sources.push((Box::new(o), profile.id == "codex" && !resume, stdout_raw));
    }
    if let Some(e) = child.stderr.take() {
        sources.push((Box::new(e), false, stderr_raw));
    }
    let readers: Vec<_> = sources
        .into_iter()
        .map(|(mut src, capture_session, raw_sink)| {
            let log = std::sync::Arc::clone(&log_file);
            let captured = std::sync::Arc::clone(&captured_session);
            thread::spawn(move || -> std::io::Result<()> {
                let mut buf = [0u8; 4096];
                let mut pending = Vec::new();
                loop {
                    match src.read(&mut buf) {
                        Ok(0) => {
                            if capture_session && !pending.is_empty() {
                                if let Some(id) = codex_thread_id_from_json_line(&pending) {
                                    if let Ok(mut guard) = captured.lock() {
                                        *guard = Some(id);
                                    }
                                }
                            }
                            break;
                        }
                        Err(error) => return Err(error),
                        Ok(n) => {
                            if capture_session {
                                capture_codex_thread_id(&mut pending, &buf[..n], &captured);
                            }
                            if let Ok(mut guard) = log.lock() {
                                if let Some(f) = guard.as_mut() {
                                    let _ = f.write_all(&buf[..n]);
                                    let _ = f.flush();
                                }
                            }
                            if let Some(raw_sink) = &raw_sink {
                                if let Ok(mut raw) = raw_sink.lock() {
                                    raw.write_all(&buf[..n])?;
                                    raw.flush()?;
                                } else {
                                    return Err(std::io::Error::other(
                                        "attempt raw stream lock poisoned",
                                    ));
                                }
                            }
                        }
                    }
                }
                Ok(())
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
    let mut reader_error = None;
    for reader in readers {
        match reader.join() {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                reader_error.get_or_insert(error);
            }
            Err(_) => {
                reader_error.get_or_insert_with(|| {
                    std::io::Error::other("worker stream reader thread panicked")
                });
            }
        }
    }
    let _ = std::fs::remove_file(&pid_path);
    if let Some(error) = reader_error {
        return Err(error).context("preserving attempt raw stream");
    }
    let session_id = captured_session
        .lock()
        .ok()
        .and_then(|captured| captured.clone());

    Ok(WorkerOutcome {
        exit_ok: status.success() && !timed_out,
        timed_out,
        session_id,
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

// ---- model/effort preset discovery -----------------------------------------
//
// Presets stay in sync with the CLIs themselves, no hand-maintained id lists:
//   - codex: the CLI maintains ~/.codex/models_cache.json with the models
//     available to THIS account, including each model's supported reasoning
//     efforts. That file is the authoritative machine-local source.
//   - claude: model aliases are the CLI's documented stable set; effort
//     levels are parsed out of `claude --help` (a complete enum in the text).
// Everything degrades to a sensible static fallback, and Settings always
// allows typing an exact id.

/// Claude Code model presets ("" = CLI default). The aliases are the CLI's
/// stable documented set; full model ids can still be typed.
pub fn known_claude_models() -> Vec<String> {
    ["", "fable", "opus", "sonnet", "haiku"]
        .iter()
        .map(|s| s.to_string())
        .collect()
}

/// Claude Code effort presets, parsed live from `claude --help`.
pub fn known_claude_efforts() -> Vec<String> {
    let help = std::process::Command::new("claude")
        .arg("--help")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut out = vec![String::new()];
    out.extend(parse_claude_efforts(&help).unwrap_or_else(|| {
        ["low", "medium", "high"]
            .iter()
            .map(|s| s.to_string())
            .collect()
    }));
    out
}

/// `--effort <level>  ... (low, medium, high, xhigh, max)` -> the level list.
fn parse_claude_efforts(help: &str) -> Option<Vec<String>> {
    let after = help.split("--effort").nth(1)?;
    let inner = after.split('(').nth(1)?.split(')').next()?;
    let levels: Vec<String> = inner
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.len() < 12 && s.chars().all(|c| c.is_ascii_alphabetic()))
        .collect();
    (!levels.is_empty()).then_some(levels)
}

/// Codex model presets ("" = CLI default), read from the CLI's own
/// models cache of what this account can use.
pub fn known_codex_models() -> Vec<String> {
    let mut out = vec![String::new()];
    if let Some((models, _)) = read_codex_models_cache() {
        out.extend(models);
    }
    if out.len() == 1 {
        // No cache yet (codex never run on this machine): configured default.
        if let Some(m) = codex_config_default_model() {
            out.push(m);
        }
    }
    out
}

/// Codex effort presets ("" = CLI default), from the models cache (the union
/// across listed models).
pub fn known_codex_efforts() -> Vec<String> {
    let mut out = vec![String::new()];
    match read_codex_models_cache() {
        Some((_, efforts)) if !efforts.is_empty() => out.extend(efforts),
        _ => out.extend(["low", "medium", "high"].iter().map(|s| s.to_string())),
    }
    out
}

/// Parse ~/.codex/models_cache.json into (listed model slugs, effort union).
fn read_codex_models_cache() -> Option<(Vec<String>, Vec<String>)> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let raw = std::fs::read_to_string(home.join(".codex/models_cache.json")).ok()?;
    parse_codex_models_cache(&raw)
}

fn parse_codex_models_cache(raw: &str) -> Option<(Vec<String>, Vec<String>)> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    let mut models = Vec::new();
    let mut efforts: Vec<String> = Vec::new();
    for m in v.get("models")?.as_array()? {
        // Hidden entries (e.g. internal review models) are not user choices.
        if m.get("visibility").and_then(|x| x.as_str()) != Some("list") {
            continue;
        }
        if let Some(slug) = m.get("slug").and_then(|x| x.as_str()) {
            if !slug.is_empty() && !models.iter().any(|s| s == slug) {
                models.push(slug.to_string());
            }
        }
        if let Some(levels) = m
            .get("supported_reasoning_levels")
            .and_then(|x| x.as_array())
        {
            for l in levels {
                if let Some(e) = l.get("effort").and_then(|x| x.as_str()) {
                    if !efforts.iter().any(|s| s == e) {
                        efforts.push(e.to_string());
                    }
                }
            }
        }
    }
    Some((models, efforts))
}

fn codex_config_default_model() -> Option<String> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let cfg = std::fs::read_to_string(home.join(".codex/config.toml")).ok()?;
    cfg.lines().find_map(|l| {
        l.trim()
            .strip_prefix("model")
            .and_then(|r| r.trim_start().strip_prefix('='))
            .map(|v| v.trim().trim_matches('"').to_string())
            .filter(|m| !m.is_empty())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_profile_honors_pin_unless_task_is_explicit() {
        let base: WorkerProfile = crate::yaml::from_str(
            "id: claude-code\nmodel: opus\neffort: high\ninvocation: { command: claude }",
        )
        .unwrap();
        // "auto" / empty per-task values keep the profile's pin.
        let p = effective_profile(&base, "auto", "");
        assert_eq!(p.model, "opus");
        assert_eq!(p.effort, "high");
        let p = effective_profile(&base, "AUTO", "auto");
        assert_eq!(p.model, "opus");
        assert_eq!(p.effort, "high");
        // An explicit per-task value overrides the pin.
        let p = effective_profile(&base, "sonnet", "low");
        assert_eq!(p.model, "sonnet");
        assert_eq!(p.effort, "low");
        // No profile pin + "auto" task = empty, so build_command later omits the
        // flag and the worker CLI picks its own default.
        let bare: WorkerProfile =
            crate::yaml::from_str("id: codex\ninvocation: { command: codex }").unwrap();
        let p = effective_profile(&bare, "auto", "auto");
        assert!(p.model.is_empty());
        assert!(p.effort.is_empty());
    }

    fn args_of(cmd: &Command) -> Vec<String> {
        cmd.get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect()
    }

    #[test]
    fn generic_adapter_builds_from_the_invocation_template() {
        let inv: Invocation = crate::yaml::from_str(
            r#"
command: mytool
supports_noninteractive: true
args: ["run", "--json", "--out", "{run_dir}"]
sandbox_args: ["--sandbox"]
full_access_args: ["--yolo"]
model_args: ["--model", "{model}"]
effort_args: ["--effort", "{effort}"]
image_args: ["-i", "{image}"]
"#,
        )
        .unwrap();
        let (bin, run, cwd) = (Path::new("mytool"), Path::new("/tmp/r"), Path::new("/tmp"));

        let sandboxed = args_of(&build_generic_command(
            &inv,
            bin,
            run,
            cwd,
            false,
            "m-1",
            "high",
            &["a.png".to_string()],
        ));
        assert_eq!(
            sandboxed,
            vec![
                "run",
                "--json",
                "--out",
                "/tmp/r",
                "--sandbox",
                "--model",
                "m-1",
                "--effort",
                "high",
                "-i",
                "a.png",
            ]
        );

        // Full access swaps the access args; auto model/effort add nothing.
        let full = args_of(&build_generic_command(
            &inv,
            bin,
            run,
            cwd,
            true,
            "auto",
            "",
            &[],
        ));
        assert_eq!(full, vec!["run", "--json", "--out", "/tmp/r", "--yolo"]);
    }

    #[test]
    fn codex_models_cache_yields_listed_models_and_efforts() {
        let raw = r#"{
            "models": [
                { "slug": "gpt-5.5", "visibility": "list",
                  "supported_reasoning_levels": [
                    {"effort": "low"}, {"effort": "medium"},
                    {"effort": "high"}, {"effort": "xhigh"} ] },
                { "slug": "gpt-5.4-mini", "visibility": "list",
                  "supported_reasoning_levels": [{"effort": "low"}] },
                { "slug": "internal-review", "visibility": "hide",
                  "supported_reasoning_levels": [{"effort": "secret"}] }
            ]
        }"#;
        let (models, efforts) = parse_codex_models_cache(raw).unwrap();
        assert_eq!(models, vec!["gpt-5.5", "gpt-5.4-mini"]);
        // Hidden models contribute neither slugs nor efforts.
        assert_eq!(efforts, vec!["low", "medium", "high", "xhigh"]);
    }

    #[test]
    fn claude_effort_levels_parse_from_help_text() {
        let help = "  --effort <level>   Effort level for the current session\n\
                    (low, medium, high, xhigh, max)\n  --other ...";
        assert_eq!(
            parse_claude_efforts(help).unwrap(),
            vec!["low", "medium", "high", "xhigh", "max"]
        );
        assert!(parse_claude_efforts("no flag here").is_none());
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

    #[cfg(unix)]
    #[test]
    fn fresh_codex_session_id_comes_from_that_childs_stdout() {
        use std::os::unix::fs::PermissionsExt;

        let root =
            std::env::temp_dir().join(format!("yard-codex-session-capture-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let fake_codex = root.join("codex");
        std::fs::write(
            &fake_codex,
            r#"#!/bin/sh
printf '%s\n' '{"type":"thread.started","thread_id":"11111111-2222-4333-8444-555555555555"}'
printf '%s\n' '{"type":"thread.started","thread_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}' >&2
"#,
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&fake_codex).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&fake_codex, permissions).unwrap();

        let profile: WorkerProfile = crate::yaml::from_str(
            "id: codex\ninvocation: {command: codex}\nlimits: {max_wall_minutes: 1}\n",
        )
        .unwrap();
        let log = root.join("worker-output.log");
        let outcome = spawn(
            &profile,
            &fake_codex,
            "packet",
            &root,
            &root,
            &[],
            &log,
            Duration::from_secs(5),
            false,
            &[],
            None,
            false,
        )
        .unwrap();

        assert!(outcome.exit_ok);
        assert_eq!(
            outcome.session_id.as_deref(),
            Some("11111111-2222-4333-8444-555555555555"),
            "only the exact fresh child's stdout may identify its session"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn fresh_codex_without_stdout_thread_event_has_no_session_to_resume() {
        use std::os::unix::fs::PermissionsExt;

        let root = std::env::temp_dir().join(format!(
            "yard-codex-session-fail-closed-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let fake_codex = root.join("codex");
        std::fs::write(
            &fake_codex,
            r#"#!/bin/sh
printf '%s\n' '{"type":"thread.started","thread_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"}' >&2
"#,
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&fake_codex).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&fake_codex, permissions).unwrap();

        let profile: WorkerProfile = crate::yaml::from_str(
            "id: codex\ninvocation: {command: codex}\nlimits: {max_wall_minutes: 1}\n",
        )
        .unwrap();
        let outcome = spawn(
            &profile,
            &fake_codex,
            "packet",
            &root,
            &root,
            &[],
            &root.join("worker-output.log"),
            Duration::from_secs(5),
            false,
            &[],
            None,
            false,
        )
        .unwrap();

        assert!(outcome.exit_ok);
        assert_eq!(outcome.session_id, None);
        let _ = std::fs::remove_dir_all(root);
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

    #[test]
    fn codex_public_stream_normalizes_messages_and_tools_but_not_reasoning() {
        let raw = concat!(
            "{\"type\":\"thread.started\",\"thread_id\":\"11111111-2222-4333-8444-555555555555\"}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"reasoning\",\"text\":\"private\"}}\n",
            "{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\",\"command\":\"cargo test\"}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"command\":\"cargo test\",\"exit_code\":0}}\n",
            "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"public update\"}}\n"
        );
        let events = normalize_worker_output(
            "codex",
            RawStreamKind::Stdout,
            raw.as_bytes(),
            "raw_att_1_stdout",
        );

        assert_eq!(events.len(), 3);
        assert_eq!(
            events[0].event_type,
            crate::schemas::ChannelEventType::ToolStarted
        );
        assert_eq!(
            events[1].event_type,
            crate::schemas::ChannelEventType::ToolCompleted
        );
        assert_eq!(
            events[2].event_type,
            crate::schemas::ChannelEventType::WorkerMessage
        );
        assert_eq!(events[2].payload["text"], "public update");
        assert!(events.iter().all(|event| {
            event.raw_ref.byte_end > event.raw_ref.byte_start
                && event.raw_ref.artifact_id == "raw_att_1_stdout"
        }));
        assert!(events
            .iter()
            .all(|event| !event.payload.to_string().contains("private")));
    }

    #[test]
    fn text_only_stream_degrades_to_message_events_with_exact_spans() {
        let events = normalize_worker_output(
            "generic-text",
            RawStreamKind::Stderr,
            b"first line\n\nsecond line\n",
            "raw_att_2_stderr",
        );
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].payload["text"], "first line");
        assert_eq!(events[0].raw_ref.byte_start, 0);
        assert_eq!(events[0].raw_ref.byte_end, 11);
        assert_eq!(events[1].payload["text"], "second line");
        assert_eq!(events[1].raw_ref.stream, "stderr");
    }

    #[cfg(unix)]
    #[test]
    fn attempt_capture_separates_stdout_stderr_and_refuses_overwrite() {
        let root =
            std::env::temp_dir().join(format!("yard-attempt-capture-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let profile: WorkerProfile = crate::yaml::from_str(
            r#"
id: fixture
invocation:
  command: sh
  args: ["-c", "printf stdout-only; printf stderr-only >&2"]
limits: {max_wall_minutes: 1}
"#,
        )
        .unwrap();
        let capture = AttemptCapture {
            combined_log: root.join("worker-output.log"),
            stdout_log: root.join("attempts/att_1/stdout.log"),
            stderr_log: root.join("attempts/att_1/stderr.log"),
        };
        let outcome = spawn_attempt(
            &profile,
            Path::new("/bin/sh"),
            "packet",
            &root,
            &root,
            &[],
            &capture,
            Duration::from_secs(5),
            false,
            &[],
            None,
            false,
        )
        .unwrap();
        assert!(outcome.exit_ok);
        assert_eq!(
            std::fs::read_to_string(&capture.stdout_log).unwrap(),
            "stdout-only"
        );
        assert_eq!(
            std::fs::read_to_string(&capture.stderr_log).unwrap(),
            "stderr-only"
        );
        let combined = std::fs::read_to_string(&capture.combined_log).unwrap();
        assert!(combined.contains("stdout-only"));
        assert!(combined.contains("stderr-only"));

        let error = spawn_attempt(
            &profile,
            Path::new("/bin/sh"),
            "packet",
            &root,
            &root,
            &[],
            &capture,
            Duration::from_secs(5),
            false,
            &[],
            None,
            false,
        )
        .unwrap_err();
        assert!(error
            .to_string()
            .contains("attempt raw stream already exists"));
        assert_eq!(
            std::fs::read_to_string(&capture.stdout_log).unwrap(),
            "stdout-only"
        );
        let _ = std::fs::remove_dir_all(root);
    }
}
