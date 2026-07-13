//! Deterministic, user-owned Git finish policy.
//!
//! This module is the only Yardlet path that pushes. It accepts an OID that
//! the completion engine has already attributed to the current run, checks the
//! repository and user policy, pushes a non-force OID refspec, and verifies the
//! remote ref independently. Records intentionally have no URL, output, or
//! environment fields.

use std::collections::{hash_map::DefaultHasher, BTreeSet};
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::schemas::{GitFinishPolicy, TaskState};
use crate::state::Workspace;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitFinishStatus {
    Disabled,
    NotNeeded,
    Prepared,
    Pushed,
    AlreadyApplied,
    CheckBlocked,
    SafetyBlocked,
    GitFailed,
    RemoteMismatch,
}

impl GitFinishStatus {
    pub fn verified_complete(self) -> bool {
        matches!(
            self,
            Self::Pushed | Self::AlreadyApplied | Self::Disabled | Self::NotNeeded
        )
    }

    pub fn recoverable(self) -> bool {
        matches!(self, Self::Prepared)
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GitFinishOwnership {
    #[serde(default)]
    pub baseline_oid: String,
    #[serde(default)]
    pub expected_oid: String,
    #[serde(default)]
    pub owned_oids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitFinishPolicySnapshot {
    pub auto_push: bool,
    pub remote: String,
    pub target_ref: String,
    pub pre_push_checks: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitFinishCheckRecord {
    pub name: String,
    pub passed: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitFinishRecord {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub attempted_at: String,
    pub status: GitFinishStatus,
    pub policy: GitFinishPolicySnapshot,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_oid: Option<String>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub baseline_oid: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub owned_oids: Vec<String>,
    pub checks: Vec<GitFinishCheckRecord>,
    pub push_invoked: bool,
    pub push_succeeded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_oid: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_before_oid: Option<String>,
    pub reason: String,
}

impl GitFinishRecord {
    pub fn user_line(&self) -> String {
        match self.status {
            GitFinishStatus::Disabled => "git finish: disabled by workspace policy".to_string(),
            GitFinishStatus::NotNeeded => "git finish: not needed (no changes)".to_string(),
            GitFinishStatus::Prepared => "git finish: prepared but push not started".to_string(),
            GitFinishStatus::Pushed => format!(
                "git finish: pushed and verified {} {}",
                self.policy.remote, self.policy.target_ref
            ),
            GitFinishStatus::AlreadyApplied => format!(
                "git finish: already applied and verified {} {}",
                self.policy.remote, self.policy.target_ref
            ),
            GitFinishStatus::CheckBlocked => "git finish: blocked by pre-push check".to_string(),
            GitFinishStatus::SafetyBlocked => {
                format!("git finish: safety blocked ({})", self.reason)
            }
            GitFinishStatus::GitFailed => format!("git finish: Git failed ({})", self.reason),
            GitFinishStatus::RemoteMismatch => {
                "git finish: remote verification mismatch".to_string()
            }
        }
    }
}

impl GitFinishStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::NotNeeded => "not_needed",
            Self::Prepared => "prepared",
            Self::Pushed => "pushed",
            Self::AlreadyApplied => "already_applied",
            Self::CheckBlocked => "check_blocked",
            Self::SafetyBlocked => "safety_blocked",
            Self::GitFailed => "git_failed",
            Self::RemoteMismatch => "remote_mismatch",
        }
    }
}

pub fn finish_owned_run(
    ws: &Workspace,
    run_dir: &Path,
    run_id: &str,
    task_id: &str,
    task_state: TaskState,
    ownership: Option<GitFinishOwnership>,
) -> anyhow::Result<GitFinishRecord> {
    finish_owned_run_with_mode(
        ws,
        run_dir,
        run_id,
        task_id,
        task_state,
        ownership,
        FinishMode::CurrentHead,
    )
}

pub fn finish_no_change_run(
    ws: &Workspace,
    run_dir: &Path,
    run_id: &str,
    task_id: &str,
    task_state: TaskState,
) -> anyhow::Result<GitFinishRecord> {
    let policy = match ws.load_config() {
        Ok(config) => config.git_finish,
        Err(_) => {
            let policy = GitFinishPolicy::default();
            let mut record = base_record(run_id, task_id, &policy, None);
            block(&mut record, "config_unreadable");
            return persist_and_return(ws, run_dir, record);
        }
    };
    if ws
        .load_git_finish_record(run_dir)
        .ok()
        .and_then(|record| record_ownership(&record))
        .is_some()
    {
        let mut record = base_record(run_id, task_id, &policy, None);
        block(&mut record, "run_ownership_evidence_changed");
        return persist_and_return(ws, run_dir, record);
    }
    let mut record = base_record(run_id, task_id, &policy, None);
    if !policy.auto_push {
        return persist_and_return(ws, run_dir, record);
    }
    if task_state != TaskState::Done {
        block(&mut record, "task_not_done");
        return persist_and_return(ws, run_dir, record);
    }
    record.status = GitFinishStatus::NotNeeded;
    record.reason = "no_changes".to_string();
    persist_and_return(ws, run_dir, record)
}

/// Resume a run whose integration commit may now be behind later, independently
/// attributed integration commits. The normal finish path still requires the
/// run's exact OID at HEAD; recovery only accepts an OID that remains in the
/// current HEAD history and still rechecks the run's own baseline and owned set.
pub(crate) fn recover_owned_run(
    ws: &Workspace,
    run_dir: &Path,
    run_id: &str,
    task_id: &str,
    task_state: TaskState,
    ownership: Option<GitFinishOwnership>,
) -> anyhow::Result<GitFinishRecord> {
    finish_owned_run_with_mode(
        ws,
        run_dir,
        run_id,
        task_id,
        task_state,
        ownership,
        FinishMode::AccumulatedHead,
    )
}

#[derive(Clone, Copy)]
enum FinishMode {
    CurrentHead,
    AccumulatedHead,
}

fn finish_owned_run_with_mode(
    ws: &Workspace,
    run_dir: &Path,
    run_id: &str,
    task_id: &str,
    task_state: TaskState,
    ownership: Option<GitFinishOwnership>,
    mode: FinishMode,
) -> anyhow::Result<GitFinishRecord> {
    let policy = match ws.load_config() {
        Ok(config) => config.git_finish,
        Err(_) => {
            let policy = GitFinishPolicy::default();
            let mut record = base_record(run_id, task_id, &policy, ownership.as_ref());
            block(&mut record, "config_unreadable");
            return persist_and_return(ws, run_dir, record);
        }
    };
    let previous = ws.load_git_finish_record(run_dir).ok();
    let target_changed = previous.as_ref().is_some_and(|record| {
        record.policy.auto_push
            && (record.policy.remote != policy.remote
                || record.policy.target_ref != policy.target_ref)
    });
    let recorded_ownership = previous.as_ref().and_then(record_ownership);
    let ownership_changed = recorded_ownership
        .as_ref()
        .is_some_and(|recorded| ownership.as_ref() != Some(recorded));
    // The caller must supply ownership from a core receipt on every push or
    // recovery attempt. A previous record is comparison evidence only: the run
    // directory is worker-writable, so adopting its ownership when the trusted
    // caller supplied none would let a forged record claim unrelated commits.
    if ownership_changed {
        let mut blocked_record = base_record(run_id, task_id, &policy, recorded_ownership.as_ref());
        block(&mut blocked_record, "run_ownership_evidence_changed");
        return persist_and_return(ws, run_dir, blocked_record);
    }
    let mut record = base_record(run_id, task_id, &policy, ownership.as_ref());
    if target_changed {
        block(&mut record, "git_finish_target_changed");
        return persist_and_return(ws, run_dir, record);
    }

    if !policy.auto_push {
        return persist_and_return(ws, run_dir, record);
    }
    if task_state != TaskState::Done {
        block(&mut record, "task_not_done");
        return persist_and_return(ws, run_dir, record);
    }
    if policy.remote.trim().is_empty() {
        block(&mut record, "remote_not_configured");
        return persist_and_return(ws, run_dir, record);
    }
    let Some(branch) = policy.target_ref.strip_prefix("refs/heads/") else {
        block(&mut record, "target_ref_must_be_branch");
        return persist_and_return(ws, run_dir, record);
    };
    if branch.is_empty() || policy.target_ref.contains([' ', ':', '^', '~']) {
        block(&mut record, "target_ref_invalid");
        return persist_and_return(ws, run_dir, record);
    }
    if !git_ok(&ws.root, &["check-ref-format", &policy.target_ref]) {
        block(&mut record, "target_ref_invalid");
        return persist_and_return(ws, run_dir, record);
    }
    let _lock = match FinishLock::acquire(&ws.root, &policy.remote, &policy.target_ref) {
        Ok(lock) => lock,
        Err(reason) => {
            // Lock contention did not perform a finish attempt. Return a
            // non-durable safety block for this caller; never project an older
            // status as current truth, and never overwrite a concurrent
            // finisher's durable record.
            return Ok(lock_failure_record(record, reason));
        }
    };
    let pins_before = match git_security_pins(&ws.root, &policy.remote) {
        Ok(pins) => pins,
        Err(()) => {
            block(&mut record, "remote_not_found");
            return persist_and_return(ws, run_dir, record);
        }
    };
    if pins_before.head.is_empty() {
        block(&mut record, "remote_not_found");
        return persist_and_return(ws, run_dir, record);
    }
    let Some(push_destination) = single_push_destination(&pins_before.push_urls) else {
        block(&mut record, "remote_must_have_one_push_destination");
        return persist_and_return(ws, run_dir, record);
    };
    let current_branch = git_stdout(&ws.root, &["symbolic-ref", "--quiet", "--short", "HEAD"]);
    if current_branch.as_deref().map(str::trim) != Some(branch) {
        block(&mut record, "branch_does_not_match_target_ref");
        return persist_and_return(ws, run_dir, record);
    }
    let Some(expected) = record.expected_oid.clone() else {
        block(&mut record, "run_has_no_owned_commit");
        return persist_and_return(ws, run_dir, record);
    };
    match mode {
        FinishMode::CurrentHead if pins_before.head != expected => {
            block(&mut record, "owned_oid_is_not_head");
            return persist_and_return(ws, run_dir, record);
        }
        FinishMode::AccumulatedHead
            if !git_ok(
                &ws.root,
                &["merge-base", "--is-ancestor", &expected, &pins_before.head],
            ) =>
        {
            block(&mut record, "owned_oid_is_not_in_head_history");
            return persist_and_return(ws, run_dir, record);
        }
        _ => {}
    }
    if !worktree_clean_except_agents(&ws.root) {
        block(&mut record, "worktree_not_clean");
        return persist_and_return(ws, run_dir, record);
    }

    let remote_before = match remote_oid(&ws.root, &policy.remote, &policy.target_ref) {
        Ok(Some(oid)) if oid == expected => {
            record.status = GitFinishStatus::AlreadyApplied;
            record.remote_oid = Some(oid);
            record.reason = "remote_already_matches".to_string();
            return persist_and_return(ws, run_dir, record);
        }
        Ok(Some(oid))
            if matches!(mode, FinishMode::AccumulatedHead)
                && git_ok(&ws.root, &["merge-base", "--is-ancestor", &expected, &oid]) =>
        {
            record.status = GitFinishStatus::AlreadyApplied;
            record.remote_oid = Some(oid);
            record.reason = "remote_contains_owned_commit".to_string();
            return persist_and_return(ws, run_dir, record);
        }
        Ok(oid) => oid,
        Err(()) => {
            record.status = GitFinishStatus::GitFailed;
            record.reason = "remote_lookup_before_push_failed".to_string();
            return persist_and_return(ws, run_dir, record);
        }
    };
    record.remote_before_oid = remote_before.clone();

    if !ownership_proven(&ws.root, &record, remote_before.as_deref()) {
        block(&mut record, "reachable_commits_not_owned_by_run");
        return persist_and_return(ws, run_dir, record);
    }

    for (index, check) in policy.pre_push_checks.iter().enumerate() {
        let passed = !check.name.trim().is_empty()
            && !check.command.trim().is_empty()
            && shell_ok(&ws.root, &check.command);
        record.checks.push(GitFinishCheckRecord {
            name: check_label(index),
            passed,
        });
        if !passed {
            record.status = GitFinishStatus::CheckBlocked;
            record.reason = "pre_push_check_failed".to_string();
            return persist_and_return(ws, run_dir, record);
        }
    }

    let pins_after = match git_security_pins(&ws.root, &policy.remote) {
        Ok(pins) => pins,
        Err(()) => {
            block(&mut record, "git_state_changed_during_checks");
            return persist_and_return(ws, run_dir, record);
        }
    };
    if pins_after.head != pins_before.head {
        block(&mut record, "head_changed_during_checks");
        return persist_and_return(ws, run_dir, record);
    }
    if pins_after.fetch_urls != pins_before.fetch_urls
        || pins_after.push_urls != pins_before.push_urls
    {
        block(&mut record, "remote_urls_changed_during_checks");
        return persist_and_return(ws, run_dir, record);
    }
    if !worktree_clean_except_agents(&ws.root) {
        block(&mut record, "worktree_changed_during_checks");
        return persist_and_return(ws, run_dir, record);
    }
    match remote_oid(&ws.root, &policy.remote, &policy.target_ref) {
        Ok(oid) if oid == remote_before => {}
        Ok(_) => {
            block(&mut record, "remote_ref_changed_during_checks");
            return persist_and_return(ws, run_dir, record);
        }
        Err(()) => {
            record.status = GitFinishStatus::GitFailed;
            record.reason = "remote_lookup_during_checks_failed".to_string();
            return persist_and_return(ws, run_dir, record);
        }
    }

    // This durable write is a hard gate. If Yardlet cannot record that it is
    // about to mutate the remote, the error reaches the completion path and no
    // push subprocess is started.
    record.status = GitFinishStatus::Prepared;
    record.reason = "ready_to_push".to_string();
    persist(ws, run_dir, &record)?;

    record.push_invoked = true;
    let refspec = format!("{expected}:{}", policy.target_ref);
    if !git_ok(
        &ws.root,
        &["push", "--porcelain", "--", &push_destination, &refspec],
    ) {
        record.status = GitFinishStatus::GitFailed;
        record.reason = "push_failed".to_string();
        return persist_and_return(ws, run_dir, record);
    }
    record.push_succeeded = true;

    match remote_oid(&ws.root, &policy.remote, &policy.target_ref) {
        Ok(Some(oid)) if oid == expected => {
            record.status = GitFinishStatus::Pushed;
            record.remote_oid = Some(oid);
            record.reason = "remote_verified".to_string();
        }
        Ok(oid) => {
            record.status = GitFinishStatus::RemoteMismatch;
            record.remote_oid = oid;
            record.reason = "remote_oid_does_not_match_expected".to_string();
        }
        Err(()) => {
            record.status = GitFinishStatus::GitFailed;
            record.reason = "remote_lookup_after_push_failed".to_string();
        }
    }
    persist_and_return(ws, run_dir, record)
}

fn single_push_destination(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    let destinations = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect::<Vec<_>>();
    (destinations.len() == 1).then(|| destinations[0].to_string())
}

fn base_record(
    run_id: &str,
    task_id: &str,
    policy: &GitFinishPolicy,
    ownership: Option<&GitFinishOwnership>,
) -> GitFinishRecord {
    GitFinishRecord {
        schema_version: 2,
        run_id: run_id.to_string(),
        task_id: task_id.to_string(),
        attempted_at: Local::now().to_rfc3339(),
        status: GitFinishStatus::Disabled,
        policy: GitFinishPolicySnapshot {
            auto_push: policy.auto_push,
            remote: policy.remote.clone(),
            target_ref: policy.target_ref.clone(),
            pre_push_checks: policy
                .pre_push_checks
                .iter()
                .enumerate()
                .map(|(index, _)| check_label(index))
                .collect(),
        },
        expected_oid: ownership.map(|proof| proof.expected_oid.clone()),
        baseline_oid: ownership
            .map(|proof| proof.baseline_oid.clone())
            .unwrap_or_default(),
        owned_oids: ownership
            .map(|proof| proof.owned_oids.clone())
            .unwrap_or_default(),
        checks: Vec::new(),
        push_invoked: false,
        push_succeeded: false,
        remote_oid: None,
        remote_before_oid: None,
        reason: "policy_disabled".to_string(),
    }
}

fn record_ownership(record: &GitFinishRecord) -> Option<GitFinishOwnership> {
    Some(GitFinishOwnership {
        baseline_oid: record.baseline_oid.clone(),
        expected_oid: record.expected_oid.clone()?,
        owned_oids: record.owned_oids.clone(),
    })
}

fn ownership_proven(root: &Path, record: &GitFinishRecord, remote_before: Option<&str>) -> bool {
    let Some(expected) = record.expected_oid.as_deref() else {
        return false;
    };
    if record.owned_oids.is_empty() || record.baseline_oid.is_empty() {
        return false;
    }
    if remote_before != Some(record.baseline_oid.as_str()) {
        return false;
    }
    let range = format!("{}..{expected}", record.baseline_oid);
    let Some(commits) = git_stdout(root, &["rev-list", "--reverse", &range]) else {
        return false;
    };
    let reachable = commits
        .lines()
        .map(str::trim)
        .filter(|oid| !oid.is_empty())
        .map(str::to_string)
        .collect::<BTreeSet<_>>();
    let owned = record.owned_oids.iter().cloned().collect::<BTreeSet<_>>();
    !reachable.is_empty() && reachable == owned && owned.contains(expected)
}

fn lock_failure_record(mut fallback: GitFinishRecord, reason: &str) -> GitFinishRecord {
    block(&mut fallback, reason);
    fallback
}

struct FinishLock {
    file: fs::File,
}

impl FinishLock {
    fn acquire(root: &Path, remote: &str, target_ref: &str) -> Result<Self, &'static str> {
        Self::acquire_with_timeout(root, remote, target_ref, Duration::from_secs(10))
    }

    fn acquire_with_timeout(
        root: &Path,
        remote: &str,
        target_ref: &str,
        timeout: Duration,
    ) -> Result<Self, &'static str> {
        let common = git_stdout(root, &["rev-parse", "--git-common-dir"])
            .ok_or("git_common_dir_unreadable")?;
        let common = PathBuf::from(common.trim());
        let common = if common.is_absolute() {
            common
        } else {
            root.join(common)
        };
        let lock_root = common.join("yardlet-finish-locks");
        fs::create_dir_all(&lock_root).map_err(|_| "finish_lock_unavailable")?;
        let mut hasher = DefaultHasher::new();
        remote.hash(&mut hasher);
        target_ref.hash(&mut hasher);
        let path = lock_root.join(format!("{:016x}.lock", hasher.finish()));
        let file = open_finish_lock_file(&path)?;
        let started = Instant::now();
        loop {
            // SAFETY: `file` remains open for the full lock lifetime and flock
            // only reads its valid descriptor. The kernel releases the lock if
            // this process crashes, so no stale-owner deletion race is needed.
            let result = unsafe {
                libc::flock(
                    std::os::fd::AsRawFd::as_raw_fd(&file),
                    libc::LOCK_EX | libc::LOCK_NB,
                )
            };
            if result == 0 {
                return Ok(Self { file });
            }
            let error = std::io::Error::last_os_error();
            if !matches!(error.raw_os_error(), Some(code) if code == libc::EAGAIN || code == libc::EWOULDBLOCK)
            {
                return Err("finish_lock_unavailable");
            }
            if started.elapsed() >= timeout {
                return Err("finish_lock_timeout");
            }
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for FinishLock {
    fn drop(&mut self) {
        // SAFETY: this descriptor belongs to `self.file` and remains valid
        // until after Drop returns. Unlock failure is non-fatal on teardown.
        let _ = unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&self.file), libc::LOCK_UN) };
    }
}

fn open_finish_lock_file(path: &Path) -> Result<fs::File, &'static str> {
    let open = || {
        fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
    };
    match open() {
        Ok(file) => Ok(file),
        Err(_) if path.is_dir() && stale_legacy_lock(path) => {
            // Older Yardlet versions used a PID directory. Replacing a dead
            // legacy directory with a file is race-safe: a concurrent migrator's
            // remove_dir_all cannot delete the newly created regular file.
            let _ = fs::remove_dir_all(path);
            open().map_err(|_| "finish_lock_unavailable")
        }
        Err(_) => Err("finish_lock_unavailable"),
    }
}

fn stale_legacy_lock(path: &Path) -> bool {
    let pid = fs::read_to_string(path.join("pid"))
        .ok()
        .and_then(|pid| pid.trim().parse::<u32>().ok())
        .filter(|pid| *pid > 0);
    if let Some(pid) = pid {
        return !process_alive(pid);
    }

    // There is a short interval between the atomic mkdir claim and writing the
    // owner PID. A contender must not steal the directory during that interval.
    // Only an ownerless/corrupt lock older than the fallback lease is reclaimable.
    fs::metadata(path)
        .ok()
        .and_then(|metadata| metadata.modified().ok())
        .and_then(|time| time.elapsed().ok())
        .is_some_and(|age| age > Duration::from_secs(30))
}

fn process_alive(pid: u32) -> bool {
    Command::new("kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

fn block(record: &mut GitFinishRecord, reason: &str) {
    record.status = GitFinishStatus::SafetyBlocked;
    record.reason = reason.to_string();
}

fn check_label(index: usize) -> String {
    format!("check_{}", index + 1)
}

fn persist(ws: &Workspace, run_dir: &Path, record: &GitFinishRecord) -> anyhow::Result<()> {
    ws.save_git_finish_record(run_dir, record)
}

fn persist_and_return(
    ws: &Workspace,
    run_dir: &Path,
    record: GitFinishRecord,
) -> anyhow::Result<GitFinishRecord> {
    persist(ws, run_dir, &record)?;
    Ok(record)
}

#[derive(Debug, PartialEq, Eq)]
struct GitSecurityPins {
    head: String,
    fetch_urls: Vec<u8>,
    push_urls: Vec<u8>,
}

/// Capture the exact Git state that a user-owned pre-push check must not be
/// able to retarget. URL bytes stay in memory only and are never rendered or
/// serialized.
fn git_security_pins(root: &Path, remote: &str) -> Result<GitSecurityPins, ()> {
    let head = git_stdout(root, &["rev-parse", "--verify", "HEAD"])
        .map(|s| s.trim().to_string())
        .ok_or(())?;
    let fetch_urls = git_stdout_bytes(root, &["remote", "get-url", "--all", "--", remote])?;
    let push_urls = git_stdout_bytes(
        root,
        &["remote", "get-url", "--push", "--all", "--", remote],
    )?;
    Ok(GitSecurityPins {
        head,
        fetch_urls,
        push_urls,
    })
}

fn git_stdout_bytes(root: &Path, args: &[&str]) -> Result<Vec<u8>, ()> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .map_err(|_| ())?;
    output.status.success().then_some(output.stdout).ok_or(())
}

fn worktree_clean_except_agents(root: &Path) -> bool {
    git_stdout_bytes(
        root,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )
    .is_ok_and(|status| status_paths_are_agents_only(&status))
}

fn status_paths_are_agents_only(status: &[u8]) -> bool {
    let mut fields = status.split(|byte| *byte == 0).peekable();
    while let Some(entry) = fields.next() {
        if entry.is_empty() {
            return fields.peek().is_none();
        }
        if entry.len() < 4 || entry[2] != b' ' || !is_agents_path(&entry[3..]) {
            return false;
        }
        if matches!(entry[0], b'R' | b'C') || matches!(entry[1], b'R' | b'C') {
            let Some(source) = fields.next() else {
                return false;
            };
            if source.is_empty() || !is_agents_path(source) {
                return false;
            }
        }
    }
    true
}

fn is_agents_path(path: &[u8]) -> bool {
    path == b".agents" || path.starts_with(b".agents/")
}

fn remote_oid(root: &Path, remote: &str, target_ref: &str) -> Result<Option<String>, ()> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["ls-remote", "--refs", "--", remote, target_ref])
        .output()
        .map_err(|_| ())?;
    if !output.status.success() {
        return Err(());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.split_whitespace().next().map(str::to_string))
}

fn git_stdout(root: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(test)]
fn head_oid(root: &Path) -> Option<String> {
    git_stdout(root, &["rev-parse", "--verify", "HEAD"]).map(|s| s.trim().to_string())
}

fn git_ok(root: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn shell_ok(root: &Path, command: &str) -> bool {
    Command::new("sh")
        .args(["-c", command])
        .current_dir(root)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{GitFinishCheck, GitFinishPolicy};
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(1);

    struct Fixture {
        root: std::path::PathBuf,
        remote: std::path::PathBuf,
        initial_oid: String,
        ws: Workspace,
        run_dir: std::path::PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Self {
            let id = NEXT.fetch_add(1, Ordering::Relaxed);
            let base = std::env::temp_dir().join(format!(
                "yard-git-finish-{name}-{}-{id}",
                std::process::id()
            ));
            let root = base.join("repo");
            let remote = base.join("remote.git");
            let _ = std::fs::remove_dir_all(&base);
            std::fs::create_dir_all(&root).unwrap();
            cmd(&root, &["init", "-q", "-b", "main"]);
            cmd(&root, &["config", "user.name", "Yardlet Test"]);
            cmd(&root, &["config", "user.email", "yardlet@example.test"]);
            std::fs::write(root.join("seed.txt"), "seed\n").unwrap();
            cmd(&root, &["add", "seed.txt"]);
            cmd(&root, &["commit", "-q", "-m", "seed"]);
            cmd(&base, &["init", "-q", "--bare", remote.to_str().unwrap()]);
            cmd(
                &root,
                &["remote", "add", "fixture", remote.to_str().unwrap()],
            );
            cmd(&root, &["push", "-q", "fixture", "HEAD:refs/heads/main"]);
            let initial_oid = head_oid(&root).unwrap();
            crate::init::init(&root, false).unwrap();
            let ws = Workspace::at(&root);
            let run_dir = ws.runs_dir().join("run-test");
            std::fs::create_dir_all(&run_dir).unwrap();
            Self {
                root,
                remote,
                initial_oid,
                ws,
                run_dir,
            }
        }

        fn configure(&self, checks: Vec<GitFinishCheck>) {
            let mut cfg = self.ws.load_config().unwrap();
            cfg.git_finish = GitFinishPolicy {
                auto_push: true,
                remote: "fixture".to_string(),
                target_ref: "refs/heads/main".to_string(),
                pre_push_checks: checks,
            };
            crate::state::save_yaml(&self.ws.config_path(), &cfg).unwrap();
        }

        fn commit(&self, text: &str) -> String {
            std::fs::write(self.root.join("owned.txt"), text).unwrap();
            cmd(&self.root, &["add", "owned.txt"]);
            cmd(&self.root, &["commit", "-q", "-m", text]);
            head_oid(&self.root).unwrap()
        }

        fn finish(&self, oid: Option<String>) -> GitFinishRecord {
            let ownership = oid.map(|expected_oid| self.ownership(expected_oid));
            self.finish_at(&self.run_dir, ownership)
        }

        fn ownership(&self, expected_oid: String) -> GitFinishOwnership {
            GitFinishOwnership {
                baseline_oid: git_stdout(&self.root, &["rev-parse", &format!("{expected_oid}^")])
                    .unwrap()
                    .trim()
                    .to_string(),
                owned_oids: vec![expected_oid.clone()],
                expected_oid,
            }
        }

        fn finish_at(
            &self,
            run_dir: &Path,
            ownership: Option<GitFinishOwnership>,
        ) -> GitFinishRecord {
            let run_id = run_dir.file_name().unwrap().to_str().unwrap();
            finish_owned_run(
                &self.ws,
                run_dir,
                run_id,
                "YARD-001",
                TaskState::Done,
                ownership,
            )
            .unwrap()
        }

        fn recover_at(
            &self,
            run_dir: &Path,
            run_id: &str,
            ownership: Option<GitFinishOwnership>,
        ) -> GitFinishRecord {
            recover_owned_run(
                &self.ws,
                run_dir,
                run_id,
                "YARD-001",
                TaskState::Done,
                ownership,
            )
            .unwrap()
        }

        fn bare_remote(&self, name: &str) -> std::path::PathBuf {
            let path = self.root.parent().unwrap().join(format!("{name}.git"));
            cmd(
                self.root.parent().unwrap(),
                &["init", "-q", "--bare", path.to_str().unwrap()],
            );
            path
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.root.parent().unwrap());
        }
    }

    fn cmd(dir: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {:?}: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn check(name: &str, command: &str) -> GitFinishCheck {
        GitFinishCheck {
            name: name.to_string(),
            command: command.to_string(),
        }
    }

    #[test]
    fn legacy_config_defaults_to_no_remote_mutation() {
        let f = Fixture::new("default-off");
        let oid = f.commit("owned");
        let record = f.finish(Some(oid));
        assert_eq!(record.status, GitFinishStatus::Disabled);
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn legacy_record_defaults_new_ownership_fields() {
        let raw = r#"{
            "schema_version":1,"run_id":"old","task_id":"YARD-OLD",
            "attempted_at":"2026-01-01T00:00:00Z","status":"prepared",
            "policy":{"auto_push":true,"remote":"origin","target_ref":"refs/heads/main","pre_push_checks":[]},
            "expected_oid":"abc","checks":[],"push_invoked":false,
            "push_succeeded":false,"reason":"ready_to_push"
        }"#;
        let record: GitFinishRecord = serde_json::from_str(raw).unwrap();
        assert!(record.baseline_oid.is_empty());
        assert!(record.owned_oids.is_empty());
        assert_eq!(record.remote_before_oid, None);
    }

    #[test]
    fn only_verified_or_disabled_statuses_are_complete() {
        for status in [
            GitFinishStatus::Prepared,
            GitFinishStatus::CheckBlocked,
            GitFinishStatus::SafetyBlocked,
            GitFinishStatus::GitFailed,
            GitFinishStatus::RemoteMismatch,
        ] {
            assert!(!status.verified_complete(), "{status:?}");
        }
        for status in [
            GitFinishStatus::Disabled,
            GitFinishStatus::NotNeeded,
            GitFinishStatus::Pushed,
            GitFinishStatus::AlreadyApplied,
        ] {
            assert!(status.verified_complete(), "{status:?}");
        }
    }

    #[test]
    fn verified_no_change_finish_never_pushes() {
        let f = Fixture::new("no-change-finish");
        f.configure(vec![]);

        let record =
            finish_no_change_run(&f.ws, &f.run_dir, "run-test", "YARD-001", TaskState::Done)
                .unwrap();

        assert_eq!(record.status, GitFinishStatus::NotNeeded);
        assert!(record.status.verified_complete());
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn pushes_exact_oid_verifies_and_converges_idempotently() {
        let f = Fixture::new("success");
        f.configure(vec![
            check("first", "printf first > .agents/first"),
            check("second", "test -f .agents/first"),
        ]);
        let oid = f.commit("owned");

        let first = f.finish(Some(oid.clone()));
        assert_eq!(first.status, GitFinishStatus::Pushed);
        assert!(first.push_invoked);
        assert!(first.push_succeeded);
        assert_eq!(first.remote_oid.as_deref(), Some(oid.as_str()));
        assert_eq!(
            first
                .checks
                .iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>(),
            vec!["check_1", "check_2"]
        );

        let second = f.finish(Some(oid.clone()));
        assert_eq!(second.status, GitFinishStatus::AlreadyApplied);
        assert!(!second.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(oid)
        );

        let json = std::fs::read_to_string(f.run_dir.join("git-finish.json")).unwrap();
        assert!(!json.contains(f.remote.to_str().unwrap()));
        assert!(!json.contains("printf first"));
    }

    #[test]
    fn failed_check_blocks_before_push_and_preserves_order() {
        let f = Fixture::new("check-block");
        f.configure(vec![
            check("passes", "true"),
            check("stops", "false"),
            check("never", "true"),
        ]);
        let oid = f.commit("owned");
        let record = f.finish(Some(oid));
        assert_eq!(record.status, GitFinishStatus::CheckBlocked);
        assert!(!record.push_invoked);
        assert_eq!(
            record
                .checks
                .iter()
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>(),
            vec!["check_1", "check_2"]
        );
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn failed_leading_check_then_two_runs_recover_in_integration_order() {
        let f = Fixture::new("accumulated-check-recovery");
        f.configure(vec![check("blocked", "false")]);
        let first_oid = f.commit("first");
        let first_proof = f.ownership(first_oid.clone());
        let run_first = f.run_dir.parent().unwrap().join("run-first");
        let run_second = f.run_dir.parent().unwrap().join("run-second");
        std::fs::create_dir_all(&run_first).unwrap();
        std::fs::create_dir_all(&run_second).unwrap();

        let blocked = f.finish_at(&run_first, Some(first_proof.clone()));
        assert_eq!(blocked.status, GitFinishStatus::CheckBlocked);
        let second_oid = f.commit("second");
        let second_proof = f.ownership(second_oid.clone());
        let blocked_later = f.finish_at(&run_second, Some(second_proof.clone()));
        assert_eq!(blocked_later.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(blocked_later.reason, "reachable_commits_not_owned_by_run");

        f.configure(vec![check("passes", "true")]);
        let first = f.recover_at(&run_first, "run-first", Some(first_proof.clone()));
        let second = f.recover_at(&run_second, "run-second", Some(second_proof.clone()));
        let repeated_first = f.recover_at(&run_first, "run-first", Some(first_proof));
        let repeated_second = f.recover_at(&run_second, "run-second", Some(second_proof));

        assert_eq!(first.status, GitFinishStatus::Pushed);
        assert_eq!(
            first.remote_before_oid.as_deref(),
            Some(f.initial_oid.as_str())
        );
        assert_eq!(second.status, GitFinishStatus::Pushed);
        assert_eq!(
            second.remote_before_oid.as_deref(),
            Some(first_oid.as_str())
        );
        assert_eq!(repeated_first.status, GitFinishStatus::AlreadyApplied);
        assert!(!repeated_first.push_invoked);
        assert_eq!(repeated_second.status, GitFinishStatus::AlreadyApplied);
        assert!(!repeated_second.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(second_oid)
        );
    }

    #[test]
    fn accumulated_recovery_stops_on_out_of_order_remote() {
        let f = Fixture::new("accumulated-out-of-order");
        f.configure(vec![]);
        let first_oid = f.commit("first");
        let first_proof = f.ownership(first_oid.clone());
        let run_first = f.run_dir.parent().unwrap().join("run-first");
        std::fs::create_dir_all(&run_first).unwrap();
        let policy = f.ws.load_config().unwrap().git_finish;
        let pending = base_record("run-first", "YARD-001", &policy, Some(&first_proof));
        persist(&f.ws, &run_first, &pending).unwrap();
        let _second_oid = f.commit("second");
        let peer = cmd(
            &f.root,
            &[
                "commit-tree",
                "HEAD^{tree}",
                "-p",
                f.initial_oid.as_str(),
                "-m",
                "peer",
            ],
        )
        .trim()
        .to_string();
        cmd(
            &f.root,
            &["push", "-q", "fixture", &format!("{peer}:refs/heads/main")],
        );

        let recovered = f.recover_at(&run_first, "run-first", Some(first_proof));

        assert_eq!(recovered.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(recovered.reason, "reachable_commits_not_owned_by_run");
        assert!(!recovered.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(peer)
        );
    }

    #[test]
    fn recorded_ownership_cannot_be_replaced_during_recovery() {
        let f = Fixture::new("recovery-ownership-mismatch");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();
        let mut changed = proof.clone();
        changed.owned_oids.push(f.initial_oid.clone());

        let recovered = f.recover_at(&f.run_dir, "run-test", Some(changed));
        let durable = f.ws.load_git_finish_record(&f.run_dir).unwrap();

        assert_eq!(recovered.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(recovered.reason, "run_ownership_evidence_changed");
        assert_eq!(durable.baseline_oid, proof.baseline_oid);
        assert_eq!(durable.expected_oid.as_deref(), Some(oid.as_str()));
        assert_eq!(durable.owned_oids, proof.owned_oids);
        assert!(!recovered.push_invoked);
    }

    #[test]
    fn recorded_ownership_is_never_adopted_without_core_evidence() {
        let f = Fixture::new("recovery-forged-ownership");
        f.configure(vec![]);
        let oid = f.commit("unrelated local commit");
        let forged = f.ownership(oid);
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&forged));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "forged worker record".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();

        let recovered = f.recover_at(&f.run_dir, "run-test", None);

        assert_eq!(recovered.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(recovered.reason, "run_ownership_evidence_changed");
        assert!(!recovered.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn worker_projected_verified_status_never_short_circuits_recovery() {
        let f = Fixture::new("forged-verified-projection");
        f.configure(vec![check("must fail", "false")]);
        let oid = f.commit("trusted integrated commit");
        let proof = f.ownership(oid);
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut forged = base_record("run-test", "YARD-001", &policy, None);
        forged.status = GitFinishStatus::Pushed;
        forged.push_invoked = true;
        forged.push_succeeded = true;
        forged.reason = "worker forged verified status".into();
        std::fs::write(
            f.run_dir.join("git-finish.json"),
            serde_json::to_string_pretty(&forged).unwrap(),
        )
        .unwrap();

        let recovered = f.recover_at(&f.run_dir, "run-test", Some(proof));

        assert_eq!(recovered.status, GitFinishStatus::CheckBlocked);
        assert!(!recovered.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn recovery_cannot_retarget_a_recorded_remote() {
        let f = Fixture::new("recovery-retarget");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();
        let other = f.bare_remote("recovery-retarget-other");
        let mut config = f.ws.load_config().unwrap();
        config.git_finish.remote = other.to_string_lossy().into_owned();
        crate::state::save_yaml(&f.ws.config_path(), &config).unwrap();

        let recovered = f.recover_at(&f.run_dir, "run-test", Some(proof));

        assert_eq!(recovered.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(recovered.reason, "git_finish_target_changed");
        assert!(!recovered.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
        assert_eq!(
            remote_oid(&f.root, other.to_str().unwrap(), "refs/heads/main").unwrap(),
            None
        );
    }

    #[test]
    fn missing_ownership_and_dirty_tree_are_safety_blocks() {
        let f = Fixture::new("safety");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let no_owner = f.finish(None);
        assert_eq!(no_owner.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(no_owner.reason, "run_has_no_owned_commit");

        std::fs::write(f.root.join("dirty.txt"), "dirty\n").unwrap();
        let dirty = f.finish(Some(oid));
        assert_eq!(dirty.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(dirty.reason, "worktree_not_clean");
        assert!(!dirty.push_invoked);
    }

    #[test]
    fn rename_from_outside_into_agents_is_blocked_before_push() {
        let f = Fixture::new("rename-into-agents");
        f.configure(vec![]);
        std::fs::write(f.root.join("outside.txt"), "outside\n").unwrap();
        cmd(&f.root, &["add", "outside.txt"]);
        cmd(&f.root, &["commit", "-q", "-m", "owned"]);
        let oid = head_oid(&f.root).unwrap();
        cmd(&f.root, &["mv", "outside.txt", ".agents/inside.txt"]);

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "worktree_not_clean");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn porcelain_z_parser_checks_both_rename_paths() {
        assert!(status_paths_are_agents_only(
            b"R  .agents/new.txt\0.agents/old.txt\0"
        ));
        assert!(!status_paths_are_agents_only(
            b"R  .agents/inside.txt\0outside.txt\0"
        ));
        assert!(!status_paths_are_agents_only(
            b"R  outside.txt\0.agents/inside.txt\0"
        ));
        assert!(!status_paths_are_agents_only(b"R  .agents/inside.txt\0"));
    }

    #[test]
    fn live_owner_lock_is_preserved_and_dead_owner_is_reclaimed() {
        let f = Fixture::new("lock-owner-liveness");
        let owner = FinishLock::acquire(&f.root, "fixture", "refs/heads/main").unwrap();

        assert_eq!(
            FinishLock::acquire_with_timeout(
                &f.root,
                "fixture",
                "refs/heads/main",
                Duration::from_millis(50),
            )
            .err(),
            Some("finish_lock_timeout")
        );
        drop(owner);

        let lock_root = f.root.join(".git/yardlet-finish-locks");
        let lock_path = std::fs::read_dir(&lock_root)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        std::fs::remove_file(&lock_path).unwrap();
        std::fs::create_dir(&lock_path).unwrap();
        std::fs::write(lock_path.join("pid"), "2147483647\n").unwrap();
        let _reclaimed = FinishLock::acquire_with_timeout(
            &f.root,
            "fixture",
            "refs/heads/main",
            Duration::from_secs(1),
        )
        .unwrap();
        assert!(
            lock_path.is_file(),
            "dead legacy lock must migrate to a file"
        );
    }

    #[test]
    fn lock_failure_does_not_overwrite_prepared_record() {
        let f = Fixture::new("preserve-prepared");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid);
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();

        let fallback = base_record("run-test", "YARD-001", &policy, Some(&proof));
        let returned = lock_failure_record(fallback, "finish_lock_timeout");
        let durable = f.ws.load_git_finish_record(&f.run_dir).unwrap();

        assert_eq!(returned.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(returned.reason, "finish_lock_timeout");
        assert_eq!(durable.status, GitFinishStatus::Prepared);
        assert_eq!(durable.reason, "ready_to_push");
    }

    #[test]
    fn check_cannot_retarget_fetch_url_before_push() {
        let f = Fixture::new("fetch-retarget");
        let other = f.bare_remote("retarget-fetch");
        f.configure(vec![check(
            "retarget fetch",
            &format!("git remote set-url fixture {}", other.display()),
        )]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "remote_urls_changed_during_checks");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, f.remote.to_str().unwrap(), "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
        assert!(
            remote_oid(&f.root, other.to_str().unwrap(), "refs/heads/main")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn check_cannot_retarget_push_url_before_push() {
        let f = Fixture::new("push-retarget");
        let other = f.bare_remote("retarget-push");
        f.configure(vec![check(
            "retarget push",
            &format!("git remote set-url --push fixture {}", other.display()),
        )]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "remote_urls_changed_during_checks");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, f.remote.to_str().unwrap(), "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
        assert!(
            remote_oid(&f.root, other.to_str().unwrap(), "refs/heads/main")
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn check_cannot_move_head_before_push() {
        let f = Fixture::new("head-move");
        f.configure(vec![check("move head", "git reset --hard HEAD^")]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "head_changed_during_checks");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn failed_pre_push_attempt_record_blocks_push_and_propagates_error() {
        let f = Fixture::new("record-failure");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let ownership = GitFinishOwnership {
            baseline_oid: f.initial_oid.clone(),
            expected_oid: oid.clone(),
            owned_oids: vec![oid],
        };
        std::fs::create_dir_all(f.run_dir.join("git-finish.json")).unwrap();

        let error = finish_owned_run(
            &f.ws,
            &f.run_dir,
            "run-test",
            "YARD-001",
            TaskState::Done,
            Some(ownership),
        )
        .unwrap_err();

        assert!(error.to_string().contains("git-finish.json"));
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn user_check_name_and_output_are_not_reflected() {
        let f = Fixture::new("check-redaction");
        let secret = "sensitive-check-marker-92841";
        f.configure(vec![check(
            secret,
            &format!("printf '{secret}'; printf '{secret}' >&2; false"),
        )]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));
        let json = std::fs::read_to_string(f.run_dir.join("git-finish.json")).unwrap();
        let user_line = record.user_line();

        assert_eq!(record.status, GitFinishStatus::CheckBlocked);
        assert_eq!(record.checks[0].name, "check_1");
        assert!(!json.contains(secret));
        assert!(!user_line.contains(secret));
    }

    #[test]
    fn rejected_push_is_git_failed_without_leaking_remote_details() {
        use std::os::unix::fs::PermissionsExt;

        let f = Fixture::new("git-failed");
        f.configure(vec![]);
        let hook = f.remote.join("hooks/pre-receive");
        std::fs::write(&hook, "#!/bin/sh\nexit 1\n").unwrap();
        let mut perms = std::fs::metadata(&hook).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&hook, perms).unwrap();
        let oid = f.commit("owned");
        let record = f.finish(Some(oid));
        assert_eq!(record.status, GitFinishStatus::GitFailed);
        assert_eq!(record.reason, "push_failed");
        assert!(record.push_invoked);
        assert!(!record.push_succeeded);
        let json = std::fs::read_to_string(f.run_dir.join("git-finish.json")).unwrap();
        assert!(!json.contains(f.remote.to_str().unwrap()));
    }

    #[test]
    fn post_push_independent_lookup_detects_remote_mismatch() {
        let f = Fixture::new("mismatch");
        f.configure(vec![]);
        let other = f.root.parent().unwrap().join("push-only.git");
        cmd(
            f.root.parent().unwrap(),
            &["init", "-q", "--bare", other.to_str().unwrap()],
        );
        cmd(
            &f.root,
            &[
                "remote",
                "set-url",
                "--push",
                "fixture",
                other.to_str().unwrap(),
            ],
        );
        let oid = f.commit("owned");
        let record = f.finish(Some(oid.clone()));
        assert_eq!(record.status, GitFinishStatus::RemoteMismatch);
        assert!(record.push_invoked);
        assert!(record.push_succeeded);
        assert_eq!(record.remote_oid, Some(f.initial_oid.clone()));
        assert_eq!(
            remote_oid(&f.root, other.to_str().unwrap(), "refs/heads/main").unwrap(),
            Some(oid)
        );
    }

    #[test]
    fn unowned_local_commit_in_reachable_set_is_never_pushed() {
        let f = Fixture::new("unowned-reachable");
        f.configure(vec![]);
        std::fs::write(f.root.join("external.txt"), "external\n").unwrap();
        cmd(&f.root, &["add", "external.txt"]);
        cmd(
            &f.root,
            &["commit", "-q", "-m", "external local automation"],
        );
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "reachable_commits_not_owned_by_run");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn index_or_worktree_change_during_checks_blocks_before_push() {
        let f = Fixture::new("index-change");
        f.configure(vec![check(
            "mutate index",
            "printf changed > owned.txt && git add owned.txt",
        )]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "worktree_changed_during_checks");
        assert!(!record.push_invoked);
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(f.initial_oid.clone())
        );
    }

    #[test]
    fn remote_ref_change_during_checks_blocks_yardlet_push() {
        let f = Fixture::new("remote-ref-change");
        f.configure(vec![check(
            "advance remote",
            "peer=$(printf peer | git commit-tree HEAD^{tree} -p HEAD) && \
             git push -q fixture \"$peer:refs/heads/main\"",
        )]);
        let oid = f.commit("owned");

        let record = f.finish(Some(oid));

        assert_eq!(record.status, GitFinishStatus::SafetyBlocked);
        assert_eq!(record.reason, "remote_ref_changed_during_checks");
        assert!(!record.push_invoked);
        assert_ne!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            record.expected_oid
        );
    }

    #[test]
    fn same_target_finishers_serialize_and_push_once() {
        let f = Fixture::new("serialized");
        f.configure(vec![check("hold lock", "sleep 0.2")]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let run_a = f.run_dir.parent().unwrap().join("run-a");
        let run_b = f.run_dir.parent().unwrap().join("run-b");
        std::fs::create_dir_all(&run_a).unwrap();
        std::fs::create_dir_all(&run_b).unwrap();
        let ws_a = f.ws.clone();
        let ws_b = f.ws.clone();
        let proof_a = proof.clone();
        let a = std::thread::spawn(move || {
            finish_owned_run(
                &ws_a,
                &run_a,
                "run-a",
                "YARD-A",
                TaskState::Done,
                Some(proof_a),
            )
            .unwrap()
        });
        let b = std::thread::spawn(move || {
            finish_owned_run(
                &ws_b,
                &run_b,
                "run-b",
                "YARD-B",
                TaskState::Done,
                Some(proof),
            )
            .unwrap()
        });
        let records = [a.join().unwrap(), b.join().unwrap()];

        assert_eq!(
            records
                .iter()
                .filter(|record| record.status == GitFinishStatus::Pushed)
                .count(),
            1
        );
        assert_eq!(
            records
                .iter()
                .filter(|record| record.status == GitFinishStatus::AlreadyApplied)
                .count(),
            1
        );
        assert_eq!(
            records.iter().filter(|record| record.push_invoked).count(),
            1
        );
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(oid)
        );
    }

    #[test]
    fn prepared_record_recovers_idempotently_from_remote_truth() {
        let f = Fixture::new("recover-prepared");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();

        let recovered = f.finish_at(&f.run_dir, Some(proof.clone()));
        let repeated = f.finish_at(&f.run_dir, Some(proof));

        assert_eq!(recovered.status, GitFinishStatus::Pushed);
        assert!(recovered.push_invoked);
        assert_eq!(repeated.status, GitFinishStatus::AlreadyApplied);
        assert!(!repeated.push_invoked);
        assert_eq!(repeated.remote_oid.as_deref(), Some(oid.as_str()));
    }

    #[test]
    fn concurrent_and_repeated_recovery_preserves_pushed_record() {
        let f = Fixture::new("concurrent-recover-prepared");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();

        let ws_a = f.ws.clone();
        let ws_b = f.ws.clone();
        let run_a = f.run_dir.clone();
        let run_b = f.run_dir.clone();
        let proof_a = proof.clone();
        let proof_b = proof.clone();
        let a = std::thread::spawn(move || {
            recover_owned_run(
                &ws_a,
                &run_a,
                "run-test",
                "YARD-001",
                TaskState::Done,
                Some(proof_a),
            )
            .unwrap()
        });
        let b = std::thread::spawn(move || {
            recover_owned_run(
                &ws_b,
                &run_b,
                "run-test",
                "YARD-001",
                TaskState::Done,
                Some(proof_b),
            )
            .unwrap()
        });
        let records = [a.join().unwrap(), b.join().unwrap()];
        let repeated = f.recover_at(&f.run_dir, "run-test", Some(proof));
        let durable = f.ws.load_git_finish_record(&f.run_dir).unwrap();

        assert!(records.iter().all(|record| matches!(
            record.status,
            GitFinishStatus::Pushed | GitFinishStatus::AlreadyApplied
        )));
        assert_eq!(
            records.iter().filter(|record| record.push_invoked).count(),
            1
        );
        assert_eq!(repeated.status, GitFinishStatus::AlreadyApplied);
        assert!(!repeated.push_invoked);
        assert_eq!(durable.status, GitFinishStatus::AlreadyApplied);
        assert!(!durable.push_invoked);
        assert_eq!(durable.remote_oid.as_deref(), Some(oid.as_str()));
        assert_eq!(
            remote_oid(&f.root, "fixture", "refs/heads/main").unwrap(),
            Some(oid)
        );
    }

    #[test]
    fn prepared_after_push_recovers_without_duplicate_push() {
        let f = Fixture::new("recover-after-push");
        f.configure(vec![]);
        let oid = f.commit("owned");
        let proof = f.ownership(oid.clone());
        let policy = f.ws.load_config().unwrap().git_finish;
        let mut prepared = base_record("run-test", "YARD-001", &policy, Some(&proof));
        prepared.status = GitFinishStatus::Prepared;
        prepared.reason = "ready_to_push".to_string();
        persist(&f.ws, &f.run_dir, &prepared).unwrap();
        cmd(
            &f.root,
            &["push", "-q", "fixture", &format!("{oid}:refs/heads/main")],
        );

        let recovered = f.finish_at(&f.run_dir, Some(proof.clone()));
        let repeated = f.finish_at(&f.run_dir, Some(proof));

        assert_eq!(recovered.status, GitFinishStatus::AlreadyApplied);
        assert!(!recovered.push_invoked);
        assert_eq!(repeated.status, GitFinishStatus::AlreadyApplied);
        assert!(!repeated.push_invoked);
    }
}
