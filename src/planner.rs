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
    ambiguity: PlanAmbiguity,
    #[serde(default)]
    tasks: Vec<PlanTask>,
    #[serde(default)]
    questions_for_user: Vec<PlanQuestion>,
}

#[derive(Debug, Default, Deserialize)]
struct PlanAmbiguity {
    #[serde(default)]
    score: String,
    #[serde(default)]
    open_questions: Vec<String>,
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
    skills: Vec<String>,
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

/// Express lane (P2): skip the planning worker entirely and lay down a tiny
/// deterministic queue for a single goal. Builds task T1 (do the goal) and,
/// when a verify condition is given, a separate T2 (a reviewer that checks the
/// condition against the workspace — the verifier is never the doer). No
/// ambiguity gate (you accepted the goal by typing it). Returns the queue size.
pub fn plan_goal(
    ws: &Workspace,
    goal: &str,
    verify: Option<&str>,
    worker_override: Option<&str>,
) -> Result<usize> {
    let goal = goal.trim();
    if goal.is_empty() {
        bail!("describe the goal, e.g. `yard goal \"fix the login redirect\"`");
    }
    let intent_id = format!("intent-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let worker = worker_override.unwrap_or("").to_string();

    let mut tasks = vec![Task {
        id: "YARD-001".to_string(),
        title: goal.chars().take(80).collect(),
        state: TaskState::Queued,
        priority: 10,
        risk: "low".to_string(),
        kind: "implementation".to_string(),
        preferred_worker: worker.clone(),
        model: String::new(),
        effort: String::new(),
        depends_on: vec![],
        skills: vec![],
        allowed_scope: vec![],
        acceptance: vec![yaml::Value::String(goal.to_string())],
        validation: None,
        approval: None,
        interaction: None,
        worker_rationale: Some("express goal (yard goal)".to_string()),
    }];

    if let Some(v) = verify.map(str::trim).filter(|v| !v.is_empty()) {
        // A separate reviewer task: a fresh pair of eyes, not the worker that
        // did the work. For visual goals this picks up the ui-review /
        // browser-evidence skills and must cite screenshot evidence.
        tasks.push(Task {
            id: "YARD-002".to_string(),
            title: "Verify the goal".to_string(),
            state: TaskState::Queued,
            priority: 20,
            risk: "low".to_string(),
            kind: "review".to_string(),
            preferred_worker: String::new(),
            model: String::new(),
            effort: String::new(),
            depends_on: vec!["YARD-001".to_string()],
            skills: vec![],
            allowed_scope: vec![],
            acceptance: vec![yaml::Value::String(format!(
                "Verify against the actual workspace, with evidence: {v}"
            ))],
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: Some("verifier is never the doer".to_string()),
        });
    }

    let intent = IntentContract {
        schema_version: 1,
        id: intent_id.clone(),
        source: "user".to_string(),
        raw_request: goal.to_string(),
        summary: goal.to_string(),
        allowed_scope: vec![],
        out_of_scope: vec![],
        acceptance: verify
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(|v| vec![yaml::Value::String(v.to_string())])
            .unwrap_or_default(),
        images: vec![],
        ambiguity: "low".to_string(),
        open_questions: vec![],
        clarifications: vec![],
        interview_turns: 0,
        status: "accepted".to_string(),
    };
    let queue = WorkQueue {
        schema_version: 1,
        queue_id: format!("queue-{intent_id}"),
        intent_id,
        selection_policy: SelectionPolicy::default(),
        tasks,
    };
    let task_count = queue.tasks.len();
    let _ = crate::report::archive_intent(ws);
    state::save_yaml(&ws.intent_path(), &intent)?;
    ws.save_queue(&queue)?;
    let _ = crate::skills::auto_equip(ws, &inspect::summarize(&ws.root));
    Ok(task_count)
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

    // Images: explicit --image plus any path detected in the request.
    let mut images: Vec<String> = explicit_images.to_vec();
    for d in packet::detect_images(request, &ws.root) {
        if !images.contains(&d) {
            images.push(d);
        }
    }

    plan_core(
        ws,
        &workers,
        &billing,
        &config,
        request,
        request,
        &images,
        worker_override,
        "new",
        true,
    )
}

/// Hard cap on interview turns; past it the gate opens (proceed on
/// recorded assumptions).
pub const INTERVIEW_CAP: u32 = 10;

/// Is this intent still gated on the planner's own ambiguity self-report?
pub fn intent_gated(intent: &IntentContract, gate_enabled: bool) -> bool {
    gate_enabled
        && intent.ambiguity == "high"
        && intent.interview_turns < INTERVIEW_CAP
        && !intent.open_questions.is_empty()
}

/// One interview turn (absorption.md A2): feed the user's answer back to the
/// planning worker and derive a REVISED plan in place — same intent id, no
/// archive (this is the same intent being refined before any work starts).
/// The new plan re-scores ambiguity; the gate opens when it drops below
/// "high", the user overrides, or `INTERVIEW_CAP` turns have run.
pub fn run_planning_interview(ws: &Workspace, answer: &str) -> Result<PlanningReport> {
    let Some(prev) = ws.load_intent()? else {
        bail!("no intent to interview \u{2014} plan first (n)");
    };
    let queue = ws.load_queue()?;
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;

    let turns = prev.interview_turns + 1;
    let mut clarifications = prev.clarifications.clone();
    clarifications.push(format!(
        "Q: {}\nA: {}",
        prev.open_questions.join(" / "),
        answer.trim()
    ));

    let mut ctx = String::new();
    ctx.push_str(&format!("Original request:\n{}\n\n", prev.raw_request));
    ctx.push_str(&format!("Current plan summary: {}\n", prev.summary));
    if !queue.tasks.is_empty() {
        ctx.push_str("Current planned tasks (revise them freely):\n");
        for t in &queue.tasks {
            ctx.push_str(&format!("- {} {}\n", t.id, t.title));
        }
    }
    ctx.push_str("\nInterview so far:\n");
    for c in &clarifications {
        ctx.push_str(c);
        ctx.push_str("\n---\n");
    }
    ctx.push_str(&format!(
        "\nThis is interview turn {turns}/{cap}. RE-PLAN the whole intent with these \
         answers folded in: revise the summary, scope, acceptance, and tasks as needed. \
         Re-score `ambiguity` honestly \u{2014} drop it below \"high\" only when you are no \
         longer guessing about product behavior or architecture. If something essential \
         is still unclear, ask up to 3 NEW questions (never repeat an answered one).",
        cap = INTERVIEW_CAP
    ));

    let report = plan_core(
        ws,
        &workers,
        &billing,
        &config,
        &ctx,
        &prev.raw_request,
        &prev.images,
        None,
        "interview",
        false,
    )?;

    // plan_core derived a fresh intent; restore identity + interview bookkeeping.
    if let Some(mut intent) = ws.load_intent()? {
        intent.id = prev.id.clone();
        intent.raw_request = prev.raw_request.clone();
        intent.clarifications = clarifications;
        intent.interview_turns = turns;
        state::save_yaml(&ws.intent_path(), &intent)?;
        let mut q = ws.load_queue()?;
        q.intent_id = prev.id.clone();
        q.queue_id = format!("queue-{}", prev.id);
        ws.save_queue(&q)?;
    }
    Ok(report)
}

/// The planning machinery shared by fresh plans and interview re-plans.
/// `packet_request` goes to the worker; `store_request` is recorded as the
/// intent's raw request; `archive` controls whether the previous intent is
/// archived first (interview refines in place).
#[allow(clippy::too_many_arguments)]
fn plan_core(
    ws: &Workspace,
    workers: &WorkersFile,
    billing: &crate::schemas::BillingPolicy,
    config: &crate::schemas::YardConfig,
    packet_request: &str,
    store_request: &str,
    images: &[String],
    worker_override: Option<&str>,
    mode: &str,
    archive: bool,
) -> Result<PlanningReport> {
    let language = packet::resolve_language(&config.language, store_request);

    // Choose a ready planning worker.
    let (profile, bin, worker_id) = pick_ready_worker(workers, billing, worker_override)?;

    let run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");
    state::save_yaml(
        &run_dir.join("plan-meta.yaml"),
        &PlanMeta {
            mode: mode.to_string(),
            request: store_request.to_string(),
        },
    )?;

    let mut lines = Vec::new();

    // Evidence + packet.
    let summary = inspect::summarize(&ws.root);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    // Auto-equip skills for this repo's detected presets before compiling the
    // packet, so the catalog the planner sees already includes them (S1).
    let equipped = crate::skills::auto_equip(ws, &summary);
    if !equipped.is_empty() {
        lines.push(format!("equipped skills: {}", equipped.join(", ")));
    }
    let pruned = crate::skills::auto_prune(ws);
    if !pruned.is_empty() {
        lines.push(format!("pruned weak skills: {}", pruned.join(", ")));
    }
    let worker_guidance = build_worker_guidance(workers);
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let packet_text = packet::compile_planning(
        packet_request,
        &summary,
        &run_dir_rel,
        &language,
        &worker_guidance,
        images,
        &harness,
        &worker_id,
    );
    write_str(&workers::packet_path(&run_dir), &packet_text)?;

    // For a fresh plan, archive the previous intent and CLEAR the queue now,
    // before the worker runs — otherwise the Home screen shows the old queue
    // for the whole planning run, which reads as stale. (Interview/amend keep
    // the live queue; they refine it in place.)
    if archive {
        let _ = crate::report::archive_intent(ws);
        let _ = ws.save_queue(&WorkQueue {
            schema_version: 1,
            queue_id: "planning".to_string(),
            intent_id: String::new(),
            selection_policy: SelectionPolicy::default(),
            tasks: Vec::new(),
        });
    }

    // Invoke the worker with a sanitized environment.
    let env = guard::sanitized_worker_env_for(billing, &profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
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
        images,
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
    let intent = build_intent(&intent_id, store_request, &plan, images);
    let queue = build_queue(&intent_id, &plan);

    // (Fresh plans already archived + cleared the prior queue before the
    // worker ran; here we just write the new canonical state.)
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
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let packet_text = packet::compile_planning(
        &ctx,
        &summary,
        &run_dir_rel,
        &language,
        &worker_guidance,
        &images,
        &harness,
        &worker_id,
    );
    write_str(&workers::packet_path(&run_dir), &packet_text)?;
    let env = guard::sanitized_worker_env_for(&billing, &profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
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
            skills: pt.skills.clone(),
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
    // The gate reads one merged question list: the planner's explicit
    // questions_for_user plus whatever its ambiguity block still holds open.
    let mut open_questions: Vec<String> = plan
        .questions_for_user
        .iter()
        .map(|q| match q {
            PlanQuestion::Text(s) => s.clone(),
            PlanQuestion::Obj {
                question,
                statement,
            } => {
                if !question.trim().is_empty() {
                    question.clone()
                } else {
                    statement.clone()
                }
            }
        })
        .filter(|q| !q.trim().is_empty())
        .collect();
    for q in &plan.ambiguity.open_questions {
        if !q.trim().is_empty() && !open_questions.contains(q) {
            open_questions.push(q.clone());
        }
    }
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
        ambiguity: plan.ambiguity.score.to_lowercase(),
        open_questions,
        clarifications: Vec::new(),
        interview_turns: 0,
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
            skills: t.skills.clone(),
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

    ensure_review_task(&mut tasks);

    WorkQueue {
        schema_version: 1,
        queue_id: format!("queue-{intent_id}"),
        intent_id: intent_id.to_string(),
        selection_policy: SelectionPolicy::default(),
        tasks,
    }
}

/// The Semantic verification rung (absorption.md A3), as a deterministic
/// guarantee: a risky plan (any high-risk task) or a sizable one (3+ tasks)
/// must end in a review-kind task that verifies the intent's acceptance
/// criteria against the actual workspace. The planner is asked to include
/// one; if it forgot, Yard appends it — planner forgetfulness cannot skip
/// verification, and the verifier is never the doer (a separate reviewer-
/// role run, not a smarter evaluator).
fn ensure_review_task(tasks: &mut Vec<Task>) {
    let risky = tasks.iter().any(|t| t.risk.eq_ignore_ascii_case("high"));
    let sizable = tasks.len() >= 3;
    let has_review = tasks.iter().any(|t| t.kind.eq_ignore_ascii_case("review"));
    if !(risky || sizable) || has_review || tasks.is_empty() {
        return;
    }
    let next_num = tasks
        .iter()
        .filter_map(|t| {
            t.id.strip_prefix("YARD-")
                .and_then(|n| n.parse::<usize>().ok())
        })
        .max()
        .unwrap_or(tasks.len())
        + 1;
    let depends_on: Vec<String> = tasks.iter().map(|t| t.id.clone()).collect();
    let priority = tasks.iter().map(|t| t.priority).max().unwrap_or(0) + 10;
    tasks.push(Task {
        id: format!("YARD-{next_num:03}"),
        title: "Acceptance review (auto-added)".to_string(),
        state: TaskState::Queued,
        priority,
        risk: "low".to_string(),
        kind: "review".to_string(),
        preferred_worker: String::new(), // routing decides (kind overrides apply)
        model: String::new(),
        effort: String::new(),
        depends_on,
        skills: vec![],
        allowed_scope: vec![],
        acceptance: vec![yaml::Value::String(
            "Every intent acceptance criterion is verified against the actual workspace, \
             with per-criterion pass/fail and evidence in report.md"
                .to_string(),
        )],
        validation: None,
        approval: None,
        interaction: None,
        worker_rationale: Some(
            "deterministic semantic-verification rung: the verifier is never the doer".to_string(),
        ),
    });
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
    fn review_task_is_guaranteed_for_risky_or_sizable_plans() {
        let plan = |n: usize, risk: &str, with_review: bool| -> WorkQueue {
            let mut json_tasks: Vec<String> = (1..=n)
                .map(|i| {
                    format!(
                        r#"{{ "id": "YARD-{i:03}", "title": "t{i}", "risk": "{risk}", "kind": "implementation" }}"#
                    )
                })
                .collect();
            if with_review {
                json_tasks.push(
                    r#"{ "id": "YARD-099", "title": "review", "kind": "review" }"#.to_string(),
                );
            }
            let json = format!(
                r#"{{ "summary": "s", "tasks": [{}] }}"#,
                json_tasks.join(",")
            );
            let p: PlanningResult = serde_json::from_str(&json).unwrap();
            build_queue("i", &p)
        };

        // High risk, single task: review appended with deps on everything.
        let q = plan(1, "high", false);
        assert_eq!(q.tasks.len(), 2);
        let review = q.tasks.last().unwrap();
        assert_eq!(review.kind, "review");
        assert_eq!(review.id, "YARD-002");
        assert_eq!(review.depends_on, vec!["YARD-001"]);

        // 3+ tasks, all low risk: appended too.
        let q = plan(3, "low", false);
        assert_eq!(q.tasks.len(), 4);
        assert_eq!(
            q.tasks.last().unwrap().depends_on,
            vec!["YARD-001", "YARD-002", "YARD-003"]
        );

        // Planner already included a review: nothing added.
        let q = plan(3, "high", true);
        assert_eq!(q.tasks.iter().filter(|t| t.kind == "review").count(), 1);

        // Small low-risk plan: no forced ceremony.
        let q = plan(2, "low", false);
        assert_eq!(q.tasks.len(), 2);
    }

    #[test]
    fn goal_builds_a_two_task_queue_with_a_separate_verifier() {
        let root = std::env::temp_dir().join(format!("yard-goal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);

        // No verify: a single implementation task, no ambiguity gate.
        let n = plan_goal(&ws, "fix the login redirect", None, None).unwrap();
        assert_eq!(n, 1);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks.len(), 1);
        assert_eq!(q.tasks[0].kind, "implementation");
        let intent = ws.load_intent().unwrap().unwrap();
        assert_eq!(intent.ambiguity, "low");
        assert!(!intent_gated(&intent, true));

        // With verify: a second reviewer task depends on the first.
        let n = plan_goal(
            &ws,
            "polish the title screen",
            Some("no clipped text and the theme is consistent"),
            None,
        )
        .unwrap();
        assert_eq!(n, 2);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[1].kind, "review");
        assert_eq!(q.tasks[1].depends_on, vec!["YARD-001"]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ambiguity_gate_logic() {
        let mut intent = IntentContract {
            schema_version: 1,
            id: "i".into(),
            source: String::new(),
            raw_request: String::new(),
            summary: String::new(),
            allowed_scope: vec![],
            out_of_scope: vec![],
            acceptance: vec![],
            images: vec![],
            ambiguity: "high".into(),
            open_questions: vec!["which auth provider?".into()],
            clarifications: vec![],
            interview_turns: 0,
            status: String::new(),
        };
        assert!(intent_gated(&intent, true));
        assert!(!intent_gated(&intent, false)); // config off
        intent.ambiguity = "medium".into();
        assert!(!intent_gated(&intent, true)); // only high gates
        intent.ambiguity = "high".into();
        intent.interview_turns = INTERVIEW_CAP;
        assert!(!intent_gated(&intent, true)); // cap opens the gate
        intent.interview_turns = 0;
        intent.open_questions.clear();
        assert!(!intent_gated(&intent, true)); // nothing to ask = no gate
    }

    #[test]
    fn intent_records_planner_ambiguity_and_questions() {
        let json = r#"{
            "summary": "s",
            "tasks": [{ "id": "YARD-001", "title": "t" }],
            "ambiguity": { "score": "HIGH", "open_questions": ["q1", "q2"] },
            "questions_for_user": ["q1", "q3"]
        }"#;
        let plan: PlanningResult = serde_json::from_str(json).unwrap();
        let intent = build_intent("i", "req", &plan, &[]);
        assert_eq!(intent.ambiguity, "high");
        // merged + deduped: questions_for_user first, then ambiguity extras
        assert_eq!(intent.open_questions, vec!["q1", "q3", "q2"]);
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
