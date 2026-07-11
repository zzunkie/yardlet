//! Intent-level final report.
//!
//! A deterministic, human-readable wrap-up of the current intent + queue,
//! synthesized from the intent contract, the task states, and each task's run
//! result. Zero-key: Yardlet assembles it from artifacts, never calls a worker.

use anyhow::Result;

use crate::run::latest_run_for;
use crate::schemas::{
    FollowUpTask, PreservedFollowUps, RunResult, RunnableClass, TaskState, WorkQueue,
};
use crate::state::{self, Workspace};
use crate::yaml;

/// Archive the current intent + queue + final report under
/// `.agents/intents/<intent_id>/` so starting fresh work doesn't lose the
/// record. Also preserves the proposed-but-unrun follow-ups the intent's runs
/// left behind (`follow-up-tasks.yaml`), so "what to do next" survives a reset
/// and can be promoted into a fresh intent later. Returns the archived intent
/// id, or None if there is no intent.
pub fn archive_intent(ws: &Workspace) -> Result<Option<String>> {
    let Some(intent) = ws.load_intent()? else {
        return Ok(None);
    };
    let queue = ws.load_queue()?;
    let dir = ws.agents_dir().join("intents").join(&intent.id);
    std::fs::create_dir_all(&dir)?;
    state::save_yaml(&dir.join("intent-contract.yaml"), &intent)?;
    state::save_yaml(&dir.join("work-queue.yaml"), &queue)?;
    let report = build_final_report(ws).unwrap_or_default();
    state::write_str(&dir.join("final-report.md"), &report)?;

    // Preserve the proposed follow-ups this intent's runs surfaced. Only write
    // the file when there is something to keep, so an empty archive stays clean.
    let follow_ups = collect_proposed_follow_ups(ws, &queue);
    if !follow_ups.is_empty() {
        let preserved = PreservedFollowUps {
            schema_version: 1,
            intent_id: intent.id.clone(),
            tasks: follow_ups,
        };
        state::save_yaml(&dir.join("follow-up-tasks.yaml"), &preserved)?;
    }
    Ok(Some(intent.id))
}

/// Gather every follow-up PROPOSED by this intent's runs (each task's latest
/// `result.json::follow_up_tasks`), de-duplicated by title so the same idea
/// surfaced across re-runs is kept once. Titleless entries are dropped.
pub fn collect_proposed_follow_ups(ws: &Workspace, queue: &WorkQueue) -> Vec<FollowUpTask> {
    let mut out: Vec<FollowUpTask> = Vec::new();
    for t in &queue.tasks {
        let Some((_, dir)) = latest_run_for(ws, &t.id) else {
            continue;
        };
        let Some(r) = read_result(&dir) else { continue };
        for fu in r.follow_up_tasks {
            let title = fu.title.trim();
            if title.is_empty() {
                continue;
            }
            if out
                .iter()
                .any(|e| e.title.trim().eq_ignore_ascii_case(title))
            {
                continue;
            }
            out.push(fu);
        }
    }
    out
}

/// Promote a preserved (or freshly proposed) follow-up into a new live intent +
/// queue seed. The engine path behind AC-007: it mints a fresh intent id, writes
/// the derived `intent-contract.yaml`, and seeds a one-task queue by handing the
/// follow-up to the planner's own ingest logic — so the seed task's id, approval
/// gating, and decision handling match a normally-ingested follow-up. Returns
/// the new intent id. Archive + clear the current intent first if one is live.
pub fn promote_follow_up(ws: &Workspace, fu: &FollowUpTask) -> Result<String> {
    let intent_id = format!("intent-{}", chrono::Local::now().format("%Y%m%d-%H%M%S"));
    ws.seed_intent_from_follow_up(fu, &intent_id, |queue| {
        crate::planner::ingest_follow_ups(
            queue,
            &fu.allowed_scope,
            std::slice::from_ref(fu),
            Some(ws),
        );
    })
}

/// Yardlet's own run bookkeeping (under `.agents/`) — not a deliverable, so it is
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
    let workers = ws.load_workers().ok();
    let vocab = workers
        .as_ref()
        .map(crate::routing::declared_capabilities)
        .unwrap_or_default();
    let classified = queue
        .tasks
        .iter()
        .map(|t| {
            let approved = t.approval_required() && crate::approvals::is_granted(ws, &t.id);
            (t, queue.runnable_class(t, approved, &vocab))
        })
        .collect::<Vec<_>>();
    let live: Vec<String> = classified
        .iter()
        .filter(|(_, class)| {
            matches!(
                class,
                RunnableClass::Runnable
                    | RunnableClass::Running
                    | RunnableClass::WaitingDecision
                    | RunnableClass::WaitingApproval
                    | RunnableClass::WaitingDependency
                    | RunnableClass::WaitingCapability
            )
        })
        .map(|(t, class)| format!("{} ({})", t.id, class.label()))
        .collect();
    let held: Vec<String> = classified
        .iter()
        .filter(|(_, class)| matches!(class, RunnableClass::Held | RunnableClass::SetAside))
        .map(|(t, class)| format!("{} ({})", t.id, class.label()))
        .collect();
    md.push_str(&format!("**Progress:** {done}/{total} tasks done"));
    if !live.is_empty() {
        md.push_str(&format!(" \u{2014} unfinished: {}\n\n", live.join(", ")));
    } else if queue.drained() && !held.is_empty() {
        md.push_str(&format!(
            " \u{2014} complete (held: {}) \u{2713}\n\n",
            held.join(", ")
        ));
    } else {
        md.push_str(" \u{2014} complete \u{2713}\n\n");
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
        md.push_str(&format!(
            "### {} {} \u{2014} {:?}\n\n",
            t.id, t.title, t.state
        ));
        if let Some(rec) = ws.latest_transition(&t.id) {
            md.push_str(&format!("Last transition: {}\n\n", rec.detail.trim()));
        }
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
            // Non-code tasks deliver a written report.md — surface it in full.
            if let Ok(rep) = std::fs::read_to_string(dir.join("report.md")) {
                if !rep.trim().is_empty() {
                    md.push_str(&format!("{}\n\n", rep.trim()));
                }
            }
            if let Ok(raw) = std::fs::read_to_string(dir.join("git-finish.json")) {
                if let Ok(finish) = serde_json::from_str::<crate::git_finish::GitFinishRecord>(&raw)
                {
                    md.push_str(&format!("{}\n\n", finish.user_line()));
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{IntentContract, Task, TaskState};

    fn temp_ws(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("yard-report-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Workspace::at(&dir)
    }

    fn seed_task(id: &str, title: &str, state: TaskState) -> Task {
        let mut t: Task = crate::yaml::from_str(&format!("id: {id}\ntitle: \"{title}\"")).unwrap();
        t.state = state;
        t
    }

    fn write_run(ws: &Workspace, run: &str, task_id: &str, result_json: &str) {
        let dir = ws.runs_dir().join(run);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("run.yaml"), format!("task_id: {task_id}\n")).unwrap();
        std::fs::write(dir.join("result.json"), result_json).unwrap();
    }

    fn intent(id: &str) -> IntentContract {
        IntentContract {
            schema_version: 1,
            id: id.to_string(),
            source: String::new(),
            raw_request: String::new(),
            summary: "do the thing".to_string(),
            allowed_scope: vec!["src".to_string()],
            out_of_scope: vec![],
            acceptance: vec![],
            images: vec![],
            ambiguity: String::new(),
            open_questions: vec![],
            clarifications: vec![],
            interview_turns: 0,
            status: String::new(),
        }
    }

    #[test]
    fn archive_preserves_proposed_follow_ups_and_clear_empties_live_state() {
        // AC-006/AC-007: archived intents keep their runs' proposed follow-ups,
        // and the state.rs clear path empties the live intent + queue.
        let ws = temp_ws("archive");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-arch")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue
            .tasks
            .push(seed_task("YARD-001", "existing", TaskState::Done));
        ws.save_queue(&queue).unwrap();
        write_run(
            &ws,
            "run-1",
            "YARD-001",
            r#"{"schema_version":1,"run_id":"run-1","task_id":"YARD-001","status":"done",
               "follow_up_tasks":[{"title":"write the migration guide","reason":"docs gap","risk":"low"}]}"#,
        );

        let archived = archive_intent(&ws).unwrap();
        assert_eq!(archived.as_deref(), Some("intent-arch"));
        let preserved = ws
            .load_preserved_follow_ups("intent-arch")
            .expect("preserved follow-ups file");
        assert_eq!(preserved.tasks.len(), 1);
        assert_eq!(preserved.tasks[0].title, "write the migration guide");

        ws.clear_intent_and_queue().unwrap();
        assert!(ws.load_intent().unwrap().is_none());
        assert!(ws.load_queue().unwrap().tasks.is_empty());
    }

    #[test]
    fn promote_follow_up_seeds_a_fresh_intent_and_queue() {
        // AC-007: a preserved follow-up promotes into a new live intent + queue
        // seed; a destructive follow-up seed stays approval-gated (AC-002).
        let ws = temp_ws("promote");
        let fu = FollowUpTask {
            title: "delete the legacy queue file".into(),
            reason: "remove stale runtime state".into(),
            risk: "low".into(),
            allowed_scope: vec!["src/state.rs".into()],
            acceptance: vec!["the file is gone".into()],
            ..Default::default()
        };
        let new_id = promote_follow_up(&ws, &fu).unwrap();

        let live = ws.load_intent().unwrap().expect("a live intent");
        assert_eq!(live.id, new_id);
        assert_eq!(live.source, "promoted-follow-up");
        assert!(live.summary.contains("delete the legacy queue file"));
        assert_eq!(live.allowed_scope, vec!["src/state.rs".to_string()]);

        let queue = ws.load_queue().unwrap();
        assert_eq!(queue.tasks.len(), 1);
        assert_eq!(queue.tasks[0].id, "YARD-001");
        assert_eq!(queue.tasks[0].provenance, "worker-proposed");
        assert!(
            queue.tasks[0].approval_required(),
            "a destructive seed follow-up must stay approval-gated"
        );
    }
}
