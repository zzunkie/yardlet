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

use crate::schemas::{Invocation, WorkerProfile};

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
        let mut c = match profile.id.as_str() {
            // Built-in adapters with verified flags.
            "codex" | "claude-code" => build_command(
                &profile.id,
                bin,
                run_dir,
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
                run_dir,
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
