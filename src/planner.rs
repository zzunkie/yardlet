//! Planning gate.
//!
//! Turns a short natural-language request into canonical state: a worker writes
//! a structured `planning-result.json`, and Yardlet derives the
//! `intent-contract.yaml` + `work-queue.yaml` from it. Yardlet owns the canonical
//! files; the worker only authors plan content.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::Deserialize;

use crate::guard::{self, Readiness};
use crate::inspect;
use crate::schemas::{
    IntentContract, PlanningDraftContent, PlanningSession, PlanningTurnCas, SelectionPolicy, Task,
    TaskGoal, TaskState, WorkQueue, WorkerProfile, WorkersFile,
};
use crate::state::{self, write_str, PlanningWorkerConfig, Workspace};
use crate::{packet, workers, yaml};

// ---- worker-authored plan shape -------------------------------------------

#[derive(Debug, Default, Deserialize)]
struct PlanningResult {
    #[serde(default)]
    summary: String,
    #[serde(default)]
    rationale: String,
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
    required_capabilities: Vec<String>,
    #[serde(default)]
    allowed_scope: Vec<String>,
    #[serde(default)]
    acceptance: Vec<String>,
    #[serde(default)]
    goal: Option<TaskGoal>,
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
/// human-readable text — Yardlet surfaces just the question string.
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
    #[serde(default)]
    schema_version: u32,
    mode: String, // "new" | "amend"
    #[serde(default)]
    request: String,
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    expected_head: Option<String>,
    #[serde(default)]
    request_event_id: String,
    #[serde(default)]
    request_digest: String,
}

/// Marker file written into a plan run dir once Yardlet has derived the canonical
/// intent/queue from its result. Absent + result present = unconsumed.
const CONSUMED_MARKER: &str = "consumed";

fn mark_consumed(run_dir: &std::path::Path) -> Result<()> {
    state::write_str_atomic(&run_dir.join(CONSUMED_MARKER), "")
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
        schema_version: 1,
        mode: mode.to_string(),
        request,
        session_id: String::new(),
        expected_head: None,
        request_event_id: String::new(),
        request_digest: String::new(),
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
    pub session_id: String,
    pub proposal_id: String,
    pub semantic_diff_fields: Vec<String>,
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
    required_capabilities: &[String],
) -> Result<usize> {
    let goal = goal.trim();
    if goal.is_empty() {
        bail!("describe the goal, e.g. `yardlet goal \"fix the login redirect\"`");
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
        required_capabilities: required_capabilities.to_vec(),
        allowed_scope: vec![],
        acceptance: vec![yaml::Value::String(goal.to_string())],
        goal: Some(TaskGoal {
            condition: goal.to_string(),
            max_feedback_cycles: 2,
            feedback_policy: "inject_failed_checks".to_string(),
        }),
        validation: None,
        approval: None,
        interaction: None,
        worker_rationale: Some("express goal (yardlet goal)".to_string()),
        provenance: String::new(),
    }];
    // Express goals bypass the planner, so capability routing is explicit (no
    // magic keywords): pass `--requires <capability>` for a hard route, or
    // `--worker` to force a specific worker.

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
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![yaml::Value::String(format!(
                "Verify against the actual workspace, with evidence: {v}"
            ))],
            goal: Some(TaskGoal {
                condition: v.to_string(),
                max_feedback_cycles: 2,
                feedback_policy: "inject_failed_checks".to_string(),
            }),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: Some("verifier is never the doer".to_string()),
            provenance: String::new(),
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
    let mut queue = WorkQueue {
        schema_version: 1,
        queue_id: format!("queue-{intent_id}"),
        intent_id,
        selection_policy: SelectionPolicy::default(),
        tasks,
    };
    crate::skills::project_task_skills_with_context(
        ws,
        &inspect::summarize(&ws.root),
        &mut queue.tasks,
        goal,
    )?;
    let task_count = queue.tasks.len();
    crate::planning::activate_express_draft(ws, goal, PlanningDraftContent { intent, queue })?;
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
    let (session, turn) = crate::planning::begin_user_turn_exact(ws, request)?;
    run_planning_turn(ws, request, worker_override, explicit_images, session, turn)
}

pub fn run_planning_recorded_turn(
    ws: &Workspace,
    request: &str,
    worker_override: Option<&str>,
    explicit_images: &[String],
    session: PlanningSession,
    turn: PlanningTurnCas,
) -> Result<PlanningReport> {
    run_planning_turn(ws, request, worker_override, explicit_images, session, turn)
}

fn run_planning_turn(
    ws: &Workspace,
    request: &str,
    worker_override: Option<&str>,
    explicit_images: &[String],
    session: PlanningSession,
    turn: PlanningTurnCas,
) -> Result<PlanningReport> {
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;
    let packet_request = crate::planning::worker_turn_context(ws, &session, request)?;

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
        &packet_request,
        &session.initial_request,
        &images,
        worker_override,
        "new",
        false,
        Some(&session),
        Some(&turn),
    )
}

/// Hard cap on interview turns; past it the gate opens (proceed on
/// recorded assumptions).
pub const INTERVIEW_CAP: u32 = 10;

fn planning_repo_summary(ws: &Workspace) -> crate::inspect::RepoSummary {
    inspect::summarize(&ws.root).for_planning()
}

fn planning_intent_context(
    ws: &Workspace,
    archive_previous: bool,
) -> Result<Option<IntentContract>> {
    if archive_previous {
        Ok(None)
    } else {
        ws.load_intent()
    }
}

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
    if crate::planning::active_is_confirmed_or_running(ws)? {
        bail!("confirmed or running queue rejects free-form planning mutation");
    }
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
        None,
        None,
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
    planning_session: Option<&PlanningSession>,
    planning_turn: Option<&PlanningTurnCas>,
) -> Result<PlanningReport> {
    let language = packet::resolve_language(&config.language, store_request);
    let planning_config = ws.load_planning_worker_config()?;

    // Choose a ready planning worker.
    let (base_profile, bin, worker_id) = pick_ready_worker(workers, billing, worker_override)?;
    let profile = planning_worker_profile(&base_profile, &planning_config);

    let base_run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");
    state::save_yaml(
        &run_dir.join("plan-meta.yaml"),
        &PlanMeta {
            schema_version: planning_turn.map_or(1, |_| 2),
            mode: mode.to_string(),
            request: store_request.to_string(),
            session_id: planning_turn
                .map(|turn| turn.session_id.clone())
                .unwrap_or_default(),
            expected_head: planning_turn.and_then(|turn| turn.expected_head.clone()),
            request_event_id: planning_turn
                .map(|turn| turn.request_event_id.clone())
                .unwrap_or_default(),
            request_digest: planning_turn
                .map(|turn| turn.request_digest.clone())
                .unwrap_or_default(),
        },
    )?;

    let mut lines = Vec::new();

    // Evidence + packet.
    let summary = planning_repo_summary(ws);
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
    let request_classification = crate::skills::classify_repo(&summary, packet_request);
    let request_overlays =
        crate::skills::detect_overlay_skills(packet_request, &request_classification);
    let activated = crate::skills::ensure_builtin_names(ws, &request_overlays)?;
    if !activated.is_empty() {
        lines.push(format!(
            "activated built-in overlays: {}",
            activated.join(", ")
        ));
    }
    let pruned = crate::skills::auto_prune(ws);
    if !pruned.is_empty() {
        lines.push(format!("pruned weak skills: {}", pruned.join(", ")));
    }
    let worker_guidance = build_worker_guidance(workers);
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let current_intent = if let Some(session) = planning_session {
        crate::planning::current_draft(ws, session)?.map(|draft| draft.content.intent)
    } else {
        planning_intent_context(ws, archive)?
    };
    let packet_text = packet::compile_planning(
        packet_request,
        current_intent.as_ref(),
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
    if archive && planning_session.is_none() {
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
        &run_dir,
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

    // Derive canonical state. Yardlet owns these files.
    let intent_id = planning_session
        .map(|session| session.intent_id.clone())
        .unwrap_or_else(|| format!("intent-{}", Local::now().format("%Y%m%d-%H%M%S")));
    let intent = build_intent(&intent_id, store_request, &plan, images);
    let mut queue = build_queue(&intent_id, &plan);
    crate::skills::project_task_skills_with_context(ws, &summary, &mut queue.tasks, store_request)?;
    // Ground capabilities against the real workers at creation: a task needing a
    // capability no worker has is parked now, not crashed into at run time.
    let parked = reconcile_queue_capabilities(&mut queue, workers);
    if !parked.is_empty() {
        lines.push(format!(
            "parked (no worker for required capability): {}",
            parked.join(", ")
        ));
    }

    let proposal = if let (Some(session), Some(turn)) = (planning_session, planning_turn) {
        if session.session_id != turn.session_id {
            bail!("planning session and turn CAS identity mismatch");
        }
        Some(crate::planning::record_worker_proposal(
            ws,
            turn,
            &worker_id,
            &run_id,
            &plan.summary,
            if plan.rationale.trim().is_empty() {
                "planning worker proposed a complete replacement draft"
            } else {
                plan.rationale.trim()
            },
            PlanningDraftContent {
                intent: intent.clone(),
                queue: queue.clone(),
            },
        )?)
    } else {
        state::save_yaml(&ws.intent_path(), &intent)?;
        ws.save_queue(&queue)?;
        None
    };
    mark_consumed(&run_dir)?;

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
        session_id: planning_session
            .map(|session| session.session_id.clone())
            .unwrap_or_default(),
        proposal_id: proposal
            .as_ref()
            .map(|proposal| proposal.proposal_id.clone())
            .unwrap_or_default(),
        semantic_diff_fields: proposal
            .as_ref()
            .map(|proposal| {
                proposal
                    .semantic_diff
                    .iter()
                    .map(|entry| entry.field.clone())
                    .collect()
            })
            .unwrap_or_default(),
    })
}

/// Amend the current intent with follow-up tasks: keep the existing (done) work
/// and append new tasks derived from the user's continue request + the existing
/// context. Does not overwrite or archive — it extends the live queue.
pub fn run_planning_amend(ws: &Workspace, request: &str) -> Result<PlanningReport> {
    if crate::planning::active_is_confirmed_or_running(ws)? {
        bail!("confirmed or running queue rejects free-form planning mutation");
    }
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
    let planning_config = ws.load_planning_worker_config()?;
    let language = packet::resolve_language(&config.language, &ctx);
    let images: Vec<String> = Vec::new();
    let (base_profile, bin, worker_id) = pick_ready_worker(&workers, &billing, None)?;
    let profile = planning_worker_profile(&base_profile, &planning_config);
    let base_run_id = format!("plan-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");
    state::save_yaml(
        &run_dir.join("plan-meta.yaml"),
        &PlanMeta {
            schema_version: 1,
            mode: "amend".to_string(),
            request: request.to_string(),
            session_id: String::new(),
            expected_head: None,
            request_event_id: String::new(),
            request_digest: String::new(),
        },
    )?;
    let mut lines = Vec::new();
    let summary = planning_repo_summary(ws);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let worker_guidance = build_worker_guidance(&workers);
    let request_classification = crate::skills::classify_repo(&summary, &ctx);
    let request_overlays = crate::skills::detect_overlay_skills(&ctx, &request_classification);
    crate::skills::ensure_builtin_names(ws, &request_overlays)?;
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let packet_text = packet::compile_planning(
        &ctx,
        existing_intent.as_ref(),
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
        &run_dir,
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
    crate::skills::project_task_skills_with_context(ws, &summary, &mut queue.tasks, &ctx)?;
    // Ground capabilities against the real workers at creation (see run_planning).
    let parked = reconcile_queue_capabilities(&mut queue, &workers);
    if !parked.is_empty() {
        lines.push(format!(
            "parked (no worker for required capability): {}",
            parked.join(", ")
        ));
    }
    ws.save_queue(&queue)?;

    // Note the follow-up in the intent summary (keep the same intent).
    if let Some(mut intent) = existing_intent {
        if !plan.summary.trim().is_empty() {
            intent.summary = format!("{}\n\n[follow-up] {}", intent.summary, plan.summary.trim());
            state::save_yaml(&ws.intent_path(), &intent)?;
        }
    }
    mark_consumed(&run_dir)?;

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
        session_id: String::new(),
        proposal_id: String::new(),
        semantic_diff_fields: Vec::new(),
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
        let task = Task {
            id,
            title: pt.title.clone(),
            state: TaskState::Queued,
            priority: base_priority + ((i + 1) * 10) as i64,
            risk: pt.risk.clone(),
            kind: pt.kind.clone(),
            // Blank stays blank so routing's configured default_worker applies
            // (precedence: planner preferred -> learned rule -> default).
            preferred_worker: pt.preferred_worker.clone(),
            model: pt.model.clone(),
            effort: pt.effort.clone(),
            depends_on: sanitize_deps(&pt.depends_on, &prior_ids),
            skills: pt.skills.clone(),
            required_capabilities: pt.required_capabilities.clone(),
            allowed_scope: pt.allowed_scope.clone(),
            acceptance: pt
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            goal: pt.goal.clone().or_else(|| {
                Some(TaskGoal {
                    condition: pt.acceptance.join("; "),
                    max_feedback_cycles: 2,
                    feedback_policy: "inject_failed_checks".to_string(),
                })
            }),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: pt.worker_rationale.clone(),
            provenance: String::new(),
        };
        queue.tasks.push(task);
    }
    plan.tasks.len()
}

/// Ground every Queued task's `required_capabilities` against the workers that
/// actually exist: normalize the strings and, when a task requires a capability
/// no enabled worker declares, PARK it (Queued -> Blocked) with a note — at
/// queue-creation time, not at run time. Capabilities are free-form text the
/// planner/worker authors; an off-vocab one is either a human-gated need the
/// worker flagged or a typo no worker has, and either way it must not reach
/// routing as a hard failure that stops the drain. We cannot enumerate every
/// capability with an alias table, so the rule is structural: a required
/// capability outside the real worker vocabulary means "no worker can do this"
/// -> park for a human (or a newly added worker). Idempotent; touches only
/// Queued tasks. Returns one `id (caps)` note per task parked.
pub(crate) fn reconcile_queue_capabilities(
    queue: &mut WorkQueue,
    workers: &WorkersFile,
) -> Vec<String> {
    reconcile_queue_capabilities_inner(queue, workers, None)
}

pub(crate) fn reconcile_queue_capabilities_for_ids(
    queue: &mut WorkQueue,
    workers: &WorkersFile,
    task_ids: &[String],
) -> Vec<String> {
    let task_ids = task_ids
        .iter()
        .map(String::as_str)
        .collect::<std::collections::BTreeSet<_>>();
    reconcile_queue_capabilities_inner(queue, workers, Some(&task_ids))
}

fn reconcile_queue_capabilities_inner(
    queue: &mut WorkQueue,
    workers: &WorkersFile,
    task_ids: Option<&std::collections::BTreeSet<&str>>,
) -> Vec<String> {
    let vocab = crate::routing::declared_capabilities(workers);
    let mut parked = Vec::new();
    for t in queue.tasks.iter_mut() {
        if task_ids.is_some_and(|task_ids| !task_ids.contains(t.id.as_str())) {
            continue;
        }
        if t.state != TaskState::Queued || t.required_capabilities.is_empty() {
            continue;
        }
        let normalized: Vec<String> = t
            .required_capabilities
            .iter()
            .map(|c| crate::routing::norm_cap(c))
            .filter(|c| !c.is_empty())
            .collect();
        let unsatisfiable = crate::routing::unsatisfiable_capabilities(&normalized, &vocab);
        t.required_capabilities = normalized;
        if !unsatisfiable.is_empty() {
            t.state = TaskState::Blocked;
            let note = format!(
                "blocked at queue creation: no enabled worker declares required \
                 capability/capabilities [{}] — needs a human decision or a new worker",
                unsatisfiable.join(", ")
            );
            t.worker_rationale = Some(match t.worker_rationale.take() {
                Some(r) if !r.trim().is_empty() => format!("{r}\n{note}"),
                _ => note,
            });
            parked.push(format!("{} ({})", t.id, unsatisfiable.join(", ")));
        }
    }
    parked
}

/// Ingest worker-PROPOSED follow-up tasks into a queue (propose -> ingest).
/// The worker proposes follow-ups in its `result.json`; Yardlet assigns ids,
/// sanitizes deps to backward-only, dedups by title, and tags each
/// `provenance: worker-proposed` so an enqueued follow-up is a visible, tracked
/// CANDIDATE rather than a silent expansion of the current task (CLAUDE.md: an
/// adjacent idea becomes a queue candidate, never a silent scope broadening).
/// Yardlet stays the sole writer of the queue — the worker never edits
/// `.agents/work-queue.yaml` itself.
///
/// Placement: `insert: "next"` slots the task's priority below every currently
/// queued task so the selector prefers it (soft ordering); the default appends
/// after the current max. `runs_before: [ids]` is the HARD form — Yardlet
/// injects a dependency so each named existing task waits for this one (true
/// "insert between"), dropping self/unknown/cycle-forming targets.
///
/// Empty-title entries and titles that duplicate an existing queued task are
/// skipped. Returns the ids of the tasks actually ingested.
pub(crate) fn ingest_follow_ups(
    queue: &mut WorkQueue,
    // Retained for signature stability and future scoped policy; approval gating
    // is now risk/danger-based, not "merely outside the intent scope" (see
    // `follow_up_needs_approval`). A low-risk doc follow-up outside `src/` is NOT
    // gated; a destructive or external-call one is.
    _intent_allowed_scope: &[String],
    follow_ups: &[crate::schemas::FollowUpTask],
    ws: Option<&crate::state::Workspace>,
) -> Vec<String> {
    let mut next_num = queue
        .tasks
        .iter()
        .filter_map(|t| {
            t.id.strip_prefix("YARD-")
                .and_then(|n| n.parse::<usize>().ok())
        })
        .max()
        .unwrap_or(queue.tasks.len())
        + 1;
    let mut tail_priority = queue.tasks.iter().map(|t| t.priority).max().unwrap_or(0);
    // "next" tasks share one priority just below the lowest currently-queued
    // task, so the selector runs them first; equal priorities tie-break by
    // queue order, preserving the worker's proposal order among them.
    let head_priority = queue
        .tasks
        .iter()
        .filter(|t| t.state == TaskState::Queued)
        .map(|t| t.priority)
        .min()
        .map(|m| m - 10)
        .unwrap_or(tail_priority + 10);
    let mut ingested = Vec::new();
    for fu in follow_ups {
        let title = fu.title.trim();
        if title.is_empty() {
            continue;
        }
        // Dedup: skip a follow-up whose title already names a queued task.
        if queue
            .tasks
            .iter()
            .any(|t| t.state == TaskState::Queued && t.title.trim().eq_ignore_ascii_case(title))
        {
            continue;
        }
        let prior_ids: Vec<String> = queue.tasks.iter().map(|t| t.id.clone()).collect();
        let id = format!("YARD-{next_num:03}");
        let priority = if fu.insert.eq_ignore_ascii_case("next") {
            head_priority
        } else {
            tail_priority += 10;
            tail_priority
        };
        // Record the worker's `reason` as the task's rationale when it gave no
        // explicit one — it is the audit trail for why the follow-up exists.
        let rationale = fu.worker_rationale.clone().or_else(|| {
            let r = fu.reason.trim();
            (!r.is_empty()).then(|| format!("worker-proposed follow-up: {r}"))
        });
        // A follow-up that is a HUMAN DECISION (a choice/approval only the user
        // can make) is ingested as NeedsUser with its question seeded into the
        // conversation, and any `required_capabilities` is dropped: the decision
        // is resolved by `yardlet answer`, not routed to a worker that "declares"
        // some invented approval capability (which only parks it Blocked with no
        // clean resolver). Reserve capabilities for a worker's tool/license need.
        let decision = fu.decision_question.trim();
        let is_decision = !decision.is_empty();
        queue.tasks.push(Task {
            id: id.clone(),
            title: title.to_string(),
            state: if is_decision {
                TaskState::NeedsUser
            } else {
                TaskState::Queued
            },
            priority,
            risk: fu.risk.clone(),
            kind: fu.kind.clone(),
            preferred_worker: fu.preferred_worker.clone(),
            model: String::new(),
            effort: String::new(),
            depends_on: sanitize_deps(&fu.depends_on, &prior_ids),
            skills: fu.skills.clone(),
            required_capabilities: if is_decision {
                Vec::new()
            } else {
                fu.required_capabilities.clone()
            },
            allowed_scope: fu.allowed_scope.clone(),
            acceptance: fu
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            goal: Some(TaskGoal {
                condition: fu.acceptance.join("; "),
                max_feedback_cycles: 2,
                feedback_policy: "inject_failed_checks".to_string(),
            }),
            validation: None,
            approval: follow_up_needs_approval(fu).then(risk_based_approval),
            interaction: is_decision.then(|| {
                let mut interaction = serde_yaml_ng::Mapping::new();
                interaction.insert(
                    yaml::Value::String("decision_question".to_string()),
                    yaml::Value::String(decision.to_string()),
                );
                yaml::Value::Mapping(interaction)
            }),
            worker_rationale: rationale,
            provenance: "worker-proposed".to_string(),
        });
        // HARD placement: make each named existing task depend on this new one.
        inject_runs_before(queue, &id, &fu.runs_before);
        ingested.push(id);
        next_num += 1;
    }
    if let Some(ws) = ws {
        let context = ws
            .load_intent()
            .ok()
            .flatten()
            .map(|intent| intent.raw_request)
            .unwrap_or_default();
        let summary = inspect::summarize(&ws.root);
        for id in &ingested {
            if let Some(task) = queue.tasks.iter_mut().find(|task| &task.id == id) {
                let _ = crate::skills::project_task_skills_with_context(
                    ws,
                    &summary,
                    std::slice::from_mut(task),
                    &context,
                );
            }
        }
    }
    ingested
}

pub(crate) fn persist_ingested_decision_questions(
    ws: &crate::state::Workspace,
    queue: &WorkQueue,
    ingested: &[String],
) -> anyhow::Result<()> {
    for id in ingested {
        let Some(task) = queue.tasks.iter().find(|task| &task.id == id) else {
            continue;
        };
        let Some(yaml::Value::Mapping(interaction)) = task.interaction.as_ref() else {
            continue;
        };
        let Some(question) = interaction
            .get(yaml::Value::String("decision_question".to_string()))
            .and_then(yaml::Value::as_str)
            .map(str::trim)
            .filter(|question| !question.is_empty())
        else {
            continue;
        };
        crate::state::append_conversation_turn(
            ws,
            id,
            crate::schemas::ConversationTurn {
                role: crate::schemas::TurnRole::Worker,
                text: question.to_string(),
                run_id: String::new(),
                ts: String::new(),
            },
        )?;
    }
    Ok(())
}

/// Should an ingested follow-up be gated for human approval before a worker
/// runs it? Gating is by RISK and by DANGEROUS-ACTION CLASS, never by "merely
/// outside the intent scope" (a scope-adjacent idea is a tracked candidate, not
/// a danger). A follow-up is gated when either:
/// - its `risk` is `high`, or
/// - its wording names a destructive / deploy-publish-send / network-mutation /
///   external-API-call action (the classes catalogued in
///   `.agents/approval-policy.yaml::gated_actions`).
///
/// A low-risk documentation follow-up is left ungated; a "delete the old table"
/// or "call the payments API" follow-up is gated. Deterministic and pure.
fn follow_up_needs_approval(fu: &crate::schemas::FollowUpTask) -> bool {
    if fu.risk.trim().eq_ignore_ascii_case("high") {
        return true;
    }
    let mut haystack = String::new();
    haystack.push_str(&fu.title);
    haystack.push(' ');
    haystack.push_str(&fu.reason);
    haystack.push(' ');
    haystack.push_str(&fu.kind);
    for a in &fu.acceptance {
        haystack.push(' ');
        haystack.push_str(a);
    }
    follow_up_text_is_dangerous(&haystack)
}

/// Word/phrase signals for the gated-action classes in
/// `.agents/approval-policy.yaml`. Matched case-insensitively as substrings.
/// Kept deliberately small and high-signal; broadened only alongside the policy.
const DANGER_SIGNALS: &[&str] = &[
    // destructive_command
    "delete",
    "remove ",
    "rm -",
    "drop table",
    "drop the",
    "truncate",
    "wipe",
    "destroy",
    "overwrite",
    "purge",
    // deploy_publish_send
    "deploy",
    "publish",
    "release to",
    "ship to",
    "rollout",
    "cargo publish",
    "npm publish",
    "send email",
    "send a message",
    "post to",
    // network_mutation / real_external_api_validation
    "external api",
    "api call",
    "call the api",
    "network request",
    "webhook",
    "http request",
    "upload to",
    "production database",
    "prod db",
    // secret_access
    "secret",
    "credential",
    "api key",
];

fn follow_up_text_is_dangerous(text: &str) -> bool {
    let lower = text.to_lowercase();
    DANGER_SIGNALS.iter().any(|sig| lower.contains(sig))
}

fn risk_based_approval() -> yaml::Value {
    yaml::from_str("required: true").expect("static approval yaml parses")
}

/// Inject a "must run before" dependency: make each existing task named in
/// `targets` depend on `new_id`. Drops self-references, unknown ids, duplicates,
/// and any target that would form a dependency cycle (i.e. `new_id` already
/// depends, transitively, on that target).
fn inject_runs_before(queue: &mut WorkQueue, new_id: &str, targets: &[String]) {
    for target in targets {
        let target = target.trim();
        if target.is_empty() || target == new_id {
            continue;
        }
        if !queue.tasks.iter().any(|t| t.id == target) {
            continue; // unknown id
        }
        if depends_transitively(queue, new_id, target) {
            continue; // would create a cycle
        }
        if let Some(t) = queue.tasks.iter_mut().find(|t| t.id == target) {
            if !t.depends_on.iter().any(|d| d == new_id) {
                t.depends_on.push(new_id.to_string());
            }
        }
    }
}

/// Does task `from` depend, directly or transitively, on `target`? Used as a
/// cycle guard before injecting a `runs_before` dependency.
fn depends_transitively(queue: &WorkQueue, from: &str, target: &str) -> bool {
    let mut stack = vec![from.to_string()];
    let mut seen = std::collections::HashSet::new();
    while let Some(cur) = stack.pop() {
        if !seen.insert(cur.clone()) {
            continue;
        }
        if let Some(t) = queue.tasks.iter().find(|t| t.id == cur) {
            for d in &t.depends_on {
                if d == target {
                    return true;
                }
                stack.push(d.clone());
            }
        }
    }
    false
}

/// Recover a planning result left unconsumed by an interrupted session: the
/// worker finished and wrote `planning-result.json`, but Yardlet exited before
/// deriving the canonical intent/queue from it. Safe to call on every startup.
///
/// Guards against stale or double application: only the newest unconsumed plan
/// run is considered, it must not be superseded by a NEWER plan run (an
/// orphaned planning worker can finish long after the user already planned
/// something else — consuming it then would clobber the live intent/queue),
/// and its result file must be newer than the current queue file. Also
/// surfaces a still-alive planning worker from a previous session, so the
/// user knows a plan is on its way before paying for a duplicate one.
pub fn recover_unconsumed_plan(ws: &Workspace) -> Result<Option<String>> {
    crate::planning::validate_active_activation(ws)?;
    let mut best: Option<(String, std::path::PathBuf)> = None;
    // A previous session's planning worker that is still running.
    let mut live_planner: Option<(String, u32)> = None;
    let entries = match std::fs::read_dir(ws.runs_dir()) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(error).with_context(|| format!("reading {}", ws.runs_dir().display()))
        }
    };
    for entry in entries {
        let dir = entry
            .with_context(|| format!("reading {}", ws.runs_dir().display()))?
            .path();
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
        return Ok(live_planner.map(|(name, pid)| {
            format!(
                "a planning worker from a previous session is still running \
                 ({name}, pid {pid}); its plan will be picked up when it finishes"
            )
        }));
    };

    let result_path = run_dir.join("planning-result.json");
    let raw = std::fs::read_to_string(&result_path)
        .with_context(|| format!("reading {}", result_path.display()))?;
    let plan: PlanningResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", result_path.display()))?;
    if plan.summary.trim().is_empty() || plan.tasks.is_empty() {
        bail!(
            "unconsumed planning result has an empty summary or task list: {}",
            result_path.display()
        );
    }
    let meta_path = run_dir.join("plan-meta.yaml");
    let meta: PlanMeta = if meta_path.is_file() {
        state::load_yaml(&meta_path)?
    } else {
        legacy_plan_meta(&run_dir).unwrap_or_default()
    };
    if meta.schema_version != 2
        || meta.mode != "new"
        || meta.session_id.trim().is_empty()
        || meta.request_event_id.trim().is_empty()
        || meta.request_digest.trim().is_empty()
    {
        bail!("PlanMeta v2 exact session/turn binding is required for recovery");
    }
    let turn = PlanningTurnCas {
        session_id: meta.session_id.clone(),
        expected_head: meta.expected_head.clone(),
        request_event_id: meta.request_event_id.clone(),
        request_digest: meta.request_digest.clone(),
    };
    let lock = ws.acquire_planning_lock()?;
    let session = ws
        .load_planning_session(&turn.session_id)
        .with_context(|| format!("loading exact planning session {}", turn.session_id))?;
    let intent = build_intent(&session.intent_id, &meta.request, &plan, &[]);
    let mut queue = build_queue(&session.intent_id, &plan);
    crate::skills::project_task_skills_with_context(
        ws,
        &inspect::summarize(&ws.root),
        &mut queue.tasks,
        &meta.request,
    )?;
    let proposal = crate::planning::record_worker_proposal_exact_locked(
        ws,
        &lock,
        &turn,
        "recovered-planner",
        &run_id,
        &plan.summary,
        if plan.rationale.trim().is_empty() {
            "planning worker proposed a complete replacement draft"
        } else {
            plan.rationale.trim()
        },
        PlanningDraftContent { intent, queue },
    )?;
    mark_consumed(&run_dir)?;
    Ok(Some(format!(
        "recovered interrupted planning proposal ({run_id}): {}",
        proposal.proposal_id
    )))
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
        let task = Task {
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
            // Blank stays blank so routing's configured default_worker applies.
            preferred_worker: t.preferred_worker.clone(),
            model: t.model.clone(),
            effort: t.effort.clone(),
            depends_on: sanitize_deps(&t.depends_on, &prior_ids),
            skills: t.skills.clone(),
            required_capabilities: t.required_capabilities.clone(),
            allowed_scope: t.allowed_scope.clone(),
            acceptance: t
                .acceptance
                .iter()
                .map(|s| yaml::Value::String(s.clone()))
                .collect(),
            goal: t.goal.clone().or_else(|| {
                Some(TaskGoal {
                    condition: t.acceptance.join("; "),
                    max_feedback_cycles: 2,
                    feedback_policy: "inject_failed_checks".to_string(),
                })
            }),
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: t.worker_rationale.clone(),
            provenance: String::new(),
        };
        tasks.push(task);
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
/// one; if it forgot, Yardlet appends it — planner forgetfulness cannot skip
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
        required_capabilities: vec![],
        allowed_scope: vec![],
        acceptance: vec![yaml::Value::String(
            "Every intent acceptance criterion is verified against the actual workspace, \
             with per-criterion pass/fail and evidence in report.md"
                .to_string(),
        )],
        goal: Some(TaskGoal {
            condition: "Every intent acceptance criterion passes with evidence".to_string(),
            max_feedback_cycles: 2,
            feedback_policy: "inject_failed_checks".to_string(),
        }),
        validation: None,
        approval: None,
        interaction: None,
        worker_rationale: Some(
            "deterministic semantic-verification rung: the verifier is never the doer".to_string(),
        ),
        provenance: String::new(),
    });
}

/// Build the planner's worker-selection rubric from the editable profiles.
/// One neutral, parallel line per worker: a positive signal (best for) and,
/// when set, a negative one (avoid for). Contrastive boundaries and explicit
/// negatives help the planner discriminate better than long positive lists.
fn build_worker_guidance(workers: &WorkersFile) -> String {
    let mut g = format!("Cost bias: {}.\n", workers.routing.cost_bias);
    for w in &workers.workers {
        if w.best_for.is_empty() && w.capabilities.is_empty() {
            continue;
        }
        let cost = if w.cost_weight.is_empty() {
            "?"
        } else {
            &w.cost_weight
        };
        g.push_str(&format!("- {} (cost: {})", w.id, cost));
        if !w.best_for.is_empty() {
            g.push_str(&format!(": best for {}.", w.best_for));
        }
        if !w.not_for.is_empty() {
            g.push_str(&format!(" Avoid for {}.", w.not_for));
        }
        if !w.capabilities.is_empty() {
            g.push_str(&format!(" Capabilities: {}.", w.capabilities.join(", ")));
        }
        g.push('\n');
    }
    // Capabilities are HARD routing constraints, not soft preferences. Tell the
    // planner to set `required_capabilities` on a task that needs one, rather
    // than relying on title wording (no magic keywords).
    let caps: std::collections::BTreeSet<&str> = workers
        .workers
        .iter()
        .flat_map(|w| w.capabilities.iter().map(|c| c.as_str()))
        .collect();
    if !caps.is_empty() {
        let list = caps.into_iter().collect::<Vec<_>>().join(", ");
        g.push_str(&format!(
            "\nCapabilities are HARD routing constraints and name TOOLS A WORKER NEEDS. For \
             special work a listed worker CAN do, set the task's `required_capabilities` to the \
             matching capability from [{list}] (exact string): routing then runs only a worker \
             that declares it. Decide from the task's meaning, not keywords; leave it empty when \
             no special tool is needed. Do NOT conflate two different off-list cases: (1) a pure \
             HUMAN DECISION / choice / approval that a worker can carry out once answered (pick A \
             vs B, sign off on a direction) is NOT a capability — never invent one for it; raise \
             it in `questions_for_user` so Yardlet asks the user, not as a dead-end. (2) work that \
             needs a TOOL / ASSET / LICENSE / external resource NO listed worker has — THEN name \
             that needed capability even though it is not in [{list}], so Yardlet parks it for a \
             human to add a worker or provide the resource. So: a capability IN [{list}] routes to \
             a worker; an off-list capability flags a genuine tool/resource gap; a human decision \
             is a question, never a capability.\n"
        ));
    }
    g
}

/// Resolve the ordered worker preference and return the first that is ready.
pub(crate) fn pick_ready_worker(
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
        "no invocable planning worker among {tried:?}. Run `yardlet worker status` to diagnose. \
         Yardlet did not call an AI API and did not ask for an API key."
    ))
}

fn planning_worker_profile(
    profile: &WorkerProfile,
    planning_config: &PlanningWorkerConfig,
) -> WorkerProfile {
    workers::effective_profile(
        profile,
        &planning_config.planning_model,
        &planning_config.planning_effort,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn planner_inputs_exclude_historical_worker_log_but_keep_harness_anchors() {
        const SENTINEL: &str = "UNRELATED_OLD_INTENT_LARGE_WORKER_LOG_SENTINEL";
        let root = std::env::temp_dir().join(format!(
            "yard-planner-packet-boundary-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::create_dir_all(root.join(".agents/rules")).unwrap();
        std::fs::create_dir_all(root.join(".agents/skills/current-skill")).unwrap();
        std::fs::create_dir_all(root.join(".agents/memory")).unwrap();
        let old_run = root.join(".agents/runs/run-old-intent-yard-999");
        std::fs::create_dir_all(&old_run).unwrap();
        std::fs::write(
            root.join("Cargo.toml"),
            "[package]\nname='fixture'\nversion='0.1.0'\n",
        )
        .unwrap();
        std::fs::write(
            root.join(".agents/rules/current-rule.md"),
            "CURRENT_WORKSPACE_RULE_ANCHOR",
        )
        .unwrap();
        std::fs::write(
            root.join(".agents/skills/current-skill/SKILL.md"),
            "---\nname: current-skill\ndescription: Current skill anchor.\n---\nbody",
        )
        .unwrap();
        std::fs::write(
            root.join(".agents/memory/current-history.md"),
            "---\ntitle: Current history anchor\nsummary: Keep the durable decision.\n---\nMEMORY_BODY_NOT_INLINED",
        )
        .unwrap();
        std::fs::write(
            old_run.join("run.yaml"),
            "intent_id: intent-old\ntask_id: YARD-999\n",
        )
        .unwrap();
        let large_log = format!("{SENTINEL}\n{}", "old log payload\n".repeat(32_768));
        let old_log = old_run.join("worker-output.log");
        std::fs::write(&old_log, &large_log).unwrap();

        let ws = Workspace::at(&root);
        let summary = planning_repo_summary(&ws);
        let harness = packet::discover_harness(&root, false);
        let current_intent = IntentContract {
            schema_version: 1,
            id: "intent-current".into(),
            source: "user".into(),
            raw_request: "CURRENT_REQUEST_ANCHOR".into(),
            summary: "CURRENT_INTENT_ANCHOR".into(),
            allowed_scope: vec!["src/packet.rs".into()],
            out_of_scope: vec!["release".into()],
            acceptance: vec![yaml::Value::String("bounded packet".into())],
            images: vec![],
            ambiguity: "low".into(),
            open_questions: vec![],
            clarifications: vec![],
            interview_turns: 0,
            status: "accepted".into(),
        };
        state::save_yaml(&ws.intent_path(), &current_intent).unwrap();
        let same_thread_intent = planning_intent_context(&ws, false).unwrap();
        assert_eq!(same_thread_intent.as_ref().unwrap().id, "intent-current");
        assert!(planning_intent_context(&ws, true).unwrap().is_none());
        let packet = packet::compile_planning(
            "CURRENT_REQUEST_ANCHOR",
            same_thread_intent.as_ref(),
            &summary,
            ".agents/runs/plan-current",
            "en",
            "",
            &[],
            &harness,
            "codex",
        );

        assert!(packet.contains("CURRENT_REQUEST_ANCHOR"));
        assert!(packet.contains("CURRENT_INTENT_ANCHOR"));
        assert!(packet.contains("CURRENT_WORKSPACE_RULE_ANCHOR"));
        assert!(packet.contains("current-skill"));
        assert!(packet.contains(".agents/skills/current-skill/SKILL.md"));
        assert!(packet.contains("Current history anchor"));
        assert!(packet.contains(".agents/memory/current-history.md"));
        assert!(!packet.contains("MEMORY_BODY_NOT_INLINED"));
        assert!(!packet.contains(SENTINEL));
        assert!(!summary.top_level.iter().any(|entry| entry == ".agents"));
        assert_eq!(std::fs::read_to_string(&old_log).unwrap(), large_log);

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn worker_guidance_has_contrastive_positive_and_negative_lines() {
        let yaml = r#"
schema_version: 1
workers:
  - id: codex
    best_for: scoped edits
    not_for: ambiguous specs
    cost_weight: low
    invocation: { command: codex }
  - id: claude-code
    best_for: refactors
    cost_weight: high
    invocation: { command: claude }
  - id: blankworker
    cost_weight: low
    invocation: { command: blankworker }
routing:
  cost_bias: balanced
"#;
        let wf: WorkersFile = serde_yaml_ng::from_str(yaml).expect("workers yaml parses");
        let g = build_worker_guidance(&wf);
        assert!(g.contains("Cost bias: balanced."));
        // Positive + negative signal on one neutral line.
        assert!(
            g.contains("- codex (cost: low): best for scoped edits. Avoid for ambiguous specs.\n")
        );
        // No not_for -> no "Avoid for" appended.
        assert!(g.contains("- claude-code (cost: high): best for refactors.\n"));
        assert!(!g.contains("best for refactors. Avoid"));
        // Empty best_for -> worker skipped entirely.
        assert!(!g.contains("blankworker"));
    }

    #[test]
    fn planning_worker_profile_uses_planning_overrides_and_auto_falls_back() {
        let base: WorkerProfile = crate::yaml::from_str(
            r#"
id: codex
enabled: true
model: gpt-run
effort: medium
invocation: { command: codex }
"#,
        )
        .unwrap();

        let fallback = planning_worker_profile(&base, &PlanningWorkerConfig::default());
        assert_eq!(fallback.model, "gpt-run");
        assert_eq!(fallback.effort, "medium");

        let explicit = planning_worker_profile(
            &base,
            &PlanningWorkerConfig {
                planning_model: "gpt-plan".to_string(),
                planning_effort: "high".to_string(),
            },
        );
        assert_eq!(explicit.model, "gpt-plan");
        assert_eq!(explicit.effort, "high");

        let mixed = planning_worker_profile(
            &base,
            &PlanningWorkerConfig {
                planning_model: "auto".to_string(),
                planning_effort: "low".to_string(),
            },
        );
        assert_eq!(mixed.model, "gpt-run");
        assert_eq!(mixed.effort, "low");
    }

    #[test]
    fn reconcile_parks_unsatisfiable_capability_at_creation() {
        fn cap_task(id: &str, state: TaskState, caps: &[&str]) -> Task {
            Task {
                id: id.into(),
                title: id.into(),
                state,
                priority: 10,
                risk: String::new(),
                kind: String::new(),
                preferred_worker: String::new(),
                model: String::new(),
                effort: String::new(),
                depends_on: vec![],
                skills: vec![],
                required_capabilities: caps.iter().map(|s| s.to_string()).collect(),
                allowed_scope: vec![],
                acceptance: vec![],
                goal: None,
                validation: None,
                approval: None,
                interaction: None,
                worker_rationale: None,
                provenance: String::new(),
            }
        }
        let wf: WorkersFile = serde_yaml_ng::from_str(
            r#"
schema_version: 1
workers:
  - id: codex
    enabled: true
    capabilities: [image_generation]
    invocation: { command: codex }
routing:
  cost_bias: balanced
"#,
        )
        .unwrap();
        let mut q = WorkQueue {
            schema_version: 1,
            queue_id: "q".into(),
            intent_id: String::new(),
            selection_policy: SelectionPolicy::default(),
            tasks: vec![
                cap_task("A", TaskState::Queued, &["image_generation"]), // satisfiable
                cap_task("B", TaskState::Queued, &["licensed_3d_asset_intake"]), // no worker
                cap_task("C", TaskState::Queued, &["Image-Generation"]), // normalizes -> satisfiable
                cap_task("D", TaskState::Done, &["sorcery"]),            // non-Queued: untouched
                cap_task("E", TaskState::Queued, &[]),                   // no caps: untouched
            ],
        };
        let parked = reconcile_queue_capabilities(&mut q, &wf);

        assert_eq!(q.tasks[0].state, TaskState::Queued); // A satisfiable
        assert_eq!(q.tasks[1].state, TaskState::Blocked); // B parked
        assert!(q.tasks[1]
            .worker_rationale
            .as_deref()
            .unwrap()
            .contains("licensed_3d_asset_intake"));
        assert_eq!(q.tasks[2].state, TaskState::Queued); // C normalized + satisfiable
        assert_eq!(
            q.tasks[2].required_capabilities,
            vec!["image_generation".to_string()]
        );
        assert_eq!(q.tasks[3].state, TaskState::Done); // D untouched (not Queued)
        assert_eq!(
            q.tasks[3].required_capabilities,
            vec!["sorcery".to_string()]
        );
        assert_eq!(q.tasks[4].state, TaskState::Queued); // E untouched (no caps)
        assert_eq!(parked.len(), 1);
        assert!(parked[0].starts_with("B "));
    }

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
        let (session, turn) =
            crate::planning::begin_user_turn_exact(&ws, "add admin search").unwrap();
        state::save_yaml(
            &run_dir.join("plan-meta.yaml"),
            &PlanMeta {
                schema_version: 2,
                mode: "new".into(),
                request: "add admin search".into(),
                session_id: turn.session_id.clone(),
                expected_head: turn.expected_head.clone(),
                request_event_id: turn.request_event_id.clone(),
                request_digest: turn.request_digest.clone(),
            },
        )
        .unwrap();
        write_str(
            &run_dir.join("planning-result.json"),
            r#"{ "summary": "admin search",
                 "tasks": [{ "id": "YARD-001", "title": "t" }] }"#,
        )
        .unwrap();

        // First startup after the crash: only an exact-session proposal is recovered.
        let msg = recover_unconsumed_plan(&ws)
            .expect("recovery should return a result")
            .expect("plan should be recovered");
        assert!(msg.contains("proposal"));
        assert!(ws.load_intent().unwrap().is_none());
        assert!(ws.load_queue().unwrap().tasks.is_empty());
        let proposals = ws.load_planning_proposals(&session.session_id).unwrap();
        assert_eq!(proposals.len(), 1);
        assert_eq!(proposals[0].session_id, turn.session_id);
        assert_eq!(proposals[0].expected_head, turn.expected_head);
        assert_eq!(proposals[0].request_event_id, turn.request_event_id);
        assert_eq!(proposals[0].request_digest, turn.request_digest);

        // Second startup: marked consumed, nothing to do.
        assert!(recover_unconsumed_plan(&ws).unwrap().is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn corrupt_unconsumed_plan_is_an_error_and_is_not_consumed() {
        let root =
            std::env::temp_dir().join(format!("yard-planrec-corrupt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let (_session, turn) =
            crate::planning::begin_user_turn_exact(&ws, "bounded request").unwrap();
        let run_dir = ws.runs_dir().join("plan-20990101-000001");
        std::fs::create_dir_all(&run_dir).unwrap();
        state::save_yaml(
            &run_dir.join("plan-meta.yaml"),
            &PlanMeta {
                schema_version: 2,
                mode: "new".into(),
                request: "bounded request".into(),
                session_id: turn.session_id,
                expected_head: turn.expected_head,
                request_event_id: turn.request_event_id,
                request_digest: turn.request_digest,
            },
        )
        .unwrap();
        write_str(&run_dir.join("planning-result.json"), "{not-json\n").unwrap();

        let error = recover_unconsumed_plan(&ws).unwrap_err();
        assert!(error.to_string().contains("planning-result.json"));
        assert!(!run_dir.join(CONSUMED_MARKER).exists());
        assert!(ws.load_intent().unwrap().is_none());
        assert!(ws.load_queue().unwrap().tasks.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn proposal_write_error_is_propagated_and_not_consumed() {
        let root =
            std::env::temp_dir().join(format!("yard-planrec-write-error-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let (session, turn) =
            crate::planning::begin_user_turn_exact(&ws, "bounded request").unwrap();
        let run_dir = ws.runs_dir().join("plan-20990101-000002");
        std::fs::create_dir_all(&run_dir).unwrap();
        state::save_yaml(
            &run_dir.join("plan-meta.yaml"),
            &PlanMeta {
                schema_version: 2,
                mode: "new".into(),
                request: "bounded request".into(),
                session_id: turn.session_id,
                expected_head: turn.expected_head,
                request_event_id: turn.request_event_id,
                request_digest: turn.request_digest,
            },
        )
        .unwrap();
        write_str(
            &run_dir.join("planning-result.json"),
            r#"{ "summary": "bounded plan",
                 "tasks": [{ "id": "YARD-001", "title": "t" }] }"#,
        )
        .unwrap();
        write_str(
            &ws.planning_session_dir(&session.session_id)
                .join("proposals"),
            "not a directory",
        )
        .unwrap();

        let error = recover_unconsumed_plan(&ws).unwrap_err();
        assert!(error.to_string().contains("creating"), "{error:#}");
        assert!(!run_dir.join(CONSUMED_MARKER).exists());
        assert!(ws.load_intent().unwrap().is_none());
        assert!(ws.load_queue().unwrap().tasks.is_empty());
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
        let n = plan_goal(&ws, "fix the login redirect", None, None, &[]).unwrap();
        assert_eq!(n, 1);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks.len(), 1);
        assert_eq!(q.tasks[0].kind, "implementation");
        assert_eq!(q.tasks[0].goal.as_ref().unwrap().max_feedback_cycles, 2);
        assert_eq!(
            q.tasks[0].goal.as_ref().unwrap().condition,
            "fix the login redirect"
        );
        let intent = ws.load_intent().unwrap().unwrap();
        assert_eq!(intent.ambiguity, "low");
        assert!(!intent_gated(&intent, true));

        // With verify: a second reviewer task depends on the first.
        let n = plan_goal(
            &ws,
            "polish the title screen",
            Some("no clipped text and the theme is consistent"),
            None,
            &[],
        )
        .unwrap();
        assert_eq!(n, 2);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[1].kind, "review");
        assert_eq!(q.tasks[1].depends_on, vec!["YARD-001"]);
        assert_eq!(
            q.tasks[1].goal.as_ref().unwrap().condition,
            "no clipped text and the theme is consistent"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn express_goal_does_not_keyword_force_a_worker() {
        let root = std::env::temp_dir().join(format!("yard-image-goal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);

        // The express path bypasses the planner; with no --worker/--requires it
        // must NOT infer a worker from wording (the old keyword router is gone).
        let n = plan_goal(
            &ws,
            "generate icon assets for the settings page",
            None,
            None,
            &[],
        )
        .unwrap();
        assert_eq!(n, 1);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].preferred_worker, "");
        assert!(q.tasks[0].required_capabilities.is_empty());
        let _ = std::fs::remove_dir_all(&root);

        // --worker forces a worker for the express goal.
        let _ = std::fs::remove_dir_all(&root);
        let n = plan_goal(&ws, "generate icon assets", None, Some("codex"), &[]).unwrap();
        assert_eq!(n, 1);
        assert_eq!(ws.load_queue().unwrap().tasks[0].preferred_worker, "codex");
        let _ = std::fs::remove_dir_all(&root);

        // --requires sets a hard capability route (the escape hatch for the
        // express path that the capability router can then honor).
        let _ = std::fs::remove_dir_all(&root);
        let n = plan_goal(
            &ws,
            "generate icon assets",
            None,
            None,
            &["image_generation".to_string()],
        )
        .unwrap();
        assert_eq!(n, 1);
        assert_eq!(
            ws.load_queue().unwrap().tasks[0].required_capabilities,
            vec!["image_generation".to_string()]
        );
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
                ..PlanMeta::default()
            },
        )
        .unwrap();
        write_str(
            &stale.join("planning-result.json"),
            r#"{ "summary": "stale plan",
                 "tasks": [{ "id": "YARD-001", "title": "t" }] }"#,
        )
        .unwrap();

        assert!(recover_unconsumed_plan(&ws).is_err());
        // The live queue was not replaced, and a rejected result is not consumed.
        assert_eq!(ws.load_queue().unwrap().intent_id, "live");
        assert!(!stale.join(CONSUMED_MARKER).exists());
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
        let msg = recover_unconsumed_plan(&ws)
            .expect("live planner scan should succeed")
            .expect("live planner should be reported");
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
            "# Yardlet planning gate\n\n## Request (verbatim)\n\n\
             make the game feel like a game\n\n## Rules\n\n- ...\n",
        )
        .unwrap();
        write_str(
            &run_dir.join("planning-result.json"),
            r#"{ "summary": "game feel",
                 "tasks": [{ "id": "YARD-101", "title": "t" }] }"#,
        )
        .unwrap();

        let error = recover_unconsumed_plan(&ws).unwrap_err();
        assert!(error.to_string().contains("PlanMeta v2"));
        assert!(ws.load_intent().unwrap().is_none());
        assert!(!run_dir.join(CONSUMED_MARKER).exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn ingest_follow_ups_assigns_ids_dedups_and_tags_provenance() {
        use crate::schemas::FollowUpTask;
        // Start from a one-task queue (YARD-001 "existing", priority 10, Queued).
        let plan: PlanningResult = serde_json::from_str(
            r#"{ "summary": "s", "tasks": [{ "id": "YARD-001", "title": "existing", "risk": "low" }] }"#,
        )
        .unwrap();
        let mut queue = build_queue("intent-x", &plan);

        let fus = vec![
            FollowUpTask {
                title: "add tests".into(),
                reason: "coverage gap".into(),
                // backward dep kept; unknown forward dep dropped by sanitize_deps
                depends_on: vec!["YARD-001".into(), "YARD-999".into()],
                ..Default::default()
            },
            FollowUpTask {
                title: "   ".into(), // empty after trim -> dropped
                reason: "blank".into(),
                ..Default::default()
            },
            FollowUpTask {
                title: "existing".into(), // duplicates a queued title -> skipped
                reason: "dup".into(),
                ..Default::default()
            },
        ];
        let ingested = ingest_follow_ups(&mut queue, &[], &fus, None);

        // Only "add tests" survives, as the next YARD id.
        assert_eq!(ingested, vec!["YARD-002".to_string()]);
        let t = queue.tasks.iter().find(|t| t.id == "YARD-002").unwrap();
        assert_eq!(t.title, "add tests");
        assert_eq!(t.state, TaskState::Queued);
        assert_eq!(t.provenance, "worker-proposed");
        assert!(t.priority > 10, "priority sequenced after the current max");
        assert_eq!(t.depends_on, vec!["YARD-001".to_string()]);
        assert!(t
            .worker_rationale
            .as_deref()
            .unwrap()
            .contains("coverage gap"));
        // Total: original + one ingested (blank + dup were not added).
        assert_eq!(queue.tasks.len(), 2);
    }

    #[test]
    fn ingest_follow_ups_gates_by_risk_and_danger_not_scope_escape() {
        use crate::schemas::FollowUpTask;
        let plan: PlanningResult = serde_json::from_str(
            r#"{ "summary": "s", "tasks": [{ "id": "YARD-001", "title": "existing", "risk": "low" }] }"#,
        )
        .unwrap();
        let mut queue = build_queue("intent-x", &plan);
        let intent_scope = vec!["src".to_string()];

        let ingested = ingest_follow_ups(
            &mut queue,
            &intent_scope,
            &[
                // Low-risk docs, and it escapes the intent scope (docs vs src) —
                // scope-escape alone must NOT gate it.
                FollowUpTask {
                    title: "write docs".into(),
                    reason: "adjacent doc idea".into(),
                    risk: "low".into(),
                    allowed_scope: vec!["docs/*.md".into()],
                    ..Default::default()
                },
                // A destructive action, in-scope — gated by its danger class.
                FollowUpTask {
                    title: "delete the legacy queue file".into(),
                    reason: "remove stale runtime state".into(),
                    risk: "low".into(),
                    allowed_scope: vec!["src/state.rs".into()],
                    ..Default::default()
                },
                // An external API call — gated by its danger class.
                FollowUpTask {
                    title: "verify signup".into(),
                    reason: "call the external api to confirm".into(),
                    allowed_scope: vec!["src/run.rs".into()],
                    ..Default::default()
                },
                // Explicit high risk — gated regardless of wording.
                FollowUpTask {
                    title: "tune the selector".into(),
                    reason: "safe-looking but flagged".into(),
                    risk: "high".into(),
                    allowed_scope: vec!["src/run.rs".into()],
                    ..Default::default()
                },
            ],
            None,
        );

        assert_eq!(ingested.len(), 4);
        let by_id = |id: &str| queue.tasks.iter().find(|t| t.id == id).unwrap();
        assert!(
            !by_id("YARD-002").approval_required(),
            "low-risk doc follow-up must NOT be gated even when it escapes scope"
        );
        assert!(
            by_id("YARD-003").approval_required(),
            "a destructive follow-up must be gated"
        );
        assert!(
            by_id("YARD-004").approval_required(),
            "an external-API follow-up must be gated"
        );
        assert!(
            by_id("YARD-005").approval_required(),
            "a high-risk follow-up must be gated"
        );
    }

    #[test]
    fn ingest_decision_follow_up_parks_needs_user_and_drops_capability() {
        use crate::schemas::FollowUpTask;
        let plan: PlanningResult = serde_json::from_str(
            r#"{ "summary": "s", "tasks": [{ "id": "YARD-001", "title": "existing", "risk": "low" }] }"#,
        )
        .unwrap();
        let mut queue = build_queue("intent-x", &plan);

        let ingested = ingest_follow_ups(
            &mut queue,
            &[],
            &[
                FollowUpTask {
                    title: "wire signature character".into(),
                    reason: "a creative A/B choice".into(),
                    // A worker mis-filing a human decision as a capability: the
                    // decision_question must win, dropping the fake capability.
                    required_capabilities: vec!["user-creative-direction-approval".into()],
                    decision_question: "Wire character X to dept A, or author a new dept B?".into(),
                    ..Default::default()
                },
                FollowUpTask {
                    title: "real tool gap".into(),
                    reason: "needs a tool no worker has".into(),
                    required_capabilities: vec!["image_generation".into()],
                    ..Default::default()
                },
            ],
            None,
        );

        assert_eq!(
            ingested,
            vec!["YARD-002".to_string(), "YARD-003".to_string()]
        );
        // A human decision parks as NeedsUser with NO capability (resolved by
        // `yardlet answer`), not Blocked behind an invented capability.
        let decision = queue.tasks.iter().find(|t| t.id == "YARD-002").unwrap();
        assert_eq!(decision.state, TaskState::NeedsUser);
        assert!(
            decision.required_capabilities.is_empty(),
            "a decision follow-up must drop required_capabilities"
        );
        // A genuine tool need keeps its capability and stays Queued (routing /
        // reconcile decides routability later; it is not a human decision).
        let tool = queue.tasks.iter().find(|t| t.id == "YARD-003").unwrap();
        assert_eq!(tool.state, TaskState::Queued);
        assert_eq!(
            tool.required_capabilities,
            vec!["image_generation".to_string()]
        );
    }

    #[test]
    fn ingest_insert_next_sorts_before_existing_queued() {
        use crate::schemas::FollowUpTask;
        let plan: PlanningResult = serde_json::from_str(
            r#"{ "summary": "s", "tasks": [
                { "id": "YARD-001", "title": "a", "risk": "low" },
                { "id": "YARD-002", "title": "b", "risk": "low" } ] }"#,
        )
        .unwrap();
        let mut queue = build_queue("i", &plan);
        let min_before = queue
            .tasks
            .iter()
            .filter(|t| t.state == TaskState::Queued)
            .map(|t| t.priority)
            .min()
            .unwrap();

        let ingested = ingest_follow_ups(
            &mut queue,
            &[],
            &[FollowUpTask {
                title: "urgent regen".into(),
                reason: "hit a capability ceiling".into(),
                insert: "next".into(),
                ..Default::default()
            }],
            None,
        );
        assert_eq!(ingested, vec!["YARD-003".to_string()]);
        let t = queue.tasks.iter().find(|t| t.id == "YARD-003").unwrap();
        assert!(
            t.priority < min_before,
            "insert:next must sort before every currently-queued task (got {} vs min {})",
            t.priority,
            min_before
        );
        // The default (append) still lands after the current max.
        let ingested = ingest_follow_ups(
            &mut queue,
            &[],
            &[FollowUpTask {
                title: "later cleanup".into(),
                reason: "tidy up".into(),
                ..Default::default()
            }],
            None,
        );
        assert_eq!(ingested, vec!["YARD-004".to_string()]);
        let appended = queue.tasks.iter().find(|t| t.id == "YARD-004").unwrap();
        assert!(appended.priority > min_before);
    }

    #[test]
    fn ingest_runs_before_injects_dependency_and_guards_cycles() {
        use crate::schemas::FollowUpTask;
        let plan: PlanningResult = serde_json::from_str(
            r#"{ "summary": "s", "tasks": [
                { "id": "YARD-001", "title": "a", "risk": "low" },
                { "id": "YARD-002", "title": "b", "risk": "low" } ] }"#,
        )
        .unwrap();

        // runs_before YARD-002 -> YARD-002 now WAITS for the inserted task.
        // Self ("YARD-003") and unknown ("NOPE") targets are dropped.
        let mut queue = build_queue("i", &plan);
        let ingested = ingest_follow_ups(
            &mut queue,
            &[],
            &[FollowUpTask {
                title: "prerequisite".into(),
                reason: "must run first".into(),
                runs_before: vec!["YARD-002".into(), "YARD-003".into(), "NOPE".into()],
                ..Default::default()
            }],
            None,
        );
        assert_eq!(ingested, vec!["YARD-003".to_string()]);
        let target = queue.tasks.iter().find(|t| t.id == "YARD-002").unwrap();
        assert!(
            target.depends_on.contains(&"YARD-003".to_string()),
            "YARD-002 must depend on the inserted task"
        );
        let inserted = queue.tasks.iter().find(|t| t.id == "YARD-003").unwrap();
        assert!(
            !inserted.depends_on.contains(&"YARD-003".to_string()),
            "self-reference must be dropped"
        );

        // Cycle guard: a follow-up that itself depends on YARD-002 cannot also
        // make YARD-002 wait for it (that would deadlock the queue).
        let mut q2 = build_queue("i", &plan);
        ingest_follow_ups(
            &mut q2,
            &[],
            &[FollowUpTask {
                title: "cyclic".into(),
                reason: "r".into(),
                depends_on: vec!["YARD-002".into()],
                runs_before: vec!["YARD-002".into()],
                ..Default::default()
            }],
            None,
        );
        let y2 = q2.tasks.iter().find(|t| t.id == "YARD-002").unwrap();
        assert!(
            !y2.depends_on.contains(&"YARD-003".to_string()),
            "cycle-forming runs_before injection must be dropped"
        );
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
