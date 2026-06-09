//! Deterministic evaluator.
//!
//! Yard does not trust a worker's claims blindly. After a run it checks the
//! evidence on disk and decides the next task state. The first evaluator is
//! intentionally shallow but honest: every check is mechanical.

use std::path::Path;

use serde::Serialize;

use crate::schemas::{Changes, RunResult, Task, TaskState};

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

pub fn evaluate(run_dir: &Path, run_id: &str, task: &Task) -> Evaluation {
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
        let forbidden = forbidden_paths_in(&r.changes);
        checks.push(check(
            "forbidden_paths_untouched",
            forbidden.is_empty(),
            if forbidden.is_empty() {
                "no sensitive or out-of-workspace paths changed".to_string()
            } else {
                format!("changed forbidden path(s): {}", forbidden.join(", "))
            },
        ));
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

/// Changed paths that are sensitive (secrets/keys) or escape the workspace.
/// A worker touching these fails the run regardless of its self-report.
fn forbidden_paths_in(changes: &Changes) -> Vec<String> {
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
    let all = changes
        .files_modified
        .iter()
        .chain(&changes.files_created)
        .chain(&changes.files_deleted);
    for f in all {
        let lower = f.to_lowercase();
        let escapes = f.starts_with('/') || f.contains("..");
        let sensitive = SENSITIVE.iter().any(|p| lower.contains(p));
        if escapes || sensitive {
            bad.push(f.clone());
        }
    }
    bad
}

fn decide_state(reported: &str, all_passed: bool, result: Option<&RunResult>) -> TaskState {
    // A worker can only earn `done` if it claims done *and* the mechanical
    // checks pass. Anything else falls back to a safe, resumable state.
    match reported {
        "done" if all_passed => TaskState::Done,
        "done" => TaskState::Failed, // claimed done but evidence is incomplete
        "partial" => TaskState::Queued,
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
        assert_eq!(decide_state("partial", true, None), TaskState::Queued);
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
        let bad = forbidden_paths_in(&c);
        assert!(bad.contains(&"../outside.txt".to_string()));
        assert!(bad.contains(&".env".to_string()));
        assert!(bad.contains(&"/etc/hosts".to_string()));
        assert!(!bad.contains(&"src/main.rs".to_string()));
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
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
        };

        let eval = evaluate(&dir, "run-x", &t);
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
