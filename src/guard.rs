//! Zero-key worker guard.
//!
//! Yard core never requires, requests, stores, or calls AI provider API keys.
//! This module enforces two things:
//!
//! 1. Worker readiness probing without invoking provider APIs.
//! 2. A sanitized environment for worker subprocesses so an installed,
//!    subscription-backed CLI cannot accidentally bill against an API key.
//!
//! It never reads, prints, or stores secret *values*. It only reports the
//! *names* of billing variables that are present in the parent environment.

use std::env;
use std::path::PathBuf;
use std::process::Command;

use crate::schemas::{BillingPolicy, WorkerProfile};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Readiness {
    Ready,
    NotReady,
    /// Binary is present but its offline `--version` probe failed, so the
    /// resolved CLI or its runtime cannot be confirmed. Yard stops rather than
    /// guess (it never risks a billed call to verify auth).
    Ambiguous,
}

impl Readiness {
    pub fn label(self) -> &'static str {
        match self {
            Readiness::Ready => "ready",
            Readiness::NotReady => "not ready",
            Readiness::Ambiguous => "ambiguous",
        }
    }
}

#[derive(Debug, Clone)]
pub struct WorkerStatus {
    pub id: String,
    pub command: String,
    pub binary_path: Option<PathBuf>,
    pub version: Option<String>,
    /// Names (never values) of billing env vars present in the parent process.
    pub billing_env_present: Vec<String>,
    pub readiness: Readiness,
    pub detail: String,
}

/// Locate an executable on PATH (a small, dependency-free `which`).
pub fn find_binary(command: &str) -> Option<PathBuf> {
    // An explicit path is honored as-is.
    if command.contains('/') {
        let p = PathBuf::from(command);
        return if p.is_file() { Some(p) } else { None };
    }
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate = dir.join(command);
        if is_executable(&candidate) {
            return Some(candidate);
        }
    }
    None
}

#[cfg(unix)]
fn is_executable(p: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(p) {
        Ok(m) => m.is_file() && (m.permissions().mode() & 0o111 != 0),
        Err(_) => false,
    }
}

#[cfg(not(unix))]
fn is_executable(p: &std::path::Path) -> bool {
    p.is_file()
}

/// Names of billing-related env vars currently present in this process.
pub fn present_billing_env(blocked: &[String]) -> Vec<String> {
    blocked
        .iter()
        .filter(|name| env::var_os(name.as_str()).is_some())
        .cloned()
        .collect()
}

/// Well-known local install locations to fall back to when the PATH-resolved
/// binary is missing or its `--version` probe fails (e.g. a shell alias or a
/// wrapper shadows the real CLI in non-interactive shells). These are the
/// official local install paths for each worker, not host-specific guesses.
fn fallback_paths(worker_id: &str) -> Vec<PathBuf> {
    let home = match env::var_os("HOME") {
        Some(h) => PathBuf::from(h),
        None => return Vec::new(),
    };
    match worker_id {
        "claude-code" => vec![
            home.join(".claude/local/claude"),
            home.join(".claude/bin/claude"),
        ],
        "codex" => vec![home.join(".codex/bin/codex")],
        _ => Vec::new(),
    }
}

/// Probe one worker's readiness. Does not invoke any provider API. Version
/// probing runs the local CLI's own `--version`, which is offline.
///
/// Resolution prefers the first candidate whose `--version` succeeds: the
/// PATH-resolved binary first, then well-known fallback paths. This keeps a
/// worker usable even when a wrapper shadows the real CLI on PATH.
pub fn probe(profile: &WorkerProfile, billing: &BillingPolicy) -> WorkerStatus {
    let command = profile.invocation.command.clone();
    let billing_env_present = present_billing_env(&billing.blocked_worker_env_names);

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(p) = find_binary(&command) {
        candidates.push(p);
    }
    for fb in fallback_paths(&profile.id) {
        if is_executable(&fb) && !candidates.contains(&fb) {
            candidates.push(fb);
        }
    }

    // Prefer a candidate that passes the offline version probe.
    let verified = candidates
        .iter()
        .find_map(|p| read_version(p).map(|v| (p.clone(), v)));

    let (binary_path, version, readiness, detail) = match verified {
        Some((path, version)) => {
            let detail = if billing_env_present.is_empty() {
                "binary found; version ok; AI-billing env clean; will run with sanitized environment"
                    .to_string()
            } else {
                format!(
                    "binary found; version ok; {} AI-billing env var(s) present in parent and will \
                     be scrubbed before the worker runs (policy: {})",
                    billing_env_present.len(),
                    billing.worker_invocation.ai_billing_env_policy
                )
            };
            (Some(path), Some(version), Readiness::Ready, detail)
        }
        None => match candidates.into_iter().next() {
            // A binary exists but no candidate passed `--version`: ambiguous.
            Some(path) => (
                Some(path.clone()),
                None,
                Readiness::Ambiguous,
                format!(
                    "binary resolved to {} but `--version` failed; the resolved CLI or its runtime \
                     is unverified. Set an explicit `command:` path in .agents/workers.yaml or fix \
                     the login, then retry. Yard did not call an AI API and did not ask for an API key.",
                    path.display()
                ),
            ),
            // Nothing found anywhere.
            None => (
                None,
                None,
                Readiness::NotReady,
                format!(
                    "worker CLI '{command}' not found on PATH or known install paths. Install it \
                     and log in with a subscription-backed account, then retry. Yard did not call \
                     an AI API and did not ask for an API key."
                ),
            ),
        },
    };

    WorkerStatus {
        id: profile.id.clone(),
        command,
        binary_path,
        version,
        billing_env_present,
        readiness,
        detail,
    }
}

fn read_version(path: &std::path::Path) -> Option<String> {
    let out = Command::new(path).arg("--version").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let text = if !out.stdout.is_empty() {
        String::from_utf8_lossy(&out.stdout)
    } else {
        String::from_utf8_lossy(&out.stderr)
    };
    let line = text.lines().next()?.trim().to_string();
    if line.is_empty() {
        None
    } else {
        Some(line)
    }
}

/// Build a sanitized environment for spawning a worker: the current process
/// environment minus every blocked billing variable.
///
/// In `block` mode, the presence of any billing variable is a hard stop and
/// this returns an error string instead of an environment.
pub fn sanitized_worker_env(billing: &BillingPolicy) -> Result<Vec<(String, String)>, String> {
    let present = present_billing_env(&billing.blocked_worker_env_names);
    let policy = billing.worker_invocation.ai_billing_env_policy.as_str();

    if policy == "block" && !present.is_empty() {
        return Err(format!(
            "strict billing policy: refusing to run a worker while {} AI-billing env var(s) \
             are set in the parent process. Unset them or switch the policy to 'scrub_or_block'.",
            present.len()
        ));
    }

    Ok(scrub_env(env::vars(), &billing.blocked_worker_env_names))
}

/// Remove every blocked variable from an environment iterator. Pure and
/// independent of the process environment so it can be unit-tested directly.
pub fn scrub_env<I>(vars: I, blocked: &[String]) -> Vec<(String, String)>
where
    I: IntoIterator<Item = (String, String)>,
{
    let blocked: std::collections::HashSet<&str> = blocked.iter().map(|s| s.as_str()).collect();
    vars.into_iter()
        .filter(|(k, _)| !blocked.contains(k.as_str()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrub_removes_only_blocked_names() {
        let vars = vec![
            ("PATH".to_string(), "/usr/bin".to_string()),
            ("OPENAI_API_KEY".to_string(), "sk-secret".to_string()),
            ("HOME".to_string(), "/home/u".to_string()),
            ("ANTHROPIC_API_KEY".to_string(), "sk-secret2".to_string()),
        ];
        let blocked = vec![
            "OPENAI_API_KEY".to_string(),
            "ANTHROPIC_API_KEY".to_string(),
        ];
        let out = scrub_env(vars, &blocked);
        let keys: Vec<&str> = out.iter().map(|(k, _)| k.as_str()).collect();
        assert!(keys.contains(&"PATH"));
        assert!(keys.contains(&"HOME"));
        assert!(!keys.contains(&"OPENAI_API_KEY"));
        assert!(!keys.contains(&"ANTHROPIC_API_KEY"));
    }
}
