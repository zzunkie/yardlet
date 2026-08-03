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
    /// The worker is configured but explicitly disabled in workers.yaml.
    Disabled,
    /// Binary is present but its configured offline version probe failed, so the
    /// resolved CLI or its runtime cannot be confirmed. Yardlet stops rather than
    /// guess (it never risks a billed call to verify auth).
    Ambiguous,
}

impl Readiness {
    pub fn label(self) -> &'static str {
        match self {
            Readiness::Ready => "invocable",
            Readiness::NotReady => "not ready",
            Readiness::Disabled => "disabled",
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
    /// Static generic invocation contract failure. Kept separate so staged
    /// status can report why no version subprocess was started.
    pub contract_error: Option<String>,
    pub readiness: Readiness,
    pub detail: String,
}

/// Read-only bridge from the authoritative guard verdict to plan-time
/// capability coverage. Capabilities stay raw here; routing owns their shared
/// normalization vocabulary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkerCapabilityReadiness {
    pub worker_id: String,
    pub readiness: Readiness,
    pub capabilities: Vec<String>,
}

/// Probe every configured worker through the same offline gates used before
/// invocation, then pair the verdict with its declared capabilities.
pub fn capability_readiness_projection(
    workers: &crate::schemas::WorkersFile,
    billing: &BillingPolicy,
    requested_access: &str,
) -> Vec<WorkerCapabilityReadiness> {
    workers
        .workers
        .iter()
        .map(|profile| WorkerCapabilityReadiness {
            worker_id: profile.id.clone(),
            readiness: probe(profile, billing, requested_access).readiness,
            capabilities: profile.capabilities.clone(),
        })
        .collect()
}

/// Cache identity for the inputs that can change an offline readiness verdict.
/// It contains configuration and billing-variable names/presence only, never
/// secret values. Snapshot/TUI cheap reloads use this to avoid carrying a ready
/// verdict across an edited invocation contract, billing posture, or access
/// level (a generic worker's verdict depends on the requested access).
pub fn readiness_cache_key(
    profile: &WorkerProfile,
    billing: &BillingPolicy,
    requested_access: &str,
) -> String {
    let invocation = serde_json::to_string(&profile.invocation)
        .unwrap_or_else(|_| format!("{:?}", profile.invocation));
    let present = present_billing_env(&billing.blocked_worker_env_names);
    format!(
        "{}|{}|{}|{}|{}|{}",
        profile.id,
        profile.enabled,
        billing.worker_invocation.ai_billing_env_policy,
        present.join(","),
        requested_access,
        invocation
    )
}

/// Validate that a generic profile's `sandbox_args` actually declare a
/// bounded-write sandbox contract: non-empty, distinct from the full-access
/// arguments, free of elevation markers and unknown placeholders, and carrying
/// at least one literal flag. Yardlet cannot infer a missing flag or guess the
/// meaning of an unknown placeholder, so callers fail closed on Err.
pub fn generic_sandbox_declaration(profile: &WorkerProfile) -> Result<(), String> {
    let sandbox = &profile.invocation.sandbox_args;
    if sandbox.is_empty() || sandbox.iter().any(|arg| arg.trim().is_empty()) {
        return Err("sandbox_args must be non-empty".to_string());
    }
    if !profile.invocation.full_access_args.is_empty()
        && sandbox == &profile.invocation.full_access_args
    {
        return Err("sandbox and full-access arguments are identical".to_string());
    }

    let mut has_literal_contract = false;
    for arg in sandbox {
        let lower = arg.to_ascii_lowercase();
        if [
            "dangerously",
            "bypass",
            "full-access",
            "disable-sandbox",
            "no-sandbox",
            "unrestricted",
        ]
        .iter()
        .any(|marker| lower.contains(marker))
        {
            return Err("sandbox_args contain an elevation marker".to_string());
        }
        let remainder = ["{run_dir}", "{model}", "{effort}", "{image}"]
            .iter()
            .fold(arg.to_string(), |value, placeholder| {
                value.replace(placeholder, "")
            });
        if remainder.contains('{') || remainder.contains('}') {
            return Err("sandbox_args contain an unknown placeholder".to_string());
        }
        has_literal_contract |= !remainder.trim().is_empty();
    }
    if !has_literal_contract {
        return Err("sandbox_args do not declare a sandbox mode".to_string());
    }
    Ok(())
}

/// Validate the sandbox declaration used by a planning capability scout.
///
/// Built-in adapters have a core-owned sandbox argument shape. A generic
/// adapter must provide a distinct, non-empty, syntactically checkable
/// sandbox contract. Those profiles fail closed before scout spawn. The
/// disposable workspace remains the filesystem isolation boundary.
pub fn scout_sandbox_contract(profile: &WorkerProfile) -> Result<(), String> {
    if matches!(profile.id.as_str(), "codex" | "claude-code") {
        return Ok(());
    }
    generic_sandbox_declaration(profile).map_err(|reason| {
        format!("generic planning scout sandbox contract failed closed: {reason}")
    })
}

/// Whether this profile can honor the requested access level (issue #123).
///
/// `sandboxed` is an enforced boundary for the built-in adapters, whose
/// sandbox flags are core-owned; for a generic worker it is only ever the
/// profile's own declaration. A generic profile that declares no sandbox
/// contract cannot honor `sandboxed`, so it fails closed here instead of
/// running unbounded while the workspace believes writes are bounded.
pub fn access_contract(profile: &WorkerProfile, requested_access: &str) -> Result<(), String> {
    if requested_access != "sandboxed" {
        return Ok(());
    }
    if matches!(profile.id.as_str(), "codex" | "claude-code") {
        return Ok(());
    }
    generic_sandbox_declaration(profile).map_err(|reason| {
        format!(
            "worker '{}' cannot honor sandboxed access: {reason}. Yardlet cannot verify a \
             sandbox it does not own, so this profile is not invocable while the workspace \
             asks for sandboxed access; declare a real sandbox in invocation.sandbox_args \
             or grant full access explicitly (yardlet access full)",
            profile.id
        )
    })
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
    /// Worker is explicitly disabled in workers.yaml.
    Disabled,
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
            StageMark::Disabled => "off",
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

/// Whether a worker's billing env would hard-stop a run under this policy: the
/// single source of truth for the "blocked" posture, shared by the staged
/// status, the verdict, and the TUI workers panel (via snapshot). Strict
/// (`block`) policy hard-stops when any AI-billing env var is present; the
/// default scrub policy never blocks (it removes the vars before spawn).
pub fn billing_blocked(policy: &str, billing_env_present: usize) -> bool {
    policy == "block" && billing_env_present > 0
}

/// Static gates that must hold before Yardlet starts either the worker or its
/// offline version probe. Built-in adapters keep their core-owned command
/// shapes, while generic workers must also have a structurally valid template.
pub fn invocation_contract(profile: &WorkerProfile) -> Result<(), String> {
    if !profile.invocation.supports_noninteractive {
        return Err(format!(
            "worker '{}' invocation supports_noninteractive must be true",
            profile.id
        ));
    }
    let output = profile.invocation.output_contract.trim();
    match profile.id.as_str() {
        "codex" | "claude-code" if matches!(output, "files" | "json_or_files") => Ok(()),
        "codex" | "claude-code" => Err(format!(
            "worker '{}' has unsupported output_contract '{}'; expected files or json_or_files",
            profile.id, output
        )),
        _ if output != "files" => Err(format!(
            "worker '{}' generic invocation has unsupported output_contract '{}'; expected files",
            profile.id, output
        )),
        _ => profile.invocation.validate_generic(&profile.id),
    }
}

impl WorkerStatus {
    /// The readiness gates as a staged checklist for `yardlet worker status`.
    ///
    /// Auth is deliberately reported as unverifiable offline: Yardlet never
    /// makes a billed call to confirm a subscription login, so it never claims
    /// the login was verified. It only reports what it can prove locally.
    pub fn stages(&self, billing: &BillingPolicy) -> Vec<StatusStage> {
        if self.readiness == Readiness::Disabled {
            return vec![StatusStage {
                label: "enabled",
                mark: StageMark::Disabled,
                note: "disabled in .agents/workers.yaml".to_string(),
            }];
        }

        let contract = match &self.contract_error {
            Some(error) => StatusStage {
                label: "contract",
                mark: StageMark::Fail,
                note: error.clone(),
            },
            None => StatusStage {
                label: "contract",
                mark: StageMark::Pass,
                note: "non-interactive file-result invocation contract is valid".to_string(),
            },
        };

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

        let policy = billing.worker_invocation.ai_billing_env_policy.as_str();
        let blocked = billing_blocked(policy, self.billing_env_present.len());
        let version = if self.contract_error.is_some() {
            StatusStage {
                label: "version",
                mark: StageMark::Skipped,
                note: "invocation contract failed; offline probe was not started".to_string(),
            }
        } else if blocked {
            StatusStage {
                label: "version",
                mark: StageMark::Skipped,
                note: "strict billing policy blocked the offline probe before spawn".to_string(),
            }
        } else {
            match (&self.binary_path, &self.version) {
            (Some(_), Some(v)) => StatusStage {
                label: "version",
                mark: StageMark::Pass,
                note: v.clone(),
            },
            (Some(_), None) => StatusStage {
                label: "version",
                mark: StageMark::Fail,
                note: "configured offline version probe failed; resolved CLI or its runtime is unverified"
                    .to_string(),
            },
            (None, _) => StatusStage {
                label: "version",
                mark: StageMark::Skipped,
                note: "no binary to probe".to_string(),
            },
            }
        };

        let billing_env = if self.billing_env_present.is_empty() {
            StatusStage {
                label: "billing-env",
                mark: StageMark::Pass,
                note: "AI-billing env clean".to_string(),
            }
        } else if billing_blocked(policy, self.billing_env_present.len()) {
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

        vec![contract, binary, version, billing_env, auth]
    }

    /// One-line verdict framed as invocation safety under the current policy,
    /// never as a claim that the subscription login itself was verified.
    pub fn invocation_verdict(&self, billing: &BillingPolicy) -> String {
        let policy = billing.worker_invocation.ai_billing_env_policy.as_str();
        match self.readiness {
            _ if billing_blocked(policy, self.billing_env_present.len()) => {
                "blocked: strict billing policy refuses to run while AI-billing env is set"
                    .to_string()
            }
            _ if self.contract_error.is_some() => format!(
                "not invocable: {}",
                self.contract_error.as_deref().unwrap_or_default()
            ),
            Readiness::Ready => {
                "safe to invoke under current policy (auth not verified offline)".to_string()
            }
            Readiness::Ambiguous => {
                "not invocable: binary found but unverified (see version gate)".to_string()
            }
            Readiness::NotReady => format!("not invocable: {}", self.detail),
            Readiness::Disabled => {
                "not invocable: worker is disabled in .agents/workers.yaml".to_string()
            }
        }
    }
}

/// Locate an executable on PATH (a small, dependency-free `which`).
pub fn find_binary(command: &str) -> Option<PathBuf> {
    // An explicit path is honored as-is.
    if command.contains('/') {
        let p = PathBuf::from(command);
        return if is_executable(&p) { Some(p) } else { None };
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
/// binary is missing or its offline version probe fails (e.g. a shell alias or a
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
/// probing runs the local CLI's configured arguments, which must be offline.
/// Built-in adapters retain their core-owned `--version` probe.
///
/// Resolution prefers the first candidate whose version probe succeeds: the
/// PATH-resolved binary first, then well-known fallback paths. This keeps a
/// worker usable even when a wrapper shadows the real CLI on PATH.
pub fn probe(
    profile: &WorkerProfile,
    billing: &BillingPolicy,
    requested_access: &str,
) -> WorkerStatus {
    let command = profile.invocation.command.clone();
    let billing_env_present = present_billing_env(&billing.blocked_worker_env_names);

    if !profile.enabled {
        return WorkerStatus {
            id: profile.id.clone(),
            command,
            binary_path: None,
            version: None,
            billing_env_present,
            contract_error: None,
            readiness: Readiness::Disabled,
            detail: "disabled in .agents/workers.yaml".to_string(),
        };
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(p) = find_binary(&command) {
        candidates.push(p);
    }
    for fb in fallback_paths(&profile.id) {
        if is_executable(&fb) && !candidates.contains(&fb) {
            candidates.push(fb);
        }
    }

    let contract_error = invocation_contract(profile)
        .and_then(|()| access_contract(profile, requested_access))
        .err();
    if let Some(error) = contract_error {
        return WorkerStatus {
            id: profile.id.clone(),
            command,
            binary_path: candidates.into_iter().next(),
            version: None,
            billing_env_present,
            contract_error: Some(error.clone()),
            readiness: Readiness::NotReady,
            detail: error,
        };
    }

    if billing_blocked(
        &billing.worker_invocation.ai_billing_env_policy,
        billing_env_present.len(),
    ) {
        return WorkerStatus {
            id: profile.id.clone(),
            command,
            binary_path: candidates.into_iter().next(),
            version: None,
            billing_env_present,
            contract_error: None,
            readiness: Readiness::NotReady,
            detail: "strict billing policy refuses to start any worker subprocess while AI-billing env is set"
                .to_string(),
        };
    }

    // Prefer a candidate that passes the offline version probe. Generic
    // profiles own their probe arguments; built-in adapter behavior stays
    // core-owned and unchanged.
    let built_in_version_args = vec!["--version".to_string()];
    let version_args = if matches!(profile.id.as_str(), "codex" | "claude-code") {
        &built_in_version_args
    } else {
        &profile.invocation.version_args
    };
    let verified = candidates
        .iter()
        .find_map(|p| read_version(p, version_args, billing).map(|v| (p.clone(), v)));

    let (binary_path, version, readiness, detail) = match verified {
        Some((path, version)) => {
            let mut detail = if billing_env_present.is_empty() {
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
            // An operator reading "sandboxed" must be able to tell an enforced
            // boundary from a declared one (issue #123): the generic sandbox
            // passed the declaration check above, but Yardlet does not own it.
            if requested_access == "sandboxed"
                && !matches!(profile.id.as_str(), "codex" | "claude-code")
            {
                detail.push_str(
                    "; sandbox is profile-declared, not verified by Yardlet",
                );
            }
            (Some(path), Some(version), Readiness::Ready, detail)
        }
        None => match candidates.into_iter().next() {
            // A binary exists but no candidate passed its version probe: ambiguous.
            Some(path) => (
                Some(path.clone()),
                None,
                Readiness::Ambiguous,
                format!(
                    "binary resolved to {} but the configured offline version probe failed; the resolved CLI or its runtime \
                     is unverified. Set an explicit `command:` path in .agents/workers.yaml or fix \
                     the local CLI runtime, then retry. Yardlet did not call an AI API and did not ask for an API key.",
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
        contract_error: None,
        readiness,
        detail,
    }
}

fn read_version(
    path: &std::path::Path,
    version_args: &[String],
    billing: &BillingPolicy,
) -> Option<String> {
    let env = sanitized_worker_env_for(billing, &[]).ok()?;
    let mut command = Command::new(path);
    command.args(version_args).env_clear();
    for (key, value) in env {
        command.env(key, value);
    }
    let out = command.output().ok()?;
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
            contract_error: None,
            readiness: Readiness::Ready,
            detail: String::new(),
        }
    }

    #[test]
    fn billing_blocked_only_when_strict_policy_and_env_present() {
        // Default scrub policy never blocks, even with billing env present.
        assert!(!billing_blocked("scrub_or_block", 2));
        // Strict policy blocks only when billing env is actually present.
        assert!(billing_blocked("block", 1));
        assert!(!billing_blocked("block", 0));
    }

    #[test]
    fn disabled_worker_is_not_reported_as_invocable() {
        let profile: WorkerProfile = serde_yaml_ng::from_str(
            r#"
id: disabled-cargo
enabled: false
invocation:
  command: cargo
"#,
        )
        .unwrap();
        let billing = BillingPolicy::default();

        let status = probe(&profile, &billing, "full");

        assert_ne!(status.readiness, Readiness::Ready);
        assert_eq!(status.readiness.label(), "disabled");
        assert!(status.invocation_verdict(&billing).contains("disabled"));
        let stages = status.stages(&billing);
        assert_eq!(stages.len(), 1);
        assert_eq!(stages[0].label, "enabled");
        assert_eq!(stages[0].mark, StageMark::Disabled);
    }

    #[test]
    fn generic_invocation_contract_blocks_false_ready_profiles() {
        for (yaml, expected) in [
            (
                r#"
id: generic
invocation:
  command: bash
  supports_noninteractive: false
  output_contract: files
"#,
                "supports_noninteractive",
            ),
            (
                r#"
id: generic
invocation:
  command: bash
  supports_noninteractive: true
  output_contract: stdout_json
"#,
                "output_contract",
            ),
        ] {
            let profile: WorkerProfile = crate::yaml::from_str(yaml).unwrap();
            let status = probe(&profile, &BillingPolicy::default(), "full");
            assert_eq!(status.readiness, Readiness::NotReady, "{}", status.detail);
            assert!(status.detail.contains(expected), "{}", status.detail);
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

    #[test]
    fn capability_readiness_projection_keeps_ready_not_ready_and_disabled_distinct() {
        let workers: crate::schemas::WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - id: ready\n    capabilities: [Shell Tool]\n    invocation: { command: bash, supports_noninteractive: true, output_contract: files }\n  - id: absent\n    capabilities: [browser]\n    invocation: { command: yardlet-definitely-missing-command, supports_noninteractive: true, output_contract: files }\n  - id: disabled\n    enabled: false\n    capabilities: [image-generation]\n    invocation: { command: bash }\n",
        )
        .unwrap();
        let projection =
            capability_readiness_projection(&workers, &BillingPolicy::default(), "full");
        assert_eq!(projection.len(), 3);
        assert_eq!(projection[0].readiness, Readiness::Ready);
        assert_eq!(projection[1].readiness, Readiness::NotReady);
        assert_eq!(projection[2].readiness, Readiness::Disabled);
        assert_eq!(projection[0].capabilities, vec!["Shell Tool"]);
    }

    #[test]
    fn built_in_adapters_keep_their_existing_file_contracts_invocable() {
        for (id, output_contract) in [("codex", "files"), ("claude-code", "json_or_files")] {
            let profile: WorkerProfile = crate::yaml::from_str(&format!(
                "id: {id}\ninvocation:\n  command: bash\n  supports_noninteractive: true\n  output_contract: {output_contract}\n  version_args: [definitely-not-a-built-in-version-flag]\n"
            ))
            .unwrap();
            let status = probe(&profile, &BillingPolicy::default(), "full");
            assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
            assert!(status.contract_error.is_none());
        }
    }

    // Issue #123: `sandboxed` must not be an unverified claim for generic
    // workers. A profile that declares no way to bound writes is not invocable
    // while the workspace asks for sandboxed access, and stays invocable under
    // explicit full access.
    #[test]
    fn generic_worker_without_sandbox_declaration_is_not_invocable_under_sandboxed_access() {
        let profile: WorkerProfile = crate::yaml::from_str(
            "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files }\n",
        )
        .unwrap();
        let billing = BillingPolicy::default();

        let sandboxed = probe(&profile, &billing, "sandboxed");
        assert_eq!(
            sandboxed.readiness,
            Readiness::NotReady,
            "{}",
            sandboxed.detail
        );
        assert!(
            sandboxed.detail.contains("cannot honor sandboxed access"),
            "{}",
            sandboxed.detail
        );

        let full = probe(&profile, &billing, "full");
        assert_eq!(full.readiness, Readiness::Ready, "{}", full.detail);
    }

    #[test]
    fn generic_worker_with_declared_sandbox_is_ready_but_labeled_declared_not_verified() {
        let profile: WorkerProfile = crate::yaml::from_str(
            "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, sandbox_args: ['--restricted'] }\n",
        )
        .unwrap();
        let status = probe(&profile, &BillingPolicy::default(), "sandboxed");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        assert!(
            status.detail.contains("profile-declared, not verified"),
            "{}",
            status.detail
        );
    }

    #[test]
    fn built_in_adapters_stay_invocable_under_sandboxed_access_without_declared_label() {
        for id in ["codex", "claude-code"] {
            let profile: WorkerProfile = crate::yaml::from_str(&format!(
                "id: {id}\ninvocation: {{ command: bash, supports_noninteractive: true, output_contract: files }}\n"
            ))
            .unwrap();
            let status = probe(&profile, &BillingPolicy::default(), "sandboxed");
            assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
            assert!(
                !status.detail.contains("profile-declared"),
                "{}",
                status.detail
            );
        }
    }

    #[test]
    fn access_contract_rejects_elevation_markers_and_identical_full_args_under_sandboxed() {
        let base = "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, sandbox_args: ['--dangerously-bypass'] }\n";
        let profile: WorkerProfile = crate::yaml::from_str(base).unwrap();
        let error = access_contract(&profile, "sandboxed").unwrap_err();
        assert!(error.contains("elevation marker"), "{error}");
        assert!(access_contract(&profile, "full").is_ok());

        let identical: WorkerProfile = crate::yaml::from_str(
            "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, sandbox_args: ['--x'], full_access_args: ['--x'] }\n",
        )
        .unwrap();
        let error = access_contract(&identical, "sandboxed").unwrap_err();
        assert!(error.contains("identical"), "{error}");
    }

    #[test]
    fn readiness_cache_key_changes_with_requested_access() {
        let profile: WorkerProfile = crate::yaml::from_str(
            "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files }\n",
        )
        .unwrap();
        let billing = BillingPolicy::default();
        assert_ne!(
            readiness_cache_key(&profile, &billing, "sandboxed"),
            readiness_cache_key(&profile, &billing, "full")
        );
    }

    #[test]
    fn generic_scout_sandbox_contract_fails_closed_when_missing_or_unverifiable() {
        let profile = |sandbox_args: &[&str], full_access_args: &[&str]| WorkerProfile {
            id: "generic-fixture".into(),
            enabled: true,
            kind: "cli_worker".into(),
            role_strengths: vec![],
            capabilities: vec![],
            best_for: String::new(),
            not_for: String::new(),
            cost_weight: String::new(),
            model: String::new(),
            effort: String::new(),
            billing: crate::schemas::Billing::default(),
            invocation: crate::schemas::Invocation {
                command: "bash".into(),
                supports_noninteractive: true,
                output_contract: "files".into(),
                args: vec!["{run_dir}".into()],
                prompt_transport: "stdin".into(),
                version_args: vec!["--version".into()],
                sandbox_args: sandbox_args.iter().map(|arg| (*arg).into()).collect(),
                full_access_args: full_access_args.iter().map(|arg| (*arg).into()).collect(),
                image_args: vec![],
                model_args: vec![],
                effort_args: vec![],
                pass_env: vec![],
                session: None,
            },
            limits: crate::schemas::Limits::default(),
            provider_response_refusal_patterns: vec![],
            background_deferral_patterns: vec![],
        };

        assert!(scout_sandbox_contract(&profile(&[], &[])).is_err());
        assert!(scout_sandbox_contract(&profile(&["   "], &[])).is_err());
        assert!(scout_sandbox_contract(&profile(&["{unknown_mode}"], &[])).is_err());
        assert!(scout_sandbox_contract(&profile(&["sandboxed"], &["sandboxed"])).is_err());
        assert!(scout_sandbox_contract(&profile(&["sandboxed"], &["full"])).is_ok());

        let mut builtin = profile(&[], &[]);
        builtin.id = "codex".into();
        assert!(scout_sandbox_contract(&builtin).is_ok());
    }
}
