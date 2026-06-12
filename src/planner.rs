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
    questions_for_user: Vec<PlanQuestion>,
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
    model: String,
    #[serde(default)]
    effort: String,
    #[serde(default)]
    depends_on: Vec<String>,
    #[serde(default)]
    allowed_scope: Vec<String>,
    #[serde(default)]
    acceptance: Vec<String>,
    #[serde(default)]
    worker_rationale: Option<String>,
}

/// Keep only dependencies on tasks that come earlier (`prior_ids`). This drops
/// self-references, forward references, and cycles in one rule: a task may only
/// depend on work already planned before it.
fn sanitize_deps(depends_on: &[String], prior_ids: &[String]) -> Vec<String> {
    depends_on
        .iter()
        .filter(|d| prior_ids.iter().any(|p| p == *d))
        .cloned()
        .collect()
}

/// A worker may emit `questions_for_user` either as plain strings or as objects
/// (e.g. `{ "id": ..., "question": ..., "topic": ... }`) when it mirrors the
/// object style of the `acceptance` hint. Accept both shapes and keep only the
/// human-readable text — Yard surfaces just the question string.
#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum PlanQuestion {
    Text(String),
    Obj {
        #[serde(default)]
        question: String,
        #[serde(default)]
        statement: String,
    },
}

impl PlanQuestion {
    fn into_text(self) -> String {
        match self {
            PlanQuestion::Text(s) => s,
            PlanQuestion::Obj {
                question,
                statement,
            } => {
                if !question.trim().is_empty() {
                    question
                } else {
                    statement
                }
            }
        }
    }
}

// ---- plan-run metadata (crash recovery) ------------------------------------

/// Written when a plan run starts, so an interrupted session can still consume
/// the worker's result on the next startup.
#[derive(Debug, Default, serde::Serialize, Deserialize)]
struct PlanMeta {
    mode: String, // "new" | "amend"
    #[serde(default)]
    request: String,
}

/// Marker file written into a plan run dir once Yard has derived the canonical
/// intent/queue from its result. Absent + result present = unconsumed.
const CONSUMED_MARKER: &str = "consumed";

fn mark_consumed(run_dir: &std::path::Path) {
    let _ = write_str(&run_dir.join(CONSUMED_MARKER), "");
}

/// Reconstruct plan metadata for run dirs created before plan-meta.yaml
/// existed: the compiled packet carries the verbatim request, and follow-up
/// (amend) packets embed a recognizable FOLLOW-UP preamble.
fn legacy_plan_meta(run_dir: &std::path::Path) -> Option<PlanMeta> {
    let packet = std::fs::read_to_string(workers::packet_path(run_dir)).ok()?;
    let request = packet
        .split("## Request (verbatim)")
        .nth(1)?
        .split("\n## ")
        .next()
        .unwrap_or("")
        .trim()
        .to_string();
    let mode = if request.contains("This is a FOLLOW-UP") {
        "amend"
    } else {
        "new"
    };
    Some(PlanMeta {
        mode: mode.to_string(),
        request,
    })
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
    explicit_images: &[String],
) -> Result<PlanningReport> {
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;
    let language = packet::resolve_language(&config.language, request);

    // Images: explicit --image plus any path detected in the request.
    let mut images: Vec<String> = explicit_images.to_vec();
    for d in packet::detect_images(request, &ws.root) {
        if !images.contains(&d) {
            images.push(d);
        }
    }

    // Choose a ready planning worker.
    let (profile, bin, worker_id) = pick_ready_worker(&workers, &billing, worker_override)?;

    let run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");
    state::save_yaml(
        &run_dir.join("plan-meta.yaml"),
        &PlanMeta {
            mode: "new".to_string(),
            request: request.to_string(),
        },
    )?;

    let mut lines = Vec::new();

    // Evidence + packet.
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let worker_guidance = build_worker_guidance(&workers);
    let packet_text = packet::compile_planning(
        request,
        &summary,
        &run_dir_rel,
        &language,
        &worker_guidance,
        &images,
    );
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
        &images,
        None,
        false,
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
    let intent = build_intent(&intent_id, request, &plan, &images);
    let queue = build_queue(&intent_id, &plan);

    // Archive the previous intent before overwriting it (new work shouldn't lose
    // the finished one's record). Best-effort; no-op on the first plan.
    let _ = crate::report::archive_intent(ws);

    state::save_yaml(&ws.intent_path(), &intent)?;
    ws.save_queue(&queue)?;
    mark_consumed(&run_dir);

    Ok(PlanningReport {
        run_id,
        worker_id,
        intent_summary: intent.summary,
        task_count: queue.tasks.len(),
        questions: plan
            .questions_for_user
            .into_iter()
            .map(PlanQuestion::into_text)
            .filter(|q| !q.trim().is_empty())
            .collect(),
        lines,
    })
}

/// Amend the current intent with follow-up tasks: keep the existing (done) work
/// and append new tasks derived from the user's continue request + the existing
/// context. Does not overwrite or archive — it extends the live queue.
pub fn run_planning_amend(ws: &Workspace, request: &str) -> Result<PlanningReport> {
    let existing_intent = ws.load_intent()?;
    let existing_queue = ws.load_queue()?;

    // Give the planner the existing context and ask for new tasks only.
    let mut ctx = String::new();
    if let Some(i) = &existing_intent {
        ctx.push_str(&format!(
            "This is a FOLLOW-UP to an existing intent.\nCurrent goal: {}\n\n",
            i.summary
        ));
    }
    if !existing_queue.tasks.is_empty() {
        ctx.push_str("Already-planned tasks (do NOT recreate these):\n");
        for t in &existing_queue.tasks {
            ctx.push_str(&format!("- {} [{:?}] {}\n", t.id, t.state, t.title));
        }
        ctx.push('\n');
    }
    ctx.push_str(&format!(
        "Follow-up request from the user:\n{request}\n\nProduce ONLY new tasks that add \
         to this work; do not redo the tasks above."
    ));

    // Invoke the planner worker (same machinery as run_planning).
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;
    let language = packet::resolve_language(&config.language, &ctx);
    let images: Vec<String> = Vec::new();
    let (profile, bin, worker_id) = pick_ready_worker(&workers, &billing, None)?;
    let run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");
    state::save_yaml(
        &run_dir.join("plan-meta.yaml"),
        &PlanMeta {
            mode: "amend".to_string(),
            request: request.to_string(),
        },
    )?;
    let mut lines = Vec::new();
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let worker_guidance = build_worker_guidance(&workers);
    let packet_text = packet::compile_planning(
        &ctx,
        &summary,
        &run_dir_rel,
        &language,
        &worker_guidance,
        &images,
    );
    write_str(&workers::packet_path(&run_dir), &packet_text)?;
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
        false,
        &images,
        None,
        false,
    )?;
    lines.push(format!("worker outcome: {}", outcome.note));
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
    if plan.tasks.is_empty() {
        bail!("amend produced no new tasks. See {}", result_path.display());
    }

    // Merge: append the new tasks to the existing queue (continue the numbering).
    let mut queue = existing_queue;
    let added = append_plan_tasks(&mut queue, &plan);
    ws.save_queue(&queue)?;

    // Note the follow-up in the intent summary (keep the same intent).
    if let Some(mut intent) = existing_intent {
        if !plan.summary.trim().is_empty() {
            intent.summary = format!("{}\n\n[follow-up] {}", intent.summary, plan.summary.trim());
            state::save_yaml(&ws.intent_path(), &intent)?;
        }
    }
    mark_consumed(&run_dir);

    Ok(PlanningReport {
        run_id,
        worker_id,
        intent_summary: format!("+{added} task(s)"),
        task_count: queue.tasks.len(),
        questions: plan
            .questions_for_user
            .into_iter()
            .map(PlanQuestion::into_text)
            .filter(|q| !q.trim().is_empty())
            .collect(),
        lines,
    })
}

/// Append a plan's tasks to an existing queue (follow-up/amend semantics):
/// continue the YARD-nnn numbering and stack priorities after existing tasks.
/// Returns how many tasks were added.
fn append_plan_tasks(queue: &mut WorkQueue, plan: &PlanningResult) -> usize {
    let next_num = queue
        .tasks
        .iter()
        .filter_map(|t| {
            t.id.strip_prefix("YARD-")
                .and_then(|n| n.parse::<usize>().ok())
        })
        .max()
        .unwrap_or(queue.tasks.len())
        + 1;
    let base_priority = queue.tasks.iter().map(|t| t.priority).max().unwrap_or(0);
    for (i, pt) in plan.tasks.iter().enumerate() {
        let id = if pt.id.trim().is_empty() {
            format!("YARD-{:03}", next_num + i)
        } else {
            pt.id.clone()
        };
        // Follow-up tasks may depend on existing queue tasks or earlier new ones.
        let prior_ids: Vec<String> = queue.tasks.iter().map(|t| t.id.clone()).collect();
        queue.tasks.push(Task {
            id,
            title: pt.title.clone(),
            state: TaskState::Queued,
            priority: base_priority + ((i + 1) * 10) as i64,
            risk: pt.risk.clone(),
            kind: pt.kind.clone(),
            preferred_worker: if pt.preferred_worker.trim().is_empty() {
                "codex".to_string()
            } else {
                pt.preferred_worker.clone()
            },
            model: pt.model.clone(),
            effort: pt.effort.clone(),
            depends_on: sanitize_deps(&pt.depends_on, &prior_ids),
            allowed_scope: pt.allowed_scope.clone(),
            acceptance: pt
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: pt.worker_rationale.clone(),
        });
    }
    plan.tasks.len()
}

/// Recover a planning result left unconsumed by an interrupted session: the
/// worker finished and wrote `planning-result.json`, but Yard exited before
/// deriving the canonical intent/queue from it. Safe to call on every startup.
///
/// Guards against stale or double application: only the newest unconsumed plan
/// run is considered, it must not be superseded by a NEWER plan run (an
/// orphaned planning worker can finish long after the user already planned
/// something else — consuming it then would clobber the live intent/queue),
/// and its result file must be newer than the current queue file. Also
/// surfaces a still-alive planning worker from a previous session, so the
/// user knows a plan is on its way before paying for a duplicate one.
pub fn recover_unconsumed_plan(ws: &Workspace) -> Option<String> {
    let mut best: Option<(String, std::path::PathBuf)> = None;
    // The newest plan run with a result, consumed or not (supersession check).
    let mut newest_finished: Option<String> = None;
    // A previous session's planning worker that is still running.
    let mut live_planner: Option<(String, u32)> = None;
    for entry in std::fs::read_dir(ws.runs_dir()).ok()?.flatten() {
        let dir = entry.path();
        let Some(name) = dir.file_name().and_then(|n| n.to_str()).map(String::from) else {
            continue;
        };
        if !name.starts_with("plan-") {
            continue;
        }
        if !dir.join("planning-result.json").is_file() {
            // No result yet: is its worker still alive (orphaned planning)?
            if let Some(pid) = crate::run::live_worker_pid(&dir) {
                if live_planner
                    .as_ref()
                    .map(|(n, _)| name > *n)
                    .unwrap_or(true)
                {
                    live_planner = Some((name, pid));
                }
            }
            continue;
        }
        if newest_finished.as_ref().map(|n| name > *n).unwrap_or(true) {
            newest_finished = Some(name.clone());
        }
        let has_meta = dir.join("plan-meta.yaml").is_file() || workers::packet_path(&dir).is_file();
        if !has_meta || dir.join(CONSUMED_MARKER).exists() {
            continue;
        }
        if best.as_ref().map(|(n, _)| name > *n).unwrap_or(true) {
            best = Some((name, dir));
        }
    }
    let Some((run_id, run_dir)) = best else {
        // Nothing to consume — but report a planning worker still at work.
        return live_planner.map(|(name, pid)| {
            format!(
                "a planning worker from a previous session is still running \
                 ({name}, pid {pid}); its plan will be picked up when it finishes"
            )
        });
    };

    // Superseded: a newer plan run exists (consumed or not). Consuming this
    // older one would overwrite the user's current intent/queue with a stale
    // plan — retire it instead.
    if newest_finished
        .as_deref()
        .is_some_and(|n| n > run_id.as_str())
    {
        mark_consumed(&run_dir);
        return None;
    }

    // Freshness guard: the result must be newer than the canonical queue.
    let result_path = run_dir.join("planning-result.json");
    let result_mtime = std::fs::metadata(&result_path)
        .and_then(|m| m.modified())
        .ok()?;
    if let Ok(queue_mtime) = std::fs::metadata(ws.queue_path()).and_then(|m| m.modified()) {
        if result_mtime <= queue_mtime {
            // Already applied (or superseded by newer work): retire it quietly.
            mark_consumed(&run_dir);
            return None;
        }
    }

    let raw = std::fs::read_to_string(&result_path).ok()?;
    let plan: PlanningResult = serde_json::from_str(&raw).ok()?;
    if plan.tasks.is_empty() {
        mark_consumed(&run_dir); // unusable; don't retry forever
        return None;
    }
    let meta: PlanMeta = state::load_yaml(&run_dir.join("plan-meta.yaml"))
        .ok()
        .or_else(|| legacy_plan_meta(&run_dir))
        .unwrap_or_default();

    if meta.mode == "amend" {
        let mut queue = ws.load_queue().ok()?;
        let added = append_plan_tasks(&mut queue, &plan);
        ws.save_queue(&queue).ok()?;
        if let Ok(Some(mut intent)) = ws.load_intent() {
            if !plan.summary.trim().is_empty() {
                intent.summary =
                    format!("{}\n\n[follow-up] {}", intent.summary, plan.summary.trim());
                let _ = state::save_yaml(&ws.intent_path(), &intent);
            }
        }
        mark_consumed(&run_dir);
        return Some(format!(
            "recovered interrupted follow-up plan ({run_id}): +{added} task(s)"
        ));
    }

    if plan.summary.trim().is_empty() {
        mark_consumed(&run_dir);
        return None;
    }
    let intent_id = format!("intent-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let intent = build_intent(&intent_id, &meta.request, &plan, &[]);
    let queue = build_queue(&intent_id, &plan);
    let _ = crate::report::archive_intent(ws);
    state::save_yaml(&ws.intent_path(), &intent).ok()?;
    ws.save_queue(&queue).ok()?;
    mark_consumed(&run_dir);
    Some(format!(
        "recovered interrupted plan ({run_id}): {} ({} tasks)",
        intent.summary,
        queue.tasks.len()
    ))
}

fn build_intent(
    intent_id: &str,
    request: &str,
    plan: &PlanningResult,
    images: &[String],
) -> IntentContract {
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
        images: images.to_vec(),
        status: "accepted".to_string(),
    }
}

fn build_queue(intent_id: &str, plan: &PlanningResult) -> WorkQueue {
    let mut tasks: Vec<Task> = Vec::with_capacity(plan.tasks.len());
    for (i, t) in plan.tasks.iter().enumerate() {
        let prior_ids: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
        tasks.push(Task {
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
            model: t.model.clone(),
            effort: t.effort.clone(),
            depends_on: sanitize_deps(&t.depends_on, &prior_ids),
            allowed_scope: t.allowed_scope.clone(),
            acceptance: t
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: t.worker_rationale.clone(),
        });
    }

    WorkQueue {
        schema_version: 1,
        queue_id: format!("queue-{intent_id}"),
        intent_id: intent_id.to_string(),
        selection_policy: SelectionPolicy::default(),
        tasks,
    }
}

/// Build the planner's worker-selection rubric from the editable profiles.
fn build_worker_guidance(workers: &WorkersFile) -> String {
    let mut g = format!("Cost bias: {}.\n", workers.routing.cost_bias);
    for w in &workers.workers {
        if w.best_for.is_empty() {
            continue;
        }
        let cost = if w.cost_weight.is_empty() {
            "?"
        } else {
            &w.cost_weight
        };
        g.push_str(&format!("- {}: {} (cost: {})\n", w.id, w.best_for, cost));
    }
    g
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
    let pg = &workers.routing.planning_gate;
    for v in [&pg.primary, &pg.fallback] {
        if !v.is_empty() && v != "none" {
            order.push(v.clone());
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
        if !profile.enabled {
            continue;
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    // Regression: a worker emitted `questions_for_user` as objects
    // ({id, question, topic}) mirroring the `acceptance` hint, which used to
    // crash serde with `invalid type: map, expected a string`. Accept both
    // object and string shapes and extract the human-readable text.
    #[test]
    fn questions_accept_object_or_string_shape() {
        let json = r#"{
            "summary": "do a thing",
            "tasks": [{ "id": "YARD-001", "title": "t" }],
            "questions_for_user": [
                { "id": "Q1", "question": "scope ok?", "topic": "scope" },
                "plain string question",
                { "id": "Q2", "statement": "fallback to statement" }
            ]
        }"#;
        let plan: PlanningResult =
            serde_json::from_str(json).expect("both question shapes must parse");
        let qs: Vec<String> = plan
            .questions_for_user
            .into_iter()
            .map(PlanQuestion::into_text)
            .collect();
        assert_eq!(
            qs,
            vec![
                "scope ok?".to_string(),
                "plain string question".to_string(),
                "fallback to statement".to_string(),
            ]
        );
    }

    #[test]
    fn recovers_unconsumed_plan_after_restart() {
        let root = std::env::temp_dir().join(format!("yard-planrec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let run_dir = ws.runs_dir().join("plan-20990101-000000");
        std::fs::create_dir_all(&run_dir).unwrap();
        state::save_yaml(
            &run_dir.join("plan-meta.yaml"),
            &PlanMeta {
                mode: "new".into(),
                request: "add admin search".into(),
            },
        )
        .unwrap();
        write_str(
            &run_dir.join("planning-result.json"),
            r#"{ "summary": "admin search",
                 "tasks": [{ "id": "YARD-001", "title": "t" }] }"#,
        )
        .unwrap();

        // First startup after the crash: the plan is consumed into canonical state.
        let msg = recover_unconsumed_plan(&ws).expect("plan should be recovered");
        assert!(msg.contains("admin search"));
        let queue = ws.load_queue().unwrap();
        assert_eq!(queue.tasks.len(), 1);
        let intent = ws.load_intent().unwrap().unwrap();
        assert_eq!(intent.raw_request, "add admin search");

        // Second startup: marked consumed, nothing to do.
        assert!(recover_unconsumed_plan(&ws).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn superseded_plan_is_never_recovered_over_a_newer_one() {
        // An orphaned planning worker can finish AFTER the user has already
        // planned (and consumed) something newer. Recovering the stale plan
        // would clobber the live intent/queue — it must be retired instead.
        let root = std::env::temp_dir().join(format!("yard-stale-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);

        // Newer plan: already consumed (the user's current work).
        let newer = ws.runs_dir().join("plan-20990202-000000");
        std::fs::create_dir_all(&newer).unwrap();
        write_str(&newer.join("planning-result.json"), "{}").unwrap();
        write_str(&newer.join(CONSUMED_MARKER), "").unwrap();
        ws.save_queue(&WorkQueue {
            schema_version: 1,
            queue_id: "q".into(),
            intent_id: "live".into(),
            selection_policy: Default::default(),
            tasks: vec![],
        })
        .unwrap();

        // Older plan: finished late by an orphaned worker, never consumed.
        // Its result file is NEWER than the queue on disk (written just now).
        let stale = ws.runs_dir().join("plan-20990101-000000");
        std::fs::create_dir_all(&stale).unwrap();
        state::save_yaml(
            &stale.join("plan-meta.yaml"),
            &PlanMeta {
                mode: "new".into(),
                request: "old request".into(),
            },
        )
        .unwrap();
        write_str(
            &stale.join("planning-result.json"),
            r#"{ "summary": "stale plan",
                 "tasks": [{ "id": "YARD-001", "title": "t" }] }"#,
        )
        .unwrap();

        assert!(recover_unconsumed_plan(&ws).is_none());
        // The live queue was not replaced, and the stale plan is retired.
        assert_eq!(ws.load_queue().unwrap().intent_id, "live");
        assert!(stale.join(CONSUMED_MARKER).exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn reports_a_still_running_planning_worker() {
        let root = std::env::temp_dir().join(format!("yard-liveplan-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let dir = ws.runs_dir().join("plan-20990101-000000");
        std::fs::create_dir_all(&dir).unwrap();
        // No result yet, but the worker (our own pid) is alive.
        write_str(&dir.join("worker.pid"), &std::process::id().to_string()).unwrap();
        let msg = recover_unconsumed_plan(&ws).expect("live planner should be reported");
        assert!(msg.contains("still running"), "{msg}");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovers_legacy_plan_without_meta_file() {
        // Plan dirs created before plan-meta.yaml existed: reconstruct the
        // request (and mode) from the compiled packet.
        let root = std::env::temp_dir().join(format!("yard-planrec-legacy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let run_dir = ws.runs_dir().join("plan-20990101-000000");
        std::fs::create_dir_all(&run_dir).unwrap();
        write_str(
            &workers::packet_path(&run_dir),
            "# Yard planning gate\n\n## Request (verbatim)\n\n\
             make the game feel like a game\n\n## Rules\n\n- ...\n",
        )
        .unwrap();
        write_str(
            &run_dir.join("planning-result.json"),
            r#"{ "summary": "game feel",
                 "tasks": [{ "id": "YARD-101", "title": "t" }] }"#,
        )
        .unwrap();

        let msg = recover_unconsumed_plan(&ws).expect("legacy plan should be recovered");
        assert!(msg.contains("game feel"));
        let intent = ws.load_intent().unwrap().unwrap();
        assert_eq!(intent.raw_request, "make the game feel like a game");
        assert!(recover_unconsumed_plan(&ws).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn queue_keeps_only_backward_dependencies() {
        let json = r#"{
            "summary": "do a thing",
            "tasks": [
                { "id": "YARD-001", "title": "a" },
                { "id": "YARD-002", "title": "b",
                  "depends_on": ["YARD-001", "YARD-002", "YARD-003", "NOPE"] },
                { "id": "YARD-003", "title": "c", "depends_on": ["YARD-001"] }
            ]
        }"#;
        let plan: PlanningResult = serde_json::from_str(json).unwrap();
        let q = build_queue("intent-x", &plan);
        assert!(q.tasks[0].depends_on.is_empty());
        // self-reference, forward reference, and unknown id are all dropped
        assert_eq!(q.tasks[1].depends_on, vec!["YARD-001".to_string()]);
        assert_eq!(q.tasks[2].depends_on, vec!["YARD-001".to_string()]);
    }
}
