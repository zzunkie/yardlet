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

    let run_started = std::time::Instant::now();
    let outcome = workers::spawn(
        &eff_profile,
        &bin,
        &packet_text,
        &ws.root,
        &env,
        &run_dir.join("worker-output.log"),
        timeout,
        full_access,
        &images,
    )?;
    let wall_seconds = run_started.elapsed().as_secs();
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

    // Recover orphans first: a task left in Running means an earlier drain was
    // interrupted (its worker process is gone). Nothing is running it now, so
    // requeue it before draining. Yard assumes one instance per workspace.
    {
        let mut q = ws.load_queue()?;
        let recovered: Vec<String> = q
            .tasks
            .iter_mut()
            .filter(|t| t.state == TaskState::Running)
            .map(|t| {
                t.state = TaskState::Queued;
                t.id.clone()
            })
            .collect();
        if !recovered.is_empty() {
            ws.save_queue(&q)?;
            emit(format!(
                "recovered {} orphaned running task(s): {}",
                recovered.len(),
                recovered.join(", ")
            ));
        }
    }

    loop {
        let queue = ws.load_queue()?;
        // Hard gate: never run a later task while an earlier one needs attention.
        // A NeedsUser/Blocked/Failed task must be resolved (yard answer / fix /
        // requeue) before the drain proceeds — it is not silently skipped.
        if let Some(t) = queue.tasks.iter().find(|t| {
            matches!(
                t.state,
                TaskState::NeedsUser | TaskState::Blocked | TaskState::Failed
            )
        }) {
            emit(format!(
                "stopped: {} is {:?} \u{2014} resolve it before draining",
                t.id, t.state
            ));
            break;
        }
        let Some(idx) = select_next(&queue, &probe_opts)? else {
            // Nothing queued: either fully drained or waiting on a human gate.
            let stuck = queue.tasks.iter().find(|t| {
                matches!(
                    t.state,
                    TaskState::Blocked | TaskState::NeedsUser | TaskState::Failed
                )
            });
            match stuck {
                Some(t) => emit(format!(
                    "stopped: {} is {:?} \u{2014} needs you (see `yard handoff`)",
                    t.id, t.state
                )),
                None => emit("done: queue drained, all tasks complete".to_string()),
            }
            break;
        };

        let task_id = queue.tasks[idx].id.clone();
        let n = attempts.entry(task_id.clone()).or_default();
        *n += 1;
        if *n > 2 {
            emit(format!(
                "stopped: {task_id} keeps coming back \u{2014} needs you"
            ));
            break;
        }

        emit(format!("running {task_id}\u{2026}"));
        let report = run_next(
            ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: None,
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
            TaskState::Failed => {
                emit(format!(
                    "stopped: {} failed \u{2014} needs you",
                    report.task_id
                ));
                break;
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
