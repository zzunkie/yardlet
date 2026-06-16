//! Phase H3 (docs/harness.md): workspace-owned deterministic guards that bind
//! EVERY worker, not just one CLI. Executables in `.agents/hooks/pre-run.d/*`
//! run before a worker is spawned (a non-zero exit blocks the run); those in
//! `.agents/hooks/post-run.d/*` run during evaluation (a non-zero exit is a
//! fatal check the task cannot be Done past). Hooks are the workspace's OWN
//! code — Yardlet ships only a documented README, never enabled hooks. Each hook
//! runs in the workspace root with `YARD_TASK_ID` / `YARD_RUN_DIR` /
//! `YARD_WORKER` in its environment, a wall-clock timeout, and its stdout +
//! stderr captured into the run dir.

use std::path::Path;
use std::process::Stdio;
use std::time::{Duration, Instant};

use crate::state::Workspace;

/// Per-hook wall-clock limit. A hook that runs longer is killed and counts as
/// a failure (a guard that hangs must not hang the run forever).
const HOOK_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy)]
pub enum Phase {
    /// Before the worker spawns; a failure blocks the run entirely.
    Pre,
    /// During evaluation; a failure is a fatal check (blocks Done).
    Post,
}

impl Phase {
    fn dir(self) -> &'static str {
        match self {
            Phase::Pre => "pre-run.d",
            Phase::Post => "post-run.d",
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Phase::Pre => "pre-run",
            Phase::Post => "post-run",
        }
    }
}

/// One hook that did not pass: it exited non-zero, timed out, or failed to run.
pub struct HookFailure {
    pub name: String,
    /// Why it failed (`exit 3`, `timed out after 30s`, `spawn failed: ...`).
    pub note: String,
    pub stderr: String,
}

impl HookFailure {
    /// One-line report: name, why, and the last line of stderr (if any).
    pub fn summary(&self) -> String {
        let tail: String = self
            .stderr
            .trim()
            .lines()
            .last()
            .unwrap_or("")
            .chars()
            .take(200)
            .collect();
        if tail.is_empty() {
            format!("{} ({})", self.name, self.note)
        } else {
            format!("{} ({}): {}", self.name, self.note, tail)
        }
    }
}

/// The result of running a phase's hooks.
pub struct HookOutcome {
    pub ran: usize,
    pub failures: Vec<HookFailure>,
}

impl HookOutcome {
    pub fn ok(&self) -> bool {
        self.failures.is_empty()
    }
}

/// Run every executable hook for `phase`, in sorted filename order, from the
/// workspace root. Each hook's output goes to `<run_dir>/hooks/<phase>/<name>`
/// (`.out` / `.err`). A hook that exits non-zero, times out, or fails to spawn
/// becomes a `HookFailure`. No-op (empty outcome) when hooks are disabled in
/// config, the directory is absent, or it holds no executables.
pub fn run_phase(
    ws: &Workspace,
    phase: Phase,
    task_id: &str,
    run_dir: &Path,
    worker_id: &str,
) -> HookOutcome {
    let mut outcome = HookOutcome {
        ran: 0,
        failures: Vec::new(),
    };
    if !ws.load_config().map(|c| c.hooks).unwrap_or(true) {
        return outcome;
    }
    let dir = ws.agents_dir().join("hooks").join(phase.dir());
    let mut entries: Vec<std::path::PathBuf> = match std::fs::read_dir(&dir) {
        Ok(rd) => rd
            .flatten()
            .map(|e| e.path())
            .filter(|p| is_executable_file(p))
            .collect(),
        Err(_) => return outcome,
    };
    if entries.is_empty() {
        return outcome;
    }
    entries.sort();

    let log_dir = run_dir.join("hooks").join(phase.label());
    let _ = std::fs::create_dir_all(&log_dir);

    for path in entries {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("hook")
            .to_string();
        outcome.ran += 1;
        let out_path = log_dir.join(format!("{name}.out"));
        let err_path = log_dir.join(format!("{name}.err"));
        match run_one(
            &path, &ws.root, task_id, run_dir, worker_id, &out_path, &err_path,
        ) {
            Ok(0) => {}
            Ok(code) => outcome.failures.push(HookFailure {
                name,
                note: format!("exit {code}"),
                stderr: std::fs::read_to_string(&err_path).unwrap_or_default(),
            }),
            Err(why) => outcome.failures.push(HookFailure {
                name,
                note: why,
                stderr: std::fs::read_to_string(&err_path).unwrap_or_default(),
            }),
        }
    }
    outcome
}

/// Run one hook with output redirected straight to files (no pipe buffer to
/// deadlock on) and a wall-clock timeout. Returns the exit code, or an error
/// note for a timeout / spawn failure.
#[allow(clippy::too_many_arguments)]
fn run_one(
    path: &Path,
    cwd: &Path,
    task_id: &str,
    run_dir: &Path,
    worker_id: &str,
    out_path: &Path,
    err_path: &Path,
) -> Result<i32, String> {
    let out = std::fs::File::create(out_path).map_err(|e| format!("log create: {e}"))?;
    let err = std::fs::File::create(err_path).map_err(|e| format!("log create: {e}"))?;
    let mut child = std::process::Command::new(path)
        .current_dir(cwd)
        .env("YARD_TASK_ID", task_id)
        .env("YARD_RUN_DIR", run_dir)
        .env("YARD_WORKER", worker_id)
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err))
        .spawn()
        .map_err(|e| format!("spawn failed: {e}"))?;

    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            return Ok(status.code().unwrap_or(-1));
        }
        if start.elapsed() >= HOOK_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("timed out after {}s", HOOK_TIMEOUT.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(unix)]
fn is_executable_file(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p)
        .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(not(unix))]
fn is_executable_file(p: &Path) -> bool {
    // No unix permission bits: treat any non-dotfile regular file as a hook.
    p.is_file()
        && p.file_name()
            .and_then(|n| n.to_str())
            .map(|n| !n.starts_with('.'))
            .unwrap_or(false)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn ws_with_hook(phase: Phase, name: &str, script: &str) -> (Workspace, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!("yard-hooks-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        crate::init::ensure_initialized(&root).unwrap();
        let dir = ws.agents_dir().join("hooks").join(phase.dir());
        std::fs::create_dir_all(&dir).unwrap();
        let hook = dir.join(name);
        std::fs::write(&hook, script).unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        let run_dir = ws.runs_dir().join("run-test");
        std::fs::create_dir_all(&run_dir).unwrap();
        (ws, run_dir)
    }

    #[test]
    fn passing_hook_is_ok_and_failing_hook_reports() {
        let (ws, run_dir) = ws_with_hook(Phase::Pre, "00-ok.sh", "#!/bin/sh\nexit 0\n");
        let out = run_phase(&ws, Phase::Pre, "YARD-001", &run_dir, "codex");
        assert_eq!(out.ran, 1);
        assert!(out.ok());
        let _ = std::fs::remove_dir_all(&ws.root);

        let (ws, run_dir) = ws_with_hook(
            Phase::Post,
            "00-deny.sh",
            "#!/bin/sh\necho 'secret found in diff' >&2\nexit 3\n",
        );
        let out = run_phase(&ws, Phase::Post, "YARD-001", &run_dir, "codex");
        assert_eq!(out.ran, 1);
        assert!(!out.ok());
        assert_eq!(out.failures[0].note, "exit 3");
        assert!(out.failures[0].summary().contains("secret found in diff"));
        // output captured to the run dir
        assert!(run_dir.join("hooks/post-run/00-deny.sh.err").exists());
        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn env_is_exposed_to_the_hook() {
        let (ws, run_dir) = ws_with_hook(
            Phase::Pre,
            "00-env.sh",
            "#!/bin/sh\n[ \"$YARD_TASK_ID\" = \"YARD-042\" ] && [ \"$YARD_WORKER\" = \"claude-code\" ]\n",
        );
        let out = run_phase(&ws, Phase::Pre, "YARD-042", &run_dir, "claude-code");
        assert!(out.ok(), "hook should see YARD_TASK_ID/YARD_WORKER");
        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn disabled_in_config_is_a_noop() {
        let (ws, run_dir) = ws_with_hook(Phase::Pre, "00-fail.sh", "#!/bin/sh\nexit 1\n");
        let mut cfg = ws.load_config().unwrap();
        cfg.hooks = false;
        crate::state::save_yaml(&ws.config_path(), &cfg).unwrap();
        let out = run_phase(&ws, Phase::Pre, "YARD-001", &run_dir, "codex");
        assert_eq!(out.ran, 0);
        assert!(out.ok());
        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn non_executable_files_are_ignored() {
        let (ws, run_dir) = ws_with_hook(Phase::Pre, "00-run.sh", "#!/bin/sh\nexit 0\n");
        // a non-executable example file in the same dir must not run
        let dir = ws.agents_dir().join("hooks").join("pre-run.d");
        std::fs::write(dir.join("README.md"), "docs, not a hook").unwrap();
        let out = run_phase(&ws, Phase::Pre, "YARD-001", &run_dir, "codex");
        assert_eq!(out.ran, 1); // only the executable
        let _ = std::fs::remove_dir_all(&ws.root);
    }
}
