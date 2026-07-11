//! Deterministic, user-owned Git finish policy.
//!
//! This module is the only Yardlet path that pushes. It accepts an OID that
//! the completion engine has already attributed to the current run, checks the
//! repository and user policy, pushes a non-force OID refspec, and verifies the
//! remote ref independently. Records intentionally have no URL, output, or
//! environment fields.

use std::path::Path;
use std::process::Command;

use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::schemas::{GitFinishPolicy, TaskState};
use crate::state::Workspace;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GitFinishStatus {
    Disabled,
    Prepared,
    Pushed,
    AlreadyApplied,
    CheckBlocked,
    SafetyBlocked,
    GitFailed,
    RemoteMismatch,
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
    pub checks: Vec<GitFinishCheckRecord>,
    pub push_invoked: bool,
    pub push_succeeded: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub remote_oid: Option<String>,
    pub reason: String,
}

impl GitFinishRecord {
    pub fn user_line(&self) -> String {
        match self.status {
            GitFinishStatus::Disabled => "git finish: disabled by workspace policy".to_string(),
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
    owned_oid: Option<String>,
) -> anyhow::Result<GitFinishRecord> {
    let policy = match ws.load_config() {
        Ok(config) => config.git_finish,
        Err(_) => {
            let policy = GitFinishPolicy::default();
            let mut record = base_record(run_id, task_id, &policy, owned_oid);
            block(&mut record, "config_unreadable");
            return persist_and_return(ws, run_dir, record);
        }
    };
    let mut record = base_record(run_id, task_id, &policy, owned_oid);

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
    let current_branch = git_stdout(&ws.root, &["symbolic-ref", "--quiet", "--short", "HEAD"]);
    if current_branch.as_deref().map(str::trim) != Some(branch) {
        block(&mut record, "branch_does_not_match_target_ref");
        return persist_and_return(ws, run_dir, record);
    }
    let Some(expected) = record.expected_oid.clone() else {
        block(&mut record, "run_has_no_owned_commit");
        return persist_and_return(ws, run_dir, record);
    };
    if pins_before.head != expected {
        block(&mut record, "owned_oid_is_not_head");
        return persist_and_return(ws, run_dir, record);
    }
    if !worktree_clean_except_agents(&ws.root) {
        block(&mut record, "worktree_not_clean");
        return persist_and_return(ws, run_dir, record);
    }

    match remote_oid(&ws.root, &policy.remote, &policy.target_ref) {
        Ok(Some(oid)) if oid == expected => {
            record.status = GitFinishStatus::AlreadyApplied;
            record.remote_oid = Some(oid);
            record.reason = "remote_already_matches".to_string();
            return persist_and_return(ws, run_dir, record);
        }
        Ok(_) => {}
        Err(()) => {
            record.status = GitFinishStatus::GitFailed;
            record.reason = "remote_lookup_before_push_failed".to_string();
            return persist_and_return(ws, run_dir, record);
        }
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
        &["push", "--porcelain", "--", &policy.remote, &refspec],
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

fn base_record(
    run_id: &str,
    task_id: &str,
    policy: &GitFinishPolicy,
    expected_oid: Option<String>,
) -> GitFinishRecord {
    GitFinishRecord {
        schema_version: 1,
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
        expected_oid,
        checks: Vec::new(),
        push_invoked: false,
        push_succeeded: false,
        remote_oid: None,
        reason: "policy_disabled".to_string(),
    }
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
    let Some(status) = git_stdout(root, &["status", "--porcelain=v1", "--untracked-files=all"])
    else {
        return false;
    };
    status.lines().all(|line| {
        let path = line.get(3..).unwrap_or("");
        let path = path.split(" -> ").last().unwrap_or(path).trim_matches('"');
        path == ".agents" || path.starts_with(".agents/")
    })
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
            crate::init::init(&root, false).unwrap();
            let ws = Workspace::at(&root);
            let run_dir = ws.runs_dir().join("run-test");
            std::fs::create_dir_all(&run_dir).unwrap();
            Self {
                root,
                remote,
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
            finish_owned_run(
                &self.ws,
                &self.run_dir,
                "run-test",
                "YARD-001",
                TaskState::Done,
                oid,
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
        assert!(remote_oid(&f.root, "fixture", "refs/heads/main")
            .unwrap()
            .is_none());
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
        assert!(remote_oid(&f.root, "fixture", "refs/heads/main")
            .unwrap()
            .is_none());
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
        assert!(
            remote_oid(&f.root, f.remote.to_str().unwrap(), "refs/heads/main")
                .unwrap()
                .is_none()
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
        assert!(
            remote_oid(&f.root, f.remote.to_str().unwrap(), "refs/heads/main")
                .unwrap()
                .is_none()
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
        assert!(remote_oid(&f.root, "fixture", "refs/heads/main")
            .unwrap()
            .is_none());
    }

    #[test]
    fn failed_pre_push_attempt_record_blocks_push_and_propagates_error() {
        let f = Fixture::new("record-failure");
        f.configure(vec![]);
        let oid = f.commit("owned");
        std::fs::create_dir_all(f.run_dir.join("git-finish.json")).unwrap();

        let error = finish_owned_run(
            &f.ws,
            &f.run_dir,
            "run-test",
            "YARD-001",
            TaskState::Done,
            Some(oid),
        )
        .unwrap_err();

        assert!(error.to_string().contains("git-finish.json"));
        assert!(remote_oid(&f.root, "fixture", "refs/heads/main")
            .unwrap()
            .is_none());
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
        assert_eq!(record.remote_oid, None);
        assert_eq!(
            remote_oid(&f.root, other.to_str().unwrap(), "refs/heads/main").unwrap(),
            Some(oid)
        );
    }
}
