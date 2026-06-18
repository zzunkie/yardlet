//! Deterministic evaluator.
//!
//! Yardlet does not trust a worker's claims blindly. After a run it checks the
//! evidence on disk and decides the next task state. The first evaluator is
//! intentionally shallow but honest: every check is mechanical.

use std::path::Path;

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
        checks.push(check(
            "no_uncontrolled_drift",
            !r.intent_adherence.drift_detected,
            if r.intent_adherence.drift_detected {
                format!("worker reported drift: {}", r.intent_adherence.notes)
            } else {
                "worker reported no scope drift".to_string()
            },
        ));
        // Forbidden-path runs on the ACTUAL on-disk diff when Yardlet could
        // collect it (the worker's self-reported file list is not trusted); it
        // falls back to the reported changes only when git evidence is absent.
        let reported: Vec<String> = r
            .changes
            .files_modified
            .iter()
            .chain(&r.changes.files_created)
            .chain(&r.changes.files_deleted)
            .cloned()
            .collect();
        let basis: &[String] = actual_changes.unwrap_or(&reported);
        let forbidden = forbidden_in(basis.iter());
        checks.push(check(
            "forbidden_paths_untouched",
            forbidden.is_empty(),
            if forbidden.is_empty() {
                "no sensitive or out-of-workspace paths changed".to_string()
            } else {
                format!("changed forbidden path(s): {}", forbidden.join(", "))
            },
        ));
        // With the real diff in hand, flag files the worker changed but did not
        // disclose (advisory: surfaces incomplete/dishonest self-reports without
        // blocking an otherwise-clean run).
        if let Some(actual) = actual_changes {
            let norm = |p: &str| p.trim_start_matches("./").to_string();
            let reported_norm: std::collections::HashSet<String> =
                reported.iter().map(|p| norm(p)).collect();
            let undisclosed: Vec<String> = actual
                .iter()
                .map(|p| norm(p))
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
        // Structured review verdict: the quality signal Yardlet records instead
        // of trusting prose. For a review/safety task it is the contract —
        // an empty verdict or any failed criterion blocks Done.
        let is_review = matches!(crate::packet::role_for(&task.kind), "reviewer" | "security");
        if is_review {
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

/// Paths that are sensitive (secrets/keys) or escape the workspace. A worker
/// touching these fails the run regardless of its self-report.
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
        if escapes || sensitive {
            bad.push(f.clone());
        }
    }
    bad
}

/// Paths git reports as changed or untracked in `cwd`: the actual on-disk
/// evidence of what a run touched, independent of what the worker claims. Empty
/// when git is unavailable or `cwd` is not a repository (the evaluator then
/// falls back to the worker's self-report).
pub fn changed_paths(cwd: &Path) -> Vec<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(["status", "--porcelain=v1", "--untracked-files=all"])
        .output();
    let Ok(out) = out else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    let mut paths = Vec::new();
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        if line.len() < 4 {
            continue;
        }
        // "XY <path>", or a rename "XY old -> new"; the new path is on disk.
        let rest = line[3..].trim();
        let path = rest.rsplit(" -> ").next().unwrap_or(rest).trim_matches('"');
        if !path.is_empty() {
            paths.push(path.to_string());
        }
    }
    paths
}

fn decide_state(reported: &str, all_passed: bool, result: Option<&RunResult>) -> TaskState {
    // A worker can only earn `done` if it claims done *and* the mechanical
    // checks pass. Anything else falls back to a safe, resumable state.
    match reported {
        "done" if all_passed => TaskState::Done,
        "done" => TaskState::Failed, // claimed done but evidence is incomplete
        "partial" => TaskState::Partial,
        "blocked" => TaskState::Blocked,
        "needs_user" => TaskState::NeedsUser,
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
    use crate::schemas::Changes;

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
        }
    }

    #[test]
    fn done_requires_all_checks_passing() {
        assert_eq!(decide_state("done", true, None), TaskState::Done);
        // claimed done but evidence incomplete -> not trusted
        assert_eq!(decide_state("done", false, None), TaskState::Failed);
    }

    #[test]
    fn non_done_states_map_safely() {
        assert_eq!(decide_state("partial", true, None), TaskState::Partial);
        assert_eq!(decide_state("blocked", true, None), TaskState::Blocked);
        assert_eq!(decide_state("needs_user", true, None), TaskState::NeedsUser);
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
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
        };
        t.kind = kind.into();
        let e = evaluate(&dir, "run-x", &t, None);
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
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
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

    // Regression: a done result with no validation commands must stay Done.
    // "did validation run" is advisory, not an integrity gate.
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
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
        };

        let eval = evaluate(&dir, "run-x", &t, None);
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
