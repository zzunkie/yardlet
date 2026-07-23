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
/// and can be promoted into a fresh intent later. A same-intent replan reuses
/// the intent id, so the canonical archive would be overwritten by the next
/// drain: when the live queue carries a confirmation id, the same snapshot is
/// additionally kept under `drains/<confirmation_id>/` so every confirmed
/// drain stays recoverable. Returns the archived intent id, or None if there
/// is no intent.
pub fn archive_intent(ws: &Workspace) -> Result<Option<String>> {
    let Some(intent) = ws.load_intent()? else {
        return Ok(None);
    };
    let queue = ws.load_queue()?;
    let report = build_final_report(ws).unwrap_or_default();
    // Preserve the proposed follow-ups this intent's runs surfaced. Only write
    // the file when there is something to keep, so an empty archive stays clean.
    // Reused canonical archive directories must also drop an older file when
    // the latest drain has no follow-ups.
    let follow_ups = collect_proposed_follow_ups(ws, &queue);
    let write_snapshot = |dir: &std::path::Path| -> Result<()> {
        std::fs::create_dir_all(dir)?;
        state::save_yaml(&dir.join("intent-contract.yaml"), &intent)?;
        state::save_yaml(&dir.join("work-queue.yaml"), &queue)?;
        state::write_str(&dir.join("final-report.md"), &report)?;
        let follow_up_path = dir.join("follow-up-tasks.yaml");
        if follow_ups.is_empty() {
            state::remove_file_if_exists(&follow_up_path)?;
        } else {
            let preserved = PreservedFollowUps {
                schema_version: 1,
                intent_id: intent.id.clone(),
                tasks: follow_ups.clone(),
            };
            state::save_yaml(&follow_up_path, &preserved)?;
        }
        Ok(())
    };

    let dir = ws.agents_dir().join("intents").join(&intent.id);
    write_snapshot(&dir)?;
    // Best-effort drain preservation: a queue that doesn't parse as an
    // activated snapshot (legacy layout) archives exactly as before.
    if let Some(confirmation_id) = ws
        .load_activated_queue()
        .ok()
        .flatten()
        .map(|q| q.confirmation_id)
        .filter(|id| !id.trim().is_empty())
    {
        write_snapshot(&dir.join("drains").join(drain_dir_name(&confirmation_id)))?;
    }
    Ok(Some(intent.id))
}

/// Per-drain snapshots preserved under an archived intent's `drains/`
/// directory, newest first. A replanned intent archives one snapshot per
/// confirmed drain; browsing lists each so earlier drains stay reachable.
/// An archive with at most one drain returns nothing — its canonical layout
/// already serves that drain, and single-drain intents must list unchanged.
pub fn archived_drain_snapshots(intent_dir: &std::path::Path) -> Vec<(String, std::path::PathBuf)> {
    let Ok(entries) = std::fs::read_dir(intent_dir.join("drains")) else {
        return Vec::new();
    };
    let mut drains: Vec<(String, std::path::PathBuf)> = entries
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .filter_map(|p| {
            let id = p.file_name()?.to_str()?.to_string();
            Some((id, p))
        })
        .collect();
    if drains.len() < 2 {
        return Vec::new();
    }
    // Confirmation ids are timestamped → newest first, like the intent list.
    drains.sort_by(|a, b| b.0.cmp(&a.0));
    drains
}

/// Confirmation ids are minted path-safe by Yardlet, but they round-trip
/// through user-editable YAML — keep the derived directory name inside the
/// intent's archive dir no matter what the file says.
fn drain_dir_name(confirmation_id: &str) -> String {
    let name: String = confirmation_id
        .trim()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') {
                c
            } else {
                '-'
            }
        })
        .collect();
    if name.chars().all(|c| c == '.') {
        "drain".to_string()
    } else {
        name
    }
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

/// Return proposals that remain visible in run results but are intentionally
/// not ingested because their declared scope leaves this workspace.
fn collect_withheld_follow_ups(ws: &Workspace, queue: &WorkQueue) -> Vec<FollowUpTask> {
    collect_proposed_follow_ups(ws, queue)
        .into_iter()
        .filter(|follow_up| !crate::planner::follow_up_scope_is_workspace_local(follow_up))
        .collect()
}

/// Promote a preserved (or freshly proposed) follow-up into a new live intent +
/// queue seed. The engine path behind AC-007: it mints a fresh intent id, writes
/// the derived `intent-contract.yaml`, and seeds a one-task queue by handing the
/// follow-up to the planner's own ingest logic — so the seed task's id, approval
/// gating, and decision handling match a normally-ingested follow-up. Returns
/// the new intent id. Archive + clear the current intent first if one is live.
pub fn promote_follow_up(ws: &Workspace, fu: &FollowUpTask) -> Result<String> {
    let intent_id = format!("intent-{}", chrono::Local::now().format("%Y%m%d-%H%M%S"));
    let mut ingested = Vec::new();
    let intent_id = ws.seed_intent_from_follow_up(fu, &intent_id, |queue| {
        ingested = crate::planner::ingest_follow_ups(
            queue,
            &fu.allowed_scope,
            std::slice::from_ref(fu),
            Some(ws),
        );
    })?;
    let queue = ws.load_queue()?;
    crate::planner::persist_ingested_decision_questions(ws, &queue, &ingested)?;
    Ok(intent_id)
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
    } else if queue
        .tasks
        .iter()
        .any(|task| task.state == TaskState::Partial)
    {
        md.push_str(&format!(
            " \u{2014} unfinished (held: {})\n\n",
            held.join(", ")
        ));
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
        if let Some(rec) = ws.latest_transition_for_intent(&t.id, &queue.intent_id) {
            md.push_str(&format!("Last transition: {}\n\n", rec.detail.trim()));
        }
        if let Some((run_id, dir)) = latest_run_for(ws, &t.id) {
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
            // Worktree preparation left copy warnings behind: keep them visible
            // in the wrap-up. Clean runs write no evidence file and add nothing.
            if let Some(count) = crate::snapshot::harness_copy_warning_count(&dir) {
                md.push_str(&format!(
                    "Harness copy warnings: {count} warning(s) during worktree preparation \
                     (run {run_id}, {})\n\n",
                    crate::state::HARNESS_COPY_WARNINGS_FILE
                ));
            }
        }
    }

    let withheld = collect_withheld_follow_ups(ws, &queue);
    if !withheld.is_empty() {
        md.push_str("## Withheld suggestions\n\n");
        md.push_str(&format!(
            "{} cross-workspace follow-up suggestion(s) were not ingested into this workspace:\n\n",
            withheld.len()
        ));
        for follow_up in withheld {
            md.push_str(&format!("- {}\n", follow_up.title.trim()));
        }
        md.push('\n');
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

    fn save_activated_queue(ws: &Workspace, intent_id: &str, confirmation_id: &str, task: Task) {
        let queue = crate::schemas::ActivatedQueue {
            schema_version: 1,
            queue_id: format!("queue-{intent_id}"),
            intent_id: intent_id.to_string(),
            activation_required: false,
            selection_policy: Default::default(),
            tasks: vec![crate::schemas::ActivatedTask {
                task,
                materialized_by_confirmation_id: confirmation_id.to_string(),
            }],
            planning_session_id: "ps_fixture".to_string(),
            confirmation_id: confirmation_id.to_string(),
            draft_revision_id: String::new(),
            draft_content_digest: String::new(),
            materialized_queue_digest: String::new(),
            materialized_queue: None,
        };
        crate::state::save_yaml(&ws.queue_path(), &queue).unwrap();
    }

    #[test]
    fn replan_archive_preserves_each_confirmations_drain() {
        // A same-intent replan drains the same intent id twice. The second
        // archive must not erase the first drain's record: each confirmed
        // drain also lands at a confirmation-scoped path under the intent's
        // archive directory.
        let ws = temp_ws("replan-drains");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-replan")).unwrap();
        save_activated_queue(
            &ws,
            "intent-replan",
            "cnf_first",
            seed_task("YARD-001", "first drain task", TaskState::Done),
        );
        write_run(
            &ws,
            "run-1",
            "YARD-001",
            r#"{"schema_version":1,"run_id":"run-1","task_id":"YARD-001","status":"done",
               "follow_up_tasks":[{"title":"first-drain-follow-up","reason":"from drain one","risk":"low"}]}"#,
        );
        assert_eq!(
            archive_intent(&ws).unwrap().as_deref(),
            Some("intent-replan")
        );

        // Replan: a new confirmation re-materializes the queue, runs, drains.
        save_activated_queue(
            &ws,
            "intent-replan",
            "cnf_second",
            seed_task("YARD-002", "second drain task", TaskState::Done),
        );
        write_run(
            &ws,
            "run-2",
            "YARD-002",
            r#"{"schema_version":1,"run_id":"run-2","task_id":"YARD-002","status":"done",
               "follow_up_tasks":[{"title":"second-drain-follow-up","reason":"from drain two","risk":"low"}]}"#,
        );
        assert_eq!(
            archive_intent(&ws).unwrap().as_deref(),
            Some("intent-replan")
        );

        let dir = ws.agents_dir().join("intents").join("intent-replan");
        let first = std::fs::read_to_string(dir.join("drains/cnf_first/work-queue.yaml")).unwrap();
        assert!(first.contains("first drain task"), "{first}");
        let first_fu =
            std::fs::read_to_string(dir.join("drains/cnf_first/follow-up-tasks.yaml")).unwrap();
        assert!(first_fu.contains("first-drain-follow-up"), "{first_fu}");
        assert!(dir.join("drains/cnf_first/final-report.md").is_file());
        let second =
            std::fs::read_to_string(dir.join("drains/cnf_second/work-queue.yaml")).unwrap();
        assert!(second.contains("second drain task"), "{second}");

        // The canonical single-archive layout keeps serving existing
        // consumers (final report browsing, follow-up promotion) with the
        // latest drain.
        let canonical = std::fs::read_to_string(dir.join("work-queue.yaml")).unwrap();
        assert!(canonical.contains("second drain task"), "{canonical}");
        let preserved = ws
            .load_preserved_follow_ups("intent-replan")
            .expect("canonical follow-ups keep resolving by intent id");
        assert_eq!(preserved.tasks.len(), 1);
        assert_eq!(preserved.tasks[0].title, "second-drain-follow-up");
    }

    #[test]
    fn replan_archive_clears_stale_canonical_follow_ups_when_latest_drain_has_none() {
        let ws = temp_ws("replan-empty-latest-follow-ups");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-replan-empty")).unwrap();
        save_activated_queue(
            &ws,
            "intent-replan-empty",
            "cnf_first",
            seed_task("YARD-001", "first drain task", TaskState::Done),
        );
        write_run(
            &ws,
            "run-first",
            "YARD-001",
            r#"{"schema_version":1,"run_id":"run-first","task_id":"YARD-001","status":"done",
               "follow_up_tasks":[{"title":"first-drain-follow-up","reason":"from drain one","risk":"low"}]}"#,
        );
        archive_intent(&ws).unwrap();

        save_activated_queue(
            &ws,
            "intent-replan-empty",
            "cnf_second",
            seed_task("YARD-002", "second drain task", TaskState::Done),
        );
        write_run(
            &ws,
            "run-second",
            "YARD-002",
            r#"{"schema_version":1,"run_id":"run-second","task_id":"YARD-002","status":"done",
               "follow_up_tasks":[]}"#,
        );
        archive_intent(&ws).unwrap();

        assert!(
            ws.load_preserved_follow_ups("intent-replan-empty")
                .is_none(),
            "the canonical archive must represent the latest drain's empty follow-up set"
        );
        let first_snapshot = std::fs::read_to_string(
            ws.agents_dir()
                .join("intents/intent-replan-empty/drains/cnf_first/follow-up-tasks.yaml"),
        )
        .unwrap();
        assert!(
            first_snapshot.contains("first-drain-follow-up"),
            "the prior drain snapshot must remain recoverable: {first_snapshot}"
        );
        assert!(
            !ws.agents_dir()
                .join("intents/intent-replan-empty/drains/cnf_second/follow-up-tasks.yaml")
                .exists(),
            "an empty latest drain must stay free of a follow-up snapshot"
        );
    }

    #[test]
    fn archive_without_confirmation_keeps_single_canonical_layout() {
        // Legacy / unconfirmed queues carry no confirmation id; their archive
        // layout stays exactly as before.
        let ws = temp_ws("no-confirmation");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-plain")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue
            .tasks
            .push(seed_task("YARD-001", "plain", TaskState::Done));
        ws.save_queue(&queue).unwrap();

        assert_eq!(
            archive_intent(&ws).unwrap().as_deref(),
            Some("intent-plain")
        );

        let dir = ws.agents_dir().join("intents").join("intent-plain");
        assert!(dir.join("work-queue.yaml").is_file());
        assert!(
            !dir.join("drains").exists(),
            "unconfirmed queues must not grow a drains directory"
        );
    }

    #[test]
    fn rearchiving_the_same_confirmation_reuses_its_drain_snapshot() {
        // Archiving the same live confirmation twice (e.g. a re-generated
        // report) refreshes the one drain snapshot instead of piling up dirs.
        let ws = temp_ws("same-confirmation");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-same")).unwrap();
        save_activated_queue(
            &ws,
            "intent-same",
            "cnf_only",
            seed_task("YARD-001", "only drain", TaskState::Done),
        );
        archive_intent(&ws).unwrap();
        archive_intent(&ws).unwrap();

        let drains = ws
            .agents_dir()
            .join("intents")
            .join("intent-same")
            .join("drains");
        let entries: Vec<String> = std::fs::read_dir(&drains)
            .unwrap()
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .collect();
        assert_eq!(entries, vec!["cnf_only".to_string()]);
    }

    #[test]
    fn archived_drain_snapshots_lists_replan_drains_newest_first() {
        // A replanned intent's archive holds one snapshot per confirmed drain;
        // browsing must surface each of them so earlier drains stay reachable.
        let ws = temp_ws("list-drains");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-replan")).unwrap();
        save_activated_queue(
            &ws,
            "intent-replan",
            "cnf_first",
            seed_task("YARD-001", "first drain task", TaskState::Done),
        );
        archive_intent(&ws).unwrap();
        save_activated_queue(
            &ws,
            "intent-replan",
            "cnf_second",
            seed_task("YARD-002", "second drain task", TaskState::Done),
        );
        archive_intent(&ws).unwrap();

        let dir = ws.agents_dir().join("intents").join("intent-replan");
        let drains = archived_drain_snapshots(&dir);
        assert_eq!(
            drains.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(),
            vec!["cnf_second", "cnf_first"],
            "confirmation ids are timestamped \u{2192} newest first"
        );
        for (id, path) in &drains {
            assert_eq!(path, &dir.join("drains").join(id));
            assert!(path.join("final-report.md").is_file());
        }
    }

    #[test]
    fn archived_drain_snapshots_hides_single_drain_archives() {
        // With at most one drain the canonical layout already shows that
        // drain — the browser list must not change for such intents.
        let ws = temp_ws("single-drain");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-single")).unwrap();
        save_activated_queue(
            &ws,
            "intent-single",
            "cnf_only",
            seed_task("YARD-001", "only drain", TaskState::Done),
        );
        archive_intent(&ws).unwrap();

        let dir = ws.agents_dir().join("intents").join("intent-single");
        assert!(dir.join("drains/cnf_only").is_dir());
        assert!(archived_drain_snapshots(&dir).is_empty());
        // Legacy archives without a drains directory stay empty too.
        assert!(archived_drain_snapshots(&dir.join("missing")).is_empty());
    }

    #[test]
    fn drain_dir_name_stays_inside_the_archive_dir() {
        assert_eq!(
            drain_dir_name("cnf_20260722120000_000001"),
            "cnf_20260722120000_000001"
        );
        assert_eq!(drain_dir_name("../escape"), "..-escape");
        assert_eq!(drain_dir_name(".."), "drain");
        assert_eq!(drain_dir_name("  "), "drain");
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
    fn partial_git_finish_never_renders_as_complete() {
        let ws = temp_ws("git-finish-partial");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-finish")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue
            .tasks
            .push(seed_task("YARD-001", "finish", TaskState::Partial));
        ws.save_queue(&queue).unwrap();

        let report = build_final_report(&ws).unwrap();

        assert!(report.contains("unfinished (held:"), "{report}");
        assert!(!report.contains("complete (held:"), "{report}");
    }

    #[test]
    fn final_report_surfaces_cross_workspace_follow_ups_as_withheld_suggestions() {
        let ws = temp_ws("withheld-follow-ups");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-withheld")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-withheld".to_string();
        queue
            .tasks
            .push(seed_task("YARD-001", "builder", TaskState::Done));
        ws.save_queue(&queue).unwrap();
        write_run(
            &ws,
            "run-withheld",
            "YARD-001",
            r#"{"schema_version":1,"run_id":"run-withheld","task_id":"YARD-001","status":"done",
               "follow_up_tasks":[
                 {"title":"modify another repository","allowed_scope":["/tmp/other/**"]},
                 {"title":"modify a home checkout","allowed_scope":["~/other/**"]},
                 {"title":"record local evidence","allowed_scope":["evidence/**"]}
               ]}"#,
        );

        let report = build_final_report(&ws).unwrap();

        assert!(report.contains("## Withheld suggestions"), "{report}");
        assert!(
            report.contains("2 cross-workspace follow-up suggestion(s) were not ingested"),
            "{report}"
        );
        assert!(report.contains("- modify another repository"), "{report}");
        assert!(report.contains("- modify a home checkout"), "{report}");
        assert!(!report.contains("- record local evidence"), "{report}");
    }

    #[test]
    fn final_report_surfaces_harness_copy_warning_evidence_only_when_present() {
        let ws = temp_ws("harness-copy-warnings");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-harness")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-harness".to_string();
        queue
            .tasks
            .push(seed_task("YARD-001", "builder", TaskState::Done));
        ws.save_queue(&queue).unwrap();
        write_run(
            &ws,
            "run-harness",
            "YARD-001",
            r#"{"schema_version":1,"run_id":"run-harness","task_id":"YARD-001","status":"done"}"#,
        );

        let clean = build_final_report(&ws).unwrap();
        assert!(!clean.contains("Harness copy warnings"), "{clean}");

        let log = ws
            .runs_dir()
            .join("run-harness/evidence/harness-copy-warnings.log");
        std::fs::create_dir_all(log.parent().unwrap()).unwrap();
        std::fs::write(
            &log,
            "copy_dir: skipped symlink 'a' -> 'b'\ncopy_dir: skipped symlink 'c' -> 'd'\n",
        )
        .unwrap();

        let report = build_final_report(&ws).unwrap();
        assert!(
            report.contains("Harness copy warnings: 2 warning(s)"),
            "{report}"
        );
        assert!(
            report.contains("evidence/harness-copy-warnings.log"),
            "{report}"
        );
    }

    #[test]
    fn final_report_does_not_render_a_reused_task_ids_previous_intent_transition() {
        let ws = temp_ws("intent-scoped-transition");
        crate::state::save_yaml(&ws.intent_path(), &intent("intent-current")).unwrap();
        let mut queue = crate::schemas::WorkQueue::empty();
        queue.intent_id = "intent-current".to_string();
        queue
            .tasks
            .push(seed_task("SHARED", "reused task", TaskState::Done));
        ws.save_queue(&queue).unwrap();

        std::fs::create_dir_all(ws.transitions_dir()).unwrap();
        std::fs::write(
            ws.transition_path("SHARED"),
            r#"task_id: SHARED
records:
  - task_id: SHARED
    intent_id: intent-previous
    from: queued
    to: failed
    cause: run_outcome
    detail: stale previous-intent reason
    actor:
      kind: system
    ts: "2026-07-11T00:00:00+09:00"
"#,
        )
        .unwrap();

        let report = build_final_report(&ws).unwrap();

        assert!(report.contains("### SHARED reused task"), "{report}");
        assert!(!report.contains("stale previous-intent reason"), "{report}");
        assert!(!report.contains("Last transition:"), "{report}");
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
