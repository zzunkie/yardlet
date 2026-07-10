//! Run orchestration: select one bounded task, prepare it, and (optionally)
//! execute it through a hidden worker, then evaluate and compact.
//!
//! Yardlet stays deterministic until a worker is invoked. By default `run_next`
//! prepares everything (run dir, evidence, packet, sanitized env) and stops
//! *before* spawning, because spawning a subscription-backed worker consumes
//! real usage. Pass `execute: true` to actually invoke the worker.

use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Result};
use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::guard;
use crate::inspect;
use crate::packet::{self, PacketInputs};
use crate::schemas::{
    ConversationTurn, RunResult, TaskState, TransitionActor, TransitionCause, TurnRole, WorkQueue,
    WorkerProfile, WorkersFile,
};
use crate::state::{self, append_str, write_str, Workspace};
use crate::{compact, evaluator, routing, telemetry, workers};

/// A live worker session a previous task finished in, offered to the next
/// task: same worker + dependency link = the worker keeps its hot context
/// (P1 — the bounded-task model without the cold-boot tax).
#[derive(Clone)]
pub struct ChainHandle {
    pub prev_task_id: String,
    pub worker_id: String,
    pub session: String,
    /// How many tasks this session has already run (cap guards context rot).
    pub length: u32,
}

/// Longest run of tasks one session may carry before a forced fresh start —
/// hot context helps until it rots.
pub const CHAIN_CAP: u32 = 3;

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
    /// Run even though the planner scored ambiguity "high" (gate override).
    pub accept_ambiguity: bool,
    /// Continue in this session instead of booting a fresh worker, when the
    /// resolved worker matches (run_auto offers it for dependent tasks).
    pub chain: Option<ChainHandle>,
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
    /// The worker session this run used (for chaining the next task).
    pub session: Option<String>,
    /// Whether this run continued a previous task's session.
    pub chained: bool,
}

// Every field defaults so a partial run.yaml (e.g. an older or hand-written one
// that only carries run_id/task_id/worker) still deserializes — both
// `seal_run_record` and `run_worker` read it through `state::load_yaml`.
#[derive(Serialize, Deserialize, Default)]
pub(crate) struct RunRecord {
    #[serde(default)]
    pub schema_version: u32,
    #[serde(default)]
    pub run_id: String,
    #[serde(default)]
    pub task_id: String,
    #[serde(default)]
    pub intent_id: String,
    #[serde(default)]
    pub worker: String,
    /// Lifecycle: `prepared`/`running` at spawn, then sealed by `finalize_run`
    /// to the run's terminal outcome (`done`/`failed`/`partial`/`needs_user`/…).
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub started_at: String,
    /// Set when `finalize_run` seals the record; absent while the run is in
    /// flight. Lets the Trust Report and run-dir scans tell a finished run from
    /// a stranded one without re-deriving it from the queue.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(default)]
    pub worktree: String,
}

#[derive(Serialize, Deserialize, Default)]
pub(crate) struct RunFailover {
    pub from: String,
    pub to: String,
    pub reason: String,
    pub at: String,
}

pub fn run_next(ws: &Workspace, opts: &RunOptions) -> Result<RunReport> {
    let mut queue = ws.load_queue()?;
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let intent = ws.load_intent()?;
    let config = ws.load_config()?;

    // Ambiguity gate (absorption.md A2): while the planner's own self-report
    // says it is still guessing, queue-selected runs refuse to start. A named
    // target or --accept-ambiguity is an explicit human override.
    if opts.target.is_none() && !opts.accept_ambiguity {
        if let Some(i) = &intent {
            if crate::planner::intent_gated(i, config.ambiguity_gate) {
                return Err(anyhow!(
                    "the plan is still guessing (ambiguity: high, {} open question(s), \
                     interview turn {}/{}). Answer with `a` in the TUI or `yardlet answer`, \
                     or override with --accept-ambiguity.",
                    i.open_questions.len(),
                    i.interview_turns,
                    crate::planner::INTERVIEW_CAP
                ));
            }
        }
    }

    // ---- select task: a named target, or the next eligible queued one ---
    let idx = match &opts.target {
        Some(id) => queue
            .tasks
            .iter()
            .position(|t| &t.id == id)
            .ok_or_else(|| anyhow!("task {id} not found in the queue"))?,
        None => {
            let vocab = routing::declared_capabilities(&workers);
            select_next_ready(&queue, &vocab, |id| crate::approvals::is_granted(ws, id))?
                .ok_or_else(|| anyhow!("no eligible queued task to run"))?
        }
    };
    let task = queue.tasks[idx].clone();

    // Capability backstop: if this task requires a capability no enabled worker
    // declares, park it Blocked HERE — before any run dir or worker spawn —
    // instead of letting routing hard-fail and strand an orphaned run. Queue
    // creation already grounds capabilities (planner::reconcile_queue_capabilities);
    // this guards the path that bypasses that: a named `--task` the user forced.
    {
        let vocab = routing::declared_capabilities(&workers);
        let unsatisfiable =
            routing::unsatisfiable_capabilities(&task.required_capabilities, &vocab);
        if !unsatisfiable.is_empty() {
            match routing::classify_stale_gate(&unsatisfiable) {
                routing::GateShape::Decision => {
                    migrate_stale_gate_to_decision(ws, &mut queue, &task, &unsatisfiable)?;
                    return Ok(RunReport {
                        run_id: String::new(),
                        task_id: task.id.clone(),
                        worker_id: String::new(),
                        run_dir: ws.runs_dir(),
                        prepared: false,
                        executed: false,
                        lines: vec![format!(
                            "{}: migrated stale capability gate to NeedsUser; answer it with `yardlet answer --task {}`",
                            task.id, task.id
                        )],
                        result_state: Some(TaskState::NeedsUser),
                        session: None,
                        chained: false,
                    });
                }
                routing::GateShape::ToolGap => {
                    save_task_state_on_latest_queue(
                        ws,
                        &mut queue,
                        &task.id,
                        TaskState::Deferred,
                        TransitionCause::TidyDefer,
                        &format!(
                            "set aside because no enabled worker declares required capability/capabilities [{}]",
                            unsatisfiable.join(", ")
                        ),
                        TransitionActor::System,
                    )?;
                }
            }
            return Ok(RunReport {
                run_id: String::new(),
                task_id: task.id.clone(),
                worker_id: String::new(),
                run_dir: ws.runs_dir(),
                prepared: false,
                executed: false,
                lines: vec![format!(
                    "{}: set aside Deferred — no enabled worker declares required \
                     capability/capabilities [{}]; add a capable worker and revive it when ready",
                    task.id,
                    unsatisfiable.join(", ")
                )],
                result_state: Some(TaskState::Deferred),
                session: None,
                chained: false,
            });
        }
    }

    // Resuming after a question: record the user's reply and thread the whole
    // conversation back so the worker has memory of it. Seed the worker's prior
    // question for a task that paused before transcripts existed (legacy/first).
    let conversation: Vec<ConversationTurn> = if let Some(answer) = opts
        .answer
        .as_deref()
        .map(str::trim)
        .filter(|a| !a.is_empty())
    {
        if ws.load_conversation(&task.id).turns.is_empty() {
            if let Some(q) = latest_question_for(ws, &task.id) {
                let _ = state::append_conversation_turn(
                    ws,
                    &task.id,
                    ConversationTurn {
                        role: TurnRole::Worker,
                        text: q,
                        run_id: String::new(),
                        ts: String::new(),
                    },
                );
            }
        }
        let _ = state::append_conversation_turn(
            ws,
            &task.id,
            ConversationTurn {
                role: TurnRole::User,
                text: answer.to_string(),
                run_id: String::new(),
                ts: Local::now().to_rfc3339(),
            },
        );
        ws.load_conversation(&task.id).turns
    } else {
        Vec::new()
    };
    // Re-running a Partial task: continue from the previous run's checkpoint
    // instead of redoing the work from scratch.
    let continuation = if task.state == TaskState::Partial {
        continuation_context(ws, &task.id)
    } else {
        None
    };

    // ---- resolve worker (deterministic: candidate -> readiness -> fallback) --
    let resolved = routing::resolve_worker_for_task(
        ws,
        &workers,
        &billing,
        opts.worker_override.as_deref(),
        &task,
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

    let role_notes = packet::load_role_notes(&ws.root, packet::role_for(&task.kind));
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let chained_from = opts.chain.as_ref().map(|c| c.prev_task_id.clone());
    // A grant present now (consumed below at execute time) means the human has
    // approved this run's gated action: tell the worker to finish it, not re-ask.
    let approved = task.approval_required() && crate::approvals::is_granted(ws, &task.id);
    let packet_text = packet::compile(&PacketInputs {
        worker_id: &worker_id,
        task: &task,
        intent: intent.as_ref(),
        repo: &summary,
        run_dir_rel: &run_dir_rel,
        conversation: &conversation,
        continuation: continuation.as_deref(),
        chained_from: chained_from.as_deref(),
        language: &language,
        images: &images,
        role_notes: &role_notes,
        harness: &harness,
        approved,
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
        completed_at: None,
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
            Err(e) => lines.push(format!("no invocable worker: {e}")),
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
            session: None,
            chained: false,
        });
    }

    // ---- execute ---------------------------------------------------------
    if task.approval_required() {
        if crate::approvals::is_granted(ws, &task.id) {
            crate::approvals::consume(ws, &task.id)?; // single-use
            lines.push(format!("approval consumed for {}", task.id));
        } else {
            return Err(anyhow!(
                "task {} requires approval. Run `yardlet approve {}` first, then \
                 `yardlet run --task {} --execute`.",
                task.id,
                task.id,
                task.id
            ));
        }
    }
    let resolved = resolved?; // hard stop if no ready worker
    let mut active_worker_id = worker_id.clone();
    let mut active_reason = resolved.reason;
    let mut active_bin = resolved.bin;
    let profile = find_worker(&workers.workers, &active_worker_id)?;
    // A per-task model/effort overrides the worker profile only when explicit;
    // "auto"/empty keeps the profile's pin (so the planner's `model: auto` does
    // not clobber a worker-level model pin). The in-flight task thus captures
    // its own effective profile.
    let mut eff_profile = workers::effective_profile(profile, &task.model, &task.effort);
    // Per-run --full-access OR the workspace's default_access=full.
    let full_access = opts.full_access || config.default_access.eq_ignore_ascii_case("full");
    let mut env = guard::sanitized_worker_env_for(&billing, &eff_profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
    let mut timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    lines.push(format!("worker: {active_worker_id} ({active_reason})"));

    // H3: workspace-owned pre-run gates bind every worker. A non-zero hook
    // blocks the run before any worker spawns (detect-secrets, lint, "don't
    // run while CI is red"). The task fails with the hook's reason so the
    // auto-drain stops on it rather than looping; fix the cause and re-run.
    let pre = crate::hooks::run_phase(
        ws,
        crate::hooks::Phase::Pre,
        &task.id,
        &run_dir,
        &active_worker_id,
    );
    if !pre.ok() {
        for f in &pre.failures {
            lines.push(format!("pre-run hook blocked the run: {}", f.summary()));
        }
        let from = queue.tasks[idx].state;
        queue.tasks[idx].state = TaskState::Failed;
        ws.save_queue(&queue)?;
        let _ = state::append_transition(
            ws,
            state::transition(
                &task.id,
                from,
                TaskState::Failed,
                TransitionCause::RunOutcome,
                "pre-run hook blocked the run",
                TransitionActor::System,
            ),
        );
        return Ok(RunReport {
            run_id: run_id.clone(),
            task_id: task.id.clone(),
            worker_id: active_worker_id.clone(),
            run_dir: run_dir.clone(),
            prepared: true,
            executed: false,
            lines,
            result_state: Some(TaskState::Failed),
            session: None,
            chained: false,
        });
    }

    // mark running
    let from = queue.tasks[idx].state;
    queue.tasks[idx].state = TaskState::Running;
    ws.save_queue(&queue)?;
    let _ = state::append_transition(
        ws,
        state::transition(
            &task.id,
            from,
            TaskState::Running,
            TransitionCause::RunOutcome,
            "worker run started",
            TransitionActor::System,
        ),
    );

    // Chaining (P1): when run_auto offers the previous task's live session and
    // routing kept the same worker, continue IN that session — the worker
    // keeps its hot context instead of re-learning the repo from zero.
    let chained = opts
        .chain
        .as_ref()
        .is_some_and(|c| c.worker_id == active_worker_id);
    if chained {
        lines.push(format!(
            "chaining into {}'s session (task {} of a hot chain)",
            active_worker_id,
            opts.chain.as_ref().map(|c| c.length + 1).unwrap_or(1)
        ));
    }

    // Session id for resume-on-transient: claude lets us set one up front; codex
    // generates its own, captured from its rollout file after the run starts.
    let log_path = run_dir.join("worker-output.log");
    let mut effective_chained = chained;
    let mut session_id: Option<String> = if chained {
        opts.chain.as_ref().map(|c| c.session.clone())
    } else if active_worker_id == "claude-code" {
        Some(gen_session_uuid(&run_id))
    } else {
        None
    };
    // Snapshot the workspace before the worker runs so the evaluator can diff
    // against ACTUAL on-disk changes, not the worker's self-report. Git
    // workspaces use `git status`; non-git workspaces use a bounded folder scan.
    // The current run dir is excluded so Yardlet's own result/handoff artifacts
    // are not attributed as worker deliverables.
    let run_excludes = vec![run_dir.clone()];
    let baseline_fp = evaluator::run_fingerprints(&ws.root, &run_excludes);
    let started_sys = std::time::SystemTime::now();
    let run_started = std::time::Instant::now();
    let mut outcome = workers::spawn(
        &eff_profile,
        &active_bin,
        &packet_text,
        &ws.root,
        &env,
        &log_path,
        timeout,
        full_access,
        &images,
        session_id.as_deref(),
        chained,
    )?;
    if active_worker_id == "codex" && session_id.is_none() {
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
            &active_bin,
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

    // User stopped it (Esc): requeue rather than evaluate as a real failure.
    if cancelled_marker.exists() {
        let _ = std::fs::remove_file(&cancelled_marker);
        // Re-read the latest queue before saving: the worker may have written a
        // follow-up task before the cancel was observed (no stale clobber).
        save_task_state_on_latest_queue(
            ws,
            &mut queue,
            &task.id,
            TaskState::Queued,
            TransitionCause::RunOutcome,
            "stopped by user; task requeued",
            TransitionActor::System,
        )?;
        lines.push(format!("stopped by user; {} requeued", task.id));
        return Ok(RunReport {
            run_id: run_id.clone(),
            task_id: task.id.clone(),
            worker_id: active_worker_id.clone(),
            run_dir: run_dir.clone(),
            prepared: true,
            executed: true,
            lines,
            result_state: Some(TaskState::Queued),
            session: session_id.clone(),
            chained: effective_chained,
        });
    }

    let mut failover_note: Option<String> = None;
    if !run_dir.join("result.json").exists() {
        match routing::resolve_failover_worker_for_task(
            &workers,
            &billing,
            &active_worker_id,
            &task,
        ) {
            Ok(alt) => {
                let from = active_worker_id.clone();
                let to = alt.worker_id.clone();
                let note = format!(
                    "worker failover: {from} -> {to}; {from} exited without result.json \
                     after {resumes}/{max_retries} resume attempt(s)"
                );
                lines.push(note.clone());
                record_failover(&run_dir, &from, &to, &note);

                active_worker_id = to;
                active_reason = format!("failover from {from} ({})", alt.reason);
                active_bin = alt.bin;
                let profile = find_worker(&workers.workers, &active_worker_id)?;
                eff_profile = workers::effective_profile(profile, &task.model, &task.effort);
                env = guard::sanitized_worker_env_for(&billing, &eff_profile.invocation.pass_env)
                    .map_err(|e| anyhow!(e))?;
                timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
                effective_chained = false;
                session_id = if active_worker_id == "claude-code" {
                    Some(gen_session_uuid(&format!("{run_id}-{active_worker_id}")))
                } else {
                    None
                };
                let failover_packet = packet::compile(&PacketInputs {
                    worker_id: &active_worker_id,
                    task: &task,
                    intent: intent.as_ref(),
                    repo: &summary,
                    run_dir_rel: &run_dir_rel,
                    conversation: &conversation,
                    continuation: continuation.as_deref(),
                    chained_from: None,
                    language: &language,
                    images: &images,
                    role_notes: &role_notes,
                    harness: &harness,
                    approved,
                });
                write_str(&workers::packet_path(&run_dir), &failover_packet)?;
                let failover_started = SystemTime::now();
                outcome = workers::spawn(
                    &eff_profile,
                    &active_bin,
                    &failover_packet,
                    &ws.root,
                    &env,
                    &log_path,
                    timeout,
                    full_access,
                    &images,
                    session_id.as_deref(),
                    false,
                )?;
                if active_worker_id == "codex" && session_id.is_none() {
                    session_id = find_codex_session(failover_started);
                }
                failover_note = Some(note);
            }
            Err(e) => {
                let note = format!(
                    "worker failover unavailable after {} exited without result.json: {e}",
                    active_worker_id
                );
                lines.push(note.clone());
                failover_note = Some(note);
            }
        }
    }

    if cancelled_marker.exists() {
        let _ = std::fs::remove_file(&cancelled_marker);
        save_task_state_on_latest_queue(
            ws,
            &mut queue,
            &task.id,
            TaskState::Queued,
            TransitionCause::RunOutcome,
            "stopped by user after failover; task requeued",
            TransitionActor::System,
        )?;
        lines.push(format!("stopped by user; {} requeued", task.id));
        return Ok(RunReport {
            run_id: run_id.clone(),
            task_id: task.id.clone(),
            worker_id: active_worker_id.clone(),
            run_dir: run_dir.clone(),
            prepared: true,
            executed: true,
            lines,
            result_state: Some(TaskState::Queued),
            session: session_id.clone(),
            chained: effective_chained,
        });
    }
    let wall_seconds = run_started.elapsed().as_secs();
    lines.push(format!(
        "worker outcome: {} (exit_ok={}, timed_out={})",
        outcome.note, outcome.exit_ok, outcome.timed_out
    ));

    // ---- evaluate + compact ---------------------------------------------
    // Worker-attributed changes: diff the file fingerprints before and after
    // the run, so a path the worker re-modified while it was already dirty is
    // still attributed (plain path-set subtraction would miss it). `None` means
    // evidence capture itself failed, in which case the evaluator fails closed
    // rather than trusting the worker's self-report.
    let evidence: Option<Vec<String>> = match (
        &baseline_fp,
        evaluator::run_fingerprints(&ws.root, &run_excludes),
    ) {
        (Ok(base), Ok(after)) => Some(evaluator::worker_touched(base, &after)),
        (Err(e), _) => {
            lines.push(format!(
                "change evidence unavailable before worker run: {e}"
            ));
            None
        }
        (_, Err(e)) => {
            lines.push(format!("change evidence unavailable after worker run: {e}"));
            None
        }
    };
    // Clone the worker's touched paths for auto-commit, but only when it is on
    // (it consumes `evidence` below; off = no allocation).
    let evidence_for_commit = config.auto_commit.then(|| evidence.clone()).flatten();
    let user_override = opts.worker_override.as_ref().map(|o| {
        let from = if task.preferred_worker.is_empty() {
            "(default)".to_string()
        } else {
            task.preferred_worker.clone()
        };
        format!("{from}->{o}")
    });
    let intent_summary = intent.as_ref().map(|i| i.summary.as_str()).unwrap_or("");
    let report = finalize_run(FinalizeInput {
        ws,
        run_dir: &run_dir,
        run_id: &run_id,
        task: &task,
        evidence,
        worker_id: &active_worker_id,
        reason: &active_reason,
        wall_seconds,
        user_override,
        intent_summary,
        billing: &billing,
        queue: &mut queue,
        flags: FinalizeFlags::serial(),
        merge: None,
    })?;
    let next_state = report.next_state;
    lines.extend(report.lines);
    if let Some(note) = &failover_note {
        append_failover_note(&run_dir, note)?;
    }

    // Auto-commit (1d): a serial run edits the SHARED working tree, where a
    // before/after fingerprint cannot tell the worker's changes apart from a
    // concurrent user/other-session edit — so in-place auto-commit is unsafe and
    // NOT performed. The parallel path commits safely via its isolated worktree +
    // merge (auto-commit is worktree-only for now); when an opted-in serial run
    // actually produced worker changes, point the user at that path or a manual
    // commit. Full serial-in-worktree auto-commit lands as the next slice.
    if config.auto_commit
        && next_state == TaskState::Done
        && worker_changed_outside_agents(evidence_for_commit.as_deref())
    {
        lines.push(format!(
            "auto-commit deferred: a serial in-place run isn't auto-committed \
             (worktree/parallel path only for now); commit {}'s changes manually",
            task.id
        ));
    }

    Ok(RunReport {
        run_id,
        task_id: task.id,
        worker_id: active_worker_id,
        run_dir,
        prepared: true,
        executed: true,
        lines,
        result_state: Some(next_state),
        session: session_id,
        chained: effective_chained,
    })
}

/// Did the worker touch any path OUTSIDE Yardlet's own `.agents/` state? Drives
/// the serial auto-commit guidance: only worth telling an opted-in user their
/// changes were left to commit when the run actually produced deliverable
/// (non-`.agents/`) edits. `None` evidence (no git signal) counts as no change.
/// A leading `./` is normalized so `./.agents/x` is still recognized as state.
fn worker_changed_outside_agents(evidence: Option<&[String]>) -> bool {
    evidence
        .map(|e| {
            e.iter().any(|p| {
                let p = p.trim_start_matches("./");
                !p.starts_with(".agents/") && p != ".agents"
            })
        })
        .unwrap_or(false)
}

/// Surface-neutral auto-drain guidance.
///
/// `run_auto` streams these lines to whatever surface drives it — the TUI live
/// view or the CLI — so they must NOT embed `yardlet ...` command literals. Each
/// surface names its own affordance: the TUI shows key hints (`a` to answer, `p`
/// to approve) via `ui/i18n.rs`, and cli.rs command handlers print the imperative
/// `yardlet ...` form. A stop message that hardcoded one surface's command would
/// read wrong on the other, so the engine stays neutral and just says WHAT to do.
pub(crate) mod gate_msg {
    /// A task paused for the user's answer.
    pub fn needs_user(id: &str) -> String {
        format!("stopped: {id} needs you \u{2014} answer it, then run again")
    }
    /// A task is blocked and needs a human to resolve it.
    pub fn blocked(id: &str) -> String {
        format!("stopped: {id} blocked \u{2014} resolve it, then run again")
    }
    /// The queue drained with some tasks set aside (deferred).
    pub fn drained_with_deferred(ids: &[&str]) -> String {
        format!(
            "done: queue drained \u{2014} {} set aside: {}; revive any to continue",
            ids.len(),
            ids.join(", ")
        )
    }
    /// The queue fully drained, nothing left.
    pub fn drained_complete() -> String {
        "done: queue drained, all tasks complete".to_string()
    }
}

/// Autonomous mode: drain the queue, stopping only at genuine human gates.
///
/// Runs eligible queued tasks one after another — or, when parallelism is
/// enabled (config `max_parallel` or the `--parallel` flag) and several
/// independent tasks are ready in a clean git workspace, in concurrent
/// worktree batches. Done (or partial->re-queued) advances; Blocked /
/// NeedsUser / Failed stop the loop and hand back to the user (those need a
/// human). A per-task attempt cap prevents looping on a task that keeps
/// coming back partial. `bypass` drops the worker sandbox for the whole run
/// (workers still self-gate dangerous actions per the packet).
#[allow(clippy::too_many_arguments)]
pub fn run_auto<F: FnMut(&str)>(
    ws: &Workspace,
    bypass: bool,
    pause: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
    parallel: Option<usize>,
    accept_ambiguity: bool,
    mut on_event: F,
) -> Result<Vec<String>> {
    use std::collections::HashMap;
    let max_parallel = parallel
        .or_else(|| ws.load_config().ok().map(|c| c.max_parallel))
        .unwrap_or(1)
        .max(1);
    let mut parallel_warned = false;
    let mut out = Vec::new();
    let mut emit = |s: String| {
        on_event(&s);
        out.push(s);
    };
    let mut attempts: HashMap<String, u32> = HashMap::new();
    let mut waits: HashMap<String, u32> = HashMap::new();
    // P1: the previous Done task's live session, offered to a dependent
    // successor on the same worker. Cut on anything but a clean Done.
    let mut chain: Option<ChainHandle> = None;
    // Recover orphans (interrupted runs left "running") and any unconsumed
    // planning result from an interrupted session before draining.
    if let Some(m) = crate::planner::recover_unconsumed_plan(ws) {
        emit(m);
    }
    for m in recover_orphans(ws) {
        emit(m);
    }

    // Ambiguity gate: don't drain a plan that says it is still guessing.
    if !accept_ambiguity {
        let gate_on = ws.load_config().map(|c| c.ambiguity_gate).unwrap_or(true);
        if let Ok(Some(i)) = ws.load_intent() {
            if crate::planner::intent_gated(&i, gate_on) {
                emit(format!(
                    "stopped: the plan is still guessing (ambiguity high, interview turn \
                     {}/{}) \u{2014} answer its questions (a) or run with --accept-ambiguity",
                    i.interview_turns,
                    crate::planner::INTERVIEW_CAP
                ));
                for q in i.open_questions.iter().take(5) {
                    emit(format!("  ? {q}"));
                }
                return Ok(out);
            }
        }
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
        // A worker adopted from a previous session is still on a task: wait
        // for it instead of starting overlapping work in the same workspace.
        // recover_orphans evaluates it the moment its result appears.
        if let Some(t) = queue.tasks.iter().find(|t| t.state == TaskState::Running) {
            let task_id = t.id.clone();
            for m in recover_orphans(ws) {
                if !m.starts_with("adopted:") {
                    emit(m);
                }
            }
            let still_running = ws
                .load_queue()?
                .tasks
                .iter()
                .any(|x| x.state == TaskState::Running);
            if still_running {
                let n = waits.entry(task_id.clone()).or_default();
                *n += 1;
                if *n == 1 {
                    emit(format!(
                        "waiting for {task_id}'s worker from a previous session\u{2026}"
                    ));
                }
                if *n > 360 {
                    emit(format!(
                        "stopped: {task_id} has run for 30+ minutes \u{2014} kill its worker \
                         or keep waiting, then run auto again"
                    ));
                    break;
                }
                std::thread::sleep(Duration::from_secs(5));
            }
            continue;
        }
        // NeedsUser/Blocked tasks do NOT halt the drain. They are not Queued, so
        // select_next skips them, and any task depending on one stays gated by
        // deps_met. Independent ready work keeps flowing; only when nothing else
        // is runnable does the select_next `None` branch below report them.
        // A merge-conflict Partial needs a human; a self-reported Partial is
        // auto-continued from its checkpoint (retry path below, attempts-capped).
        if let Some(t) = queue.tasks.iter().find(|t| t.state == TaskState::Partial) {
            if partial_is_conflict(ws, &t.id) {
                emit(format!(
                    "stopped: {} has a merge conflict \u{2014} resolve it (see handoff), then \
                     run auto again",
                    t.id
                ));
                break;
            }
        }
        // A Failed task may be transient (e.g. a dropped connection) and a
        // Partial one continues from its checkpoint: retry them first, bounded
        // by the attempts cap below, instead of halting the drain.
        let retry_target = queue
            .tasks
            .iter()
            .find(|t| matches!(t.state, TaskState::Failed | TaskState::Partial))
            .map(|t| t.id.clone());
        // With parallelism on, a clean git tree, and 2+ independent ready
        // tasks: run them as a concurrent worktree batch instead. (A Failed
        // task still gets its sequential retry first.)
        if retry_target.is_none() && max_parallel > 1 {
            let assessment = crate::parallel::assess_parallelism(&queue, max_parallel);
            let ready = crate::parallel::ready_independent(&queue, max_parallel);
            if ready.len() >= 2 {
                match crate::parallel::git_preflight(&ws.root) {
                    Ok(()) => {
                        let mut capped = false;
                        for &i in &ready {
                            let n = attempts.entry(queue.tasks[i].id.clone()).or_default();
                            *n += 1;
                            capped |= *n > 2;
                        }
                        if capped {
                            emit(
                                "stopped: a task did not complete after retries \u{2014} needs you"
                                    .to_string(),
                            );
                            break;
                        }
                        chain = None; // parallel fan-out: fresh contexts
                        crate::parallel::run_batch(ws, &ready, bypass, |s| {
                            emit(s.to_string());
                        })?;
                        continue;
                    }
                    Err(why) => {
                        if !parallel_warned {
                            emit(format!("parallel off ({why}); running sequentially"));
                            parallel_warned = true;
                        }
                    }
                }
            } else if !parallel_warned && !assessment.reasons.is_empty() {
                emit(format!("parallel sequential: {}", assessment.summary()));
                parallel_warned = true;
            }
        }
        // Pick the work: retry the failed task first, else the next queued one.
        let task_id = match &retry_target {
            Some(id) => id.clone(),
            None => {
                let vocab = ws
                    .load_workers()
                    .map(|w| routing::declared_capabilities(&w))
                    .unwrap_or_default();
                match select_next_ready(&queue, &vocab, |id| crate::approvals::is_granted(ws, id))?
                {
                    Some(idx) => queue.tasks[idx].id.clone(),
                    None => {
                        // Nothing runnable. Report why, in priority of action: tasks
                        // that need a human (NeedsUser/Blocked) first, then
                        // queued-but-gated (approval or deps), else a drained queue.
                        let needs_you: Vec<&str> = queue
                            .tasks
                            .iter()
                            .filter(|t| {
                                matches!(t.state, TaskState::NeedsUser | TaskState::Blocked)
                            })
                            .map(|t| t.id.as_str())
                            .collect();
                        let deferred_tasks: Vec<&str> = queue
                            .tasks
                            .iter()
                            .filter(|t| t.state == TaskState::Deferred)
                            .map(|t| t.id.as_str())
                            .collect();
                        // Tasks that will never reach Done on their own: terminally
                        // stuck states, then (transitively) any Queued task gated
                        // behind one — so a whole stalled chain is caught, not just
                        // the direct dependent.
                        let mut dead: std::collections::HashSet<&str> = queue
                            .tasks
                            .iter()
                            .filter(|t| {
                                matches!(
                                    t.state,
                                    TaskState::Failed
                                        | TaskState::Deferred
                                        | TaskState::NeedsUser
                                        | TaskState::Blocked
                                )
                            })
                            .map(|t| t.id.as_str())
                            .collect();
                        loop {
                            let mut grew = false;
                            for t in &queue.tasks {
                                if t.state == TaskState::Queued
                                    && !dead.contains(t.id.as_str())
                                    && t.depends_on.iter().any(|d| dead.contains(d.as_str()))
                                {
                                    dead.insert(t.id.as_str());
                                    grew = true;
                                }
                            }
                            if !grew {
                                break;
                            }
                        }
                        // Split Queued tasks: stuck (gated behind a dep that won't
                        // complete) vs benignly waiting on a runnable dep / approval.
                        let mut stuck: Vec<String> = Vec::new();
                        let mut waiting: Vec<&str> = Vec::new();
                        for t in queue.tasks.iter().filter(|t| t.state == TaskState::Queued) {
                            match t.depends_on.iter().find(|d| dead.contains(d.as_str())) {
                                Some(d) => stuck.push(format!("{} (behind {})", t.id, d)),
                                None => waiting.push(t.id.as_str()),
                            }
                        }
                        if !needs_you.is_empty() {
                            emit(format!(
                            "stopped: {} need you \u{2014} answer (a) or resolve, then run auto again",
                            needs_you.join(", ")
                        ));
                        } else if !stuck.is_empty() {
                            emit(format!(
                            "stopped: {} \u{2014} the blocking task will not complete; fix, defer, \
                             or re-scope it",
                            stuck.join("; ")
                        ));
                        } else if !waiting.is_empty() {
                            emit(format!(
                                "stopped: {} waiting on approval or dependencies",
                                waiting.join(", ")
                            ));
                        } else if !deferred_tasks.is_empty() {
                            emit(gate_msg::drained_with_deferred(&deferred_tasks));
                        } else {
                            emit(gate_msg::drained_complete());
                        }
                        break;
                    }
                }
            }
        };
        if retry_target.is_some()
            && queue
                .tasks
                .iter()
                .find(|t| t.id == task_id)
                .is_some_and(|t| t.approval_required())
            && !crate::approvals::is_granted(ws, &task_id)
        {
            let mut fallback = queue.clone();
            save_task_state_on_latest_queue(
                ws,
                &mut fallback,
                &task_id,
                TaskState::NeedsUser,
                TransitionCause::RunOutcome,
                "approval required before retry; task paused for user",
                TransitionActor::System,
            )?;
            chain = None;
            emit(format!(
                "{task_id} requires approval; skipped retry and continued runnable work"
            ));
            continue;
        }
        let n = attempts.entry(task_id.clone()).or_default();
        *n += 1;
        if *n > 2 {
            // Surface any task hard-gated behind this one (a `depends_on` edge,
            // e.g. a runs_before-injected dependency) so it is not silently
            // stranded. A 1c review re-queued behind its fix is NOT listed here:
            // it is soft-sequenced by priority with no dep edge, so it stays
            // Queued and simply re-runs on the next drain rather than being
            // stranded by this stop.
            let gated: Vec<&str> = queue
                .tasks
                .iter()
                .filter(|t| {
                    t.state == TaskState::Queued && t.depends_on.iter().any(|d| d == &task_id)
                })
                .map(|t| t.id.as_str())
                .collect();
            let gated_note = if gated.is_empty() {
                String::new()
            } else {
                format!(" ({} depend on it and stay gated)", gated.join(", "))
            };
            emit(format!(
                "stopped: {task_id} did not complete after retries \u{2014} needs you{gated_note}"
            ));
            break;
        }

        // Offer the previous session only to a DEPENDENT successor (shared
        // context is the point) and under the rot cap; retries start cold.
        let offer = chain
            .as_ref()
            .filter(|c| {
                retry_target.is_none()
                    && c.length < CHAIN_CAP
                    && queue
                        .tasks
                        .iter()
                        .find(|t| t.id == task_id)
                        .is_some_and(|t| t.depends_on.contains(&c.prev_task_id))
            })
            .cloned();
        emit(format!("running {task_id}\u{2026}"));
        let report = run_next(
            ws,
            &RunOptions {
                execute: true,
                worker_override: None,
                target: retry_target.clone(),
                answer: None,
                full_access: bypass,
                accept_ambiguity: false,
                chain: offer.clone(),
            },
        )?;
        let state = report.result_state.unwrap_or(TaskState::Failed);
        emit(format!("{} \u{2192} {:?}", report.task_id, state));
        chain = if state == TaskState::Done {
            report.session.as_ref().map(|sess| ChainHandle {
                prev_task_id: report.task_id.clone(),
                worker_id: report.worker_id.clone(),
                session: sess.clone(),
                length: if report.chained {
                    offer.map(|o| o.length + 1).unwrap_or(1)
                } else {
                    1
                },
            })
        } else {
            None // a messy ending poisons the context; next run starts clean
        };

        match state {
            // Deferred never arises from a run (it is a manual decision), but if
            // it did it is resolved-not-pending, so move on like Done/Queued.
            TaskState::Done | TaskState::Queued | TaskState::Deferred => continue,
            TaskState::Blocked => {
                emit(gate_msg::blocked(&report.task_id));
                break;
            }
            TaskState::NeedsUser => {
                emit(gate_msg::needs_user(&report.task_id));
                break;
            }
            TaskState::Partial => {
                // Loop back: the conflict check halts, a self-report continues
                // from its checkpoint, and the attempts cap bounds it all.
                emit(format!(
                    "{} is partial \u{2014} continuing from its checkpoint",
                    report.task_id
                ));
                continue;
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

/// Pick the highest-priority eligible queued task index. Test-only convenience
/// wrapper over `select_next_ready` (no capability vocab, nothing approved);
/// production always routes through `select_next_ready` with the real inputs.
#[cfg(test)]
pub fn select_next(queue: &crate::schemas::WorkQueue, _opts: &RunOptions) -> Result<Option<usize>> {
    select_next_ready(queue, &std::collections::BTreeSet::new(), |_| false)
}

pub fn select_next_ready(
    queue: &crate::schemas::WorkQueue,
    cap_vocab: &std::collections::BTreeSet<String>,
    approved: impl Fn(&str) -> bool,
) -> Result<Option<usize>> {
    let pol = &queue.selection_policy;
    let mut best: Option<usize> = None;
    for (i, t) in queue.tasks.iter().enumerate() {
        if !queue.is_runnable_now(t, approved(&t.id), cap_vocab) {
            continue;
        }
        if pol.skip_if_blocked && t.state == TaskState::Blocked {
            continue;
        }
        if pol.skip_if_approval_required && t.approval_required() && !approved(&t.id) {
            continue;
        }
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

fn migrate_stale_gate_to_decision(
    ws: &Workspace,
    queue: &mut WorkQueue,
    task: &crate::schemas::Task,
    unsatisfiable: &[String],
) -> Result<()> {
    let mut latest = ws.load_queue().unwrap_or_else(|_| queue.clone());
    if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == task.id) {
        let from = t.state;
        t.state = TaskState::NeedsUser;
        t.required_capabilities.clear();
        let detail = format!(
            "migrated stale capability gate to a human decision question: {}",
            unsatisfiable.join(", ")
        );
        t.worker_rationale = Some(match t.worker_rationale.take() {
            Some(r) if !r.trim().is_empty() => format!("{r}\n{detail}"),
            _ => detail.clone(),
        });
        let question = format!(
            "This task needs your decision before Yardlet can run it: {}. Reply with the decision or instructions to proceed.",
            t.title
        );
        state::append_conversation_turn(
            ws,
            &t.id,
            ConversationTurn {
                role: TurnRole::Worker,
                text: question,
                run_id: String::new(),
                ts: Local::now().to_rfc3339(),
            },
        )?;
        state::append_transition(
            ws,
            state::transition(
                &t.id,
                from,
                t.state,
                TransitionCause::StaleMigration,
                &detail,
                TransitionActor::System,
            ),
        )?;
        ws.save_queue(&latest)?;
        *queue = latest;
    }
    Ok(())
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
        let tid = yaml.lines().find_map(|l| {
            l.trim()
                .strip_prefix("task_id:")
                .map(|v| v.trim().to_string())
        });
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
pub(crate) fn gen_session_uuid(seed: &str) -> String {
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

/// Validation commands configured on a task: `validation: { commands: [..] }`
/// or a bare sequence. Yardlet runs these itself (a worker's self-reported
/// validation is advisory, not the gate).
fn validation_commands(task: &crate::schemas::Task) -> Vec<String> {
    let Some(v) = &task.validation else {
        return Vec::new();
    };
    let seq = v
        .get("commands")
        .and_then(|c| c.as_sequence())
        .or_else(|| v.as_sequence());
    seq.map(|s| {
        s.iter()
            .filter_map(|x| x.as_str().map(|t| t.to_string()))
            .collect()
    })
    .unwrap_or_default()
}

/// Whether the task marks validation as required. A required task with no
/// commands to run is treated as a failed gate.
fn validation_required(task: &crate::schemas::Task) -> bool {
    task.validation
        .as_ref()
        .and_then(|v| v.get("required"))
        .and_then(|r| r.as_bool())
        .unwrap_or(false)
}

/// Does deterministic validation apply to this task? Configured validation
/// (e.g. `cargo test`) gates CODE: it is the acceptance of an implementation
/// task. A doc/research/review/safety task delivers findings as prose, so an
/// unrelated whole-app command is NOT its acceptance and must never flip it to
/// Failed (goal-1 c). Only builder-role (implementation) tasks are validated;
/// the split reuses the same role mapping the packet builder uses so a task's
/// kind decides validation and packet shape consistently.
fn validation_applies(task: &crate::schemas::Task) -> bool {
    crate::packet::role_for(&task.kind) == "builder"
}

/// Run `cmds` in `cwd` via `sh -c`, write the deterministic outcome to
/// `run_dir/validation.json`, and return `(any_ran, all_passed)`. Yardlet (not
/// the worker) decides whether validation passed.
/// How long a single validation command may run before Yardlet kills it. A
/// stuck command must not hang the orchestrator after the worker has finished.
const VALIDATION_TIMEOUT: Duration = Duration::from_secs(300);

/// Kill a timed-out validation command and its whole process group (so children
/// spawned by `npm test` / `cargo test` etc. do not survive the timeout), then
/// reap it. On unix the child leads its own group (process_group(0)), so a
/// negative pgid signals the group; the direct kill is a backstop.
fn kill_validation_child(child: &mut std::process::Child) {
    #[cfg(unix)]
    {
        let pgid = child.id();
        let _ = std::process::Command::new("kill")
            .arg("-9")
            .arg(format!("-{pgid}"))
            .status();
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// Run the task's validation commands as a deterministic gate. These commands
/// are planner-authored, so Yardlet runs them itself (not the worker) with a
/// billing-scrubbed core environment (no provider keys, no worker `pass_env`),
/// captures each command's output to the run dir, and kills any command that
/// exceeds VALIDATION_TIMEOUT. Returns (ran_any, all_passed); a timeout counts
/// as a failure. Note: the kill targets the `sh` process, not its whole process
/// tree, so a command that backgrounds a grandchild may leave it running.
fn run_validation_commands(
    cmds: &[String],
    cwd: &std::path::Path,
    run_dir: &std::path::Path,
    billing: &crate::schemas::BillingPolicy,
) -> (bool, bool) {
    use std::process::{Command, Stdio};
    let env = guard::scrub_env(std::env::vars(), &billing.blocked_worker_env_names);
    let mut results = Vec::new();
    let mut all_passed = true;
    for (i, c) in cmds.iter().enumerate() {
        let log_rel = format!("validation-{i}.log");
        let log = std::fs::File::create(run_dir.join(&log_rel)).ok();
        let mut cmd = Command::new("sh");
        cmd.arg("-c")
            .arg(c)
            .current_dir(cwd)
            .env_clear()
            .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
            .stdin(Stdio::null());
        // Put the command in its own process group so a timeout can kill the
        // whole tree (children of `sh` too), not just the shell.
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            cmd.process_group(0);
        }
        if let Some(f) = &log {
            if let (Ok(o), Ok(e)) = (f.try_clone(), f.try_clone()) {
                cmd.stdout(Stdio::from(o)).stderr(Stdio::from(e));
            }
        }
        let started = Instant::now();
        let (passed, code, timed_out) = match cmd.spawn() {
            Ok(mut child) => loop {
                match child.try_wait() {
                    Ok(Some(status)) => break (status.success(), status.code(), false),
                    Ok(None) => {
                        if started.elapsed() > VALIDATION_TIMEOUT {
                            kill_validation_child(&mut child);
                            break (false, None, true);
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                    Err(_) => break (false, None, false),
                }
            },
            Err(_) => (false, None, false),
        };
        if !passed {
            all_passed = false;
        }
        results.push(serde_json::json!({
            "command": c,
            "passed": passed,
            "exit_code": code,
            "timed_out": timed_out,
            "log": log_rel,
        }));
    }
    let report = serde_json::json!({
        "ran": !cmds.is_empty(),
        "all_passed": all_passed,
        "note": "planner-authored commands, run by Yardlet with a billing-scrubbed env; \
                 not sandboxed like a worker",
        "commands": results,
    });
    let _ = write_str(
        &run_dir.join("validation.json"),
        &serde_json::to_string_pretty(&report).unwrap_or_default(),
    );
    (!cmds.is_empty(), all_passed)
}

/// The worktree a run executed in, when it was a parallel worktree run.
pub(crate) fn run_worktree(run_dir: &std::path::Path) -> Option<PathBuf> {
    let yaml = std::fs::read_to_string(run_dir.join("run.yaml")).ok()?;
    let v = yaml
        .lines()
        .find_map(|l| l.trim().strip_prefix("worktree:"))
        .map(|v| v.trim().trim_matches('"').to_string())?;
    (v != "." && !v.is_empty()).then(|| PathBuf::from(v))
}

/// The worker a run used, read from its run.yaml so a recovered run's salvaged
/// telemetry stays attributable to the worker that produced it. Uses the typed
/// `RunRecord` load (every field defaults) rather than a hand-rolled line scan.
fn run_worker(run_dir: &std::path::Path) -> Option<String> {
    state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
        .ok()
        .map(|r| r.worker)
        .filter(|s| !s.is_empty())
}

/// The pid of a run's worker, if that process is still alive. The pid file is
/// written at spawn and removed when the worker exits cleanly under a live
/// Yardlet; an orphaned worker (Yardlet quit mid-run) keeps running with the file
/// in place.
pub(crate) fn live_worker_pid(run_dir: &std::path::Path) -> Option<u32> {
    let pid: u32 = std::fs::read_to_string(run_dir.join("worker.pid"))
        .ok()?
        .trim()
        .parse()
        .ok()?;
    // Signal 0: existence check only, never delivered.
    std::process::Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .ok()?
        .success()
        .then_some(pid)
}

/// A run Yardlet never finalized: its `worker.pid` is still on disk (a finalized
/// run removes it the moment it sees the worker exit), the process is now gone,
/// and it left a `result.json`. Such a run was orphaned by a dying orchestrator
/// *after* the worker finished but *before* evaluation — its completed work is
/// stranded. Distinct from a legitimately-failed run, which was evaluated and
/// so has no pid file left.
fn is_orphaned_unfinalized(run_dir: &std::path::Path) -> bool {
    run_dir.join("worker.pid").exists()
        && live_worker_pid(run_dir).is_none()
        && run_dir.join("result.json").exists()
}

/// A run that was prepared/started but never finalized and is no longer alive:
/// its run.yaml still reads `prepared`/`running` (never sealed), no worker
/// process is alive, and it left NO result.json. Distinct from
/// `is_orphaned_unfinalized`, which HAS a result to salvage. Such a run strands
/// its task when the task's own state (e.g. `NeedsUser` after a `yardlet answer`
/// run died before finalize) does not itself flag the task for recovery.
fn is_abandoned_run(run_dir: &std::path::Path) -> bool {
    let Ok(rec) = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")) else {
        return false;
    };
    rec.completed_at.is_none()
        && matches!(rec.state.as_str(), "prepared" | "running" | "")
        && live_worker_pid(run_dir).is_none()
        && !run_dir.join("result.json").exists()
}

/// Recover tasks left "running" by an interrupted/quit session: if the task's
/// latest run produced a result, evaluate it (keep the finished work); if its
/// worker is still alive (quitting Yardlet does not kill workers), ADOPT it —
/// keep the task Running and let a later pass evaluate the result, instead of
/// starting a duplicate worker on the same task. Only a dead worker with no
/// result is requeued. A parallel worktree run that finished Done is also
/// merged back — without this its changes would be stranded in the worktree
/// while the task reads Done. It also SALVAGES a task wrongly stuck `Failed`
/// when the orchestrator died after the worker finished but before evaluating
/// it (an unfinalized orphan run — `worker.pid` still on disk): the stranded
/// result is re-evaluated rather than the whole task re-run from scratch (a
/// genuinely-bad result stays failed). Returns messages describing what
/// changed. Safe to call on startup and periodically.
pub(crate) fn recover_orphans(ws: &Workspace) -> Vec<String> {
    let mut msgs = Vec::new();
    let Ok(mut q) = ws.load_queue() else {
        return msgs;
    };
    let billing = ws.load_billing().unwrap_or_default();
    let mut requeued = Vec::new();
    let mut finished = Vec::new();
    // Snapshot (id, state): the finalize branch borrows the queue mutably
    // through finalize_run, so we cannot hold an iter_mut over it here. Each
    // task's recover decision keys off its state at recovery start.
    let candidates: Vec<(String, TaskState)> =
        q.tasks.iter().map(|t| (t.id.clone(), t.state)).collect();
    for (id, state) in candidates {
        let latest = latest_run_for(ws, &id);
        let recover_this = match state {
            TaskState::Running => true,
            // Salvage a task wrongly stuck terminal because the orchestrator
            // died before evaluating a finished orphan run (worker.pid still on
            // disk, process gone, result written). Re-route it through the
            // evaluator — a genuinely-bad result stays failed; completed work
            // is no longer stranded by a full re-run.
            TaskState::Failed => latest
                .as_ref()
                .map(|(_, rd)| is_orphaned_unfinalized(rd))
                .unwrap_or(false),
            // A task stranded by an ABANDONED run: an answer/run spawned an
            // execution that died before finalize without persisting a Running
            // state (e.g. the worker never produced anything), so the task keeps
            // its pre-run NeedsUser state while its run.yaml is stuck `running`
            // with no result. The arms above key off task state and miss it;
            // catch it by the abandoned run record and requeue it to re-run.
            TaskState::NeedsUser => latest
                .as_ref()
                .map(|(_, rd)| is_abandoned_run(rd))
                .unwrap_or(false),
            _ => false,
        };
        if !recover_this {
            continue;
        }
        match latest {
            Some((run_id, run_dir)) if run_dir.join("result.json").exists() => {
                // Evidence for an orphan: its worktree (isolated, so git status
                // is exactly the worker's diff) when present, else the workspace's
                // own git status (an orphan froze the tree at the crash, so its
                // status is real evidence, not the worker's self-report). `None`
                // only when neither is a git repo, in which case the evaluator
                // fails closed.
                let evidence = run_worktree(&run_dir)
                    .filter(|w| w.exists())
                    .and_then(|w| evaluator::changed_paths(&w))
                    .or_else(|| {
                        // No worktree: the workspace git status is the evidence,
                        // but it also carries Yardlet's OWN canonical-state
                        // writes (it wrote the queue when it marked this task
                        // Running). With no pre-run baseline those cannot be
                        // attributed to the worker, so drop them rather than
                        // false-fail the canonical-state gate on Yardlet's own
                        // writes.
                        evaluator::changed_paths(&ws.root).map(|paths| {
                            paths
                                .into_iter()
                                .filter(|p| !evaluator::is_canonical_state_path(p))
                                .collect()
                        })
                    });
                // Mark this orphan run finalized so a later pass won't
                // re-evaluate it (a persistent failure must not loop).
                let _ = std::fs::remove_file(run_dir.join("worker.pid"));
                let Some(task) = q.tasks.iter().find(|t| t.id == id).cloned() else {
                    continue;
                };
                // Finalize through the shared pipeline: evaluate the stranded
                // result, merge a Done worktree back (conflict -> Partial,
                // worktree kept), and commit the state. Recovery flags keep it
                // to just that — no re-emitted artifacts/telemetry/hooks.
                let branch = format!("yard/{}", id.to_lowercase());
                let wt = run_worktree(&run_dir).filter(|w| w.exists());
                let merge = wt.as_ref().map(|w| MergeBack {
                    wt_path: w.as_path(),
                    branch: branch.as_str(),
                });
                // Attribute the salvaged telemetry to the worker that actually
                // ran it (recorded in run.yaml), not an empty string.
                let recovered_worker = run_worker(&run_dir).unwrap_or_default();
                match finalize_run(FinalizeInput {
                    ws,
                    run_dir: &run_dir,
                    run_id: &run_id,
                    task: &task,
                    evidence,
                    worker_id: &recovered_worker,
                    reason: "recovery",
                    wall_seconds: 0,
                    user_override: None,
                    intent_summary: "",
                    billing: &billing,
                    queue: &mut q,
                    flags: FinalizeFlags::recovery(),
                    merge,
                }) {
                    Ok(report) => {
                        // Surface only the task-prefixed merge lines; the generic
                        // eval/ingest lines would clutter the recovery summary.
                        for line in report.lines {
                            if line.starts_with(&format!("{id}: ")) {
                                msgs.push(line);
                            }
                        }
                        finished.push(format!("{} \u{2192} {:?}", id, report.next_state));
                    }
                    Err(e) => msgs.push(format!("{id}: recovery finalize error: {e}")),
                }
            }
            run => {
                // Worker still alive: adopt it — its original session keeps
                // working; the result lands in the run dir and the next
                // recovery pass evaluates it.
                if let Some((_, run_dir)) = &run {
                    if let Some(pid) = live_worker_pid(run_dir) {
                        msgs.push(format!(
                            "adopted: {id} still running from a previous session (pid {pid})"
                        ));
                        continue;
                    }
                }
                // Dead with no result: redo from scratch; drop the worktree and
                // SEAL the stranded run record (it was left stuck `running`) so a
                // later recovery pass does not re-detect it as an abandoned run.
                if let Some((run_id, run_dir)) = run {
                    if let Some(wt) = run_worktree(&run_dir).filter(|w| w.exists()) {
                        let branch = format!("yard/{}", id.to_lowercase());
                        crate::parallel::remove_worktree(&ws.root, &wt, &branch);
                    }
                    if let Some(t) = q.tasks.iter().find(|t| t.id == id).cloned() {
                        let worker = run_worker(&run_dir).unwrap_or_default();
                        seal_run_record(
                            &run_dir,
                            &run_id,
                            &t,
                            &q.intent_id,
                            &worker,
                            TaskState::Failed,
                            None,
                        );
                    }
                    let _ = std::fs::remove_file(run_dir.join("worker.pid"));
                }
                if let Some(t) = q.tasks.iter_mut().find(|t| t.id == id) {
                    t.state = TaskState::Queued;
                }
                // Persist now: a later sibling's finalize_run re-reads the queue
                // from disk, which would otherwise clobber this in-memory requeue.
                let _ = ws.save_queue(&q);
                requeued.push(id.clone());
            }
        }
    }
    if !finished.is_empty() || !requeued.is_empty() {
        let _ = ws.save_queue(&q);
        if !finished.is_empty() {
            msgs.push(format!(
                "recovered completed run(s): {}",
                finished.join(", ")
            ));
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

pub(crate) fn find_worker<'a>(workers: &'a [WorkerProfile], id: &str) -> Result<&'a WorkerProfile> {
    workers
        .iter()
        .find(|w| w.id == id)
        .ok_or_else(|| anyhow!("worker '{id}' is not defined in .agents/workers.yaml"))
}

fn save_task_state_on_latest_queue(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> Result<()> {
    finalize_on_latest_queue(
        ws,
        fallback_queue,
        task_id,
        state,
        &[],
        &[],
        None,
        cause,
        detail,
        actor,
    )
    .map(|_| ())
}

/// Re-point a finished review at the queue (1c review auto-remediation): set its
/// state and, for a soft re-verify (`fix_ids` non-empty, re-queued `Queued`),
/// re-sequence it to run just AFTER the remediation fixes by PRIORITY — never a
/// hard `depends_on` edge. A hard edge deadlocks: `deps_met` only clears on Done,
/// so a fix that fails / is deferred / is title-deduped would strand the review
/// forever. With soft ordering the fixes run first by priority; if one never
/// reaches Done it simply leaves the Queued set and the review re-verifies anyway,
/// and the drain's per-task attempt cap bounds the fix+re-verify loop ("try hard,
/// then ask"). Re-reads the latest queue first so a concurrent change is not
/// clobbered.
/// Of the just-ingested follow-up ids, those that can run RIGHT NOW: `Queued`
/// AND dependency-satisfied. This mirrors `select_next` eligibility exactly so a
/// failed review (1c) is soft-sequenced ONLY behind fixes that will actually run
/// before it — an off-vocabulary fix parked `Blocked`, a `Deferred` one, or a
/// `Queued` fix carrying its own unmet `depends_on` is excluded, so the dep-free
/// review can never out-race a still-gated fix and re-verify unchanged code. When
/// this is empty the review surfaces to the user instead.
fn runnable_fix_ids(queue: &WorkQueue, ingested: &[String]) -> Vec<String> {
    ingested
        .iter()
        .filter(|id| {
            queue
                .tasks
                .iter()
                .any(|t| &t.id == *id && t.state == TaskState::Queued && queue.deps_met(t))
        })
        .cloned()
        .collect()
}

fn requeue_review(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    review_id: &str,
    state: TaskState,
    fix_ids: &[String],
) -> Result<()> {
    let mut latest = ws.load_queue().unwrap_or_else(|_| fallback_queue.clone());
    if state == TaskState::Queued && !fix_ids.is_empty() {
        // Lowest priority among the other queued tasks: pull the fixes just below
        // it (run first) and slot the review between the fixes and the rest, so
        // the selector runs every fix before re-verifying. Equal-priority fixes
        // tie-break by queue order, preserving the reviewer's proposal order.
        let front = latest
            .tasks
            .iter()
            .filter(|t| t.state == TaskState::Queued && t.id != review_id)
            .map(|t| t.priority)
            .min()
            .unwrap_or(0);
        for t in latest.tasks.iter_mut() {
            if fix_ids.iter().any(|f| f == &t.id) {
                t.priority = front - 20;
            }
        }
        if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == review_id) {
            let from = t.state;
            t.state = state;
            t.priority = front - 10;
            if from != state {
                state::append_transition(
                    ws,
                    state::transition(
                        review_id,
                        from,
                        state,
                        TransitionCause::RunOutcome,
                        "review failed; requeued behind runnable remediation",
                        TransitionActor::System,
                    ),
                )?;
            }
        }
    } else if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == review_id) {
        let from = t.state;
        t.state = state;
        if from != state {
            state::append_transition(
                ws,
                state::transition(
                    review_id,
                    from,
                    state,
                    TransitionCause::RunOutcome,
                    "review failed with no runnable fix; paused for user",
                    TransitionActor::System,
                ),
            )?;
        }
    }
    ws.save_queue(&latest)?;
    *fallback_queue = latest;
    Ok(())
}

/// Re-read the latest on-disk queue, set the finished task's state, ingest any
/// worker-proposed follow-up tasks, and save once. Re-reading first means a
/// change made since the run started is not clobbered by a stale start-of-run
/// copy; folding the state update and follow-up ingestion into one write keeps
/// Yardlet the sole queue writer (propose -> ingest). Returns the ids of the
/// follow-up tasks ingested.
// The single canonical "settle a task on the latest queue" path: it needs the
// full run context (identity, scope, follow-ups, worker vocab) plus the typed
// transition record (cause/detail/actor). Bundling would just scatter one
// cohesive call, so keep the args explicit.
#[allow(clippy::too_many_arguments)]
fn finalize_on_latest_queue(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    intent_allowed_scope: &[String],
    follow_ups: &[crate::schemas::FollowUpTask],
    workers: Option<&WorkersFile>,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> Result<Vec<String>> {
    // Ground any just-ingested follow-up's capabilities against the real
    // workers before saving: a follow-up requiring a capability no worker has is
    // parked Blocked at ingest, not crashed into when the drain later picks it.
    let reconcile = |q: &mut WorkQueue| {
        if let Some(w) = workers {
            let _ = crate::planner::reconcile_queue_capabilities(q, w);
        }
    };
    let mut latest = ws.load_queue().unwrap_or_else(|_| fallback_queue.clone());
    if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == task_id) {
        let from = t.state;
        t.state = state;
        let ingested = crate::planner::ingest_follow_ups(
            &mut latest,
            intent_allowed_scope,
            follow_ups,
            Some(ws),
        );
        reconcile(&mut latest);
        ws.save_queue(&latest)?;
        if from != state {
            state::append_transition(
                ws,
                state::transition(task_id, from, state, cause, detail, actor.clone()),
            )?;
        }
        append_ingested_decision_transitions(ws, &latest, &ingested)?;
        *fallback_queue = latest;
        return Ok(ingested);
    }

    // The task vanished from the on-disk queue (rare): fall back to the
    // in-memory copy so the state update is not lost.
    if let Some(t) = fallback_queue.tasks.iter_mut().find(|t| t.id == task_id) {
        let from = t.state;
        t.state = state;
        if from != state {
            state::append_transition(
                ws,
                state::transition(task_id, from, state, cause, detail, actor),
            )?;
        }
    }
    let ingested = crate::planner::ingest_follow_ups(
        fallback_queue,
        intent_allowed_scope,
        follow_ups,
        Some(ws),
    );
    reconcile(fallback_queue);
    ws.save_queue(fallback_queue)?;
    append_ingested_decision_transitions(ws, fallback_queue, &ingested)?;
    Ok(ingested)
}

fn append_ingested_decision_transitions(
    ws: &Workspace,
    queue: &WorkQueue,
    ingested: &[String],
) -> Result<()> {
    for id in ingested {
        if let Some(task) = queue
            .tasks
            .iter()
            .find(|t| &t.id == id && t.state == TaskState::NeedsUser)
        {
            state::append_transition(
                ws,
                state::transition(
                    &task.id,
                    TaskState::Queued,
                    TaskState::NeedsUser,
                    TransitionCause::DecisionSeed,
                    "seeded worker-proposed human decision as a NeedsUser question",
                    TransitionActor::System,
                ),
            )?;
        }
    }
    Ok(())
}

/// Per-path divergences in the finalization pipeline. The serial path runs
/// every step; parallel skips the in-place-only gates (hooks/validation/
/// conversation/learned); recovery skips artifacts/telemetry too. Slice 1
/// wires the serial path only — the flags exist so a later slice can flip
/// them for parallel/recovery without re-deriving the pipeline.
pub(crate) struct FinalizeFlags {
    pub post_hooks: bool,
    pub validation: bool,
    pub conversation: bool,
    pub learned: bool,
    pub artifacts: bool,
    pub telemetry: bool,
    /// Ingest worker-proposed follow-ups AND run review auto-remediation (both
    /// rewrite queue topology from the worker's proposals). Off for recovery,
    /// which must only finalize the stranded run, not mutate the queue graph.
    pub follow_ups: bool,
}

impl FinalizeFlags {
    /// The serial path runs the full finalization pipeline.
    pub fn serial() -> Self {
        Self {
            post_hooks: true,
            validation: true,
            conversation: true,
            learned: true,
            artifacts: true,
            telemetry: true,
            follow_ups: true,
        }
    }

    /// The parallel path runs in an isolated worktree, so the in-tree gates that
    /// need the real workspace are deferred: validation is OFF (the pre-merge
    /// worktree lacks gitignored build deps like node_modules/target, so running
    /// it there spuriously fails self-contained-looking tasks — a post-merge gate
    /// is the proper future design), and post-run hooks are OFF for the same
    /// reason. The evaluator's forbidden-path gate still runs on the worktree
    /// diff, so the safety floor holds. Conversation/learned are skipped (batches
    /// only pick Queued tasks). Artifacts, telemetry, and follow-up ingestion land.
    pub fn parallel() -> Self {
        Self {
            post_hooks: false,
            validation: false,
            conversation: false,
            learned: false,
            artifacts: true,
            telemetry: true,
            follow_ups: true,
        }
    }

    /// Recovery salvages an interrupted run: re-evaluate its stranded result,
    /// merge a Done worktree back, and commit the state. Artifacts/hooks/
    /// validation stay off, and follow-up ingestion + review auto-remediation are
    /// OFF too — recovery must NOT mutate the queue graph (re-queue a review, add
    /// dependency edges, ingest new tasks) during a crash-recovery pass; it only
    /// finalizes the one stranded run. Telemetry IS emitted (labeled `reason:
    /// recovery`, attributed to the run.yaml worker) so the trust report does not
    /// undercount salvaged tasks.
    pub fn recovery() -> Self {
        Self {
            post_hooks: false,
            validation: false,
            conversation: false,
            learned: false,
            artifacts: false,
            telemetry: true,
            follow_ups: false,
        }
    }
}

/// A worker's isolated worktree to merge back into the main workspace when its
/// run lands Done. Set by the parallel and recovery paths (which run in a
/// worktree on branch `yard/<task-id>`); `None` for the serial path, which edits
/// the workspace in place and has nothing to merge.
pub(crate) struct MergeBack<'a> {
    pub wt_path: &'a std::path::Path,
    pub branch: &'a str,
}

/// Everything one finished worker run needs to turn its raw output into
/// committed state. `evidence` is computed by the caller because the serial
/// (fingerprint-diff) and parallel (worktree status) paths derive it
/// differently; finalize_run evaluates from it.
pub(crate) struct FinalizeInput<'a> {
    pub ws: &'a Workspace,
    pub run_dir: &'a std::path::Path,
    pub run_id: &'a str,
    pub task: &'a crate::schemas::Task,
    pub evidence: Option<Vec<String>>,
    pub worker_id: &'a str,
    pub reason: &'a str,
    pub wall_seconds: u64,
    pub user_override: Option<String>,
    pub intent_summary: &'a str,
    pub billing: &'a crate::schemas::BillingPolicy,
    pub queue: &'a mut WorkQueue,
    pub flags: FinalizeFlags,
    /// When the run lands Done, merge this worktree back (parallel/recovery). A
    /// conflict downgrades the task to Partial and keeps the worktree.
    pub merge: Option<MergeBack<'a>>,
}

pub(crate) struct FinalizeReport {
    pub next_state: TaskState,
    pub lines: Vec<String>,
}

/// The single finalization pipeline shared by the run paths (Slice 1: serial
/// only). Evaluate -> gates -> artifacts -> conversation -> learned -> queue
/// state + follow-up ingestion -> telemetry. Behavior is identical to the
/// inline serial code it replaces; only the structure changed.
pub(crate) fn finalize_run(input: FinalizeInput) -> Result<FinalizeReport> {
    let FinalizeInput {
        ws,
        run_dir,
        run_id,
        task,
        evidence,
        worker_id,
        reason,
        wall_seconds,
        user_override,
        intent_summary,
        billing,
        queue,
        flags,
        merge,
    } = input;
    let mut lines = Vec::new();
    // Capture the intent this run belonged to BEFORE finalize_on_latest_queue
    // reloads `queue` from disk (which would swap in a re-plan's intent_id):
    // telemetry must attribute the run to the intent it actually ran under.
    let intent_id = queue.intent_id.clone();

    let mut eval = evaluator::evaluate(run_dir, run_id, task, evidence.as_deref());

    // H3: workspace-owned post-run gates. A non-zero hook is a fatal check the
    // task cannot be Done past (e.g. scanning the produced diff for secrets).
    if flags.post_hooks {
        let post =
            crate::hooks::run_phase(ws, crate::hooks::Phase::Post, &task.id, run_dir, worker_id);
        if !post.ok() {
            for f in &post.failures {
                lines.push(format!(
                    "post-run hook failed (blocks Done): {}",
                    f.summary()
                ));
                eval.checks
                    .push(evaluator::fatal_failure("post-run hook", f.summary()));
            }
            if eval.next_task_state == TaskState::Done {
                eval.next_task_state = TaskState::Failed;
            }
        }
    }

    // Deterministic validation: Yardlet core runs the task's configured
    // validation commands itself. Any failure (or a `required` task with
    // nothing to run) is fatal and blocks Done. Scoped to code tasks: a
    // doc/non-code task is not failed by an unrelated whole-app command
    // (goal-1 c) — see `validation_applies`.
    if flags.validation && validation_applies(task) {
        // A worktree run (parallel/recovery) validates its worktree — its edits
        // live there until merged — so a failing task is caught BEFORE the merge
        // and never reaches the workspace (it stays Partial, worktree kept). The
        // serial path edits in place and validates the workspace itself.
        let validation_cwd = merge
            .as_ref()
            .map(|m| m.wt_path)
            .unwrap_or(ws.root.as_path());
        let validation_cmds = validation_commands(task);
        let (validation_ran, validation_passed) =
            run_validation_commands(&validation_cmds, validation_cwd, run_dir, billing);
        if (validation_ran && !validation_passed) || (validation_required(task) && !validation_ran)
        {
            lines.push("validation failed (blocks Done)".to_string());
            eval.checks.push(evaluator::fatal_failure(
                "validation",
                "configured validation did not pass",
            ));
            if eval.next_task_state == TaskState::Done {
                eval.next_task_state = TaskState::Failed;
            }
        }
    }

    if flags.artifacts {
        state::write_str(
            &run_dir.join("evaluation.json"),
            &serde_json::to_string_pretty(&eval)?,
        )?;
    }

    let result: Option<RunResult> = std::fs::read_to_string(run_dir.join("result.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok());

    // Record the worker's user-facing message into the conversation transcript
    // whenever a run pauses for the user, so the next resume threads the full
    // exchange back (deduped by run_id).
    if flags.conversation {
        if let Some(q) = result
            .as_ref()
            .filter(|r| r.status == "needs_user")
            .and_then(|r| {
                r.question_for_user
                    .as_deref()
                    .map(str::trim)
                    .filter(|q| !q.is_empty())
            })
        {
            let _ = state::append_conversation_turn(
                ws,
                &task.id,
                ConversationTurn {
                    role: TurnRole::Worker,
                    text: q.to_string(),
                    run_id: run_id.to_string(),
                    ts: Local::now().to_rfc3339(),
                },
            );
        }
    }

    if flags.artifacts {
        compact::write_checkpoint(run_dir, task, &eval, result.as_ref(), intent_summary)?;
        compact::write_handoff(run_dir, task, &eval, result.as_ref())?;
        if let Some(r) = &result {
            append_nonblocking_follow_up_notes(run_dir, r)?;
        }
    }

    // Harness learning loop (S3): record skills/rules the worker proposed. The
    // worker authored the content; Yardlet (the core) does the writing.
    if flags.learned {
        if let Some(r) = &result {
            let learned = crate::skills::record_run_suggestions(ws, &r.harness_suggestions);
            if !learned.is_empty() {
                lines.push(format!("learned skill(s): {}", learned.join(", ")));
            }
            let rules = crate::skills::record_run_rules(ws, &r.harness_suggestions);
            if !rules.is_empty() {
                lines.push(format!("learned rule(s): {}", rules.join(", ")));
            }
        }
    }

    // Integrate the worktree (parallel/recovery only). A Done run is merged
    // back into the workspace in completion order; a conflict (or any merge
    // error) is never auto-resolved — the task drops to Partial and its worktree
    // is kept for manual integration. The committed state below is this
    // post-merge state, so the queue and telemetry both record what really
    // happened.
    let mut next_state = eval.next_task_state;
    if let Some(m) = &merge {
        if next_state == TaskState::Done {
            match crate::parallel::integrate_worktree(&ws.root, m.wt_path, m.branch, &task.id) {
                Ok(crate::parallel::Integration::Merged) => {
                    lines.push(format!(
                        "{}: merged {} into the workspace",
                        task.id, m.branch
                    ));
                    crate::parallel::remove_worktree(&ws.root, m.wt_path, m.branch);
                }
                Ok(crate::parallel::Integration::NoChanges) => {
                    lines.push(format!("{}: no file changes to merge", task.id));
                    crate::parallel::remove_worktree(&ws.root, m.wt_path, m.branch);
                }
                Ok(crate::parallel::Integration::Conflict(why)) => {
                    next_state = TaskState::Partial;
                    let _ = state::write_str(&run_dir.join("partial-reason"), "merge_conflict");
                    let note = format!(
                        "\n## Merge conflict\n\nYard could not merge `{}` back: {}\n\
                         The worktree is kept at `{}` for manual integration.\n",
                        m.branch,
                        why.trim(),
                        m.wt_path.display()
                    );
                    let hp = run_dir.join("handoff.md");
                    let mut existing = std::fs::read_to_string(&hp).unwrap_or_default();
                    existing.push_str(&note);
                    let _ = state::write_str(&hp, &existing);
                    lines.push(format!(
                        "{}: merge conflict — task is partial; worktree kept at {}",
                        task.id,
                        m.wt_path.display()
                    ));
                }
                Err(e) => {
                    next_state = TaskState::Partial;
                    let _ = state::write_str(&run_dir.join("partial-reason"), "merge_conflict");
                    lines.push(format!("{}: integration error: {e}", task.id));
                }
            }
        } else {
            lines.push(format!(
                "{}: {:?} — worktree kept at {}",
                task.id,
                next_state,
                m.wt_path.display()
            ));
        }
    }

    // Update the queue: set state AND ingest any follow-up tasks the worker
    // proposed (propose -> ingest). Yardlet stays the sole queue writer — both
    // land in one re-read-then-save.
    // Recovery (follow_ups off) only finalizes the stranded run's state — it must
    // not ingest new follow-ups or re-queue a review, which would rewrite the
    // queue graph during a crash-recovery pass.
    let follow_ups = if flags.follow_ups {
        result
            .as_ref()
            .map(|r| r.follow_up_tasks.clone())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    // Workers (when loadable) let the queue commit ground a proposed follow-up's
    // capabilities; if workers.yaml can't be read we skip grounding rather than
    // false-park everything.
    let workers = ws.load_workers().ok();
    let intent_allowed_scope = if flags.follow_ups {
        ws.load_intent()
            .ok()
            .flatten()
            .map(|i| i.allowed_scope)
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    let ingested = finalize_on_latest_queue(
        ws,
        queue,
        &task.id,
        next_state,
        &intent_allowed_scope,
        &follow_ups,
        workers.as_ref(),
        TransitionCause::RunOutcome,
        &format!("worker evaluated task as {next_state:?}"),
        TransitionActor::Worker(run_id.to_string()),
    )?;
    if !ingested.is_empty() {
        lines.push(format!(
            "ingested {} worker-proposed follow-up task(s): {}",
            ingested.len(),
            ingested.join(", ")
        ));
    }

    // The run's evaluated outcome, captured BEFORE review auto-remediation may
    // overwrite next_state to Queued/NeedsUser — telemetry must record what the
    // run actually evaluated to (a failed review), not the queue-management
    // decision, or the trust report would not see the failure.
    let evaluated_state = next_state;

    // Review auto-remediation (1c): a review that failed its criteria must not
    // blind-loop on the same unchanged code. Re-queue THIS review to run AFTER the
    // reviewer's proposed remediation (soft priority ordering, no hard dep) so the
    // fix runs first and the review then re-verifies; the drain's per-task attempt
    // cap bounds the cycles.
    let is_review = matches!(crate::packet::role_for(&task.kind), "reviewer" | "security");
    if flags.follow_ups && is_review && matches!(next_state, TaskState::Failed | TaskState::Partial)
    {
        // Sequence only behind fixes that can actually run NOW (Queued &&
        // deps_met). With no runnable fix, surface to the user instead.
        let runnable = runnable_fix_ids(queue, &ingested);
        if runnable.is_empty() {
            requeue_review(ws, queue, &task.id, TaskState::NeedsUser, &[])?;
            next_state = TaskState::NeedsUser;
            lines.push(format!(
                "{}: review failed with no runnable fix — needs you",
                task.id
            ));
        } else {
            requeue_review(ws, queue, &task.id, TaskState::Queued, &runnable)?;
            next_state = TaskState::Queued;
            lines.push(format!(
                "{}: review failed — re-queued behind remediation [{}] to re-verify",
                task.id,
                runnable.join(", ")
            ));
        }
    }

    if flags.telemetry {
        let _ = telemetry::append_run(
            ws,
            &telemetry::RunTelemetry {
                ts: Local::now().to_rfc3339(),
                task_id: task.id.clone(),
                intent_id: intent_id.clone(),
                kind: task.kind.clone(),
                risk: task.risk.clone(),
                worker: worker_id.to_string(),
                chosen_reason: reason.to_string(),
                result_status: result
                    .as_ref()
                    .map(|r| r.status.clone())
                    .unwrap_or_else(|| "no-result".to_string()),
                eval_state: format!("{evaluated_state:?}"),
                wall_seconds,
                user_override,
                skills: task.skills.clone(),
                verdict_pass: result.as_ref().and_then(|r| {
                    (!r.verdict.is_empty())
                        .then(|| (r.verdict.iter().filter(|v| v.pass).count(), r.verdict.len()))
                }),
            },
        );
    }

    lines.push(format!("evaluation status: {}", eval.status));
    lines.push(format!("next task state: {next_state:?}"));

    // Seal the run record. It was written "running" at spawn and never updated,
    // so without this every run.yaml looks in-flight forever — the Trust Report
    // and any run-dir scan cannot tell a finished run from a stranded one. All
    // paths (serial/parallel/recovery) end here, so this single write keeps the
    // record honest. Best-effort: a record failure must not fail the run.
    seal_run_record(
        run_dir,
        run_id,
        task,
        // The captured spawn-time intent (not the post-reload `queue.intent_id`),
        // same as telemetry above — attribute the record to the intent the run
        // belonged to even if the on-disk queue was re-planned mid-run.
        intent_id.as_str(),
        worker_id,
        next_state,
        merge.as_ref(),
    );

    Ok(FinalizeReport { next_state, lines })
}

/// Snake-case label for a run's terminal outcome, matching the queue's
/// `TaskState` vocabulary so a sealed run.yaml reads the same as the queue.
fn run_outcome_label(state: TaskState) -> &'static str {
    match state {
        TaskState::Queued => "queued",
        TaskState::Running => "running",
        TaskState::Done => "done",
        TaskState::Blocked => "blocked",
        TaskState::Failed => "failed",
        TaskState::NeedsUser => "needs_user",
        TaskState::Partial => "partial",
        TaskState::Deferred => "deferred",
    }
}

/// Rewrite `run.yaml` from its in-flight `running` to the run's real terminal
/// outcome with a `completed_at`. Preserves the spawn-time fields by re-reading
/// the existing record; falls back to what `finalize_run` already knows if the
/// file is missing or unreadable.
fn seal_run_record(
    run_dir: &std::path::Path,
    run_id: &str,
    task: &crate::schemas::Task,
    intent_id: &str,
    worker_id: &str,
    next_state: TaskState,
    merge: Option<&MergeBack>,
) {
    let path = run_dir.join("run.yaml");
    let mut rec: RunRecord = state::load_yaml(&path).unwrap_or(RunRecord {
        schema_version: 1,
        run_id: run_id.to_string(),
        task_id: task.id.clone(),
        intent_id: intent_id.to_string(),
        worker: worker_id.to_string(),
        state: String::new(),
        started_at: String::new(),
        completed_at: None,
        worktree: merge
            .map(|m| m.wt_path.display().to_string())
            .unwrap_or_else(|| ".".to_string()),
    });
    rec.state = run_outcome_label(next_state).to_string();
    rec.worker = worker_id.to_string();
    rec.completed_at = Some(Local::now().to_rfc3339());
    let _ = state::save_yaml(&path, &rec);
}

fn record_failover(run_dir: &std::path::Path, from: &str, to: &str, reason: &str) {
    let event = RunFailover {
        from: from.to_string(),
        to: to.to_string(),
        reason: reason.to_string(),
        at: Local::now().to_rfc3339(),
    };
    let _ = write_str(
        &run_dir.join("failover.json"),
        &serde_json::to_string_pretty(&event).unwrap_or_default(),
    );
}

fn append_failover_note(run_dir: &std::path::Path, note: &str) -> Result<()> {
    let mut md = String::from("\n## Worker failover\n\n");
    md.push_str(note);
    md.push('\n');
    append_str(&run_dir.join("checkpoint.md"), &md)?;
    append_str(&run_dir.join("handoff.md"), &md)?;
    Ok(())
}

fn append_nonblocking_follow_up_notes(run_dir: &std::path::Path, result: &RunResult) -> Result<()> {
    if result.status != "done" || result.follow_up_tasks.is_empty() {
        return Ok(());
    }
    let mut note = String::from("\n## Non-blocking follow-up notes\n\n");
    note.push_str(
        "Acceptance was reported as complete. These leftovers did not block Done and were \
         kept as follow-up notes:\n",
    );
    let mut wrote_item = false;
    for fu in &result.follow_up_tasks {
        let title = fu.title.trim();
        if title.is_empty() {
            continue;
        }
        wrote_item = true;
        note.push_str("- ");
        note.push_str(title);
        let reason = fu.reason.trim();
        if !reason.is_empty() {
            note.push_str(": ");
            note.push_str(reason);
        }
        note.push('\n');
    }
    if !wrote_item {
        return Ok(());
    }
    append_str(&run_dir.join("checkpoint.md"), &note)?;
    append_str(&run_dir.join("handoff.md"), &note)?;
    Ok(())
}

/// Context for CONTINUING a Partial task instead of redoing it: the previous
/// run's checkpoint plus what evaluation said is still missing. Injected into
/// the next packet of that task (docs/harness.md, phase H2).
pub(crate) fn continuation_context(ws: &Workspace, task_id: &str) -> Option<String> {
    let (_, run_dir) = latest_run_for(ws, task_id)?;
    let mut s = String::new();
    if let Ok(cp) = std::fs::read_to_string(run_dir.join("checkpoint.md")) {
        s.push_str(cp.trim());
        s.push_str("\n\n");
    }
    if let Ok(raw) = std::fs::read_to_string(run_dir.join("result.json")) {
        if let Ok(r) = serde_json::from_str::<RunResult>(&raw) {
            if !r.compact_summary.is_empty() {
                s.push_str("Previous run summary: ");
                s.push_str(&r.compact_summary);
                s.push('\n');
            }
            if !r.validation.failures.is_empty() {
                s.push_str("Unresolved failures:\n");
                for f in &r.validation.failures {
                    s.push_str("- ");
                    s.push_str(f);
                    s.push('\n');
                }
            }
        }
    }
    // Keep the packet lean even if a checkpoint ballooned.
    const CAP: usize = 6 * 1024;
    if s.len() > CAP {
        let mut end = CAP;
        while !s.is_char_boundary(end) {
            end -= 1;
        }
        s.truncate(end);
        s.push_str("\n[truncated]");
    }
    let trimmed = s.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// Did this task's latest run go Partial because of a merge conflict (needs a
/// human) rather than a worker self-report (safe to auto-continue)?
pub(crate) fn partial_is_conflict(ws: &Workspace, task_id: &str) -> bool {
    latest_run_for(ws, task_id)
        .map(|(_, dir)| dir.join("partial-reason").exists())
        .unwrap_or(false)
}

/// The intent a run belonged to, read from its `run.yaml` (empty if unknown).
fn run_intent_id(run_dir: &std::path::Path) -> Option<String> {
    state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
        .ok()
        .map(|r| r.intent_id)
        .filter(|s| !s.is_empty())
}

/// The most recent unanswered question a worker left for a given task, if any.
///
/// Scoped to the CURRENT intent. Task ids repeat across intents (a fresh plan
/// can reuse `YARD-001`), and a past plan's `result.json`/conversation stays on
/// disk (new plans do not sweep `runs/`). Without intent scoping the newest
/// on-disk run for that bare id wins — surfacing a stale question from a past
/// intent (the dogfood-caught stale-question defect). We take the live intent
/// from the queue and only consider runs/turns that belong to it. When the
/// intent is unknown (no queue / unattributed legacy run) we fall back to the
/// old bare-id behavior rather than hide a genuine question.
pub fn latest_question_for(ws: &Workspace, task_id: &str) -> Option<String> {
    let current_intent = ws
        .load_queue()
        .ok()
        .map(|q| q.intent_id)
        .filter(|s| !s.is_empty());
    let mut best: Option<(SystemTime, String)> = None;
    if let Ok(entries) = std::fs::read_dir(ws.runs_dir()) {
        for entry in entries.flatten() {
            let dir = entry.path();
            let result_path = dir.join("result.json");
            let Ok(text) = std::fs::read_to_string(&result_path) else {
                continue;
            };
            let Ok(result) = serde_json::from_str::<RunResult>(&text) else {
                continue;
            };
            if result.task_id != task_id {
                continue;
            }
            // Reject a same-id result that belongs to a different (past) intent.
            if let Some(cur) = &current_intent {
                if run_intent_id(&dir).as_deref() != Some(cur.as_str()) {
                    continue;
                }
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
    }
    if let Some((_, q)) = best {
        return Some(q);
    }
    // Fallback: a question seeded straight into the conversation (a
    // worker-proposed DECISION follow-up ingested as NeedsUser) has no run
    // result.json. It is pending only while unanswered — i.e. the last turn is
    // still the worker's; once the user replies, the last turn is theirs. The
    // conversation file is per-task and also survives replanning, so scope the
    // last worker turn to the current intent when its run is attributable.
    let conv = ws.load_conversation(task_id);
    match conv.turns.last() {
        Some(t) if t.role == TurnRole::Worker && !t.text.trim().is_empty() => {
            if let Some(cur) = &current_intent {
                if !t.run_id.is_empty() {
                    let rd = ws.runs_dir().join(&t.run_id);
                    if rd.join("run.yaml").exists()
                        && run_intent_id(&rd).as_deref() != Some(cur.as_str())
                    {
                        return None;
                    }
                }
            }
            Some(t.text.clone())
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{SelectionPolicy, Task, WorkQueue};

    #[test]
    fn gate_messages_are_surface_neutral_no_command_literals() {
        // AC-004: engine-streamed guidance names WHAT to do, never a `yardlet ...`
        // command literal (each surface renders its own affordance).
        let msgs = [
            gate_msg::needs_user("YARD-007"),
            gate_msg::blocked("YARD-008"),
            gate_msg::drained_with_deferred(&["YARD-009", "YARD-010"]),
            gate_msg::drained_complete(),
        ];
        for m in &msgs {
            assert!(
                !m.contains("yardlet"),
                "gate message leaked a command literal: {m:?}"
            );
        }
        assert!(gate_msg::needs_user("YARD-007").contains("YARD-007"));
        assert!(gate_msg::blocked("YARD-008").contains("YARD-008"));
        let def = gate_msg::drained_with_deferred(&["YARD-009", "YARD-010"]);
        assert!(def.contains("YARD-009") && def.contains("YARD-010"));
    }

    #[test]
    fn validation_runner_blocks_on_failure() {
        let dir = std::env::temp_dir().join(format!("yard-valrun-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let billing = crate::schemas::BillingPolicy::default();
        // A passing command -> ran and passed.
        let (ran, passed) = run_validation_commands(&["true".to_string()], &dir, &dir, &billing);
        assert!(ran && passed);
        // A failing command -> ran but not passed (this is the gate that blocks Done).
        let (ran, passed) = run_validation_commands(&["false".to_string()], &dir, &dir, &billing);
        assert!(ran && !passed);
        assert!(dir.join("validation.json").is_file());
        // No commands -> nothing ran (a task with nothing to validate is allowed).
        let (ran, _) = run_validation_commands(&[], &dir, &dir, &billing);
        assert!(!ran);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn validation_scoped_to_code_tasks_only() {
        // goal-1 c: configured validation gates CODE. A doc/non-code task must
        // not be run through (and failed by) an unrelated whole-app command.
        let mut t = task("X", TaskState::Queued, 1, false);
        for k in ["", "implementation", "IMPLEMENTATION", "feature"] {
            t.kind = k.into();
            assert!(validation_applies(&t), "code task {k:?} should validate");
        }
        for k in ["research", "review", "safety"] {
            t.kind = k.into();
            assert!(
                !validation_applies(&t),
                "non-code task {k:?} must not be gated by validation"
            );
        }
    }

    fn write_needs_user_run(ws: &Workspace, run_id: &str, intent: &str, question: &str) {
        let rd = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&rd).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "needs_user".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: Some(question.into()),
            compact_summary: String::new(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &rd.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(
            &rd.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\nintent_id: {intent}\n"),
        )
        .unwrap();
    }

    #[test]
    fn latest_question_is_scoped_to_the_current_intent() {
        // stale-question (AC-006): a past plan's result.json for the SAME task id
        // stays on disk. `answer` must surface the CURRENT intent's question, not
        // the past one — even when the stale run is newer on disk.
        let root = std::env::temp_dir().join(format!("yard-staleq-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::NeedsUser, 10, false);
        t.kind = "implementation".into();
        let mut q = queue(vec![t]);
        q.intent_id = "intent-current".into();
        ws.save_queue(&q).unwrap();

        // Current-intent run FIRST, then a NEWER stale run from a past intent
        // that reused the same task id. Newest-by-mtime would pick the stale one.
        write_needs_user_run(
            &ws,
            "run-20260710-100000",
            "intent-current",
            "current question",
        );
        write_needs_user_run(
            &ws,
            "run-20260710-120000",
            "intent-old",
            "STALE past question",
        );

        assert_eq!(
            latest_question_for(&ws, "YARD-001").as_deref(),
            Some("current question")
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn latest_question_ignores_a_past_intent_when_current_has_none() {
        // Only a past intent left a question: the current plan has none pending,
        // so nothing is surfaced (the stale one is not resurrected).
        let root = std::env::temp_dir().join(format!("yard-staleq2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::NeedsUser, 10, false);
        t.kind = "implementation".into();
        let mut q = queue(vec![t]);
        q.intent_id = "intent-current".into();
        ws.save_queue(&q).unwrap();

        write_needs_user_run(
            &ws,
            "run-20260101-000000",
            "intent-old",
            "STALE past question",
        );

        assert_eq!(latest_question_for(&ws, "YARD-001"), None);
        let _ = std::fs::remove_dir_all(&root);
    }

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
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
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
            provenance: String::new(),
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
            accept_ambiguity: false,
            chain: None,
        }
    }

    fn init_test_workspace(name: &str, worker_yaml: &str) -> Workspace {
        let root = std::env::temp_dir().join(format!("yard-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let ws = Workspace::at(&root);
        let _ = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(&root)
            .output();
        write_str(
            &ws.config_path(),
            "schema_version: 1\nproduct: yardlet\nworkspace_id: test\ncreated_at: \"2026-07-03T00:00:00Z\"\nstate_dir: .agents\ndefault_interface: tui\ncanonical_queue: work-queue.yaml\ncurrent_intent: intent-contract.yaml\n",
        )
        .unwrap();
        write_str(&ws.billing_path(), "schema_version: 1\n").unwrap();
        write_str(
            &ws.intent_path(),
            "schema_version: 1\nid: intent-test\nsummary: test\nstatus: accepted\n",
        )
        .unwrap();
        write_str(&ws.workers_path(), worker_yaml).unwrap();
        ws
    }

    fn shell_literal(path: &std::path::Path) -> String {
        serde_json::to_string(&path.display().to_string()).unwrap()
    }

    fn write_worker_script(root: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
        let path = root.join(name);
        write_str(&path, body).unwrap();
        path
    }

    #[test]
    fn no_result_worker_fails_over_once_to_alternate_worker() {
        let root = std::env::temp_dir().join(format!("yard-failover-src-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let dead = write_worker_script(
            &root,
            "dead.sh",
            "#!/bin/sh\nrun_dir=\"$1\"\ncat >/dev/null\nexit 1\n",
        );
        let builder = write_worker_script(
            &root,
            "builder.sh",
            r#"#!/bin/sh
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-001",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "done by failover worker",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff
done by builder
EOF
exit 0
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: dead\n  fallback_order: [dead, builder]\nworkers:\n  - id: dead\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&dead),
            shell_literal(&builder)
        );
        let ws = init_test_workspace("failover", &worker_yaml);
        ws.save_queue(&queue(vec![task("YARD-001", TaskState::Queued, 10, false)]))
            .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-001".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.worker_id, "builder");
        assert_eq!(report.result_state, Some(TaskState::Done));
        assert!(report.lines.iter().any(|l| l.contains("dead -> builder")));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);

        let handoff = std::fs::read_to_string(report.run_dir.join("handoff.md")).unwrap();
        assert!(handoff.contains("Worker failover"));
        assert!(handoff.contains("dead -> builder"));
        let rec: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        assert_eq!(rec.worker, "builder");
        let failover: RunFailover = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("failover.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(failover.from, "dead");
        assert_eq!(failover.to, "builder");

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn approval_gate_blocks_unapproved_and_grant_is_single_use() {
        // Security: run_next is the single choke-point for approval. An
        // approval_required task spawns a worker ONLY with a valid grant, the
        // grant is consumed on execution, and a retry after consumption STOPS
        // unless re-approved. The worker increments an on-disk attempt counter so
        // the assertions can prove it did / did not actually run — the failover,
        // checkpoint-retry, and recover paths all re-enter through this gate.
        let root =
            std::env::temp_dir().join(format!("yard-approval-gate-src-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let attempts = root.join("attempts");
        let builder = write_worker_script(
            &root,
            "builder.sh",
            &format!(
                r#"#!/bin/sh
run_dir="$1"
attempts={}
run_id=$(basename "$run_dir")
cat >/dev/null
if [ -f "$attempts" ]; then count=$(cat "$attempts"); else count=0; fi
count=$((count + 1))
printf "%s" "$count" > "$attempts"
cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-APV",
  "status": "done",
  "intent_adherence": {{ "drift_detected": false, "notes": "" }},
  "changes": {{ "files_modified": [], "files_created": [], "files_deleted": [] }},
  "validation": {{ "commands_run": [], "passed": true, "failures": [] }},
  "question_for_user": null,
  "compact_summary": "승인된 실행 완료",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff

승인된 실행 완료
EOF
exit 0
"#,
                shell_literal(&attempts)
            ),
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\n  fallback_order: [builder]\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder)
        );
        let ws = init_test_workspace("approval-gate", &worker_yaml);
        ws.save_queue(&queue(vec![task("YARD-APV", TaskState::Queued, 10, true)]))
            .unwrap();

        let run = |ws: &Workspace| {
            run_next(
                ws,
                &RunOptions {
                    execute: true,
                    target: Some("YARD-APV".into()),
                    ..opts()
                },
            )
        };

        // 1) No grant: the gate refuses and the worker never spawns.
        let err = run(&ws).err().expect("gate must refuse an ungranted task");
        assert!(err.to_string().contains("requires approval"), "{err}");
        assert!(!attempts.exists(), "worker must not run without a grant");
        assert!(!crate::approvals::is_granted(&ws, "YARD-APV"));

        // 2) Grant once, run: the task executes and the grant is CONSUMED.
        crate::approvals::grant(&ws, "YARD-APV").unwrap();
        assert!(crate::approvals::is_granted(&ws, "YARD-APV"));
        let report = run(&ws).unwrap();
        assert_eq!(report.result_state, Some(TaskState::Done));
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "1");
        assert!(report.lines.iter().any(|l| l.contains("approval consumed")));
        assert!(
            !crate::approvals::is_granted(&ws, "YARD-APV"),
            "grant must be single-use"
        );

        // 3) Retry after consumption WITHOUT re-approval: the gate stops it and
        //    the worker is NOT re-invoked (the counter stays at 1). This is the
        //    property the failover / checkpoint-retry / recover paths rely on —
        //    every re-execution re-enters this gate and needs a fresh grant.
        let mut q = ws.load_queue().unwrap();
        q.tasks[0].state = TaskState::Queued; // simulate a retry re-selecting it
        ws.save_queue(&q).unwrap();
        let err = run(&ws)
            .err()
            .expect("gate must refuse a retry after the grant was consumed");
        assert!(err.to_string().contains("requires approval"), "{err}");
        assert_eq!(
            std::fs::read_to_string(&attempts).unwrap(),
            "1",
            "no re-run without a fresh grant"
        );

        // 4) A fresh grant re-enables exactly one more execution.
        crate::approvals::grant(&ws, "YARD-APV").unwrap();
        let report = run(&ws).unwrap();
        assert_eq!(report.result_state, Some(TaskState::Done));
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "2");
        assert!(!crate::approvals::is_granted(&ws, "YARD-APV"));

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn run_auto_skips_unapproved_retry_and_continues_ready_work() {
        let root = std::env::temp_dir().join(format!(
            "yard-auto-approval-retry-src-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let attempts_dir = root.join("attempts");
        std::fs::create_dir_all(&attempts_dir).unwrap();
        let builder = write_worker_script(
            &root,
            "builder.sh",
            &format!(
                r#"#!/bin/sh
run_dir="$1"
attempts_dir={}
run_id=$(basename "$run_dir")
task_id=$(sed -n 's/^task_id: //p' "$run_dir/run.yaml" | head -n 1)
cat >/dev/null
counter="$attempts_dir/$task_id"
if [ -f "$counter" ]; then count=$(cat "$counter"); else count=0; fi
count=$((count + 1))
printf "%s" "$count" > "$counter"
cat > "$run_dir/result.json" <<EOF
{{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "intent_adherence": {{ "drift_detected": false, "notes": "" }},
  "changes": {{ "files_modified": [], "files_created": [], "files_deleted": [] }},
  "validation": {{ "commands_run": [], "passed": true, "failures": [] }},
  "question_for_user": null,
  "compact_summary": "done",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff

done
EOF
exit 0
"#,
                shell_literal(&attempts_dir)
            ),
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\n  fallback_order: [builder]\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder)
        );
        let ws = init_test_workspace("auto-approval-retry", &worker_yaml);
        ws.save_queue(&queue(vec![
            task("YARD-APV", TaskState::Queued, 10, true),
            task("YARD-NEXT", TaskState::Queued, 20, false),
        ]))
        .unwrap();

        crate::approvals::grant(&ws, "YARD-APV").unwrap();
        let first = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-APV".into()),
                ..opts()
            },
        )
        .unwrap();
        assert_eq!(first.result_state, Some(TaskState::Done));
        assert_eq!(
            std::fs::read_to_string(attempts_dir.join("YARD-APV")).unwrap(),
            "1"
        );
        assert!(!crate::approvals::is_granted(&ws, "YARD-APV"));

        let mut q = ws.load_queue().unwrap();
        q.tasks[0].state = TaskState::Failed;
        q.tasks[1].state = TaskState::Queued;
        ws.save_queue(&q).unwrap();

        let events = run_auto(&ws, false, None, Some(1), true, |_| {}).unwrap();
        assert!(
            events
                .iter()
                .any(|e| e.contains("YARD-APV requires approval; skipped retry")),
            "{events:?}"
        );
        assert_eq!(
            std::fs::read_to_string(attempts_dir.join("YARD-APV")).unwrap(),
            "1",
            "approval retry must not spawn a worker without a fresh grant"
        );
        assert_eq!(
            std::fs::read_to_string(attempts_dir.join("YARD-NEXT")).unwrap(),
            "1",
            "independent ready work should keep draining"
        );

        let q = ws.load_queue().unwrap();
        let apv = q.tasks.iter().find(|t| t.id == "YARD-APV").unwrap();
        let next = q.tasks.iter().find(|t| t.id == "YARD-NEXT").unwrap();
        assert_eq!(apv.state, TaskState::NeedsUser);
        assert_eq!(next.state, TaskState::Done);

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn result_file_evaluation_failure_does_not_failover() {
        let root = std::env::temp_dir().join(format!(
            "yard-no-failover-result-src-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let bad = write_worker_script(
            &root,
            "bad.sh",
            r#"#!/bin/sh
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "OTHER",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "bad ids",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff
bad ids
EOF
exit 0
"#,
        );
        let marker = root.join("fallback-ran");
        let fallback = write_worker_script(
            &root,
            "fallback.sh",
            &format!(
                "#!/bin/sh\nrun_dir=\"$1\"\nmarker={}\ncat >/dev/null\ntouch \"$marker\"\nexit 0\n",
                shell_literal(&marker)
            ),
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: bad-result\n  fallback_order: [bad-result, fallback]\nworkers:\n  - id: bad-result\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: fallback\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&bad),
            shell_literal(&fallback)
        );
        let ws = init_test_workspace("no-failover-result", &worker_yaml);
        ws.save_queue(&queue(vec![task("YARD-001", TaskState::Queued, 10, false)]))
            .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-001".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.worker_id, "bad-result");
        assert_eq!(report.result_state, Some(TaskState::Failed));
        assert!(
            !marker.exists(),
            "fallback worker must not run when result.json exists"
        );
        assert!(!report.lines.iter().any(|l| l.contains("worker failover")));
        let handoff = std::fs::read_to_string(report.run_dir.join("handoff.md")).unwrap();
        assert!(!handoff.contains("Worker failover"));
        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::Failed,
            "existing evaluation-failure retry semantics stay unchanged"
        );

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn failover_unready_alternate_does_not_fall_back_to_failed_worker() {
        let root =
            std::env::temp_dir().join(format!("yard-failover-unready-src-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let attempts = root.join("dead-attempts");
        let dead = write_worker_script(
            &root,
            "dead.sh",
            r#"#!/bin/sh
run_dir="$1"
attempts="$2"
cat >/dev/null
if [ -f "$attempts" ]; then
  count=$(cat "$attempts")
else
  count=0
fi
count=$((count + 1))
printf "%s" "$count" > "$attempts"
exit 1
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: dead\n  fallback_order: [dead, missing]\nworkers:\n  - id: dead\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: missing\n    invocation:\n      command: yardlet-definitely-missing-worker-command\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&dead),
            shell_literal(&attempts)
        );
        let ws = init_test_workspace("failover-unready", &worker_yaml);
        ws.save_queue(&queue(vec![task("YARD-004", TaskState::Queued, 10, false)]))
            .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-004".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.worker_id, "dead");
        assert_eq!(report.result_state, Some(TaskState::Failed));
        assert_eq!(
            std::fs::read_to_string(&attempts).unwrap(),
            "1",
            "failed worker must not be selected again during failover readiness fallback"
        );
        assert!(report.lines.iter().any(|l| {
            l.contains("worker failover unavailable")
                && l.contains("no invocable worker among")
                && l.contains("missing")
                && !l.contains("\"dead\"")
        }));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Failed);
        assert!(!report.run_dir.join("failover.json").exists());

        let eval: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let checks = eval["checks"].as_array().unwrap();
        assert!(checks.iter().any(|c| {
            c["name"] == "result_file_present" && c["passed"] == false && c["fatal"] == true
        }));

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn decision_follow_up_seeds_question_and_resolves_on_answer() {
        // End-to-end of the human-decision path: a worker-proposed DECISION
        // follow-up parks NeedsUser (capability dropped), its question is seeded
        // into the conversation so `status` surfaces it, and it stops being a
        // pending question once the user answers.
        use crate::schemas::{ConversationTurn, FollowUpTask, TurnRole};
        let root = std::env::temp_dir().join(format!("yard-decision-fu-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let mut q = queue(vec![task("YARD-001", TaskState::Done, 10, false)]);

        let ingested = crate::planner::ingest_follow_ups(
            &mut q,
            &[],
            &[FollowUpTask {
                title: "pick a signature character".into(),
                reason: "creative A/B choice".into(),
                required_capabilities: vec!["user-creative-direction-approval".into()],
                decision_question: "Option A or B?".into(),
                ..Default::default()
            }],
            Some(&ws),
        );
        let id = ingested.first().expect("one follow-up ingested").clone();

        let t = q.tasks.iter().find(|t| t.id == id).unwrap();
        assert_eq!(t.state, TaskState::NeedsUser);
        assert!(t.required_capabilities.is_empty());
        assert_eq!(
            latest_question_for(&ws, &id).as_deref(),
            Some("Option A or B?"),
            "seeded question must surface as the pending question"
        );

        crate::state::append_conversation_turn(
            &ws,
            &id,
            ConversationTurn {
                role: TurnRole::User,
                text: "A".into(),
                run_id: String::new(),
                ts: String::new(),
            },
        )
        .unwrap();
        assert_eq!(
            latest_question_for(&ws, &id),
            None,
            "an answered decision is no longer a pending question"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recover_requeues_needs_user_task_stranded_by_an_abandoned_run() {
        // An answer-triggered run died before finalize without persisting Running:
        // the task stays NeedsUser while its run.yaml is stuck `running` with no
        // result. recover must seal the abandoned run and requeue the task, and
        // not re-detect it on a later pass.
        let root = std::env::temp_dir().join(format!("yard-abandoned-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        ws.save_queue(&queue(vec![task(
            "YARD-020",
            TaskState::NeedsUser,
            50,
            false,
        )]))
        .unwrap();

        let run_dir = ws.runs_dir().join("run-20260701-034822");
        std::fs::create_dir_all(&run_dir).unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            "schema_version: 1\nrun_id: run-20260701-034822\ntask_id: YARD-020\nworker: codex\nstate: running\nworktree: .\n",
        )
        .unwrap();

        let msgs = recover_orphans(&ws);

        let t = ws
            .load_queue()
            .unwrap()
            .tasks
            .into_iter()
            .find(|t| t.id == "YARD-020")
            .unwrap();
        assert_eq!(
            t.state,
            TaskState::Queued,
            "a NeedsUser task stranded by an abandoned run must be requeued"
        );
        let rec: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert_eq!(rec.state, "failed", "the abandoned run must be sealed");
        assert!(rec.completed_at.is_some());
        assert!(
            msgs.iter().any(|m| m.contains("YARD-020")),
            "recovery must report the requeue"
        );

        // Idempotent: the sealed run is not re-detected on a second pass.
        assert!(
            recover_orphans(&ws).is_empty(),
            "a sealed run must not re-trigger recovery"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn requeue_review_soft_sequences_behind_fix_then_needs_user() {
        // 1c: a failed review with a proposed fix is re-queued to run AFTER it by
        // PRIORITY (no hard depends_on edge — that deadlocks if the fix never
        // reaches Done); with no fix it goes to needs_user.
        let root = std::env::temp_dir().join(format!("yard-requeue-rev-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        ws.save_queue(&queue(vec![
            task("REV", TaskState::Failed, 50, false),
            task("FIX", TaskState::Queued, 60, false),
        ]))
        .unwrap();
        let mut fallback = ws.load_queue().unwrap();

        // Remediation proposed: review -> Queued, sequenced behind the fix.
        requeue_review(
            &ws,
            &mut fallback,
            "REV",
            TaskState::Queued,
            &["FIX".into()],
        )
        .unwrap();
        let find = |ws: &Workspace, id: &str| {
            ws.load_queue()
                .unwrap()
                .tasks
                .into_iter()
                .find(|t| t.id == id)
                .unwrap()
        };
        let r = find(&ws, "REV");
        let f = find(&ws, "FIX");
        assert_eq!(r.state, TaskState::Queued);
        assert!(r.depends_on.is_empty(), "no hard dependency edge");
        // Lower priority runs first: the fix outranks the re-queued review.
        assert!(
            f.priority < r.priority,
            "fix ({}) must sequence before the review ({})",
            f.priority,
            r.priority
        );

        // The no-fix path surfaces to the user and leaves no dependency behind.
        requeue_review(&ws, &mut fallback, "REV", TaskState::NeedsUser, &[]).unwrap();
        let r = find(&ws, "REV");
        assert_eq!(r.state, TaskState::NeedsUser);
        assert!(r.depends_on.is_empty());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn runnable_fix_ids_excludes_blocked_deferred_and_dep_gated() {
        // 1c: a failed review is soft-sequenced ONLY behind fixes that will run
        // before it. A Blocked (off-vocab), Deferred, or dep-gated Queued fix is
        // not yet runnable, so it must not count — else the dep-free review could
        // out-race a still-gated fix and re-verify unchanged code.
        let mut q = queue(vec![
            task("FIXA", TaskState::Queued, 10, false),   // runnable
            task("FIXB", TaskState::Blocked, 20, false),  // off-vocab parked
            task("FIXC", TaskState::Deferred, 30, false), // set aside
            task("FIXD", TaskState::Queued, 40, false),   // gated by an unmet dep
            task("DEP", TaskState::Queued, 50, false),    // not Done -> gates FIXD
        ]);
        q.tasks
            .iter_mut()
            .find(|t| t.id == "FIXD")
            .unwrap()
            .depends_on = vec!["DEP".into()];
        let ingested = vec![
            "FIXA".to_string(),
            "FIXB".to_string(),
            "FIXC".to_string(),
            "FIXD".to_string(),
        ];
        assert_eq!(runnable_fix_ids(&q, &ingested), vec!["FIXA".to_string()]);
    }

    #[test]
    fn serial_auto_commit_guidance_fires_only_on_non_agents_changes() {
        // 1d worktree-only interim: a serial run never auto-commits, but it points
        // an opted-in user at a manual commit ONLY when the worker produced real
        // deliverable changes — not on a no-op Done or a .agents-only write.
        let agents_only = [".agents/work-queue.yaml".to_string(), ".agents".to_string()];
        let with_work = [
            ".agents/work-queue.yaml".to_string(),
            "src/feature.rs".to_string(),
        ];
        assert!(!worker_changed_outside_agents(None)); // no git signal
        assert!(!worker_changed_outside_agents(Some(&[]))); // nothing changed
        assert!(!worker_changed_outside_agents(Some(&agents_only))); // state-only
        assert!(!worker_changed_outside_agents(Some(&[
            "./.agents/telemetry/runs.jsonl".to_string()
        ]))); // ./-prefixed state still recognized
        assert!(worker_changed_outside_agents(Some(&with_work))); // real deliverable
        assert!(worker_changed_outside_agents(Some(&[
            "./README.md".to_string()
        ])));
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
    fn sort_for_display_puts_active_on_top_done_at_bottom() {
        // Active work rises to the top, done work sinks to the bottom, and within
        // a group it is priority order: RUN (pri 200) outranks the queued tasks
        // despite a higher number, and done1 (pri 10) sinks below them.
        let mut q = queue(vec![
            task("done1", TaskState::Done, 10, false),
            task("B", TaskState::Queued, 120, false),
            task("RUN", TaskState::Running, 200, false),
            task("A", TaskState::Queued, 110, false),
            // Deferred is resolved-not-pending: it sinks below queued but stays
            // above done (a decision, not finished work).
            task("DEF", TaskState::Deferred, 5, false),
        ]);
        q.sort_for_display();
        let ids: Vec<&str> = q.tasks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["RUN", "A", "B", "DEF", "done1"]);
    }

    #[test]
    fn drain_skips_needs_user_for_independent_ready_work() {
        // A task waiting on the user must not block independent ready work:
        // select_next skips the NeedsUser task even though it is lower priority.
        let q = queue(vec![
            task("stuck", TaskState::NeedsUser, 10, false),
            task("ready", TaskState::Queued, 20, false),
        ]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1)); // ready, not stuck
    }

    #[test]
    fn drain_does_not_run_a_dependent_of_a_needs_user_task() {
        // The safety side of skipping: a task depending on the stuck one stays
        // gated (deps_met requires Done), so the drain cannot leap ahead of it.
        let mut dependent = task("dep", TaskState::Queued, 5, false);
        dependent.depends_on = vec!["stuck".into()];
        let q = queue(vec![
            task("stuck", TaskState::NeedsUser, 10, false),
            dependent,
        ]);
        assert_eq!(select_next(&q, &opts()).unwrap(), None);
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

    #[test]
    fn recovery_merges_a_finished_orphaned_worktree_run() {
        // A parallel worktree run finished (result.json written) but Yardlet died
        // before integrating. Recovery must merge the work back, not just mark
        // the task Done with its changes stranded in the worktree.
        let root = std::env::temp_dir().join(format!("yard-orphan-wt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let sh = |args: &[&str]| {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}");
        };
        sh(&["init", "-q"]);
        // The worktree integration commit inherits the repository's identity;
        // configure one locally so the test passes on runners with no global
        // git config.
        sh(&["config", "user.name", "t"]);
        sh(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        sh(&["add", "base.txt"]);
        sh(&["commit", "-q", "-m", "init"]);

        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Running, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t.clone()])).unwrap();

        // The orphaned run: a result the evaluator will accept, plus a run.yaml
        // pointing at a live worktree with an unintegrated change.
        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let wt = ws.agents_dir().join("worktrees").join("yard-001");
        sh(&[
            "worktree",
            "add",
            &wt.display().to_string(),
            "-b",
            "yard/yard-001",
        ]);
        std::fs::write(wt.join("feature.txt"), "from worker\n").unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!(
                "run_id: {run_id}\ntask_id: YARD-001\nworktree: {}\n",
                wt.display()
            ),
        )
        .unwrap();

        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::Done);
        // The worker's change landed in the main workspace; the worktree is gone.
        assert_eq!(
            std::fs::read_to_string(root.join("feature.txt")).unwrap(),
            "from worker\n"
        );
        assert!(!wt.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovery_adopts_a_live_orphaned_worker() {
        // Quit-and-restart while a worker runs: the worker survives (it is a
        // separate process). Recovery must keep the task Running — adopting
        // the original session — not requeue it into a duplicate worker.
        let root = std::env::temp_dir().join(format!("yard-adopt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        ws.save_queue(&queue(vec![task(
            "YARD-001",
            TaskState::Running,
            10,
            false,
        )]))
        .unwrap();
        let run_dir = ws.runs_dir().join("run-20990101-000000-yard-001");
        std::fs::create_dir_all(&run_dir).unwrap();
        write_str(&run_dir.join("run.yaml"), "task_id: YARD-001\n").unwrap();
        // Use our own pid: definitely alive.
        write_str(&run_dir.join("worker.pid"), &std::process::id().to_string()).unwrap();

        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.starts_with("adopted:")), "{msgs:?}");
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::Running); // not requeued

        // Once the worker dies (pid file gone), the same task is requeued.
        std::fs::remove_file(run_dir.join("worker.pid")).unwrap();
        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("requeued")), "{msgs:?}");
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Queued);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovery_salvages_a_failed_task_whose_orphan_run_actually_finished() {
        // The reported gap: a task got stuck Failed because the orchestrator
        // died after the worker finished but before evaluating it. The run's
        // worker.pid is still on disk (dead) and a clean result was written.
        // Recovery re-evaluates that stranded result (instead of a full re-run)
        // against the workspace's real git status (not the worker's self-report);
        // with no forbidden path in the diff it salvages to Done.
        let root = std::env::temp_dir().join(format!("yard-salvage-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Failed, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\n"),
        )
        .unwrap();
        // The orphan marker: a pid file left behind for a process that is gone.
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");
        // Salvaged to Done from real git evidence (not a full re-run).
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);
        // Finalized: the pid file is cleared so a later pass is a no-op.
        assert!(!run_dir.join("worker.pid").exists());
        let again = recover_orphans(&ws);
        assert!(
            !again.iter().any(|m| m.contains("recovered")),
            "second pass should not re-recover: {again:?}"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovery_emits_attributed_salvage_telemetry() {
        // The trust report reads telemetry; a run salvaged by recovery must still
        // land there — labeled reason=recovery, attributed to its run.yaml worker
        // — or every recovered task is invisible to trust accounting.
        let root = std::env::temp_dir().join(format!("yard-rectel-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Failed, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        // run.yaml carries the worker so the salvage telemetry is attributable.
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\nworker: codex\n"),
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        assert!(telemetry::read_runs(&ws).is_empty());
        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");

        // One telemetry row for the salvaged outcome, attributed + labeled.
        let runs = telemetry::read_runs(&ws);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].task_id, "YARD-001");
        assert_eq!(runs[0].worker, "codex");
        assert_eq!(runs[0].chosen_reason, "recovery");
        assert_eq!(runs[0].eval_state, "Done");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovery_does_not_ingest_followups() {
        // Recovery (follow_ups flag off) must only finalize the stranded run, not
        // mutate the queue graph: a follow-up proposed in the stranded result is
        // NOT ingested on recovery (that would resurrect work during a crash pass).
        let root = std::env::temp_dir().join(format!("yard-recnoing-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Failed, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![crate::schemas::FollowUpTask {
                title: "a follow-up the crash pass must not ingest".into(),
                reason: String::new(),
                kind: "implementation".into(),
                risk: String::new(),
                allowed_scope: vec![],
                acceptance: vec![],
                skills: vec![],
                depends_on: vec![],
                preferred_worker: String::new(),
                required_capabilities: vec![],
                decision_question: String::new(),
                worker_rationale: None,
                insert: String::new(),
                runs_before: vec![],
            }],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\nworker: codex\n"),
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");
        let q = ws.load_queue().unwrap();
        // Salvaged to Done, and the proposed follow-up was NOT ingested.
        assert_eq!(
            q.tasks.len(),
            1,
            "no follow-up should be ingested on recovery"
        );
        assert_eq!(q.tasks[0].state, TaskState::Done);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn done_with_nonblocking_followups_records_notes_and_leaves_queue_runnable() {
        let root = std::env::temp_dir().join(format!("yard-done-fu-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Running, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t.clone()])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "acceptance met; optional cleanup remains".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![crate::schemas::FollowUpTask {
                title: "Tidy optional documentation".into(),
                reason: "Useful cleanup, but not required for the accepted task".into(),
                kind: "implementation".into(),
                risk: "low".into(),
                ..Default::default()
            }],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Worker handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\nworker: codex\n"),
        )
        .unwrap();

        let billing = crate::schemas::BillingPolicy::default();
        let mut q = ws.load_queue().unwrap();
        let report = finalize_run(FinalizeInput {
            ws: &ws,
            run_dir: &run_dir,
            run_id,
            task: &t,
            evidence: Some(vec![]),
            worker_id: "codex",
            reason: "serial",
            wall_seconds: 0,
            user_override: None,
            intent_summary: "core acceptance met",
            billing: &billing,
            queue: &mut q,
            flags: FinalizeFlags::serial(),
            merge: None,
        })
        .unwrap();

        assert_eq!(report.next_state, TaskState::Done);
        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks[0].state, TaskState::Done);
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1));

        let checkpoint = std::fs::read_to_string(run_dir.join("checkpoint.md")).unwrap();
        let handoff = std::fs::read_to_string(run_dir.join("handoff.md")).unwrap();
        for text in [checkpoint, handoff] {
            assert!(text.contains("Non-blocking follow-up notes"));
            assert!(text.contains("Tidy optional documentation"));
            assert!(text.contains("not required for the accepted task"));
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn done_with_question_preserves_question_in_run_artifacts() {
        let root = std::env::temp_dir().join(format!("yard-done-q-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Running, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t.clone()])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let question = "Should this optional cleanup become a later task?";
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: Some(question.into()),
            compact_summary: "acceptance met; optional question preserved".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Worker handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\nworker: codex\n"),
        )
        .unwrap();

        let billing = crate::schemas::BillingPolicy::default();
        let mut q = ws.load_queue().unwrap();
        let report = finalize_run(FinalizeInput {
            ws: &ws,
            run_dir: &run_dir,
            run_id,
            task: &t,
            evidence: Some(vec![]),
            worker_id: "codex",
            reason: "serial",
            wall_seconds: 0,
            user_override: None,
            intent_summary: "core acceptance met",
            billing: &billing,
            queue: &mut q,
            flags: FinalizeFlags::serial(),
            merge: None,
        })
        .unwrap();

        assert_eq!(report.next_state, TaskState::Done);
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);

        let eval: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let checks = eval["checks"].as_array().unwrap();
        assert!(checks.iter().any(|c| {
            c["name"] == "done_status_has_question" && c["fatal"] == false && c["passed"] == false
        }));

        let checkpoint = std::fs::read_to_string(run_dir.join("checkpoint.md")).unwrap();
        let handoff = std::fs::read_to_string(run_dir.join("handoff.md")).unwrap();
        for text in [checkpoint, handoff] {
            assert!(text.contains(question));
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn finalize_seals_run_record_to_terminal_outcome() {
        // run.yaml is written "running" at spawn and was never updated, so every
        // record looked in-flight forever — a Trust Report / run-dir scan could
        // not tell a finished run from a stranded one. finalize_run (here via
        // recovery) must seal it to the real terminal state + a completed_at,
        // while preserving the spawn-time started_at.
        let root = std::env::temp_dir().join(format!("yard-seal-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let _ = std::process::Command::new("git")
            .args(["init"])
            .current_dir(&root)
            .output();
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Failed, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t])).unwrap();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        // A full spawn-time record: in-flight "running" with a started_at to keep.
        let started = "2099-01-01T00:00:00+00:00";
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: "YARD-001".into(),
                intent_id: String::new(),
                worker: "codex".into(),
                state: "running".into(),
                started_at: started.into(),
                completed_at: None,
                worktree: ".".into(),
            },
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let msgs = recover_orphans(&ws);
        assert!(msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");

        // Sealed: terminal state, a completed_at, original started_at preserved.
        let sealed: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert_eq!(sealed.state, "done");
        assert!(sealed.completed_at.is_some());
        assert_eq!(sealed.started_at, started);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_finalize_merges_a_done_worktree() {
        // The parallel path finalizes a worktree run through finalize_run and, on
        // a Done outcome, merges the worktree back into the workspace. (Validation
        // is intentionally OFF for parallel — the pre-merge worktree lacks the
        // workspace build env — so this exercises the merge, not validation.)
        let root = std::env::temp_dir().join(format!("yard-pval-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let sh = |args: &[&str]| {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}");
        };
        sh(&["init", "-q"]);
        // The worktree integration commit inherits the repository's identity;
        // configure one locally so the test passes on runners with no global
        // git config.
        sh(&["config", "user.name", "t"]);
        sh(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        sh(&["add", "base.txt"]);
        sh(&["commit", "-q", "-m", "init"]);

        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Running, 10, false);
        t.kind = "implementation".into();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let wt = ws.agents_dir().join("worktrees").join("yard-001");
        sh(&[
            "worktree",
            "add",
            &wt.display().to_string(),
            "-b",
            "yard/yard-001",
        ]);
        std::fs::write(wt.join("feature.txt"), "from worker\n").unwrap();

        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-001".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "ok".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!(
                "run_id: {run_id}\ntask_id: YARD-001\nworktree: {}\n",
                wt.display()
            ),
        )
        .unwrap();

        let billing = crate::schemas::BillingPolicy::default();
        let mut q = queue(vec![t.clone()]);
        let report = finalize_run(FinalizeInput {
            ws: &ws,
            run_dir: &run_dir,
            run_id,
            task: &t,
            evidence: Some(vec!["feature.txt".into()]),
            worker_id: "codex",
            reason: "parallel",
            wall_seconds: 0,
            user_override: None,
            intent_summary: "",
            billing: &billing,
            queue: &mut q,
            flags: FinalizeFlags::parallel(),
            merge: Some(MergeBack {
                wt_path: &wt,
                branch: "yard/yard-001",
            }),
        })
        .unwrap();

        // Done -> the worktree merged back into the workspace.
        assert_eq!(report.next_state, TaskState::Done, "{:?}", report.lines);
        assert!(
            root.join("feature.txt").exists(),
            "worktree change should have merged into the workspace"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn recovery_leaves_a_genuinely_failed_task_alone() {
        // A task that was actually evaluated and failed (no orphan pid file on
        // its run) must NOT be resurrected — its result is not stranded, the
        // evaluator already judged it. Recovery skips it.
        let root = std::env::temp_dir().join(format!("yard-realfail-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let mut t = task("YARD-001", TaskState::Failed, 10, false);
        t.kind = "implementation".into();
        ws.save_queue(&queue(vec![t])).unwrap();
        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        write_str(&run_dir.join("result.json"), "{\"status\":\"done\"}").unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!("run_id: {run_id}\ntask_id: YARD-001\n"),
        )
        .unwrap();
        // No worker.pid file => the run was finalized; not an orphan.
        let msgs = recover_orphans(&ws);
        assert!(!msgs.iter().any(|m| m.contains("recovered")), "{msgs:?}");
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Failed);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn final_state_update_preserves_tasks_added_during_run() {
        let root =
            std::env::temp_dir().join(format!("yard-preserve-queue-edits-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);

        let mut stale = queue(vec![task("YARD-010", TaskState::Running, 10, false)]);
        ws.save_queue(&queue(vec![
            task("YARD-010", TaskState::Done, 10, false),
            task("YARD-011", TaskState::Queued, 20, false),
        ]))
        .unwrap();

        save_task_state_on_latest_queue(
            &ws,
            &mut stale,
            "YARD-010",
            TaskState::Partial,
            TransitionCause::RunOutcome,
            "test final state update",
            TransitionActor::System,
        )
        .unwrap();

        let q = ws.load_queue().unwrap();
        assert_eq!(q.tasks.len(), 2);
        assert_eq!(q.tasks[0].id, "YARD-010");
        assert_eq!(q.tasks[0].state, TaskState::Partial);
        assert_eq!(q.tasks[1].id, "YARD-011");
        assert_eq!(q.tasks[1].state, TaskState::Queued);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn skips_tasks_with_unmet_dependencies() {
        let mut a = task("A", TaskState::Queued, 10, false);
        let mut b = task("B", TaskState::Queued, 20, false);
        b.depends_on = vec!["A".into()];
        // B is ineligible while A is queued, even though both are queued.
        let q = queue(vec![a.clone(), b.clone()]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(0));
        // Once A is done, B becomes eligible.
        a.state = TaskState::Done;
        let q = queue(vec![a, b.clone()]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1));
        // A dependency id that does not exist is treated as met (no deadlock).
        b.depends_on = vec!["GHOST".into()];
        let q = queue(vec![b]);
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(0));
    }
}
