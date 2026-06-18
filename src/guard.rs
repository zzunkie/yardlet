//! Zero-key worker guard.
//!
//! Yardlet core never requires, requests, stores, or calls AI provider API keys.
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
    /// resolved CLI or its runtime cannot be confirmed. Yardlet stops rather than
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

/// The outcome of one readiness gate in the staged worker-status display.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StageMark {
    /// Gate satisfied.
    Pass,
    /// Gate failed; blocks readiness.
    Fail,
    /// Billing env present, but the policy scrubs it before spawning (safe).
    Scrubbed,
    /// Hard stop: strict (`block`) policy refuses to run while billing env is set.
    Blocked,
    /// Cannot be checked offline. Not a failure: Yardlet never makes a billed
    /// call to verify auth, so it relies on the worker's own subscription login.
    Offline,
    /// Gate does not apply (e.g. version when no binary was found).
    Skipped,
}

impl StageMark {
    /// A short marker for the staged checklist.
    pub fn marker(self) -> &'static str {
        match self {
            StageMark::Pass => "ok",
            StageMark::Fail => "FAIL",
            StageMark::Scrubbed => "scrub",
            StageMark::Blocked => "BLOCK",
            StageMark::Offline => "n/a",
            StageMark::Skipped => "-",
        }
    }
}

/// One line of the staged worker-status checklist.
#[derive(Debug, Clone)]
pub struct StatusStage {
    pub label: &'static str,
    pub mark: StageMark,
    pub note: String,
}

impl WorkerStatus {
    /// The readiness gates as a staged checklist for `yardlet worker status`.
    ///
    /// Auth is deliberately reported as unverifiable offline: Yardlet never
    /// makes a billed call to confirm a subscription login, so it never claims
    /// the login was verified. It only reports what it can prove locally.
    pub fn stages(&self, billing: &BillingPolicy) -> Vec<StatusStage> {
        let binary = match &self.binary_path {
            Some(p) => StatusStage {
                label: "binary",
                mark: StageMark::Pass,
                note: format!("found: {}", p.display()),
            },
            None => StatusStage {
                label: "binary",
                mark: StageMark::Fail,
                note: format!(
                    "'{}' not found on PATH or known install paths",
                    self.command
                ),
            },
        };

        let version = match (&self.binary_path, &self.version) {
            (Some(_), Some(v)) => StatusStage {
                label: "version",
                mark: StageMark::Pass,
                note: v.clone(),
            },
            (Some(_), None) => StatusStage {
                label: "version",
                mark: StageMark::Fail,
                note: "offline `--version` probe failed; resolved CLI or its runtime is unverified"
                    .to_string(),
            },
            (None, _) => StatusStage {
                label: "version",
                mark: StageMark::Skipped,
                note: "no binary to probe".to_string(),
            },
        };

        let policy = billing.worker_invocation.ai_billing_env_policy.as_str();
        let billing_env = if self.billing_env_present.is_empty() {
            StatusStage {
                label: "billing-env",
                mark: StageMark::Pass,
                note: "AI-billing env clean".to_string(),
            }
        } else if policy == "block" {
            StatusStage {
                label: "billing-env",
                mark: StageMark::Blocked,
                note: format!(
                    "{} var(s) present and policy is strict (block): the worker will refuse to run until unset [{}]",
                    self.billing_env_present.len(),
                    self.billing_env_present.join(", ")
                ),
            }
        } else {
            StatusStage {
                label: "billing-env",
                mark: StageMark::Scrubbed,
                note: format!(
                    "{} var(s) present, scrubbed before the worker runs (policy: {}) [{}]",
                    self.billing_env_present.len(),
                    policy,
                    self.billing_env_present.join(", ")
                ),
            }
        };

        let auth = StatusStage {
            label: "auth",
            mark: StageMark::Offline,
            note: "not verified offline; Yardlet never makes a billed call to check, it relies on the worker's own subscription login".to_string(),
        };

        vec![binary, version, billing_env, auth]
    }

    /// One-line verdict framed as invocation safety under the current policy,
    /// never as a claim that the subscription login itself was verified.
    pub fn invocation_verdict(&self, billing: &BillingPolicy) -> String {
        let policy = billing.worker_invocation.ai_billing_env_policy.as_str();
        match self.readiness {
            Readiness::Ready if policy == "block" && !self.billing_env_present.is_empty() => {
                "blocked: strict billing policy refuses to run while AI-billing env is set"
                    .to_string()
            }
            Readiness::Ready => {
                "safe to invoke under current policy (auth not verified offline)".to_string()
            }
            Readiness::Ambiguous => {
                "not invocable: binary found but unverified (see version gate)".to_string()
            }
            Readiness::NotReady => "not invocable: worker CLI not installed".to_string(),
        }
    }
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
                     the login, then retry. Yardlet did not call an AI API and did not ask for an API key.",
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
                     and log in with a subscription-backed account, then retry. Yardlet did not call \
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
/// A worker profile may opt back in to specific variables
/// (`invocation.pass_env`). Zero-key stays the DEFAULT: nothing passes
/// through unless the user names it on that worker in workers.yaml, and
/// Yardlet itself never reads, stores, or requires the value.
pub fn sanitized_worker_env_for(
    billing: &BillingPolicy,
    pass_env: &[String],
) -> Result<Vec<(String, String)>, String> {
    let present = present_billing_env(&billing.blocked_worker_env_names);
    let policy = billing.worker_invocation.ai_billing_env_policy.as_str();

    if policy == "block" && !present.is_empty() {
        return Err(format!(
            "strict billing policy: refusing to run a worker while {} AI-billing env var(s) \
             are set in the parent process. Unset them or switch the policy to 'scrub_or_block'.",
            present.len()
        ));
    }

    let blocked: Vec<String> = billing
        .blocked_worker_env_names
        .iter()
        .filter(|b| !pass_env.contains(b))
        .cloned()
        .collect();
    Ok(scrub_env(env::vars(), &blocked))
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
    fn pass_env_opts_a_worker_back_in_to_a_blocked_var() {
        let var = "YARD_TEST_FAKE_KEY_7741";
        std::env::set_var(var, "sk-test");
        let billing = BillingPolicy {
            schema_version: 1,
            mode: String::new(),
            worker_invocation: Default::default(),
            blocked_worker_env_names: vec![var.to_string()],
        };
        // Default: scrubbed.
        let env = sanitized_worker_env_for(&billing, &[]).unwrap();
        assert!(!env.iter().any(|(k, _)| k == var));
        // Explicit per-worker opt-in: passed through.
        let env = sanitized_worker_env_for(&billing, &[var.to_string()]).unwrap();
        assert!(env.iter().any(|(k, v)| k == var && v == "sk-test"));
        std::env::remove_var(var);
    }

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

    fn billing_with_policy(policy: &str) -> BillingPolicy {
        let mut b = BillingPolicy {
            schema_version: 1,
            mode: String::new(),
            worker_invocation: Default::default(),
            blocked_worker_env_names: vec![],
        };
        b.worker_invocation.ai_billing_env_policy = policy.to_string();
        b
    }

    fn ready_status(billing_env_present: Vec<String>) -> WorkerStatus {
        WorkerStatus {
            id: "codex".into(),
            command: "codex".into(),
            binary_path: Some(PathBuf::from("/usr/local/bin/codex")),
            version: Some("codex 1.0.0".into()),
            billing_env_present,
            readiness: Readiness::Ready,
            detail: String::new(),
        }
    }

    #[test]
    fn staged_status_reports_auth_as_unverified_offline_never_claims_verified() {
        let billing = billing_with_policy("scrub_or_block");
        let stages = ready_status(vec![]).stages(&billing);
        let auth = stages.iter().find(|s| s.label == "auth").unwrap();
        assert_eq!(auth.mark, StageMark::Offline);
        assert!(auth.note.contains("not verified offline"));
        // The verdict speaks to invocation safety, not auth verification.
        let verdict = ready_status(vec![]).invocation_verdict(&billing);
        assert!(verdict.contains("safe to invoke under current policy"));
        assert!(!verdict.to_lowercase().contains("auth verified"));
    }

    #[test]
    fn staged_status_marks_billing_env_scrubbed_vs_blocked_by_policy() {
        let present = vec!["OPENAI_API_KEY".to_string()];
        // scrub policy: present env is scrubbed, still safe to invoke.
        let scrub = billing_with_policy("scrub_or_block");
        let stage = ready_status(present.clone())
            .stages(&scrub)
            .into_iter()
            .find(|s| s.label == "billing-env")
            .unwrap();
        assert_eq!(stage.mark, StageMark::Scrubbed);
        assert!(ready_status(present.clone())
            .invocation_verdict(&scrub)
            .contains("safe to invoke"));
        // block policy: present env is a hard stop.
        let block = billing_with_policy("block");
        let stage = ready_status(present.clone())
            .stages(&block)
            .into_iter()
            .find(|s| s.label == "billing-env")
            .unwrap();
        assert_eq!(stage.mark, StageMark::Blocked);
        assert!(ready_status(present)
            .invocation_verdict(&block)
            .contains("blocked"));
    }
}
