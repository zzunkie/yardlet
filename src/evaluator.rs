//! Deterministic evaluator.
//!
//! Yard does not trust a worker's claims blindly. After a run it checks the
//! evidence on disk and decides the next task state. The first evaluator is
//! intentionally shallow but honest: every check is mechanical.

use std::path::Path;

use serde::Serialize;

use crate::schemas::{RunResult, Task, TaskState};

#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: String,
    pub passed: bool,
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
        checks.push(check(
            "validation_ran_or_noted",
            !r.validation.commands_run.is_empty()
                || r.status == "blocked"
                || r.status == "needs_user",
            "validation commands were run or a non-running status was recorded",
        ));
        reported_status = r.status.clone();
    }

    let all_passed = checks.iter().all(|c| c.passed);
    let next_task_state = decide_state(&reported_status, all_passed, result.as_ref());

    Evaluation {
        run_id: run_id.to_string(),
        task_id: task.id.clone(),
        status: reported_status,
        checks,
        next_task_state,
    }
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
}
