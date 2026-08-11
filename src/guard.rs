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
    /// A binary answered the probe, but its declared identity signature does not
    /// match: a different product is installed under the same command name.
    WrongProduct,
    /// The resolved CLI is the right product but reports a version below the
    /// profile's declared `min_version`.
    UnsupportedVersion,
    /// The declared offline auth probe positively reported that the CLI is not
    /// logged in. An unknown login is never this state (it stays Ready).
    Unauthenticated,
}

impl Readiness {
    pub fn label(self) -> &'static str {
        match self {
            Readiness::Ready => "invocable",
            Readiness::NotReady => "not ready",
            Readiness::Disabled => "disabled",
            Readiness::Ambiguous => "ambiguous",
            Readiness::WrongProduct => "wrong product",
            Readiness::UnsupportedVersion => "unsupported version",
            Readiness::Unauthenticated => "unauthenticated",
        }
    }
}

/// Outcome of the optional offline product-identity gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdentityState {
    /// No `identity_probe` in the profile: legacy posture, nothing was spawned.
    NotDeclared,
    /// The probe's first line carried the declared signature.
    Matched,
    /// The probe ran and its first line did NOT carry the declared signature.
    Mismatched,
    /// The probe could not be run (non-zero exit, no output, or no spawn).
    Unverified,
}

/// Outcome of the optional offline auth gate. Deliberately three-valued:
/// Yardlet never makes a billed call to verify a subscription login, so only a
/// positively reported "not logged in" blocks; anything else stays invocable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthState {
    /// No `auth_probe` in the profile: unchanged "not verified offline" posture.
    NotProbed,
    /// A declared unauthenticated pattern matched the probe output.
    Unauthenticated,
    /// A declared ready pattern matched the probe output.
    Authenticated,
    /// The probe was declared but inconclusive (no pattern matched, or it could
    /// not be run). Never blocks.
    Unknown,
}

/// Outcome of the optional `min_version` gate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionVerdict {
    /// Both sides parsed and the found version is at or above the minimum.
    Satisfied,
    /// Both sides parsed and the found version is below the minimum.
    Below,
    /// No `min_version` declared, or either side carries no numeric triple.
    /// Unknown is never a block.
    Undetermined,
}

/// Does an identity probe's first output line identify the expected product?
///
/// Case-insensitive substring match, so a profile can declare a stable product
/// marker (`"codex-cli"`) without pinning the whole version banner. An empty
/// signature has nothing to check and cannot fail (the static contract gate
/// rejects a declared-but-empty signature before any spawn).
pub fn identity_matches(first_line: &str, expected_signature: &str) -> bool {
    let expected = expected_signature.trim().to_lowercase();
    if expected.is_empty() {
        return true;
    }
    first_line.to_lowercase().contains(&expected)
}

/// Tolerant three-way auth verdict over an auth probe's combined output
/// (stdout + stderr). Unauthenticated patterns win over ready patterns so a CLI
/// that prints both a banner and a "not logged in" line is not read as ready.
/// Exit status is deliberately NOT a verdict: many CLIs exit non-zero exactly
/// when they are logged out, and an unrunnable probe must stay Unknown.
pub fn auth_state_from_output(
    output: &str,
    ready_patterns: &[String],
    unauthenticated_patterns: &[String],
) -> AuthState {
    let haystack = output.to_lowercase();
    let matches = |patterns: &[String]| {
        patterns
            .iter()
            .map(|pattern| pattern.trim().to_lowercase())
            .filter(|pattern| !pattern.is_empty())
            .any(|pattern| haystack.contains(&pattern))
    };
    if matches(unauthenticated_patterns) {
        AuthState::Unauthenticated
    } else if matches(ready_patterns) {
        AuthState::Authenticated
    } else {
        AuthState::Unknown
    }
}

/// Tolerant version comparison: compare the first `major.minor.patch` triple
/// found on each side and treat anything unparseable as undetermined. Yardlet
/// cannot know a worker CLI's private versioning scheme, so an uncomparable
/// version is reported as unknown and never blocks a run.
pub fn version_verdict(found: &str, min_version: &str) -> VersionVerdict {
    match (numeric_triple(found), numeric_triple(min_version)) {
        (Some(found), Some(min)) if found >= min => VersionVerdict::Satisfied,
        (Some(_), Some(_)) => VersionVerdict::Below,
        _ => VersionVerdict::Undetermined,
    }
}

/// The first `N.N.N` triple in a string, ignoring any surrounding banner text
/// and any pre-release suffix (`1.2.3-beta` parses as 1.2.3).
fn numeric_triple(text: &str) -> Option<(u64, u64, u64)> {
    let bytes: Vec<char> = text.chars().collect();
    let mut index = 0usize;
    while index < bytes.len() {
        if !bytes[index].is_ascii_digit() {
            index += 1;
            continue;
        }
        // A triple must start at a component boundary, not mid-number.
        if index > 0 && bytes[index - 1].is_ascii_digit() {
            index += 1;
            continue;
        }
        let mut cursor = index;
        let mut parts: Vec<u64> = Vec::new();
        while parts.len() < 3 {
            let start = cursor;
            while cursor < bytes.len() && bytes[cursor].is_ascii_digit() {
                cursor += 1;
            }
            if cursor == start {
                break;
            }
            let digits: String = bytes[start..cursor].iter().collect();
            match digits.parse::<u64>() {
                Ok(value) => parts.push(value),
                Err(_) => break,
            }
            if parts.len() == 3 {
                break;
            }
            if cursor < bytes.len() && bytes[cursor] == '.' {
                cursor += 1;
            } else {
                break;
            }
        }
        if parts.len() == 3 {
            return Some((parts[0], parts[1], parts[2]));
        }
        index = cursor.max(index + 1);
    }
    None
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
    /// Outcome of the optional offline product-identity gate.
    pub identity: IdentityState,
    /// Outcome of the optional offline auth gate.
    pub auth: AuthState,
    /// The profile's declared `min_version`, carried so status, the snapshot,
    /// and the TUI can all say "upgrade to >= X" without re-reading the config.
    pub required_version: Option<String>,
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
    profile.invocation.validate_probes(&profile.id)?;
    profile.invocation.validate_output_format(&profile.id)?;
    let output = profile.invocation.output_contract.trim();
    // `output_contract` answers "where does the RESULT come from"; the newer
    // `output_format` answers "what shape is stdout". They must not read as
    // rival knobs: `json_or_files` stays the built-in adapters' core-owned
    // result contract, and a generic worker keeps the `files` contract plus the
    // tolerant stdout fallback its `output_format` declaration authorizes.
    match profile.id.as_str() {
        "codex" | "claude-code" if matches!(output, "files" | "json_or_files") => Ok(()),
        "codex" | "claude-code" => Err(format!(
            "worker '{}' has unsupported output_contract '{}'; expected files or json_or_files",
            profile.id, output
        )),
        _ if output != "files" => Err(format!(
            "worker '{}' generic invocation has unsupported output_contract '{}'; expected files \
             (declare structured stdout with output_format, not output_contract)",
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

        // Only a profile that declared an identity probe gets the extra gate
        // line; every other profile keeps the existing checklist unchanged.
        let identity = match self.identity {
            IdentityState::NotDeclared => None,
            IdentityState::Matched => Some(StatusStage {
                label: "identity",
                mark: StageMark::Pass,
                note: "identity probe matched the declared product signature".to_string(),
            }),
            IdentityState::Mismatched => Some(StatusStage {
                label: "identity",
                mark: StageMark::Fail,
                note: format!(
                    "identity probe reported a different product under command '{}'; fix `command:` in .agents/workers.yaml to point at the real CLI",
                    self.command
                ),
            }),
            IdentityState::Unverified => Some(StatusStage {
                label: "identity",
                mark: StageMark::Fail,
                note: "configured identity probe failed; the resolved CLI is unverified"
                    .to_string(),
            }),
        };

        let policy = billing.worker_invocation.ai_billing_env_policy.as_str();
        let blocked = billing_blocked(policy, self.billing_env_present.len());
        let version = if self.readiness == Readiness::UnsupportedVersion {
            StatusStage {
                label: "version",
                mark: StageMark::Fail,
                note: format!(
                    "{} is below the profile's min_version; upgrade to >= {}",
                    self.version.as_deref().unwrap_or("the reported version"),
                    self.required_version.as_deref().unwrap_or("the minimum")
                ),
            }
        } else if self.contract_error.is_some() {
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

        let auth = match self.auth {
            AuthState::NotProbed => StatusStage {
                label: "auth",
                mark: StageMark::Offline,
                note: "not verified offline; Yardlet never makes a billed call to check, it relies on the worker's own subscription login".to_string(),
            },
            AuthState::Authenticated => StatusStage {
                label: "auth",
                mark: StageMark::Pass,
                note: "the declared offline auth probe reports the CLI is logged in".to_string(),
            },
            AuthState::Unauthenticated => StatusStage {
                label: "auth",
                mark: StageMark::Fail,
                note: "the declared offline auth probe reports the CLI is NOT logged in; log in with the worker CLI's own subscription account, then retry".to_string(),
            },
            AuthState::Unknown => StatusStage {
                label: "auth",
                mark: StageMark::Offline,
                note: "the declared offline auth probe was inconclusive; login stays unverified and is never assumed to have failed".to_string(),
            },
        };

        let mut stages = vec![contract, binary];
        stages.extend(identity);
        stages.extend([version, billing_env, auth]);
        stages
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
            Readiness::WrongProduct => format!(
                "not invocable: a different product answers command '{}' (see identity gate)",
                self.command
            ),
            Readiness::UnsupportedVersion => format!(
                "not invocable: {} is below the profile's min_version; upgrade to >= {}",
                self.version.as_deref().unwrap_or("the reported version"),
                self.required_version.as_deref().unwrap_or("the minimum")
            ),
            Readiness::Unauthenticated => {
                "not invocable: the worker CLI reports it is not logged in (see auth gate); log in with its own subscription account, then retry"
                    .to_string()
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

/// Probe one worker's readiness. Does not invoke any provider API. Every probe
/// runs the local CLI's configured arguments, which must be offline, in the
/// same sanitized zero-key environment used for a real invocation. Built-in
/// adapters retain their core-owned `--version` probe.
///
/// Gate order per candidate binary: identity (when declared) -> version ->
/// `min_version` (when declared); the auth probe (when declared) then runs once,
/// on the selected binary. A failed gate stops the later ones, so the reported
/// state always names the FIRST thing that is wrong. The static invocation and
/// access contracts still run before all of them, because they decide whether
/// Yardlet may spawn anything at all.
///
/// Resolution prefers the first candidate that passes those gates: the
/// PATH-resolved binary first, then well-known fallback paths. This keeps a
/// worker usable even when a wrapper shadows the real CLI on PATH.
pub fn probe(
    profile: &WorkerProfile,
    billing: &BillingPolicy,
    requested_access: &str,
) -> WorkerStatus {
    let command = profile.invocation.command.clone();
    let billing_env_present = present_billing_env(&billing.blocked_worker_env_names);
    let required_version = profile
        .invocation
        .min_version
        .as_ref()
        .map(|min| min.trim().to_string())
        .filter(|min| !min.is_empty());

    if !profile.enabled {
        return WorkerStatus {
            id: profile.id.clone(),
            command,
            binary_path: None,
            version: None,
            billing_env_present,
            contract_error: None,
            identity: IdentityState::NotDeclared,
            auth: AuthState::NotProbed,
            required_version,
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
            identity: IdentityState::NotDeclared,
            auth: AuthState::NotProbed,
            required_version,
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
            identity: IdentityState::NotDeclared,
            auth: AuthState::NotProbed,
            required_version,
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
    // Run the per-candidate gates in declaration order and keep the first
    // candidate that clears them all. A candidate's first failing gate is
    // remembered so the verdict can name what is actually wrong.
    let mut selected: Option<(PathBuf, String, IdentityState)> = None;
    let mut first_failure: Option<(PathBuf, CandidateFailure)> = None;
    for path in &candidates {
        match evaluate_candidate(
            path,
            profile,
            billing,
            version_args,
            required_version.as_deref(),
        ) {
            Ok((version, identity)) => {
                selected = Some((path.clone(), version, identity));
                break;
            }
            Err(failure) => {
                if first_failure.is_none() {
                    first_failure = Some((path.clone(), failure));
                }
            }
        }
    }

    let (binary_path, version, identity, auth, readiness, detail) = match selected {
        Some((path, version, identity)) => {
            // Auth runs last, once, and only on the binary that already proved
            // it is the right product at a supported version.
            let auth = match &profile.invocation.auth_probe {
                Some(auth_probe) => match run_probe(&path, &auth_probe.args, billing) {
                    Some(output) => auth_state_from_output(
                        &output.combined,
                        &auth_probe.ready_patterns,
                        &auth_probe.unauthenticated_patterns,
                    ),
                    None => AuthState::Unknown,
                },
                None => AuthState::NotProbed,
            };
            if auth == AuthState::Unauthenticated {
                (
                    Some(path.clone()),
                    Some(version),
                    identity,
                    auth,
                    Readiness::Unauthenticated,
                    format!(
                        "binary resolved to {} and its version is ok, but the profile's offline auth probe reports the CLI is NOT logged in. \
                         Log in with the worker CLI's own subscription account, then retry. Yardlet did not call an AI API and did not ask for an API key.",
                        path.display()
                    ),
                )
            } else {
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
                if identity == IdentityState::Matched {
                    detail.push_str("; identity probe matched the declared product signature");
                }
                match auth {
                    AuthState::Authenticated => {
                        detail.push_str("; offline auth probe reports the CLI is logged in")
                    }
                    AuthState::Unknown => detail
                        .push_str("; offline auth probe was inconclusive, login stays unverified"),
                    _ => {}
                }
                // An operator reading "sandboxed" must be able to tell an enforced
                // boundary from a declared one (issue #123): the generic sandbox
                // passed the declaration check above, but Yardlet does not own it.
                if requested_access == "sandboxed"
                    && !matches!(profile.id.as_str(), "codex" | "claude-code")
                {
                    detail.push_str("; sandbox is profile-declared, not verified by Yardlet");
                }
                (
                    Some(path),
                    Some(version),
                    identity,
                    auth,
                    Readiness::Ready,
                    detail,
                )
            }
        }
        None => match first_failure {
            Some((path, CandidateFailure::WrongProduct { seen, expected })) => (
                Some(path.clone()),
                None,
                IdentityState::Mismatched,
                AuthState::NotProbed,
                Readiness::WrongProduct,
                format!(
                    "binary resolved to {} but its identity probe reported {seen:?}, which does not carry the declared signature {expected:?}: \
                     a different product is installed under the command name '{command}'. Set an explicit `command:` path in \
                     .agents/workers.yaml, then retry. Yardlet did not call an AI API and did not ask for an API key.",
                    path.display()
                ),
            ),
            Some((path, CandidateFailure::UnsupportedVersion { found, minimum })) => (
                Some(path.clone()),
                Some(found.clone()),
                IdentityState::from_declaration(profile, true),
                AuthState::NotProbed,
                Readiness::UnsupportedVersion,
                format!(
                    "binary resolved to {} reports version {found:?}, below the profile's declared min_version {minimum}: \
                     upgrade to >= {minimum}, then retry. Yardlet did not call an AI API and did not ask for an API key.",
                    path.display()
                ),
            ),
            Some((path, CandidateFailure::IdentityProbeFailed)) => (
                Some(path.clone()),
                None,
                IdentityState::Unverified,
                AuthState::NotProbed,
                Readiness::Ambiguous,
                format!(
                    "binary resolved to {} but the configured offline identity probe failed; the resolved CLI or its runtime \
                     is unverified. Set an explicit `command:` path in .agents/workers.yaml or fix \
                     the local CLI runtime, then retry. Yardlet did not call an AI API and did not ask for an API key.",
                    path.display()
                ),
            ),
            Some((path, CandidateFailure::VersionProbeFailed)) => (
                Some(path.clone()),
                None,
                IdentityState::from_declaration(profile, true),
                AuthState::NotProbed,
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
                IdentityState::NotDeclared,
                AuthState::NotProbed,
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
        identity,
        auth,
        required_version,
        readiness,
        detail,
    }
}

impl IdentityState {
    /// The identity outcome for a gate that was already passed (or never
    /// declared) by the time a later gate failed.
    fn from_declaration(profile: &WorkerProfile, passed: bool) -> IdentityState {
        match (&profile.invocation.identity_probe, passed) {
            (None, _) => IdentityState::NotDeclared,
            (Some(_), true) => IdentityState::Matched,
            (Some(_), false) => IdentityState::Unverified,
        }
    }
}

/// The first gate a candidate binary failed.
enum CandidateFailure {
    WrongProduct { seen: String, expected: String },
    IdentityProbeFailed,
    VersionProbeFailed,
    UnsupportedVersion { found: String, minimum: String },
}

/// Run the per-candidate gates in order: identity (when declared), then the
/// offline version probe, then `min_version` (when declared). Returns the
/// verified version line and the identity outcome.
fn evaluate_candidate(
    path: &std::path::Path,
    profile: &WorkerProfile,
    billing: &BillingPolicy,
    version_args: &[String],
    required_version: Option<&str>,
) -> Result<(String, IdentityState), CandidateFailure> {
    let identity = match &profile.invocation.identity_probe {
        None => IdentityState::NotDeclared,
        Some(identity_probe) => match run_probe(path, &identity_probe.args, billing) {
            Some(output) if output.success && !output.first_line.is_empty() => {
                if identity_matches(&output.first_line, &identity_probe.expected_signature) {
                    IdentityState::Matched
                } else {
                    return Err(CandidateFailure::WrongProduct {
                        seen: output.first_line,
                        expected: identity_probe.expected_signature.trim().to_string(),
                    });
                }
            }
            _ => return Err(CandidateFailure::IdentityProbeFailed),
        },
    };

    let version =
        read_version(path, version_args, billing).ok_or(CandidateFailure::VersionProbeFailed)?;

    if let Some(minimum) = required_version {
        if version_verdict(&version, minimum) == VersionVerdict::Below {
            return Err(CandidateFailure::UnsupportedVersion {
                found: version,
                minimum: minimum.to_string(),
            });
        }
    }

    Ok((version, identity))
}

/// One offline probe attempt's output. Never contains secret values: the child
/// runs with the same sanitized zero-key environment as a real invocation.
struct ProbeOutput {
    success: bool,
    first_line: String,
    combined: String,
}

/// Spawn one offline probe in the sanitized worker environment. Returns None
/// when Yardlet must not or could not run it, which every caller treats as
/// "unknown", never as a positive result.
fn run_probe(
    path: &std::path::Path,
    args: &[String],
    billing: &BillingPolicy,
) -> Option<ProbeOutput> {
    // Never spawn a bare command: Yardlet cannot know whether it would be an
    // interactive session rather than an offline probe.
    if args.is_empty() || args.iter().all(|arg| arg.trim().is_empty()) {
        return None;
    }
    let env = sanitized_worker_env_for(billing, &[]).ok()?;
    let mut command = Command::new(path);
    command.args(args).env_clear();
    for (key, value) in env {
        command.env(key, value);
    }
    let out = command.output().ok()?;
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    let primary = if !out.stdout.is_empty() {
        &stdout
    } else {
        &stderr
    };
    Some(ProbeOutput {
        success: out.status.success(),
        first_line: primary
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .to_string(),
        combined: format!("{stdout}\n{stderr}"),
    })
}

fn read_version(
    path: &std::path::Path,
    version_args: &[String],
    billing: &BillingPolicy,
) -> Option<String> {
    let out = run_probe(path, version_args, billing)?;
    if !out.success || out.first_line.is_empty() {
        None
    } else {
        Some(out.first_line)
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
            identity: IdentityState::NotDeclared,
            auth: AuthState::NotProbed,
            required_version: None,
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

    // V010-006: `output_format` declares the STDOUT shape while
    // `output_contract` keeps declaring where the result comes from. An
    // undeclared format must leave every existing verdict untouched, an
    // unsupported value must be rejected instead of guessed at, and a built-in
    // adapter must not be able to claim a shape its core-owned normalizer will
    // not honor.
    #[test]
    fn declared_output_format_is_gated_without_moving_existing_verdicts() {
        for (label, yaml, expected) in [
            (
                "generic-unsupported",
                "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, output_format: ndjson, sandbox_args: ['--restricted'] }\n",
                Some("unsupported output_format 'ndjson'"),
            ),
            (
                "generic-stream-json",
                "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, output_format: stream-json, sandbox_args: ['--restricted'] }\n",
                None,
            ),
            (
                "generic-json",
                "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, output_format: json, sandbox_args: ['--restricted'] }\n",
                None,
            ),
            (
                "generic-undeclared",
                "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files, sandbox_args: ['--restricted'] }\n",
                None,
            ),
            (
                "builtin-restates-vendor-profile",
                "id: codex\ninvocation: { command: bash, supports_noninteractive: true, output_contract: json_or_files, output_format: stream-json }\n",
                None,
            ),
            (
                "builtin-contradicts-vendor-profile",
                "id: codex\ninvocation: { command: bash, supports_noninteractive: true, output_contract: json_or_files, output_format: text }\n",
                Some("core-owned stream-json output_format"),
            ),
        ] {
            let profile: WorkerProfile = crate::yaml::from_str(yaml).unwrap();
            match (invocation_contract(&profile), expected) {
                (Ok(()), None) => {}
                (Err(error), Some(expected)) => {
                    assert!(error.contains(expected), "{label}: {error}")
                }
                (result, expected) => panic!("{label}: got {result:?}, expected {expected:?}"),
            }
        }
    }

    // The two knobs must not read as rivals: a generic worker still cannot
    // widen its RESULT contract, and the rejection says which knob to use.
    #[test]
    fn generic_result_contract_rejection_points_at_output_format() {
        let profile: WorkerProfile = crate::yaml::from_str(
            "id: generic-fixture\ninvocation: { command: bash, supports_noninteractive: true, output_contract: json_or_files, sandbox_args: ['--restricted'] }\n",
        )
        .unwrap();
        let error = invocation_contract(&profile).unwrap_err();
        assert!(error.contains("expected files"), "{error}");
        assert!(error.contains("output_format"), "{error}");
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

    // ---- readiness contract: identity / auth / version decision logic -------
    // These three are the whole judgement surface of the extended contract, so
    // they stay pure and unit-tested away from any subprocess.

    #[test]
    fn identity_signature_matches_case_insensitively_and_rejects_another_product() {
        // The declared marker only has to appear in the probe's first line.
        assert!(identity_matches("codex-cli 0.9.7 (rust)", "codex-cli"));
        assert!(identity_matches("Codex-CLI 0.9.7", "codex-cli"));
        assert!(identity_matches("  codex-cli 0.9.7", "  CODEX-CLI  "));
        // A different product under the same command name must not pass.
        assert!(!identity_matches("GNU coreutils codex 9.4", "codex-cli"));
        assert!(!identity_matches("", "codex-cli"));
        // Nothing declared to check cannot fail.
        assert!(identity_matches("anything at all", "   "));
    }

    #[test]
    fn auth_probe_output_is_a_tolerant_three_way_verdict() {
        let ready = vec!["logged in".to_string()];
        let unauth = vec!["not logged in".to_string(), "please run login".to_string()];

        assert_eq!(
            auth_state_from_output("You are not logged in.", &ready, &unauth),
            AuthState::Unauthenticated
        );
        assert_eq!(
            auth_state_from_output("Logged in as someone", &ready, &unauth),
            AuthState::Authenticated
        );
        // Unknown output is never a hard stop.
        assert_eq!(
            auth_state_from_output("status: unavailable", &ready, &unauth),
            AuthState::Unknown
        );
        assert_eq!(
            auth_state_from_output("", &ready, &unauth),
            AuthState::Unknown
        );
        // An unauthenticated marker wins over a ready-looking banner.
        assert_eq!(
            auth_state_from_output("Logged in: no, please run login", &ready, &unauth),
            AuthState::Unauthenticated
        );
        // Blank patterns must not match everything.
        assert_eq!(
            auth_state_from_output("whatever", &[String::new()], &["  ".to_string()]),
            AuthState::Unknown
        );
    }

    #[test]
    fn min_version_comparison_blocks_only_a_confidently_lower_version() {
        assert_eq!(
            version_verdict("fixture-worker 1.2.3", "1.2.0"),
            VersionVerdict::Satisfied
        );
        assert_eq!(version_verdict("1.2.0", "1.2.0"), VersionVerdict::Satisfied);
        assert_eq!(
            version_verdict("mytool 0.9.9 (build 7)", "1.0.0"),
            VersionVerdict::Below
        );
        // Component-wise, not lexicographic.
        assert_eq!(
            version_verdict("1.10.0", "1.9.0"),
            VersionVerdict::Satisfied
        );
        // Pre-release suffixes are ignored, not treated as a parse failure.
        assert_eq!(
            version_verdict("2.0.0-beta.1", "1.9.9"),
            VersionVerdict::Satisfied
        );
        // Either side unparseable: unknown, and unknown never blocks.
        assert_eq!(
            version_verdict("nightly build", "1.0.0"),
            VersionVerdict::Undetermined
        );
        assert_eq!(
            version_verdict("1.0.0", "latest"),
            VersionVerdict::Undetermined
        );
        assert_eq!(version_verdict("1.2", "1.3"), VersionVerdict::Undetermined);
    }

    #[test]
    fn readiness_cache_key_changes_when_a_probe_declaration_changes() {
        let billing = BillingPolicy::default();
        let key = |invocation: &str| {
            let profile: WorkerProfile = crate::yaml::from_str(&format!(
                "id: generic-fixture\ninvocation: {{ command: bash, supports_noninteractive: true, output_contract: files, {invocation} }}\n"
            ))
            .unwrap();
            readiness_cache_key(&profile, &billing, "full")
        };
        let base = key("args: ['{run_dir}']");
        assert_ne!(
            base,
            key("args: ['{run_dir}'], identity_probe: { args: ['--version'], expected_signature: fixture }")
        );
        assert_ne!(
            key("args: ['{run_dir}'], identity_probe: { args: ['--version'], expected_signature: fixture }"),
            key("args: ['{run_dir}'], identity_probe: { args: ['--version'], expected_signature: other }")
        );
        assert_ne!(
            base,
            key("args: ['{run_dir}'], auth_probe: { args: [auth], unauthenticated_patterns: ['not logged in'] }")
        );
        assert_ne!(base, key("args: ['{run_dir}'], min_version: '1.2.0'"));
        assert_ne!(
            key("args: ['{run_dir}'], min_version: '1.2.0'"),
            key("args: ['{run_dir}'], min_version: '2.0.0'")
        );
    }

    #[test]
    fn declared_but_unusable_probes_fail_the_static_contract_before_any_spawn() {
        for (invocation, expected) in [
            (
                "identity_probe: { args: [], expected_signature: fixture }",
                "identity_probe.args",
            ),
            (
                "identity_probe: { args: ['--version'], expected_signature: '  ' }",
                "expected_signature",
            ),
            (
                "auth_probe: { args: [], unauthenticated_patterns: ['not logged in'] }",
                "auth_probe.args",
            ),
            (
                "auth_probe: { args: [auth, status] }",
                "at least one ready_patterns",
            ),
        ] {
            // Built-in adapters are covered too: these fields are new, so no
            // existing profile can regress and a broken declaration must never
            // spawn a bare command.
            for id in ["generic-fixture", "codex"] {
                let profile: WorkerProfile = crate::yaml::from_str(&format!(
                    "id: {id}\ninvocation: {{ command: bash, supports_noninteractive: true, output_contract: files, {invocation} }}\n"
                ))
                .unwrap();
                let status = probe(&profile, &BillingPolicy::default(), "full");
                assert_eq!(status.readiness, Readiness::NotReady, "{}", status.detail);
                assert!(status.detail.contains(expected), "{}", status.detail);
            }
        }
    }

    /// A profile whose probes are answered by `echo`: `echo <arg>` prints its
    /// arguments, so each declared probe's output is exactly what the test
    /// declares. No worker CLI is needed to exercise the gates end to end.
    fn echo_profile(invocation: &str) -> WorkerProfile {
        crate::yaml::from_str(&format!(
            "id: generic-fixture\ninvocation: {{ command: echo, supports_noninteractive: true, output_contract: files, {invocation} }}\n"
        ))
        .unwrap()
    }

    #[test]
    fn identity_mismatch_is_wrong_product_not_ready() {
        let profile = echo_profile(
            "identity_probe: { args: ['some-other-product 3.1'], expected_signature: 'fixture-worker' }",
        );
        let status = probe(&profile, &BillingPolicy::default(), "full");
        assert_eq!(
            status.readiness,
            Readiness::WrongProduct,
            "{}",
            status.detail
        );
        assert_eq!(status.readiness.label(), "wrong product");
        assert_eq!(status.identity, IdentityState::Mismatched);
        assert!(
            status.detail.contains("some-other-product"),
            "{}",
            status.detail
        );
        assert!(
            status.detail.contains("fixture-worker"),
            "{}",
            status.detail
        );

        let matching = echo_profile(
            "identity_probe: { args: ['fixture-worker 3.1'], expected_signature: 'fixture-worker' }",
        );
        let status = probe(&matching, &BillingPolicy::default(), "full");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        assert_eq!(status.identity, IdentityState::Matched);
    }

    #[test]
    fn version_below_declared_minimum_is_unsupported_version_with_upgrade_guidance() {
        let profile = echo_profile("version_args: ['fixture-worker 0.9.9'], min_version: '1.2.0'");
        let status = probe(&profile, &BillingPolicy::default(), "full");
        assert_eq!(
            status.readiness,
            Readiness::UnsupportedVersion,
            "{}",
            status.detail
        );
        assert_eq!(status.readiness.label(), "unsupported version");
        assert_eq!(status.required_version.as_deref(), Some("1.2.0"));
        assert!(status.detail.contains(">= 1.2.0"), "{}", status.detail);
        assert!(
            status
                .invocation_verdict(&BillingPolicy::default())
                .contains(">= 1.2.0"),
            "{}",
            status.invocation_verdict(&BillingPolicy::default())
        );

        // At or above the minimum stays invocable, and an unparseable version
        // is unknown rather than a block.
        for version in ["fixture-worker 1.2.0", "fixture-worker nightly"] {
            let profile = echo_profile(&format!(
                "version_args: ['{version}'], min_version: '1.2.0'"
            ));
            let status = probe(&profile, &BillingPolicy::default(), "full");
            assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        }
    }

    #[test]
    fn auth_probe_blocks_only_a_confirmed_logged_out_cli() {
        let unauthenticated = echo_profile(
            "auth_probe: { args: ['you are not logged in'], ready_patterns: ['logged in as'], unauthenticated_patterns: ['not logged in'] }",
        );
        let status = probe(&unauthenticated, &BillingPolicy::default(), "full");
        assert_eq!(
            status.readiness,
            Readiness::Unauthenticated,
            "{}",
            status.detail
        );
        assert_eq!(status.readiness.label(), "unauthenticated");
        assert_eq!(status.auth, AuthState::Unauthenticated);

        let authenticated = echo_profile(
            "auth_probe: { args: ['logged in as fixture'], ready_patterns: ['logged in as'], unauthenticated_patterns: ['not logged in'] }",
        );
        let status = probe(&authenticated, &BillingPolicy::default(), "full");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        assert_eq!(status.auth, AuthState::Authenticated);

        // Inconclusive output is a label on a ready worker, never a block.
        let unknown = echo_profile(
            "auth_probe: { args: ['status unavailable'], ready_patterns: ['logged in as'], unauthenticated_patterns: ['not logged in'] }",
        );
        let status = probe(&unknown, &BillingPolicy::default(), "full");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        assert_eq!(status.auth, AuthState::Unknown);
        let auth_stage = status
            .stages(&BillingPolicy::default())
            .into_iter()
            .find(|stage| stage.label == "auth")
            .unwrap();
        assert_eq!(auth_stage.mark, StageMark::Offline);
    }

    #[test]
    fn the_new_gates_run_in_order_and_stop_at_the_first_failure() {
        // Identity is checked before version: a wrong product with a too-low
        // version reports the wrong product, never the version.
        let profile = echo_profile(
            "version_args: ['other 0.0.1'], min_version: '9.9.9', identity_probe: { args: ['other 0.0.1'], expected_signature: 'fixture-worker' }, auth_probe: { args: ['not logged in'], unauthenticated_patterns: ['not logged in'] }",
        );
        let status = probe(&profile, &BillingPolicy::default(), "full");
        assert_eq!(
            status.readiness,
            Readiness::WrongProduct,
            "{}",
            status.detail
        );
        assert_eq!(
            status.auth,
            AuthState::NotProbed,
            "auth ran after a failed identity gate"
        );

        // Version is checked before auth: a too-low version reports the
        // version, and the auth probe never runs.
        let profile = echo_profile(
            "version_args: ['fixture-worker 0.0.1'], min_version: '9.9.9', identity_probe: { args: ['fixture-worker 0.0.1'], expected_signature: 'fixture-worker' }, auth_probe: { args: ['not logged in'], unauthenticated_patterns: ['not logged in'] }",
        );
        let status = probe(&profile, &BillingPolicy::default(), "full");
        assert_eq!(
            status.readiness,
            Readiness::UnsupportedVersion,
            "{}",
            status.detail
        );
        assert_eq!(status.identity, IdentityState::Matched);
        assert_eq!(
            status.auth,
            AuthState::NotProbed,
            "auth ran after a failed version gate"
        );
    }

    #[test]
    fn undeclared_probes_keep_the_existing_five_stage_checklist_unchanged() {
        let billing = BillingPolicy::default();
        let profile: WorkerProfile = crate::yaml::from_str(
            "id: codex\ninvocation: { command: bash, supports_noninteractive: true, output_contract: files }\n",
        )
        .unwrap();
        let status = probe(&profile, &billing, "full");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        assert_eq!(status.identity, IdentityState::NotDeclared);
        assert_eq!(status.auth, AuthState::NotProbed);
        let labels: Vec<&str> = status
            .stages(&billing)
            .iter()
            .map(|stage| stage.label)
            .collect();
        assert_eq!(
            labels,
            ["contract", "binary", "version", "billing-env", "auth"]
        );
    }

    #[test]
    fn declared_gates_appear_in_the_staged_checklist_between_binary_and_version() {
        let billing = BillingPolicy::default();
        let profile = echo_profile(
            "version_args: ['fixture-worker 1.2.3'], min_version: '1.0.0', identity_probe: { args: ['fixture-worker 1.2.3'], expected_signature: 'fixture-worker' }, auth_probe: { args: ['logged in as fixture'], ready_patterns: ['logged in as'] }",
        );
        let status = probe(&profile, &billing, "full");
        assert_eq!(status.readiness, Readiness::Ready, "{}", status.detail);
        let stages = status.stages(&billing);
        let labels: Vec<&str> = stages.iter().map(|stage| stage.label).collect();
        assert_eq!(
            labels,
            [
                "contract",
                "binary",
                "identity",
                "version",
                "billing-env",
                "auth"
            ]
        );
        assert_eq!(stages[2].mark, StageMark::Pass);
        assert_eq!(
            stages.iter().find(|s| s.label == "auth").unwrap().mark,
            StageMark::Pass
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
                output_format: None,
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
                identity_probe: None,
                auth_probe: None,
                min_version: None,
            },
            limits: crate::schemas::Limits::default(),
            provider_response_refusal_patterns: vec![],
            background_deferral_patterns: vec![],
            harness: None,
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
