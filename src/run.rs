//! Run orchestration: select one bounded task, prepare it, and (optionally)
//! execute it through a hidden worker, then evaluate and compact.
//!
//! Yard stays deterministic until a worker is invoked. By default `run_next`
//! prepares everything (run dir, evidence, packet, sanitized env) and stops
//! *before* spawning, because spawning a subscription-backed worker consumes
//! real usage. Pass `execute: true` to actually invoke the worker.

use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use chrono::Local;
use serde::Serialize;

use crate::guard;
use crate::inspect;
use crate::packet::{self, PacketInputs};
use crate::schemas::{RunResult, TaskState, WorkerProfile};
use crate::state::{self, write_str, Workspace};
use crate::{compact, evaluator, routing, telemetry, workers};

pub struct RunOptions {
    pub execute: bool,
    pub worker_override: Option<String>,
    /// Run a specific task by id (bypasses queue selection). Used to resume a
    /// task that is waiting on the user.
    pub target: Option<String>,
    /// The user's answer to a worker's prior question, threaded into the packet.
    pub answer: Option<String>,
    /// Explicit, opt-in escalation: drop the worker sandbox (network, installs,
    /// etc.). Off by default; this is a human-granted permission.
    pub full_access: bool,
}

pub struct RunReport {
    pub run_id: String,
    pub task_id: String,
    pub worker_id: String,
    pub run_dir: PathBuf,
    pub prepared: bool,
    pub executed: bool,
    pub lines: Vec<String>,
    /// The task's state after evaluation (None when only prepared).
    pub result_state: Option<TaskState>,
}

#[derive(Serialize)]
struct RunRecord {
    schema_version: u32,
    run_id: String,
    task_id: String,
    intent_id: String,
    worker: String,
    state: String,
    started_at: String,
    worktree: String,
}

pub fn run_next(ws: &Workspace, opts: &RunOptions) -> Result<RunReport> {
    let mut queue = ws.load_queue()?;
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let intent = ws.load_intent()?;
    let config = ws.load_config()?;

    // ---- select task: a named target, or the next eligible queued one ---
    let idx = match &opts.target {
        Some(id) => queue
            .tasks
            .iter()
            .position(|t| &t.id == id)
            .ok_or_else(|| anyhow!("task {id} not found in the queue"))?,
        None => {
            select_next(&queue, opts)?.ok_or_else(|| anyhow!("no eligible queued task to run"))?
        }
    };
    let task = queue.tasks[idx].clone();

    // If resuming with an answer, recover the worker's prior question for context.
    let prior_question = if opts.answer.is_some() {
        latest_question_for(ws, &task.id)
    } else {
        None
    };

    // ---- resolve worker (deterministic: candidate -> readiness -> fallback) --
    let resolved = routing::resolve_worker(
        ws,
        &workers,
        &billing,
        opts.worker_override.as_deref(),
        &task.preferred_worker,
        &task.kind,
    );
    let candidate_id = opts
        .worker_override
        .clone()
        .filter(|s| !s.is_empty())
        .or_else(|| (!task.preferred_worker.is_empty()).then(|| task.preferred_worker.clone()))
        .unwrap_or_else(|| workers.routing.default_worker.clone());
    let worker_id = resolved
        .as_ref()
        .map(|r| r.worker_id.clone())
        .unwrap_or_else(|_| candidate_id.clone());

    // ---- run directory ---------------------------------------------------
    let run_id = format!("run-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");

    let mut lines = Vec::new();
    lines.push(format!("selected task {} ({})", task.id, task.title));
    if let Some(rat) = &task.worker_rationale {
        lines.push(format!("planner rationale: {rat}"));
    }
    lines.push(format!("run dir: {run_dir_rel}"));

    // ---- deterministic evidence -----------------------------------------
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;

    // ---- compile packet --------------------------------------------------
    // Resolve output language from config (auto-detects Korean from the intent).
    let lang_sample = intent
        .as_ref()
        .map(|i| {
            if !i.raw_request.is_empty() {
                i.raw_request.clone()
            } else {
                i.summary.clone()
            }
        })
        .unwrap_or_else(|| task.title.clone());
    let language = packet::resolve_language(&config.language, &lang_sample);
    let images: Vec<String> = intent
        .as_ref()
        .map(|i| i.images.clone())
        .unwrap_or_default();

    let packet_text = packet::compile(&PacketInputs {
        worker_id: &worker_id,
        task: &task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: &run_dir_rel,
        prior_question: prior_question.as_deref(),
        user_answer: opts.answer.as_deref(),
        language: &language,
        images: &images,
    });
    write_str(&workers::packet_path(&run_dir), &packet_text)?;

    // ---- run record ------------------------------------------------------
    let record = RunRecord {
        schema_version: 1,
        run_id: run_id.clone(),
        task_id: task.id.clone(),
        intent_id: queue.intent_id.clone(),
        worker: worker_id.clone(),
        state: if opts.execute { "running" } else { "prepared" }.to_string(),
        started_at: Local::now().to_rfc3339(),
        worktree: ".".to_string(),
    };
    state::save_yaml(&run_dir.join("run.yaml"), &record)?;

    // ---- zero-key env note ----------------------------------------------
    let billing_present = guard::present_billing_env(&billing.blocked_worker_env_names);
    if !billing_present.is_empty() {
        lines.push(format!(
            "billing env present in parent ({}); will be scrubbed before worker runs",
            billing_present.len()
        ));
    }

    if !opts.execute {
        lines.push(String::new());
        match &resolved {
            Ok(r) => lines.push(format!("will use {} ({})", r.worker_id, r.reason)),
            Err(e) => lines.push(format!("no ready worker: {e}")),
        }
        lines.push("re-run with --execute to invoke the worker.".to_string());
        return Ok(RunReport {
            run_id,
            task_id: task.id,
            worker_id,
            run_dir,
            prepared: true,
            executed: false,
            lines,
            result_state: None,
        });
    }

    // ---- execute ---------------------------------------------------------
    if task.approval_required() {
        if crate::approvals::is_granted(ws, &task.id) {
            crate::approvals::consume(ws, &task.id)?; // single-use
            lines.push(format!("approval consumed for {}", task.id));
        } else {
            return Err(anyhow!(
                "task {} requires approval. Run `yard approve {}` first, then \
                 `yard run --task {} --execute`.",
                task.id,
                task.id,
                task.id
            ));
        }
    }
    let resolved = resolved?; // hard stop if no ready worker
    let reason = resolved.reason;
    let bin = resolved.bin;
    let profile = find_worker(&workers.workers, &worker_id)?;
    // Per-task model/effort override the worker profile; an empty value falls
    // back to the profile, and build_command treats "auto" as the CLI's own
    // default. The in-flight task thus captures its own effective profile.
    let mut eff_profile = profile.clone();
    if !task.model.trim().is_empty() {
        eff_profile.model = task.model.clone();
    }
    if !task.effort.trim().is_empty() {
        eff_profile.effort = task.effort.clone();
    }
    // Per-run --full-access OR the workspace's default_access=full.
    let full_access = opts.full_access || config.default_access.eq_ignore_ascii_case("full");
    let env = guard::sanitized_worker_env(&billing).map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    lines.push(format!("worker: {worker_id} ({reason})"));

    // mark running
    queue.tasks[idx].state = TaskState::Running;
    ws.save_queue(&queue)?;

    // Session id for resume-on-transient: claude lets us set one up front; codex
    // generates its own, captured from its rollout file after the run starts.
    let log_path = run_dir.join("worker-output.log");
    let mut session_id: Option<String> = if worker_id == "claude-code" {
        Some(gen_session_uuid(&run_id))
    } else {
        None
    };
    let started_sys = std::time::SystemTime::now();
    let run_started = std::time::Instant::now();
    let mut outcome = workers::spawn(
        &eff_profile,
        &bin,
        &packet_text,
        &ws.root,
        &env,
        &log_path,
        timeout,
        full_access,
        &images,
        session_id.as_deref(),
        false,
    )?;
    if worker_id == "codex" && session_id.is_none() {
        session_id = find_codex_session(started_sys);
    }
    // Resume on a transient failure (e.g. a dropped connection) instead of redoing
    // the task from scratch — unless the user stopped it (Esc writes a marker).
    let cancelled_marker = run_dir.join("cancelled");
    let max_retries = eff_profile.limits.max_retries as u32;
    let mut resumes = 0u32;
    while session_id.is_some()
        && !cancelled_marker.exists()
        && is_transient_failure(&outcome, &run_dir)
        && resumes < max_retries
    {
        resumes += 1;
        lines.push(format!(
            "transient failure; resuming session ({resumes}/{max_retries})"
        ));
        let cont = "The previous run was interrupted by a connection error before it finished. \
                    Continue from where you left off, complete the task, and write the result file \
                    exactly as specified in the original task packet.";
        outcome = workers::spawn(
            &eff_profile,
            &bin,
            cont,
            &ws.root,
            &env,
            &log_path,
            timeout,
            full_access,
            &images,
            session_id.as_deref(),
            true,
        )?;
    }
    let wall_seconds = run_started.elapsed().as_secs();

    // User stopped it (Esc): requeue rather than evaluate as a real failure.
    if cancelled_marker.exists() {
        let _ = std::fs::remove_file(&cancelled_marker);
        queue.tasks[idx].state = TaskState::Queued;
        ws.save_queue(&queue)?;
        lines.push(format!("stopped by user; {} requeued", task.id));
        return Ok(RunReport {
            run_id: run_id.clone(),
            task_id: task.id.clone(),
            worker_id: worker_id.clone(),
            run_dir: run_dir.clone(),
            prepared: true,
            executed: true,
            lines,
            result_state: Some(TaskState::Queued),
        });
    }
    lines.push(format!(
        "worker outcome: {} (exit_ok={}, timed_out={})",
        outcome.note, outcome.exit_ok, outcome.timed_out
    ));

    // ---- evaluate + compact ---------------------------------------------
    let eval = evaluator::evaluate(&run_dir, &run_id, &task);
    state::write_str(
        &run_dir.join("evaluation.json"),
        &serde_json::to_string_pretty(&eval)?,
    )?;

    let result: Option<crate::schemas::RunResult> =
        std::fs::read_to_string(run_dir.join("result.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok());
    let intent_summary = intent.as_ref().map(|i| i.summary.as_str()).unwrap_or("");
    compact::write_checkpoint(&run_dir, &task, &eval, result.as_ref(), intent_summary)?;
    compact::write_handoff(&run_dir, &task, &eval, result.as_ref())?;

    // ---- update queue ----------------------------------------------------
    queue.tasks[idx].state = eval.next_task_state;
    ws.save_queue(&queue)?;

    // ---- telemetry (best effort; feeds routing suggestions) -------------
    let user_override = opts.worker_override.as_ref().map(|o| {
        let from = if task.preferred_worker.is_empty() {
            "(default)".to_string()
        } else {
            task.preferred_worker.clone()
        };
        format!("{from}->{o}")
    });
    let _ = telemetry::append_run(
        ws,
        &telemetry::RunTelemetry {
            ts: Local::now().to_rfc3339(),
            task_id: task.id.clone(),
            kind: task.kind.clone(),
            risk: task.risk.clone(),
            worker: worker_id.clone(),
            chosen_reason: reason.clone(),
            result_status: result
                .as_ref()
                .map(|r| r.status.clone())
                .unwrap_or_else(|| "no-result".to_string()),
            eval_state: format!("{:?}", eval.next_task_state),
            wall_seconds,
            user_override,
        },
    );

    lines.push(format!("evaluation status: {}", eval.status));
    lines.push(format!("next task state: {:?}", eval.next_task_state));

    Ok(RunReport {
        run_id,
        task_id: task.id,
        worker_id,
        run_dir,
        prepared: true,
        executed: true,
        lines,
        result_state: Some(eval.next_task_state),
    })
}

/// Autonomous mode: drain the queue, stopping only at genuine human gates.
///
/// Runs eligible queued tasks one after another. Done (or partial->re-queued)
/// advances; Blocked / NeedsUser / Failed stop the loop and hand back to the
/// user (those need a human). A per-task attempt cap prevents looping on a task
/// that keeps coming back partial. `bypass` drops the worker sandbox for the
/// whole run (workers still self-gate dangerous actions per the packet).
pub fn run_auto<F: FnMut(&str)>(
    ws: &Workspace,
    bypass: bool,
    pause: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    mut on_event: F,
) -> Result<Vec<String>> {
    use std::collections::HashMap;
    let mut out = Vec::new();
    let mut emit = |s: String| {
        on_event(&s);
        out.push(s);
    };
    let mut attempts: HashMap<String, u32> = HashMap::new();
    let probe_opts = RunOptions {
        execute: false,
        worker_override: None,
        target: None,
        answer: None,
        full_access: false,
    };

    // Recover orphans (interrupted runs left "running") before draining.
    for m in recover_orphans(ws) {
        emit(m);
    }

    loop {
        // Graceful pause: stop between tasks (the current task, if any, has
        // already finished here). Resume by running auto again.
        if pause
            .as_ref()
            .map(|p| p.load(std::sync::atomic::Ordering::Relaxed))
            .unwrap_or(false)
        {
            emit("paused: stopped after the current task (run auto again to resume)".to_string());
            break;
        }
        let queue = ws.load_queue()?;
        // NeedsUser/Blocked genuinely need a human: halt (don't skip past them).
        if let Some(t) = queue
            .tasks
            .iter()
            .find(|t| {
                matches!(
                    t.state,
                    TaskState::NeedsUser | TaskState::Blocked | TaskState::Partial
                )
            })
        {
            emit(format!(
                "stopped: {} is {:?} \u{2014} answer (a) or resolve it, then run auto again",
                t.id, t.state
            ));
            break;
        }
        // A Failed task may be transient (e.g. a dropped connection): retry it
        // first, bounded by the attempts cap below, instead of halting the drain.
        let retry_target = queue
            .tasks
            .iter()
            .find(|t| t.state == TaskState::Failed)
            .map(|t| t.id.clone());
        // Pick the work: retry the failed task first, else the next queued one.
        let task_id = match &retry_target {
            Some(id) => id.clone(),
            None => match select_next(&queue, &probe_opts)? {
                Some(idx) => queue.tasks[idx].id.clone(),
                None => {
                    emit("done: queue drained, all tasks complete".to_string());
                    break;
                }
            },
        };
        let n = attempts.entry(task_id.clone()).or_default();
        *n += 1;
        if *n > 2 {
            emit(format!(
                "stopped: {task_id} did not complete after retries \u{2014} needs you"
            ));
            break;
        }

        emit(format!("running {task_id}\u{2026}"));
        let report = run_next(
            ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: retry_target.clone(),
                answer: None,
                full_access: bypass,
            },
        )?;
        let state = report.result_state.unwrap_or(TaskState::Failed);
        emit(format!("{} \u{2192} {:?}", report.task_id, state));

        match state {
            TaskState::Done | TaskState::Queued => continue,
            TaskState::Blocked => {
                emit(format!(
                    "stopped: {} blocked \u{2014} see `yard handoff`",
                    report.task_id
                ));
                break;
            }
            TaskState::NeedsUser => {
                emit(format!(
                    "stopped: {} needs you \u{2014} `yard answer \"...\"`",
                    report.task_id
                ));
                break;
            }
            TaskState::Partial => {
                emit(format!(
                    "stopped: {} is partial (incomplete) \u{2014} needs you",
                    report.task_id
                ));
                break;
            }
            TaskState::Failed => {
                // Likely transient (e.g. a dropped connection); loop to retry it,
                // bounded by the attempts cap above.
                emit(format!("{} failed; retrying", report.task_id));
                continue;
            }
            TaskState::Running => break,
        }
    }
    Ok(out)
}

/// Pick the highest-priority eligible queued task index.
pub fn select_next(queue: &crate::schemas::WorkQueue, _opts: &RunOptions) -> Result<Option<usize>> {
    let pol = &queue.selection_policy;
    let mut best: Option<usize> = None;
    for (i, t) in queue.tasks.iter().enumerate() {
        if t.state != TaskState::Queued {
            continue;
        }
        if pol.skip_if_approval_required && t.approval_required() {
            continue;
        }
        // skip_if_blocked is about the Blocked state, already filtered above.
        match best {
            None => best = Some(i),
            Some(b) => {
                if t.priority < queue.tasks[b].priority {
                    best = Some(i);
                }
            }
        }
    }
    Ok(best)
}

/// The newest run directory recorded for a task id, as (run_id, dir). Run dirs
/// are named `run-<timestamp>` so a lexicographic max is the most recent.
pub(crate) fn latest_run_for(ws: &Workspace, task_id: &str) -> Option<(String, PathBuf)> {
    let mut best: Option<(String, PathBuf)> = None;
    for entry in std::fs::read_dir(ws.runs_dir()).ok()?.flatten() {
        let dir = entry.path();
        let Some(name) = dir.file_name().and_then(|n| n.to_str()).map(String::from) else {
            continue;
        };
        if !name.starts_with("run-") {
            continue;
        }
        let yaml = std::fs::read_to_string(dir.join("run.yaml")).unwrap_or_default();
        let tid = yaml
            .lines()
            .find_map(|l| l.trim().strip_prefix("task_id:").map(|v| v.trim().to_string()));
        if tid.as_deref() != Some(task_id) {
            continue;
        }
        if best.as_ref().map(|(n, _)| name > *n).unwrap_or(true) {
            best = Some((name, dir));
        }
    }
    best
}

/// A UUID-format string (8-4-4-4-12 hex) from a seed + pid, used to set a claude
/// session id up front so a transient failure can resume the same conversation.
fn gen_session_uuid(seed: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h1 = std::collections::hash_map::DefaultHasher::new();
    seed.hash(&mut h1);
    std::process::id().hash(&mut h1);
    let a = h1.finish();
    let mut h2 = std::collections::hash_map::DefaultHasher::new();
    (a, seed).hash(&mut h2);
    let b = h2.finish();
    let hex = format!("{a:016x}{b:016x}");
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// Find the codex session id (UUID) for a run started at/after `after`, from its
/// rollout file under ~/.codex/sessions (named `rollout-<ts>-<uuid>.jsonl`, so
/// the trailing 36 chars are the id).
fn find_codex_session(after: std::time::SystemTime) -> Option<String> {
    fn walk(
        dir: &std::path::Path,
        after: std::time::SystemTime,
        best: &mut Option<(std::time::SystemTime, String)>,
    ) {
        let Ok(rd) = std::fs::read_dir(dir) else {
            return;
        };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, after, best);
                continue;
            }
            let Some(stem) = p
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| n.strip_suffix(".jsonl"))
            else {
                continue;
            };
            if !stem.starts_with("rollout-") || stem.len() < 36 {
                continue;
            }
            let Ok(mt) = e.metadata().and_then(|m| m.modified()) else {
                continue;
            };
            if mt + std::time::Duration::from_secs(3) < after {
                continue;
            }
            if best.as_ref().map(|(t, _)| mt > *t).unwrap_or(true) {
                *best = Some((mt, stem[stem.len() - 36..].to_string()));
            }
        }
    }
    let home = std::env::var_os("HOME")?;
    let base = std::path::Path::new(&home).join(".codex/sessions");
    let mut best = None;
    walk(&base, after, &mut best);
    best.map(|(_, id)| id)
}

/// A transient (likely network/infra) failure: the worker did not exit cleanly,
/// left no result, and was not stopped by us — worth resuming rather than redoing.
fn is_transient_failure(outcome: &workers::WorkerOutcome, run_dir: &std::path::Path) -> bool {
    !outcome.exit_ok && !outcome.timed_out && !run_dir.join("result.json").exists()
}

/// Recover tasks left "running" by an interrupted/quit session: if the task's
/// latest run produced a result, evaluate it (keep the finished work); otherwise
/// requeue it. Returns messages describing what changed. Safe to call on startup.
pub(crate) fn recover_orphans(ws: &Workspace) -> Vec<String> {
    let mut msgs = Vec::new();
    let Ok(mut q) = ws.load_queue() else {
        return msgs;
    };
    let mut requeued = Vec::new();
    let mut finished = Vec::new();
    for t in q.tasks.iter_mut() {
        if t.state != TaskState::Running {
            continue;
        }
        match latest_run_for(ws, &t.id) {
            Some((run_id, run_dir)) if run_dir.join("result.json").exists() => {
                let eval = evaluator::evaluate(&run_dir, &run_id, t);
                t.state = eval.next_task_state;
                finished.push(format!("{} \u{2192} {:?}", t.id, t.state));
            }
            _ => {
                t.state = TaskState::Queued;
                requeued.push(t.id.clone());
            }
        }
    }
    if !finished.is_empty() || !requeued.is_empty() {
        let _ = ws.save_queue(&q);
        if !finished.is_empty() {
            msgs.push(format!("recovered completed run(s): {}", finished.join(", ")));
        }
        if !requeued.is_empty() {
            msgs.push(format!(
                "requeued interrupted task(s): {}",
                requeued.join(", ")
            ));
        }
    }
    msgs
}

fn find_worker<'a>(workers: &'a [WorkerProfile], id: &str) -> Result<&'a WorkerProfile> {
    workers
        .iter()
        .find(|w| w.id == id)
        .ok_or_else(|| anyhow!("worker '{id}' is not defined in .agents/workers.yaml"))
}

/// The most recent unanswered question a worker left for a given task, if any.
pub fn latest_question_for(ws: &Workspace, task_id: &str) -> Option<String> {
    let mut best: Option<(SystemTime, String)> = None;
    for entry in std::fs::read_dir(ws.runs_dir()).ok()?.flatten() {
        let result_path = entry.path().join("result.json");
        let Ok(text) = std::fs::read_to_string(&result_path) else {
            continue;
        };
        let Ok(result) = serde_json::from_str::<RunResult>(&text) else {
            continue;
        };
        if result.task_id != task_id {
            continue;
        }
        let Some(q) = result.question_for_user.filter(|q| !q.trim().is_empty()) else {
            continue;
        };
        let mtime = entry
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(UNIX_EPOCH);
        if best.as_ref().map(|(t, _)| mtime > *t).unwrap_or(true) {
            best = Some((mtime, q));
        }
    }
    best.map(|(_, q)| q)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{SelectionPolicy, Task, WorkQueue};

    fn task(id: &str, state: TaskState, priority: i64, needs_approval: bool) -> Task {
        Task {
            id: id.into(),
            title: id.into(),
            state,
            priority,
            risk: String::new(),
            kind: String::new(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: if needs_approval {
                Some(crate::yaml::from_str("required: true").unwrap())
            } else {
                None
            },
            interaction: None,
            worker_rationale: None,
        }
    }

    fn queue(tasks: Vec<Task>) -> WorkQueue {
        WorkQueue {
            schema_version: 1,
            queue_id: "q".into(),
            intent_id: String::new(),
            selection_policy: SelectionPolicy::default(),
            tasks,
        }
    }

    fn opts() -> RunOptions {
        RunOptions {
            execute: false,
            worker_override: None,
            target: None,
            answer: None,
            full_access: false,
        }
    }

    #[test]
    fn picks_lowest_priority_queued() {
        let q = queue(vec![
            task("A", TaskState::Queued, 30, false),
            task("B", TaskState::Queued, 10, false),
            task("C", TaskState::Queued, 20, false),
        ]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1)); // B, priority 10
    }

    #[test]
    fn skips_non_queued_and_approval_required() {
        let q = queue(vec![
            task("done", TaskState::Done, 5, false),
            task("gated", TaskState::Queued, 1, true), // skipped: needs approval
            task("ready", TaskState::Queued, 40, false),
        ]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(2)); // ready
    }

    #[test]
    fn none_when_no_eligible() {
        let q = queue(vec![
            task("a", TaskState::Done, 1, false),
            task("b", TaskState::Blocked, 2, false),
        ]);
        assert_eq!(select_next(&q, &opts()).unwrap(), None);
    }
}
