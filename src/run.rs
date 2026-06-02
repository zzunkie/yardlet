//! Run orchestration: select one bounded task, prepare it, and (optionally)
//! execute it through a hidden worker, then evaluate and compact.
//!
//! Yard stays deterministic until a worker is invoked. By default `run_next`
//! prepares everything (run dir, evidence, packet, sanitized env) and stops
//! *before* spawning, because spawning a subscription-backed worker consumes
//! real usage. Pass `execute: true` to actually invoke the worker.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, Result};
use chrono::Local;
use serde::Serialize;

use crate::guard::{self, Readiness};
use crate::inspect;
use crate::packet::{self, PacketInputs};
use crate::schemas::{TaskState, WorkerProfile};
use crate::state::{self, write_str, Workspace};
use crate::{compact, evaluator, workers};

pub struct RunOptions {
    pub execute: bool,
    pub worker_override: Option<String>,
}

pub struct RunReport {
    pub run_id: String,
    pub task_id: String,
    pub worker_id: String,
    pub run_dir: PathBuf,
    pub prepared: bool,
    pub executed: bool,
    pub lines: Vec<String>,
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

    // ---- select next eligible task --------------------------------------
    let idx =
        select_next(&queue, opts)?.ok_or_else(|| anyhow!("no eligible queued task to run"))?;
    let task = queue.tasks[idx].clone();

    // ---- pick worker -----------------------------------------------------
    let worker_id = opts
        .worker_override
        .clone()
        .or_else(|| {
            if task.preferred_worker.is_empty() {
                None
            } else {
                Some(task.preferred_worker.clone())
            }
        })
        .unwrap_or_else(|| "codex".to_string());
    let profile = find_worker(&workers.workers, &worker_id)?;

    // ---- run directory ---------------------------------------------------
    let run_id = format!("run-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");

    let mut lines = Vec::new();
    lines.push(format!("selected task {} ({})", task.id, task.title));
    lines.push(format!("worker: {worker_id}"));
    lines.push(format!("run dir: {run_dir_rel}"));

    // ---- deterministic evidence -----------------------------------------
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;

    // ---- compile packet --------------------------------------------------
    let packet_text = packet::compile(&PacketInputs {
        worker_id: &worker_id,
        task: &task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: &run_dir_rel,
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

    // ---- zero-key env ----------------------------------------------------
    let status = guard::probe(profile, &billing);
    if !status.billing_env_present.is_empty() {
        lines.push(format!(
            "billing env present in parent ({}); will be scrubbed before worker runs",
            status.billing_env_present.len()
        ));
    }

    if !opts.execute {
        lines.push(String::new());
        lines.push("prepared (not executed). Worker readiness:".to_string());
        lines.push(format!(
            "  {} — {}",
            status.readiness.label(),
            status.detail
        ));
        lines.push("re-run with --execute to invoke the worker.".to_string());
        return Ok(RunReport {
            run_id,
            task_id: task.id,
            worker_id,
            run_dir,
            prepared: true,
            executed: false,
            lines,
        });
    }

    // ---- execute ---------------------------------------------------------
    if status.readiness != Readiness::Ready {
        return Err(anyhow!(
            "worker '{worker_id}' is {}: {}\nYard did not call an AI API and did not ask for an API key.",
            status.readiness.label(),
            status.detail
        ));
    }
    let env = guard::sanitized_worker_env(&billing).map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);

    // mark running
    queue.tasks[idx].state = TaskState::Running;
    ws.save_queue(&queue)?;

    let outcome = workers::spawn(
        profile,
        &packet_text,
        &ws.root,
        &env,
        &run_dir.join("worker-output.log"),
        timeout,
    )?;
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
    })
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
