//! Planning gate.
//!
//! Turns a short natural-language request into canonical state: a worker writes
//! a structured `planning-result.json`, and Yard derives the
//! `intent-contract.yaml` + `work-queue.yaml` from it. Yard owns the canonical
//! files; the worker only authors plan content.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::Deserialize;

use crate::guard::{self, Readiness};
use crate::inspect;
use crate::schemas::{
    IntentContract, SelectionPolicy, Task, TaskState, WorkQueue, WorkerProfile, WorkersFile,
};
use crate::state::{self, write_str, Workspace};
use crate::{packet, workers, yaml};

// ---- worker-authored plan shape -------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct PlanningResult {
    #[serde(default)]
    summary: String,
    #[serde(default)]
    allowed_scope: Vec<String>,
    #[serde(default)]
    out_of_scope: Vec<String>,
    #[serde(default)]
    acceptance: Vec<PlanAcceptance>,
    #[serde(default)]
    tasks: Vec<PlanTask>,
    #[serde(default)]
    questions_for_user: Vec<String>,
}

#[derive(Debug, Default, Deserialize)]
struct PlanAcceptance {
    #[serde(default)]
    statement: String,
}

#[derive(Debug, Default, Deserialize)]
struct PlanTask {
    #[serde(default)]
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    kind: String,
    #[serde(default)]
    risk: String,
    #[serde(default)]
    preferred_worker: String,
    #[serde(default)]
    allowed_scope: Vec<String>,
    #[serde(default)]
    acceptance: Vec<String>,
}

// ---- report ---------------------------------------------------------------

pub struct PlanningReport {
    pub run_id: String,
    pub worker_id: String,
    pub intent_summary: String,
    pub task_count: usize,
    pub questions: Vec<String>,
    pub lines: Vec<String>,
}

/// Run the planning gate for a natural-language request.
pub fn run_planning(
    ws: &Workspace,
    request: &str,
    worker_override: Option<&str>,
) -> Result<PlanningReport> {
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;
    let language = packet::resolve_language(&config.language, request);

    // Choose a ready planning worker.
    let (profile, bin, worker_id) = pick_ready_worker(&workers, &billing, worker_override)?;

    let run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");

    let mut lines = Vec::new();

    // Evidence + packet.
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let packet_text = packet::compile_planning(request, &summary, &run_dir_rel, &language);
    write_str(&workers::packet_path(&run_dir), &packet_text)?;

    // Invoke the worker with a sanitized, zero-key environment.
    let env = guard::sanitized_worker_env(&billing).map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    let outcome = workers::spawn(
        &profile,
        &bin,
        &packet_text,
        &ws.root,
        &env,
        &run_dir.join("worker-output.log"),
        timeout,
        false, // planning never needs elevated access
    )?;
    lines.push(format!("worker outcome: {}", outcome.note));

    // Read the worker-authored plan.
    let result_path = run_dir.join("planning-result.json");
    let raw = std::fs::read_to_string(&result_path).with_context(|| {
        format!(
            "planning worker did not write {}. Inspect {}/worker-output.log",
            result_path.display(),
            run_dir_rel
        )
    })?;
    let plan: PlanningResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", result_path.display()))?;

    if plan.summary.trim().is_empty() || plan.tasks.is_empty() {
        bail!(
            "planning produced no usable plan (empty summary or no tasks). See {}",
            result_path.display()
        );
    }

    // Derive canonical state. Yard owns these files.
    let intent_id = format!("intent-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let intent = build_intent(&intent_id, request, &plan);
    let queue = build_queue(&intent_id, &plan);

    state::save_yaml(&ws.intent_path(), &intent)?;
    ws.save_queue(&queue)?;

    Ok(PlanningReport {
        run_id,
        worker_id,
        intent_summary: intent.summary,
        task_count: queue.tasks.len(),
        questions: plan.questions_for_user,
        lines,
    })
}

fn build_intent(intent_id: &str, request: &str, plan: &PlanningResult) -> IntentContract {
    IntentContract {
        schema_version: 1,
        id: intent_id.to_string(),
        source: "user".to_string(),
        raw_request: request.to_string(),
        summary: plan.summary.clone(),
        allowed_scope: plan.allowed_scope.clone(),
        out_of_scope: plan.out_of_scope.clone(),
        acceptance: plan
            .acceptance
            .iter()
            .filter(|a| !a.statement.trim().is_empty())
            .map(|a| yaml::Value::String(a.statement.clone()))
            .collect(),
        status: "accepted".to_string(),
    }
}

fn build_queue(intent_id: &str, plan: &PlanningResult) -> WorkQueue {
    let tasks = plan
        .tasks
        .iter()
        .enumerate()
        .map(|(i, t)| Task {
            id: if t.id.trim().is_empty() {
                format!("YARD-{:03}", i + 1)
            } else {
                t.id.clone()
            },
            title: t.title.clone(),
            state: TaskState::Queued,
            priority: ((i + 1) * 10) as i64,
            risk: t.risk.clone(),
            kind: t.kind.clone(),
            preferred_worker: if t.preferred_worker.trim().is_empty() {
                "codex".to_string()
            } else {
                t.preferred_worker.clone()
            },
            allowed_scope: t.allowed_scope.clone(),
            acceptance: t
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            validation: None,
            approval: None,
            interaction: None,
        })
        .collect();

    WorkQueue {
        schema_version: 1,
        queue_id: format!("queue-{intent_id}"),
        intent_id: intent_id.to_string(),
        selection_policy: SelectionPolicy::default(),
        tasks,
    }
}

/// Resolve the ordered worker preference and return the first that is ready.
fn pick_ready_worker(
    workers: &WorkersFile,
    billing: &crate::schemas::BillingPolicy,
    worker_override: Option<&str>,
) -> Result<(WorkerProfile, std::path::PathBuf, String)> {
    let mut order: Vec<String> = Vec::new();
    if let Some(o) = worker_override {
        order.push(o.to_string());
    }
    if let Some(routing) = workers.routing.get("planning_gate") {
        for key in ["primary", "fallback"] {
            if let Some(v) = routing.get(key).and_then(|v| v.as_str()) {
                if v != "none" {
                    order.push(v.to_string());
                }
            }
        }
    }
    order.push("codex".to_string());

    let mut tried = Vec::new();
    for id in order {
        if tried.contains(&id) {
            continue;
        }
        tried.push(id.clone());
        let Some(profile) = workers.workers.iter().find(|w| w.id == id) else {
            continue;
        };
        let status = guard::probe(profile, billing);
        if status.readiness == Readiness::Ready {
            if let Some(bin) = status.binary_path {
                return Ok((profile.clone(), bin, id));
            }
        }
    }

    Err(anyhow!(
        "no ready planning worker among {tried:?}. Run `yard worker status` to diagnose. \
         Yard did not call an AI API and did not ask for an API key."
    ))
}
