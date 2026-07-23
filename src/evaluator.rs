//! Deterministic evaluator.
//!
//! Yardlet does not trust a worker's claims blindly. After a run it checks the
//! evidence on disk and decides the next task state. The first evaluator is
//! intentionally shallow but honest: every check is mechanical.

use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::schemas::{RunResult, Task, TaskState};

#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
    /// A fatal check gates a `done` result: if any fatal check fails, the task
    /// cannot be marked Done. Advisory checks are reported but do not downgrade
    /// the work (e.g. "did validation run" is informative, not an integrity
    /// violation, since some tasks have nothing to validate).
    pub fatal: bool,
    pub note: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Evaluation {
    pub run_id: String,
    pub task_id: String,
    pub status: String,
    pub checks: Vec<Check>,
    pub next_task_state: TaskState,
}

fn check(name: &str, passed: bool, note: impl Into<String>) -> Check {
    Check {
        name: name.into(),
        passed,
        fatal: true,
        note: note.into(),
    }
}

fn advisory(name: &str, passed: bool, note: impl Into<String>) -> Check {
    Check {
        name: name.into(),
        passed,
        fatal: false,
        note: note.into(),
    }
}

/// A failed fatal check contributed from outside the evaluator (e.g. run.rs
/// folding a non-zero post-run hook into the evaluation, H3).
pub fn fatal_failure(name: &str, note: impl Into<String>) -> Check {
    check(name, false, note)
}

pub fn evaluate(
    run_dir: &Path,
    run_id: &str,
    task: &Task,
    actual_changes: Option<&[String]>,
) -> Evaluation {
    let mut checks = Vec::new();

    let result_path = run_dir.join("result.json");
    let result: Option<RunResult> = std::fs::read_to_string(&result_path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());

    checks.push(check(
        "result_file_present",
        result_path.is_file(),
        "result.json exists",
    ));
    checks.push(check(
        "result_schema_valid",
        result.is_some(),
        "result.json parses against the result schema",
    ));
    checks.push(check(
        "handoff_present",
        run_dir.join("handoff.md").is_file(),
        "handoff.md exists",
    ));

    let mut reported_status = "failed".to_string();

    if let Some(r) = &result {
        checks.push(check(
            "ids_match",
            r.task_id == task.id && r.run_id == run_id,
            format!("result ids match run {run_id} / task {}", task.id),
        ));
        let exact_attempt_id = std::fs::read_to_string(run_dir.join("latest-attempt"))
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| run_id.to_string());
        let resource_errors = r.resource_provenance_errors(&exact_attempt_id);
        checks.push(check(
            "resource_provenance_valid",
            resource_errors.is_empty(),
            if resource_errors.is_empty() {
                format!("resource proposals link to exact attempt {exact_attempt_id}")
            } else {
                format!(
                    "invalid resource proposal provenance: {}",
                    resource_errors.join("; ")
                )
            },
        ));
        let uncontrolled = r.intent_adherence.uncontrolled_deviations(task);
        let typed_disclosures = &r.intent_adherence.deviations;
        let drift_passed = if typed_disclosures.is_empty() {
            !r.intent_adherence.drift_detected
        } else {
            uncontrolled.is_empty()
        };
        let drift_note = if typed_disclosures.is_empty() {
            if r.intent_adherence.drift_detected {
                format!(
                    "worker reported untyped drift that has no exact acceptance identity: {}",
                    r.intent_adherence.notes
                )
            } else {
                "worker reported no scope drift".to_string()
            }
        } else if uncontrolled.is_empty() {
            format!(
                "all disclosed deviations were explicitly accepted by the user: {}",
                typed_disclosures
                    .iter()
                    .map(|deviation| deviation.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        } else {
            format!(
                "worker reported new or unaccepted deviation(s): {}",
                uncontrolled
                    .iter()
                    .map(|deviation| deviation.id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        checks.push(check("no_uncontrolled_drift", drift_passed, drift_note));
        // Forbidden-path runs on the ACTUAL on-disk diff (`actual_changes`).
        // A worker's self-report is NOT evidence for a safety guarantee, so when
        // no diff evidence is available the check fails closed (the run cannot
        // reach Done) rather than trusting the worker's word.
        let reported: Vec<String> = r
            .changes
            .files_modified
            .iter()
            .chain(&r.changes.files_created)
            .chain(&r.changes.files_deleted)
            .cloned()
            .collect();
        match actual_changes {
            Some(actual) => {
                let forbidden = forbidden_in(actual.iter());
                checks.push(check(
                    "forbidden_paths_untouched",
                    forbidden.is_empty(),
                    if forbidden.is_empty() {
                        "no sensitive or out-of-workspace paths in the actual diff".to_string()
                    } else {
                        format!("changed forbidden path(s): {}", forbidden.join(", "))
                    },
                ));
                // With the real diff in hand, flag files the worker changed but
                // did not disclose (advisory: surfaces incomplete/dishonest
                // self-reports without blocking an otherwise-clean run).
                let norm = |p: &str| p.trim_start_matches("./").to_string();
                let reported_norm: std::collections::HashSet<String> =
                    reported.iter().map(|p| norm(p)).collect();
                let undisclosed: Vec<String> = actual
                    .iter()
                    .map(|p| norm(p))
                    .filter(|p| !is_current_run_artifact(p, run_id))
                    .filter(|p| !reported_norm.contains(p))
                    .collect();
                checks.push(advisory(
                    "diff_matches_report",
                    undisclosed.is_empty(),
                    if undisclosed.is_empty() {
                        "worker-reported changes match the actual diff".to_string()
                    } else {
                        format!("changed but not reported: {}", undisclosed.join(", "))
                    },
                ));
            }
            None => {
                // Fail closed: no independent evidence to certify the gate.
                checks.push(check(
                    "forbidden_paths_untouched",
                    false,
                    "no independent change evidence (git status or workspace scan failed): \
                     cannot certify forbidden paths untouched, so the run cannot be Done"
                        .to_string(),
                ));
                let reported_forbidden = forbidden_in(reported.iter());
                if !reported_forbidden.is_empty() {
                    checks.push(advisory(
                        "reported_forbidden_paths",
                        false,
                        format!(
                            "worker self-reported forbidden path(s): {}",
                            reported_forbidden.join(", ")
                        ),
                    ));
                }
            }
        }
        checks.push(advisory(
            "validation_ran",
            !r.validation.commands_run.is_empty(),
            if r.validation.commands_run.is_empty() {
                "no validation commands were run (may be fine for this task)".to_string()
            } else {
                format!(
                    "{} validation command(s) run",
                    r.validation.commands_run.len()
                )
            },
        ));
        if !r.validation.passed {
            checks.push(check(
                "reported_validation",
                false,
                if r.validation.failures.is_empty() {
                    "worker reported validation failure".to_string()
                } else {
                    format!(
                        "worker reported validation failure: {}",
                        r.validation.failures.join("; ")
                    )
                },
            ));
        }
        if r.status == "done"
            && r.question_for_user
                .as_deref()
                .map(str::trim)
                .is_some_and(|q| !q.is_empty())
        {
            checks.push(advisory(
                "done_status_has_question",
                false,
                "worker reported done but also left question_for_user; keeping Done eligible while preserving the question in run artifacts".to_string(),
            ));
        }
        // Structured review verdict: the quality signal Yardlet records instead
        // of trusting prose. For a review/safety task it is the contract —
        // an empty verdict or any failed criterion blocks Done.
        let is_review = matches!(crate::packet::role_for(&task.kind), "reviewer" | "security");
        // A review that paused for the user has not finished judging — it is
        // mid-conversation, not failing. Defer the verdict/criteria gate so a
        // clarifying turn does not read as a wall of failed criteria.
        if is_review && r.status == "needs_user" {
            checks.push(advisory(
                "review_paused_for_user",
                true,
                "review is waiting on the user; criteria not yet judged".to_string(),
            ));
        } else if is_review {
            let failed: Vec<&str> = r
                .verdict
                .iter()
                .filter(|v| !v.pass)
                .map(|v| v.criterion_id.as_str())
                .collect();
            checks.push(check(
                "review_verdict_present",
                !r.verdict.is_empty(),
                if r.verdict.is_empty() {
                    "review task wrote no structured verdict".to_string()
                } else {
                    format!("{} criterion verdict(s)", r.verdict.len())
                },
            ));
            checks.push(check(
                "review_criteria_pass",
                failed.is_empty(),
                if failed.is_empty() {
                    "all judged criteria pass".to_string()
                } else {
                    format!("criteria failed: {}", failed.join(", "))
                },
            ));
        } else if !r.verdict.is_empty() {
            let passed = r.verdict.iter().filter(|v| v.pass).count();
            checks.push(advisory(
                "self_verdict",
                passed == r.verdict.len(),
                format!("{}/{} self-checked criteria pass", passed, r.verdict.len()),
            ));
        }
        reported_status = r.status.clone();
    }

    // Only integrity (fatal) checks gate a `done` result.
    let all_fatal_passed = checks.iter().filter(|c| c.fatal).all(|c| c.passed);
    let next_task_state = decide_state(&reported_status, all_fatal_passed, result.as_ref());

    Evaluation {
        run_id: run_id.to_string(),
        task_id: task.id.clone(),
        status: reported_status,
        checks,
        next_task_state,
    }
}

fn is_current_run_artifact(path: &str, run_id: &str) -> bool {
    let path = path.trim_start_matches("./").trim_matches('"');
    let root = format!(".agents/runs/{run_id}");
    path == root || path.starts_with(&format!("{root}/"))
}

/// Paths that are sensitive (secrets/keys), escape the workspace, or are
/// Yardlet-owned canonical state a worker must never write directly. A worker
/// touching any of these fails the run regardless of its self-report.
fn forbidden_in<'a>(paths: impl Iterator<Item = &'a String>) -> Vec<String> {
    const SENSITIVE: &[&str] = &[
        ".env",
        ".ssh",
        "credentials",
        "secret",
        ".key",
        ".pem",
        ".p12",
    ];
    let mut bad = Vec::new();
    for f in paths {
        let lower = f.to_lowercase();
        let escapes = f.starts_with('/') || f.contains("..");
        let sensitive = SENSITIVE.iter().any(|p| lower.contains(p));
        if escapes || sensitive || is_canonical_state_path(f) {
            bad.push(f.clone());
        }
    }
    bad
}

/// Is this path a Yardlet-owned canonical-state file a worker must NOT write
/// directly (it proposes follow-ups via result.json instead — propose ->
/// ingest)? Scoped PRECISELY so legitimate worker writes are not false-failed:
/// the harness assets (`.agents/rules|skills|agents/`) and a run's own
/// artifacts (`.agents/runs/`) are NOT canonical and stay writable. Forbidden:
/// the top-level config files (`work-queue.yaml`, `intent-contract.yaml`,
/// `workers.yaml`, `*-policy.yaml`, `yardlet.yaml`, legacy `yard.yaml`) and the
/// whole telemetry tree.
pub fn is_canonical_state_path(path: &str) -> bool {
    let p = path.trim_start_matches("./").trim_matches('"');
    let Some(rest) = p.strip_prefix(".agents/") else {
        return false;
    };
    if rest.starts_with("telemetry/") {
        return true;
    }
    // Only top-level files directly under .agents/ are config (no nested path);
    // a nested file lives in an allowed subtree (runs/rules/skills/agents).
    if rest.contains('/') {
        return false;
    }
    matches!(
        rest,
        "work-queue.yaml" | "intent-contract.yaml" | "workers.yaml" | "yardlet.yaml" | "yard.yaml"
    ) || rest.ends_with("-policy.yaml")
}

/// Is this path a repository deliverable that Yardlet may integrate from an
/// isolated worker worktree? Everything outside `.agents/` is deliverable. The
/// only deliverables inside `.agents/` are the workspace-authored harness asset
/// roots; canonical and runtime state remain main-process-owned.
pub fn is_integratable_path(path: &str) -> bool {
    let p = path.trim_start_matches("./").trim_matches('"');
    if p == ".agents" || p.starts_with(".agents/") {
        return [".agents/rules", ".agents/skills", ".agents/agents"]
            .iter()
            .any(|root| p == *root || p.starts_with(&format!("{root}/")));
    }
    true
}

/// Paths git reports as changed or untracked in `cwd`: the actual on-disk
/// evidence of what a run touched, independent of what the worker claims.
///
/// Returns `None` when git is unavailable or `cwd` is not a repository, so the
/// caller can tell "no changes" (`Some(empty)`) apart from "no evidence"
/// (`None`). A worker's self-report is never treated as evidence for a safety
/// guarantee, so the evaluator fails closed on `None` rather than trusting it.
pub fn changed_paths(cwd: &Path) -> Option<Vec<String>> {
    git_changed_paths(cwd).ok()
}

#[derive(Debug)]
enum GitEvidenceError {
    NotRepo,
    Failed,
}

fn git_changed_paths(cwd: &Path) -> Result<Vec<String>, GitEvidenceError> {
    git_changed_paths_with(cwd, OsStr::new("git"))
}

fn git_changed_paths_with(cwd: &Path, git_bin: &OsStr) -> Result<Vec<String>, GitEvidenceError> {
    let rev_parse = std::process::Command::new(git_bin)
        .arg("-C")
        .arg(cwd)
        .args(["rev-parse", "--is-inside-work-tree"])
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .output()
        .map_err(|_| GitEvidenceError::Failed)?;
    if !rev_parse.status.success() || String::from_utf8_lossy(&rev_parse.stdout).trim() != "true" {
        return Err(GitEvidenceError::NotRepo);
    }

    let out = std::process::Command::new(git_bin)
        .arg("-C")
        .arg(cwd)
        // -z is NUL-separated and NEVER quotes paths, so non-ASCII and
        // special-char (tab/backslash/quote) filenames come through verbatim and
        // stay usable as a literal `git add` pathspec.
        .args(["status", "--porcelain=v1", "--untracked-files=all", "-z"])
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .output()
        .map_err(|_| GitEvidenceError::Failed)?;
    if !out.status.success() {
        return Err(GitEvidenceError::Failed);
    }
    // Each record is "XY <path>\0"; a rename/copy ("R"/"C") adds a trailing
    // "<orig>\0" that we consume and drop (we want the new path, which is on disk).
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut chunks = raw.split('\0');
    let mut paths = Vec::new();
    while let Some(entry) = chunks.next() {
        if entry.len() < 4 {
            continue;
        }
        let xy = &entry[..2];
        let path = entry[3..].to_string();
        if !path.is_empty() {
            paths.push(path);
        }
        if xy.starts_with('R') || xy.starts_with('C') {
            chunks.next();
        }
    }
    Ok(paths)
}

/// A cheap content fingerprint of a workspace file, used to attribute changes to
/// a run (not a security primitive). `absent` if missing; `len:N` for very large
/// files (not read, to bound cost); otherwise a non-cryptographic hash of the
/// bytes.
fn fingerprint_file(abs: &Path) -> String {
    fingerprint_regular_file(abs).unwrap_or_else(|_| "unreadable".to_string())
}

fn fingerprint_regular_file(abs: &Path) -> std::io::Result<String> {
    use std::hash::{Hash, Hasher};
    const CAP: u64 = 8 * 1024 * 1024;
    let m = match std::fs::metadata(abs) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok("absent".to_string()),
        Err(e) => return Err(e),
        Ok(m) => m,
    };
    if !m.is_file() {
        return Ok("nonfile".to_string());
    }
    if m.len() > CAP {
        return Ok(format!("len:{}", m.len()));
    }
    let bytes = std::fs::read(abs)?;
    let mut h = std::collections::hash_map::DefaultHasher::new();
    bytes.hash(&mut h);
    Ok(format!("{:016x}", h.finish()))
}

/// Fingerprints used for a worker run. Git repositories prefer the existing
/// status-based evidence path; if git evidence is unavailable for any reason,
/// Yardlet falls back to a bounded folder scan. `excluded_roots` is for
/// Yardlet-owned runtime output, especially the current run directory, so
/// result/checkpoint/handoff writes are not attributed to the worker's
/// deliverable diff.
pub fn run_fingerprints(
    cwd: &Path,
    excluded_roots: &[PathBuf],
) -> Result<Vec<(String, String)>, String> {
    run_fingerprints_with_git(cwd, excluded_roots, OsStr::new("git"))
}

fn run_fingerprints_with_git(
    cwd: &Path,
    excluded_roots: &[PathBuf],
    git_bin: &OsStr,
) -> Result<Vec<(String, String)>, String> {
    match git_changed_paths_with(cwd, git_bin) {
        Ok(paths) => Ok(paths
            .into_iter()
            .map(|p| {
                let fp = fingerprint_file(&cwd.join(&p));
                (p, fp)
            })
            .collect()),
        Err(GitEvidenceError::NotRepo | GitEvidenceError::Failed) => {
            workspace_fingerprints(cwd, excluded_roots)
                .map_err(|e| format!("workspace scan failed: {e}"))
        }
    }
}

fn workspace_fingerprints(
    cwd: &Path,
    excluded_roots: &[PathBuf],
) -> std::io::Result<Vec<(String, String)>> {
    let excluded: Vec<PathBuf> = excluded_roots
        .iter()
        .filter_map(|p| {
            let abs = if p.is_absolute() {
                p.clone()
            } else {
                cwd.join(p)
            };
            abs.strip_prefix(cwd).ok().map(PathBuf::from)
        })
        .collect();
    let mut out = Vec::new();
    scan_workspace_dir(cwd, cwd, &excluded, &mut out)?;
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

fn scan_workspace_dir(
    root: &Path,
    dir: &Path,
    excluded_roots: &[PathBuf],
    out: &mut Vec<(String, String)>,
) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let rel = path.strip_prefix(root).unwrap_or(path.as_path());
        if skip_workspace_path(rel, excluded_roots) {
            continue;
        }
        let ft = entry.file_type()?;
        if ft.is_dir() {
            scan_workspace_dir(root, &path, excluded_roots, out)?;
        } else if ft.is_file() {
            out.push((rel_path_string(rel), fingerprint_regular_file(&path)?));
        } else if ft.is_symlink() {
            let target = std::fs::read_link(&path)?;
            out.push((
                rel_path_string(rel),
                format!("symlink:{}", target.to_string_lossy()),
            ));
        }
    }
    Ok(())
}

fn skip_workspace_path(rel: &Path, excluded_roots: &[PathBuf]) -> bool {
    if rel.components().any(|c| {
        let s = c.as_os_str().to_string_lossy();
        matches!(s.as_ref(), ".git" | "target" | "node_modules")
    }) {
        return true;
    }
    excluded_roots
        .iter()
        .any(|ex| rel == ex || rel.starts_with(ex))
}

fn rel_path_string(path: &Path) -> String {
    path.components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/")
}

/// Paths the worker actually touched between `baseline` and `after`: any path
/// whose fingerprint is new or differs (added/modified), plus any that vanished
/// from the dirty set (reverted or deleted). Closes the hole where a worker
/// re-modifies a path that was already dirty before the run (plain path-set
/// subtraction would filter it out).
pub fn worker_touched(baseline: &[(String, String)], after: &[(String, String)]) -> Vec<String> {
    use std::collections::BTreeMap;
    let base: BTreeMap<&str, &str> = baseline
        .iter()
        .map(|(p, f)| (p.as_str(), f.as_str()))
        .collect();
    let aft: BTreeMap<&str, &str> = after
        .iter()
        .map(|(p, f)| (p.as_str(), f.as_str()))
        .collect();
    let mut touched: Vec<String> = Vec::new();
    for (p, f) in &aft {
        if base.get(p) != Some(f) {
            touched.push((*p).to_string());
        }
    }
    for p in base.keys() {
        if !aft.contains_key(p) {
            touched.push((*p).to_string());
        }
    }
    touched.sort();
    touched.dedup();
    touched
}

fn decide_state(reported: &str, all_passed: bool, result: Option<&RunResult>) -> TaskState {
    // A worker can only earn `done` if it claims done *and* the mechanical
    // checks pass. Non-blocking leftovers belong in follow_up_tasks while the
    // status stays done; needs_user remains reserved for acceptance-blocking
    // questions or gated actions.
    match reported {
        "done" if all_passed => TaskState::Done,
        "done" => TaskState::Failed, // claimed done but evidence is incomplete
        "partial" => TaskState::Partial,
        "blocked" => TaskState::Blocked,
        "needs_user"
            if result
                .and_then(|result| result.question_for_user.as_deref())
                .map(str::trim)
                .is_some_and(|question| !question.is_empty()) =>
        {
            TaskState::NeedsUser
        }
        // NeedsUser is an actionable hand-off contract, not just a status
        // label. A blank question is evaluated as a failed worker result so the
        // run layer can retry it or create a concrete feedback question.
        "needs_user" => TaskState::Failed,
        "failed" => TaskState::Failed,
        _ => {
            if result.is_none() {
                TaskState::Failed
            } else {
                TaskState::Blocked
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{Changes, Task};

    fn temp_path(name: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("yard-{name}-{}-{nanos}", std::process::id()))
    }

    fn dummy_result() -> RunResult {
        RunResult {
            schema_version: 1,
            run_id: "r".into(),
            task_id: "t".into(),
            status: "partial".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: String::new(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        }
    }

    fn implementation_task(id: &str) -> Task {
        Task {
            id: id.into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        }
    }

    fn write_done_result(run_dir: &Path, run_id: &str, task_id: &str) {
        std::fs::write(run_dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = run_id.into();
        r.task_id = task_id.into();
        r.status = "done".into();
        std::fs::write(
            run_dir.join("result.json"),
            serde_json::to_string(&r).unwrap(),
        )
        .unwrap();
    }

    #[test]
    fn done_requires_all_checks_passing() {
        assert_eq!(decide_state("done", true, None), TaskState::Done);
        // claimed done but evidence incomplete -> not trusted
        assert_eq!(decide_state("done", false, None), TaskState::Failed);
    }

    #[test]
    fn done_with_nonblocking_followups_stays_done() {
        let mut r = dummy_result();
        r.status = "done".into();
        r.follow_up_tasks = vec![crate::schemas::FollowUpTask {
            title: "tidy optional docs".into(),
            reason: "non-blocking cleanup after acceptance passed".into(),
            ..Default::default()
        }];
        assert_eq!(decide_state("done", true, Some(&r)), TaskState::Done);
    }

    #[test]
    fn done_with_question_records_advisory_but_stays_done() {
        let dir =
            std::env::temp_dir().join(format!("yard-eval-done-question-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();

        let mut r = dummy_result();
        r.run_id = "run-x".into();
        r.task_id = "YARD-9".into();
        r.status = "done".into();
        r.question_for_user = Some("Is this optional cleanup worth scheduling later?".into());
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();

        let t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };

        let e = evaluate(&dir, "run-x", &t, Some(&[]));
        assert_eq!(e.next_task_state, TaskState::Done);
        let c = e
            .checks
            .iter()
            .find(|c| c.name == "done_status_has_question")
            .expect("done/question contradiction must be recorded");
        assert!(!c.fatal, "contradiction is advisory, not a Done gate");
        assert!(!c.passed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn reported_validation_failure_blocks_done_and_preserves_exact_failure() {
        let dir = temp_path("reported-validation");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = "run-validation".into();
        r.task_id = "YARD-VAL".into();
        r.status = "done".into();
        r.validation.passed = false;
        r.validation.failures = vec!["cargo test: test_parser failed".into()];
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();

        let t = implementation_task("YARD-VAL");
        let e = evaluate(&dir, "run-validation", &t, Some(&[]));
        assert_eq!(e.next_task_state, TaskState::Failed);
        let check = e
            .checks
            .iter()
            .find(|c| c.name == "reported_validation")
            .expect("reported validation must be a fatal check");
        assert!(check.fatal && !check.passed);
        assert!(check.note.contains("test_parser failed"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn diff_report_ignores_current_run_artifacts_owned_by_yardlet() {
        let dir = temp_path("core-run-artifact-disclosure");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut result = dummy_result();
        result.run_id = "run-x".into();
        result.task_id = "YARD-RUN-ARTIFACT".into();
        result.status = "done".into();
        std::fs::write(
            dir.join("result.json"),
            serde_json::to_string(&result).unwrap(),
        )
        .unwrap();

        let actual = vec![
            ".agents/runs/run-x/worker-output.log".to_string(),
            ".agents/runs/another-run/worker-output.log".to_string(),
        ];
        let evaluation = evaluate(
            &dir,
            "run-x",
            &implementation_task("YARD-RUN-ARTIFACT"),
            Some(&actual),
        );
        let disclosure = evaluation
            .checks
            .iter()
            .find(|check| check.name == "diff_matches_report")
            .unwrap();
        assert!(!disclosure.passed);
        assert!(!disclosure
            .note
            .contains(".agents/runs/run-x/worker-output.log"));
        assert!(disclosure
            .note
            .contains(".agents/runs/another-run/worker-output.log"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn acceptance_blocking_question_still_needs_user() {
        let mut r = dummy_result();
        r.status = "needs_user".into();
        r.question_for_user = Some("Which production region should this target?".into());
        assert_eq!(
            decide_state("needs_user", true, Some(&r)),
            TaskState::NeedsUser
        );
    }

    #[test]
    fn needs_user_requires_an_actionable_question() {
        let mut r = dummy_result();
        r.status = "needs_user".into();
        r.question_for_user = Some(" \n\t ".into());

        assert_eq!(
            decide_state("needs_user", true, Some(&r)),
            TaskState::Failed,
            "an empty question must not be exposed as NeedsUser"
        );
        assert_eq!(
            decide_state("needs_user", true, None),
            TaskState::Failed,
            "NeedsUser without a parsed result cannot carry a question"
        );
    }

    #[test]
    fn non_done_states_map_safely() {
        assert_eq!(decide_state("partial", true, None), TaskState::Partial);
        assert_eq!(decide_state("blocked", true, None), TaskState::Blocked);
        assert_eq!(decide_state("needs_user", true, None), TaskState::Failed);
        assert_eq!(decide_state("failed", true, None), TaskState::Failed);
    }

    #[test]
    fn unknown_status_depends_on_evidence() {
        assert_eq!(decide_state("weird", true, None), TaskState::Failed);
        let r = dummy_result();
        assert_eq!(decide_state("weird", true, Some(&r)), TaskState::Blocked);
    }

    #[test]
    fn forbidden_paths_flagged() {
        let c = Changes {
            files_modified: vec!["src/main.rs".into(), "../outside.txt".into()],
            files_created: vec![".env".into()],
            files_deleted: vec!["/etc/hosts".into()],
        };
        let all: Vec<String> = c
            .files_modified
            .iter()
            .chain(&c.files_created)
            .chain(&c.files_deleted)
            .cloned()
            .collect();
        let bad = forbidden_in(all.iter());
        assert!(bad.contains(&"../outside.txt".to_string()));
        assert!(bad.contains(&".env".to_string()));
        assert!(bad.contains(&"/etc/hosts".to_string()));
        assert!(!bad.contains(&"src/main.rs".to_string()));
    }

    #[test]
    fn canonical_state_paths_are_precisely_scoped() {
        // Forbidden: the top-level config files + the telemetry tree.
        for p in [
            ".agents/work-queue.yaml",
            ".agents/intent-contract.yaml",
            ".agents/workers.yaml",
            ".agents/billing-policy.yaml",
            ".agents/yardlet.yaml",
            ".agents/yard.yaml",         // legacy
            "./.agents/work-queue.yaml", // normalized leading ./
            ".agents/telemetry/runs.jsonl",
        ] {
            assert!(is_canonical_state_path(p), "{p} should be canonical");
        }
        // Allowed: harness assets, a run's own artifacts, and normal source.
        for p in [
            ".agents/runs/run-x/result.json",
            ".agents/skills/foo/SKILL.md",
            ".agents/rules/team.md",
            ".agents/agents/reviewer.md",
            "src/main.rs",
            ".github/workflows/ci.yml",
        ] {
            assert!(!is_canonical_state_path(p), "{p} should be allowed");
        }

        // The forbidden gate flags a worker write to the queue, and passes a
        // diff that only touched a run artifact / a skill / source.
        let bad = forbidden_in([".agents/work-queue.yaml".to_string()].iter());
        assert_eq!(bad, vec![".agents/work-queue.yaml".to_string()]);
        let clean = forbidden_in(
            [
                ".agents/runs/run-x/result.json".to_string(),
                ".agents/skills/foo/SKILL.md".to_string(),
                "src/main.rs".to_string(),
            ]
            .iter(),
        );
        assert!(clean.is_empty());
    }

    #[test]
    fn git_changed_paths_classifies_non_git_without_locale_stderr_matching() {
        let root = temp_path("non-git-notrepo");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("work.txt"), "content\n").unwrap();

        assert!(
            matches!(git_changed_paths(&root), Err(GitEvidenceError::NotRepo)),
            "non-git workspaces must be classified before parsing localized git stderr"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn git_evidence_forces_c_locale_for_rev_parse_and_status() {
        use std::os::unix::fs::PermissionsExt;

        let root = temp_path("forced-git-locale");
        std::fs::create_dir_all(&root).unwrap();
        let fake_git = root.join("git");
        std::fs::write(
            &fake_git,
            r#"#!/bin/sh
if [ "$LC_ALL" != "C" ] || [ "$LANG" != "C" ]; then
  echo "unexpected locale: LC_ALL=$LC_ALL LANG=$LANG" >&2
  exit 88
fi
if [ "$3" = "rev-parse" ]; then
  echo true
  exit 0
fi
if [ "$3" = "status" ]; then
  printf '?? src/lib.rs\0'
  exit 0
fi
echo "unexpected git invocation: $*" >&2
exit 89
"#,
        )
        .unwrap();
        let mut perms = std::fs::metadata(&fake_git).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&fake_git, perms).unwrap();

        let paths = git_changed_paths_with(&root, fake_git.as_os_str()).unwrap();
        assert_eq!(paths, vec!["src/lib.rs".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn missing_git_binary_falls_back_to_workspace_fingerprints() {
        let root = temp_path("missing-git");
        let run_dir = root.join(".agents/runs/run-x");
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(root.join("src/lib.rs"), "pub fn before() {}\n").unwrap();

        let baseline = run_fingerprints_with_git(
            &root,
            std::slice::from_ref(&run_dir),
            OsStr::new("/definitely/missing/yardlet-git"),
        )
        .unwrap();
        std::fs::write(root.join("src/lib.rs"), "pub fn after() {}\n").unwrap();
        let after = run_fingerprints_with_git(
            &root,
            std::slice::from_ref(&run_dir),
            OsStr::new("/definitely/missing/yardlet-git"),
        )
        .unwrap();

        let actual = worker_touched(&baseline, &after);
        assert_eq!(actual, vec!["src/lib.rs".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn workspace_scan_error_is_the_run_fingerprints_fail_closed_boundary() {
        let missing = temp_path("missing-workspace");
        let err =
            run_fingerprints_with_git(&missing, &[], OsStr::new("/definitely/missing/yardlet-git"))
                .unwrap_err();

        assert!(
            err.starts_with("workspace scan failed:"),
            "git evidence failure should fall back; only scan IO failure should return Err: {err}"
        );
    }

    #[test]
    fn non_git_clean_run_gets_folder_evidence_and_can_finish_done() {
        let root = temp_path("non-git-clean");
        let run_dir = root.join(".agents/runs/run-x");
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/lib.rs"), "pub fn ok() {}\n").unwrap();

        let baseline = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        write_done_result(&run_dir, "run-x", "YARD-9");
        let after = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        let actual = worker_touched(&baseline, &after);

        assert!(
            actual.is_empty(),
            "current run artifacts must not count as worker file changes: {actual:?}"
        );
        let e = evaluate(
            &run_dir,
            "run-x",
            &implementation_task("YARD-9"),
            Some(&actual),
        );
        assert_eq!(e.next_task_state, TaskState::Done);
        assert!(e
            .checks
            .iter()
            .any(|c| c.name == "forbidden_paths_untouched" && c.fatal && c.passed));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn non_git_forbidden_env_change_fails_on_actual_folder_evidence() {
        let root = temp_path("non-git-env");
        let run_dir = root.join(".agents/runs/run-x");
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(root.join("safe.txt"), "before\n").unwrap();

        let baseline = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        std::fs::write(root.join(".env"), "SECRET=value\n").unwrap();
        write_done_result(&run_dir, "run-x", "YARD-9");
        let after = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        let actual = worker_touched(&baseline, &after);

        assert!(actual.contains(&".env".to_string()), "{actual:?}");
        let e = evaluate(
            &run_dir,
            "run-x",
            &implementation_task("YARD-9"),
            Some(&actual),
        );
        let forbidden = e
            .checks
            .iter()
            .find(|c| c.name == "forbidden_paths_untouched")
            .unwrap();
        assert!(!forbidden.passed);
        assert_eq!(e.next_task_state, TaskState::Failed);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn non_git_canonical_agent_yaml_change_fails_on_actual_folder_evidence() {
        let root = temp_path("non-git-canonical-yaml");
        let run_dir = root.join(".agents/runs/run-x");
        std::fs::create_dir_all(&run_dir).unwrap();
        std::fs::write(root.join("safe.txt"), "before\n").unwrap();

        let baseline = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        std::fs::write(root.join(".agents/work-queue.yaml"), "schema_version: 1\n").unwrap();
        write_done_result(&run_dir, "run-x", "YARD-9");
        let after = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        let actual = worker_touched(&baseline, &after);

        assert!(
            actual.contains(&".agents/work-queue.yaml".to_string()),
            "folder scan must surface the canonical queue write: {actual:?}"
        );
        let e = evaluate(
            &run_dir,
            "run-x",
            &implementation_task("YARD-9"),
            Some(&actual),
        );
        let forbidden = e
            .checks
            .iter()
            .find(|c| c.name == "forbidden_paths_untouched")
            .unwrap();
        assert!(!forbidden.passed);
        assert!(forbidden.fatal);
        assert!(
            forbidden.note.contains(".agents/work-queue.yaml"),
            "{forbidden:?}"
        );
        assert_ne!(e.next_task_state, TaskState::Done);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn non_git_folder_scan_skips_heavy_and_runtime_paths() {
        let root = temp_path("non-git-skip");
        let run_dir = root.join(".agents/runs/run-x");
        for dir in [
            root.join(".git"),
            root.join("target"),
            root.join("node_modules"),
            run_dir.clone(),
            root.join("src"),
        ] {
            std::fs::create_dir_all(dir).unwrap();
        }
        std::fs::write(root.join(".git/config"), "git\n").unwrap();
        std::fs::write(root.join("target/cache"), "target\n").unwrap();
        std::fs::write(root.join("node_modules/pkg"), "node\n").unwrap();
        std::fs::write(run_dir.join("result.json"), "{}\n").unwrap();
        std::fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();

        let scan = run_fingerprints(&root, std::slice::from_ref(&run_dir)).unwrap();
        let paths: Vec<String> = scan.into_iter().map(|(p, _)| p).collect();
        assert_eq!(paths, vec!["src/main.rs".to_string()]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn writing_the_queue_blocks_done() {
        let dir = std::env::temp_dir().join(format!("yard-eval-canon-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = "run-x".into();
        r.task_id = "YARD-9".into();
        r.status = "done".into();
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();
        let t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };
        // The worker wrote the canonical queue directly: a fatal violation even
        // though it claimed done — propose -> ingest is the only allowed path.
        let actual = vec![
            "src/main.rs".to_string(),
            ".agents/work-queue.yaml".to_string(),
        ];
        let e = evaluate(&dir, "run-x", &t, Some(&actual));
        assert!(e
            .checks
            .iter()
            .any(|c| c.name == "forbidden_paths_untouched" && c.fatal && !c.passed));
        assert_eq!(e.next_task_state, TaskState::Failed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn eval_with(kind: &str, status: &str, verdict: Vec<crate::schemas::Verdict>) -> Evaluation {
        let dir = std::env::temp_dir().join(format!(
            "yard-eval-verdict-{}-{}",
            std::process::id(),
            kind.to_string() + status
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = "run-x".into();
        r.task_id = "YARD-9".into();
        r.status = status.into();
        r.verdict = verdict;
        if status == "needs_user" {
            r.question_for_user = Some("Which review decision should be made?".into());
        }
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();
        let mut t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: kind.into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };
        t.kind = kind.into();
        // Some(&[]) = git evidence available, nothing forbidden changed (these
        // tests exercise verdict/state logic, not the no-evidence fail-closed).
        let e = evaluate(&dir, "run-x", &t, Some(&[]));
        let _ = std::fs::remove_dir_all(&dir);
        e
    }

    #[test]
    fn forbidden_path_uses_actual_diff_over_worker_report() {
        let dir = std::env::temp_dir().join(format!("yard-eval-diff-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = "run-x".into();
        r.task_id = "YARD-9".into();
        r.status = "done".into();
        // Worker claims it only touched a safe file.
        r.changes.files_modified = vec!["src/main.rs".into()];
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();
        let t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };
        // The real on-disk diff shows it actually wrote .env.
        let actual = vec!["src/main.rs".to_string(), ".env".to_string()];
        let e = evaluate(&dir, "run-x", &t, Some(&actual));
        let fb = e
            .checks
            .iter()
            .find(|c| c.name == "forbidden_paths_untouched")
            .unwrap();
        assert!(
            !fb.passed,
            ".env in the actual diff must fail the forbidden check"
        );
        // Claimed done, but a fatal check failed on real evidence -> not trusted.
        assert_eq!(e.next_task_state, TaskState::Failed);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn review_task_needs_a_structured_verdict() {
        use crate::schemas::Verdict;
        let v = |id: &str, pass: bool| Verdict {
            criterion_id: id.into(),
            pass,
            evidence: "e".into(),
        };

        // review claims done with all criteria passing -> Done
        let e = eval_with("review", "done", vec![v("AC-001", true), v("AC-002", true)]);
        assert_eq!(e.next_task_state, TaskState::Done);

        // review claims done but a criterion failed -> contradiction -> Failed
        let e = eval_with("review", "done", vec![v("AC-001", false)]);
        assert_eq!(e.next_task_state, TaskState::Failed);
        assert!(e
            .checks
            .iter()
            .any(|c| c.name == "review_criteria_pass" && !c.passed));

        // review correctly reports needs_user with a failed criterion -> NeedsUser
        let e = eval_with("review", "needs_user", vec![v("AC-001", false)]);
        assert_eq!(e.next_task_state, TaskState::NeedsUser);
        // A review paused for the user has not finished judging: defer the gate
        // (no AC-fail wall) and record only an advisory that it is waiting.
        assert!(!e.checks.iter().any(|c| c.name == "review_criteria_pass"));
        assert!(e.checks.iter().any(|c| c.name == "review_paused_for_user"));

        // review wrote no verdict -> didn't do its job -> Failed
        let e = eval_with("review", "done", vec![]);
        assert_eq!(e.next_task_state, TaskState::Failed);
        assert!(e
            .checks
            .iter()
            .any(|c| c.name == "review_verdict_present" && !c.passed));

        // a build task needs no verdict
        let e = eval_with("implementation", "done", vec![]);
        assert_eq!(e.next_task_state, TaskState::Done);
    }

    #[test]
    fn review_ignores_unknown_nested_domain_statuses() {
        let dir = temp_path("nested-domain-status");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        std::fs::write(
            dir.join("result.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "schema_version": 1,
                "run_id": "run-nested-domain",
                "task_id": "YARD-REVIEW",
                "status": "done",
                "validation": {
                    "commands_run": ["cargo test"],
                    "passed": true,
                    "failures": []
                },
                "verdict": [{
                    "criterion_id": "AC-001",
                    "pass": true,
                    "evidence": "foundation passes while runtime conformity remains unresolved"
                }],
                "domain_artifact": {
                    "runtime_conformity": {"status": "not_pass"},
                    "free_text": "status fail blocked not_pass",
                    "nested": [{"status": "blocked", "fail": "not_pass"}]
                }
            }))
            .unwrap(),
        )
        .unwrap();
        let mut review = implementation_task("YARD-REVIEW");
        review.kind = "review".into();

        let evaluation = evaluate(&dir, "run-nested-domain", &review, Some(&[]));

        assert_eq!(evaluation.next_task_state, TaskState::Done);
        assert!(evaluation
            .checks
            .iter()
            .any(|check| check.name == "review_criteria_pass" && check.passed));
        assert!(!evaluation
            .checks
            .iter()
            .any(|check| check.fatal && !check.passed));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn issue_16_exact_user_accepted_deviation_is_not_fatal_on_retry() {
        let dir = temp_path("accepted-prior-deviation");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        std::fs::write(
            dir.join("result.json"),
            serde_json::to_vec_pretty(&serde_json::json!({
                "schema_version": 1,
                "run_id": "run-accepted-deviation",
                "task_id": "YARD-DEVIATION",
                "status": "done",
                "intent_adherence": {
                    "drift_detected": true,
                    "notes": "historical read-only engine version probe",
                    "deviations": [{
                        "id": "engine-version-probe",
                        "scope": ["godot --version"],
                        "description": "read-only engine version probe without temporary HOME"
                    }]
                },
                "validation": {
                    "commands_run": ["cargo test"],
                    "passed": true,
                    "failures": []
                },
                "compact_summary": "accepted historical deviation only"
            }))
            .unwrap(),
        )
        .unwrap();
        let task: Task = crate::yaml::from_str(
            r#"
id: YARD-DEVIATION
title: accepted deviation retry
state: running
kind: implementation
interaction:
  accepted_deviations:
    - id: engine-version-probe
      scope: [godot --version]
      accepted_by_answer_id: ans-explicit
"#,
        )
        .unwrap();

        let evaluation = evaluate(&dir, "run-accepted-deviation", &task, Some(&[]));

        assert_eq!(evaluation.next_task_state, TaskState::Done);
        assert!(evaluation.checks.iter().any(|check| {
            check.name == "no_uncontrolled_drift"
                && check.fatal
                && check.passed
                && check.note.contains("engine-version-probe")
        }));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn issue_16_new_unscoped_or_worker_claimed_acceptance_remains_fatal() {
        let cases = [
            (
                "different-scope",
                serde_json::json!({
                    "id": "engine-version-probe",
                    "scope": ["godot --version", "HOME=/real/user"],
                    "description": "same id but broader scope"
                }),
                true,
            ),
            (
                "new-id",
                serde_json::json!({
                    "id": "project-import",
                    "scope": ["godot --headless --editor"],
                    "description": "new operation"
                }),
                true,
            ),
            (
                "worker-claimed-acceptance",
                serde_json::json!({
                    "id": "project-import",
                    "scope": ["godot --headless --editor"],
                    "description": "worker cannot self-accept",
                    "accepted": true
                }),
                false,
            ),
        ];
        for (label, deviation, drift_detected) in cases {
            let dir = temp_path(label);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("handoff.md"), "h").unwrap();
            std::fs::write(
                dir.join("result.json"),
                serde_json::to_vec_pretty(&serde_json::json!({
                    "schema_version": 1,
                    "run_id": "run-new-deviation",
                    "task_id": "YARD-DEVIATION",
                    "status": "done",
                    "intent_adherence": {
                        "drift_detected": drift_detected,
                        "notes": label,
                        "deviations": [deviation]
                    },
                    "compact_summary": label
                }))
                .unwrap(),
            )
            .unwrap();
            let task: Task = crate::yaml::from_str(
                r#"
id: YARD-DEVIATION
title: accepted deviation retry
state: running
kind: implementation
interaction:
  accepted_deviations:
    - id: engine-version-probe
      scope: [godot --version]
      accepted_by_answer_id: ans-explicit
"#,
            )
            .unwrap();

            let evaluation = evaluate(&dir, "run-new-deviation", &task, Some(&[]));

            assert_eq!(
                evaluation.next_task_state,
                TaskState::Failed,
                "{label} must remain fatal"
            );
            assert!(evaluation
                .checks
                .iter()
                .any(|check| check.name == "no_uncontrolled_drift" && !check.passed));
            let _ = std::fs::remove_dir_all(&dir);
        }
    }

    // Regression: a done result with no validation commands must stay Done.
    // "did validation run" is advisory, not an integrity gate.
    #[test]
    fn worker_touched_catches_a_re_modified_already_dirty_path() {
        // A path dirty before the run (same content) is NOT attributed; a path
        // the worker re-modified (fingerprint changed) IS; a newly-dirtied path
        // IS; a path reverted out of the dirty set IS.
        let baseline = vec![
            ("untouched.txt".to_string(), "h1".to_string()),
            (".env".to_string(), "secret-v1".to_string()),
            ("reverted.txt".to_string(), "h9".to_string()),
        ];
        let after = vec![
            ("untouched.txt".to_string(), "h1".to_string()),
            (".env".to_string(), "secret-v2".to_string()), // re-modified while dirty
            ("new.txt".to_string(), "h2".to_string()),     // newly dirtied
        ];
        let touched = worker_touched(&baseline, &after);
        assert!(touched.contains(&".env".to_string()));
        assert!(touched.contains(&"new.txt".to_string()));
        assert!(touched.contains(&"reverted.txt".to_string()));
        assert!(!touched.contains(&"untouched.txt".to_string()));
    }

    #[test]
    fn no_diff_evidence_fails_the_forbidden_gate_closed() {
        let dir = std::env::temp_dir().join(format!("yard-eval-{}-noevidence", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let mut r = dummy_result();
        r.run_id = "run-x".into();
        r.task_id = "YARD-9".into();
        r.status = "done".into();
        std::fs::write(dir.join("result.json"), serde_json::to_string(&r).unwrap()).unwrap();
        let mut t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: "implementation".into(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };
        t.kind = "implementation".into();
        // None = no git evidence: the forbidden gate fails closed, so a worker's
        // "done" cannot become Done on its self-report alone.
        let e = evaluate(&dir, "run-x", &t, None);
        assert_ne!(e.next_task_state, TaskState::Done);
        assert!(e
            .checks
            .iter()
            .any(|c| c.name == "forbidden_paths_untouched" && c.fatal && !c.passed));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn done_with_no_validation_is_still_done() {
        let dir =
            std::env::temp_dir().join(format!("yard-eval-{}-{}", std::process::id(), "novalidate"));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("handoff.md"), "h").unwrap();
        let result = RunResult {
            schema_version: 1,
            run_id: "run-x".into(),
            task_id: "YARD-9".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(), // no commands run
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        std::fs::write(
            dir.join("result.json"),
            serde_json::to_string(&result).unwrap(),
        )
        .unwrap();

        let t = crate::schemas::Task {
            id: "YARD-9".into(),
            title: "t".into(),
            state: TaskState::Running,
            priority: 0,
            risk: String::new(),
            kind: String::new(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
        };

        let eval = evaluate(&dir, "run-x", &t, Some(&[]));
        assert_eq!(eval.next_task_state, TaskState::Done);
        let v = eval
            .checks
            .iter()
            .find(|c| c.name == "validation_ran")
            .unwrap();
        assert!(!v.fatal && !v.passed); // reported, advisory, did not gate Done
        let _ = std::fs::remove_dir_all(&dir);
    }
}
