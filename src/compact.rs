//! Compact checkpoint + handoff writers.
//!
//! Yardlet must not rely on chat history as memory. At task/cycle boundaries it
//! compacts into durable artifacts that the next run can start from.

use std::path::Path;

use anyhow::Result;

use crate::evaluator::Evaluation;
use crate::schemas::{RunResult, Task, TaskState};
use crate::state::write_str;

// Checkpoints and handoffs are durable worker-input artifacts, not localized UI
// chrome. Keep their state marker language-neutral plus the stable internal
// snake_case label used in run records, instead of leaking Rust Debug variants.
fn task_state_marker(state: TaskState) -> String {
    format!("{} {}", state.glyph(), task_state_internal_label(state))
}

fn task_state_internal_label(state: TaskState) -> &'static str {
    match state {
        TaskState::Queued => "queued",
        TaskState::Running => "running",
        TaskState::Done => "done",
        TaskState::Blocked => "blocked",
        TaskState::Failed => "failed",
        TaskState::NeedsUser => "needs_user",
        TaskState::Partial => "partial",
        TaskState::Deferred => "deferred",
    }
}

/// Write `checkpoint.md` for a run: short enough to feed into the next cycle.
pub fn write_checkpoint(
    run_dir: &Path,
    task: &Task,
    eval: &Evaluation,
    result: Option<&RunResult>,
    intent_summary: &str,
) -> Result<()> {
    let mut md = String::new();
    md.push_str("# Checkpoint\n\n");
    md.push_str(&format!(
        "- Intent: {}\n",
        non_empty(intent_summary, "(none yet)")
    ));
    md.push_str(&format!("- Task: {} {}\n", task.id, task.title));
    md.push_str(&format!("- Run: {}\n", eval.run_id));
    md.push_str(&format!("- Result status: {}\n", eval.status));
    md.push_str(&format!(
        "- Next task state: {}\n",
        task_state_marker(eval.next_task_state)
    ));

    if let Some(r) = result {
        let changed = r.changes.files_modified.len()
            + r.changes.files_created.len()
            + r.changes.files_deleted.len();
        md.push_str(&format!("- Changed files: {changed}\n"));
        md.push_str(&format!(
            "- Validation: {}\n",
            if r.validation.passed {
                "passed"
            } else {
                "not passed / not run"
            }
        ));
        md.push_str(&format!(
            "- Completed: {}\n",
            non_empty(&r.compact_summary, "(no summary)")
        ));
        if let Some(q) = &r.question_for_user {
            md.push_str(&format!("- Blockers / question: {q}\n"));
        }
    }

    md.push_str("- Must-read anchors:\n");
    md.push_str("  - .agents/intent-contract.yaml\n");
    md.push_str("  - .agents/work-queue.yaml\n");
    md.push_str(&format!("  - {}/result.json\n", run_dir.display()));

    write_str(&run_dir.join("checkpoint.md"), &md)?;
    Ok(())
}

/// Write the evaluator-owned summary without replacing a worker-authored handoff.
pub fn write_evaluator_summary(
    run_dir: &Path,
    task: &Task,
    eval: &Evaluation,
    result: Option<&RunResult>,
) -> Result<()> {
    let mut md = String::new();
    md.push_str(&format!("# Handoff: {} {}\n\n", task.id, task.title));
    md.push_str(&format!(
        "Run `{}` finished with status **{}**.\n\n",
        eval.run_id, eval.status
    ));

    md.push_str("## Evaluator checks\n\n");
    for c in &eval.checks {
        md.push_str(&format!(
            "- [{}] {} — {}\n",
            if c.passed { "x" } else { " " },
            c.name,
            c.note
        ));
    }
    md.push('\n');

    if let Some(r) = result {
        md.push_str("## What changed\n\n");
        for f in &r.changes.files_created {
            md.push_str(&format!("- created `{f}`\n"));
        }
        for f in &r.changes.files_modified {
            md.push_str(&format!("- modified `{f}`\n"));
        }
        for f in &r.changes.files_deleted {
            md.push_str(&format!("- deleted `{f}`\n"));
        }
        md.push('\n');
        if !r.compact_summary.is_empty() {
            md.push_str(&format!("## Summary\n\n{}\n\n", r.compact_summary));
        }
        if let Some(q) = &r.question_for_user {
            md.push_str(&format!("## Needs user input\n\n{q}\n\n"));
        }
    }

    md.push_str(&format!(
        "## Next task state\n\n{}\n",
        task_state_marker(eval.next_task_state)
    ));

    write_str(&run_dir.join("evaluator-summary.md"), &md)?;
    let handoff_path = run_dir.join("handoff.md");
    if !handoff_path.exists() {
        write_str(&handoff_path, &md)?;
    }
    Ok(())
}

fn non_empty<'a>(s: &'a str, fallback: &'a str) -> &'a str {
    if s.trim().is_empty() {
        fallback
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_state_marker_uses_glyph_and_internal_label_not_debug_variant() {
        let marker = task_state_marker(TaskState::NeedsUser);

        assert_eq!(marker, "? needs_user");
        assert!(!marker.contains("NeedsUser"));
    }
}
