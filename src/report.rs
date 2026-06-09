//! Intent-level final report.
//!
//! A deterministic, human-readable wrap-up of the current intent + queue,
//! synthesized from the intent contract, the task states, and each task's run
//! result. Zero-key: Yard assembles it from artifacts, never calls a worker.

use anyhow::Result;

use crate::run::latest_run_for;
use crate::schemas::{RunResult, TaskState};
use crate::state::Workspace;
use crate::yaml;

/// Yard's own run bookkeeping (under `.agents/`) — not a deliverable, so it is
/// excluded from the report's file list.
fn is_internal(path: &str) -> bool {
    path.starts_with(".agents/") || path.contains("/.agents/")
}

fn read_result(dir: &std::path::Path) -> Option<RunResult> {
    std::fs::read_to_string(dir.join("result.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
}

/// Build a markdown final report for the current intent and queue.
pub fn build_final_report(ws: &Workspace) -> Result<String> {
    let intent = ws.load_intent()?;
    let queue = ws.load_queue()?;
    let mut md = String::new();

    md.push_str("# Final report\n\n");
    if let Some(i) = &intent {
        if !i.summary.trim().is_empty() {
            md.push_str(&format!("## Goal\n\n{}\n\n", i.summary));
        }
    }

    let total = queue.tasks.len();
    let done = queue
        .tasks
        .iter()
        .filter(|t| t.state == TaskState::Done)
        .count();
    let pending: Vec<&str> = queue
        .tasks
        .iter()
        .filter(|t| t.state != TaskState::Done)
        .map(|t| t.id.as_str())
        .collect();
    md.push_str(&format!("**Progress:** {done}/{total} tasks done"));
    if pending.is_empty() {
        md.push_str(" \u{2014} complete \u{2713}\n\n");
    } else {
        md.push_str(&format!(" \u{2014} unfinished: {}\n\n", pending.join(", ")));
    }

    // Acceptance criteria, carried from the intent contract.
    if let Some(i) = &intent {
        let accept: Vec<String> = i
            .acceptance
            .iter()
            .filter_map(|v| match v {
                yaml::Value::String(s) => Some(s.clone()),
                _ => None,
            })
            .filter(|s| !s.trim().is_empty())
            .collect();
        if !accept.is_empty() {
            md.push_str("## Acceptance\n\n");
            for a in accept {
                md.push_str(&format!("- {a}\n"));
            }
            md.push('\n');
        }
    }

    // Per-task outcome, plus aggregated file changes and open questions.
    md.push_str("## Tasks\n\n");
    let mut all_changed: Vec<String> = Vec::new();
    let mut open_questions: Vec<String> = Vec::new();
    for t in &queue.tasks {
        md.push_str(&format!("### {} {} \u{2014} {:?}\n\n", t.id, t.title, t.state));
        if let Some((_, dir)) = latest_run_for(ws, &t.id) {
            if let Some(r) = read_result(&dir) {
                if !r.compact_summary.trim().is_empty() {
                    md.push_str(&format!("{}\n\n", r.compact_summary.trim()));
                }
                for f in &r.changes.files_created {
                    if !is_internal(f) {
                        all_changed.push(format!("+ {f}"));
                    }
                }
                for f in &r.changes.files_modified {
                    if !is_internal(f) {
                        all_changed.push(format!("~ {f}"));
                    }
                }
                for f in &r.changes.files_deleted {
                    if !is_internal(f) {
                        all_changed.push(format!("- {f}"));
                    }
                }
                if let Some(q) = &r.question_for_user {
                    if !q.trim().is_empty() {
                        open_questions.push(format!("{}: {}", t.id, q.trim()));
                    }
                }
            }
        }
    }

    if !all_changed.is_empty() {
        all_changed.sort();
        all_changed.dedup();
        md.push_str("## Files changed\n\n");
        for f in &all_changed {
            md.push_str(&format!("- `{f}`\n"));
        }
        md.push('\n');
    }

    if !open_questions.is_empty() {
        md.push_str("## Open questions\n\n");
        for q in &open_questions {
            md.push_str(&format!("- {q}\n"));
        }
        md.push('\n');
    }

    Ok(md)
}
