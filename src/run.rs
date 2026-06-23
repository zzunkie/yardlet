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
use serde::Serialize;

use crate::guard;
use crate::inspect;
use crate::packet::{self, PacketInputs};
use crate::schemas::{
    ConversationTurn, RunResult, TaskState, TurnRole, WorkQueue, WorkerProfile, WorkersFile,
};
use crate::state::{self, write_str, Workspace};
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

#[derive(Serialize)]
pub(crate) struct RunRecord {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub intent_id: String,
    pub worker: String,
    pub state: String,
    pub started_at: String,
    pub worktree: String,
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
            select_next(&queue, opts)?.ok_or_else(|| anyhow!("no eligible queued task to run"))?
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
        let unsatisfiable: Vec<String> = task
            .required_capabilities
            .iter()
            .map(|c| routing::norm_cap(c))
            .filter(|c| !c.is_empty() && !vocab.contains(c))
            .collect();
        if !unsatisfiable.is_empty() {
            save_task_state_on_latest_queue(ws, &mut queue, &task.id, TaskState::Blocked)?;
            return Ok(RunReport {
                run_id: String::new(),
                task_id: task.id.clone(),
                worker_id: String::new(),
                run_dir: ws.runs_dir(),
                prepared: false,
                executed: false,
                lines: vec![format!(
                    "{}: parked Blocked — no enabled worker declares required \
                     capability/capabilities [{}]; add a worker that declares it (then unblock), \
                     or handle it as a human decision",
                    task.id,
                    unsatisfiable.join(", ")
                )],
                result_state: Some(TaskState::Blocked),
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
    let reason = resolved.reason;
    let bin = resolved.bin;
    let profile = find_worker(&workers.workers, &worker_id)?;
    // A per-task model/effort overrides the worker profile only when explicit;
    // "auto"/empty keeps the profile's pin (so the planner's `model: auto` does
    // not clobber a worker-level model pin). The in-flight task thus captures
    // its own effective profile.
    let eff_profile = workers::effective_profile(profile, &task.model, &task.effort);
    // Per-run --full-access OR the workspace's default_access=full.
    let full_access = opts.full_access || config.default_access.eq_ignore_ascii_case("full");
    let env = guard::sanitized_worker_env_for(&billing, &eff_profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    lines.push(format!("worker: {worker_id} ({reason})"));

    // H3: workspace-owned pre-run gates bind every worker. A non-zero hook
    // blocks the run before any worker spawns (detect-secrets, lint, "don't
    // run while CI is red"). The task fails with the hook's reason so the
    // auto-drain stops on it rather than looping; fix the cause and re-run.
    let pre = crate::hooks::run_phase(ws, crate::hooks::Phase::Pre, &task.id, &run_dir, &worker_id);
    if !pre.ok() {
        for f in &pre.failures {
            lines.push(format!("pre-run hook blocked the run: {}", f.summary()));
        }
        queue.tasks[idx].state = TaskState::Failed;
        ws.save_queue(&queue)?;
        return Ok(RunReport {
            run_id: run_id.clone(),
            task_id: task.id.clone(),
            worker_id: worker_id.clone(),
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
    queue.tasks[idx].state = TaskState::Running;
    ws.save_queue(&queue)?;

    // Chaining (P1): when run_auto offers the previous task's live session and
    // routing kept the same worker, continue IN that session — the worker
    // keeps its hot context instead of re-learning the repo from zero.
    let chained = opts
        .chain
        .as_ref()
        .is_some_and(|c| c.worker_id == worker_id);
    if chained {
        lines.push(format!(
            "chaining into {}'s session (task {} of a hot chain)",
            worker_id,
            opts.chain.as_ref().map(|c| c.length + 1).unwrap_or(1)
        ));
    }

    // Session id for resume-on-transient: claude lets us set one up front; codex
    // generates its own, captured from its rollout file after the run starts.
    let log_path = run_dir.join("worker-output.log");
    let mut session_id: Option<String> = if chained {
        opts.chain.as_ref().map(|c| c.session.clone())
    } else if worker_id == "claude-code" {
        Some(gen_session_uuid(&run_id))
    } else {
        None
    };
    // Snapshot the working tree before the worker runs so the evaluator can
    // diff against ACTUAL on-disk changes, not the worker's self-report.
    let baseline_fp = evaluator::dirty_fingerprints(&ws.root);
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
        chained,
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
        // Re-read the latest queue before saving: the worker may have written a
        // follow-up task before the cancel was observed (no stale clobber).
        save_task_state_on_latest_queue(ws, &mut queue, &task.id, TaskState::Queued)?;
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
            session: session_id.clone(),
            chained,
        });
    }
    lines.push(format!(
        "worker outcome: {} (exit_ok={}, timed_out={})",
        outcome.note, outcome.exit_ok, outcome.timed_out
    ));

    // ---- evaluate + compact ---------------------------------------------
    // Worker-attributed changes: diff the dirty-file fingerprints before and
    // after the run, so a path the worker re-modified while it was already dirty
    // is still attributed (plain path-set subtraction would miss it). `None`
    // when git evidence is unavailable, in which case the evaluator fails closed
    // rather than trusting the worker's self-report.
    let evidence: Option<Vec<String>> =
        match (&baseline_fp, evaluator::dirty_fingerprints(&ws.root)) {
            (Some(base), Some(after)) => Some(evaluator::worker_touched(base, &after)),
            _ => None,
        };
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
        worker_id: &worker_id,
        reason: &reason,
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

    Ok(RunReport {
        run_id,
        task_id: task.id,
        worker_id,
        run_dir,
        prepared: true,
        executed: true,
        lines,
        result_state: Some(next_state),
        session: session_id,
        chained,
    })
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
    let probe_opts = RunOptions {
        execute: false,
        worker_override: None,
        target: None,
        answer: None,
        full_access: false,
        accept_ambiguity: false,
        chain: None,
    };

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
            }
        }
        // Pick the work: retry the failed task first, else the next queued one.
        let task_id = match &retry_target {
            Some(id) => id.clone(),
            None => match select_next(&queue, &probe_opts)? {
                Some(idx) => queue.tasks[idx].id.clone(),
                None => {
                    // Nothing runnable. Report why, in priority of action: tasks
                    // that need a human (NeedsUser/Blocked) first, then
                    // queued-but-gated (approval or deps), else a drained queue.
                    let needs_you: Vec<&str> = queue
                        .tasks
                        .iter()
                        .filter(|t| matches!(t.state, TaskState::NeedsUser | TaskState::Blocked))
                        .map(|t| t.id.as_str())
                        .collect();
                    let waiting: Vec<&str> = queue
                        .tasks
                        .iter()
                        .filter(|t| t.state == TaskState::Queued)
                        .map(|t| t.id.as_str())
                        .collect();
                    if !needs_you.is_empty() {
                        emit(format!(
                            "stopped: {} need you \u{2014} answer (a) or resolve, then run auto again",
                            needs_you.join(", ")
                        ));
                    } else if waiting.is_empty() {
                        emit("done: queue drained, all tasks complete".to_string());
                    } else {
                        emit(format!(
                            "stopped: {} waiting on approval or dependencies",
                            waiting.join(", ")
                        ));
                    }
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
            TaskState::Done | TaskState::Queued => continue,
            TaskState::Blocked => {
                emit(format!(
                    "stopped: {} blocked \u{2014} see `yardlet handoff`",
                    report.task_id
                ));
                break;
            }
            TaskState::NeedsUser => {
                emit(format!(
                    "stopped: {} needs you \u{2014} `yardlet answer \"...\"`",
                    report.task_id
                ));
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
        if !queue.deps_met(t) {
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
fn run_worktree(run_dir: &std::path::Path) -> Option<PathBuf> {
    let yaml = std::fs::read_to_string(run_dir.join("run.yaml")).ok()?;
    let v = yaml
        .lines()
        .find_map(|l| l.trim().strip_prefix("worktree:"))
        .map(|v| v.trim().trim_matches('"').to_string())?;
    (v != "." && !v.is_empty()).then(|| PathBuf::from(v))
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
                match finalize_run(FinalizeInput {
                    ws,
                    run_dir: &run_dir,
                    run_id: &run_id,
                    task: &task,
                    evidence,
                    worker_id: "",
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
                // Dead with no result: redo from scratch; drop the worktree.
                if let Some((_, run_dir)) = run {
                    if let Some(wt) = run_worktree(&run_dir).filter(|w| w.exists()) {
                        let branch = format!("yard/{}", id.to_lowercase());
                        crate::parallel::remove_worktree(&ws.root, &wt, &branch);
                    }
                }
                if let Some(t) = q.tasks.iter_mut().find(|t| t.id == id) {
                    t.state = TaskState::Queued;
                }
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
) -> Result<()> {
    finalize_on_latest_queue(ws, fallback_queue, task_id, state, &[], None).map(|_| ())
}

/// Re-point a finished review at the queue (1c review auto-remediation): set its
/// state and append any remediation dependencies (the fix tasks it must now wait
/// for before re-verifying). Re-reads the latest queue first so a concurrent
/// change is not clobbered.
fn requeue_review(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    review_id: &str,
    state: TaskState,
    dep_ids: &[String],
) -> Result<()> {
    let mut latest = ws.load_queue().unwrap_or_else(|_| fallback_queue.clone());
    if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == review_id) {
        t.state = state;
        for d in dep_ids {
            if !t.depends_on.contains(d) {
                t.depends_on.push(d.clone());
            }
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
fn finalize_on_latest_queue(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    follow_ups: &[crate::schemas::FollowUpTask],
    workers: Option<&WorkersFile>,
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
        t.state = state;
        let ingested = crate::planner::ingest_follow_ups(&mut latest, follow_ups);
        reconcile(&mut latest);
        ws.save_queue(&latest)?;
        *fallback_queue = latest;
        return Ok(ingested);
    }

    // The task vanished from the on-disk queue (rare): fall back to the
    // in-memory copy so the state update is not lost.
    if let Some(t) = fallback_queue.tasks.iter_mut().find(|t| t.id == task_id) {
        t.state = state;
    }
    let ingested = crate::planner::ingest_follow_ups(fallback_queue, follow_ups);
    reconcile(fallback_queue);
    ws.save_queue(fallback_queue)?;
    Ok(ingested)
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
        }
    }

    /// The parallel path skips the in-place-only gates: post-run hooks and
    /// validation run against the workspace, but a parallel task's edits live in
    /// its worktree until merged, so they are deferred (the merge is sequential
    /// and a later slice can run them post-merge). Conversation/learned are
    /// skipped too (batches only pick Queued tasks, never a paused resume).
    /// Artifacts and telemetry still land, exactly as the inline code did.
    pub fn parallel() -> Self {
        Self {
            post_hooks: false,
            validation: false,
            conversation: false,
            learned: false,
            artifacts: true,
            telemetry: true,
        }
    }

    /// Recovery salvages an interrupted run: re-evaluate its stranded result,
    /// merge a Done worktree back, and commit the state. It deliberately skips
    /// everything else — the artifacts/checkpoint were the dead session's job,
    /// and re-emitting telemetry/hooks for a crash would distort the record.
    pub fn recovery() -> Self {
        Self {
            post_hooks: false,
            validation: false,
            conversation: false,
            learned: false,
            artifacts: false,
            telemetry: false,
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
    // nothing to run) is fatal and blocks Done.
    if flags.validation {
        let validation_cmds = validation_commands(task);
        let (validation_ran, validation_passed) =
            run_validation_commands(&validation_cmds, &ws.root, run_dir, billing);
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
                    let _ = std::fs::write(&hp, existing);
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
    let follow_ups = result
        .as_ref()
        .map(|r| r.follow_up_tasks.clone())
        .unwrap_or_default();
    // Workers (when loadable) let the queue commit ground a proposed follow-up's
    // capabilities; if workers.yaml can't be read we skip grounding rather than
    // false-park everything.
    let workers = ws.load_workers().ok();
    let ingested = finalize_on_latest_queue(
        ws,
        queue,
        &task.id,
        next_state,
        &follow_ups,
        workers.as_ref(),
    )?;
    if !ingested.is_empty() {
        lines.push(format!(
            "ingested {} worker-proposed follow-up task(s): {}",
            ingested.len(),
            ingested.join(", ")
        ));
    }

    // Review auto-remediation (1c): a review that failed its criteria must not
    // blind-loop on the same unchanged code. If the reviewer proposed
    // remediation follow-up(s), re-queue THIS review BEHIND them (depends_on) so
    // the fix runs first and the review then re-verifies; the drain's per-task
    // attempt cap bounds the cycles. If it proposed nothing actionable, surface
    // the findings to the user instead of retrying an unchanged target.
    let is_review = matches!(crate::packet::role_for(&task.kind), "reviewer" | "security");
    if is_review && matches!(next_state, TaskState::Failed | TaskState::Partial) {
        if ingested.is_empty() {
            requeue_review(ws, queue, &task.id, TaskState::NeedsUser, &[])?;
            next_state = TaskState::NeedsUser;
            lines.push(format!(
                "{}: review failed and proposed no fix — needs you",
                task.id
            ));
        } else {
            requeue_review(ws, queue, &task.id, TaskState::Queued, &ingested)?;
            next_state = TaskState::Queued;
            lines.push(format!(
                "{}: review failed — re-queued behind remediation [{}] to re-verify",
                task.id,
                ingested.join(", ")
            ));
        }
    }

    if flags.telemetry {
        let _ = telemetry::append_run(
            ws,
            &telemetry::RunTelemetry {
                ts: Local::now().to_rfc3339(),
                task_id: task.id.clone(),
                kind: task.kind.clone(),
                risk: task.risk.clone(),
                worker: worker_id.to_string(),
                chosen_reason: reason.to_string(),
                result_status: result
                    .as_ref()
                    .map(|r| r.status.clone())
                    .unwrap_or_else(|| "no-result".to_string()),
                eval_state: format!("{next_state:?}"),
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

    Ok(FinalizeReport { next_state, lines })
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

    #[test]
    fn requeue_review_behind_remediation_then_needs_user() {
        // 1c: a failed review with a proposed fix is re-queued BEHIND it
        // (depends_on) to re-verify; with no fix it goes to needs_user.
        let root = std::env::temp_dir().join(format!("yard-requeue-rev-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        ws.save_queue(&queue(vec![
            task("REV", TaskState::Failed, 50, false),
            task("FIX", TaskState::Queued, 60, false),
        ]))
        .unwrap();
        let mut fallback = ws.load_queue().unwrap();

        // Remediation proposed: review -> Queued, waiting on the fix.
        requeue_review(
            &ws,
            &mut fallback,
            "REV",
            TaskState::Queued,
            &["FIX".into()],
        )
        .unwrap();
        let rev = |ws: &Workspace| {
            ws.load_queue()
                .unwrap()
                .tasks
                .into_iter()
                .find(|t| t.id == "REV")
                .unwrap()
        };
        let r = rev(&ws);
        assert_eq!(r.state, TaskState::Queued);
        assert_eq!(r.depends_on, vec!["FIX".to_string()]);

        // Called again (e.g. next cycle) it does not duplicate the dependency,
        // and the no-fix path surfaces to the user.
        requeue_review(
            &ws,
            &mut fallback,
            "REV",
            TaskState::NeedsUser,
            &["FIX".into()],
        )
        .unwrap();
        let r = rev(&ws);
        assert_eq!(r.state, TaskState::NeedsUser);
        assert_eq!(r.depends_on, vec!["FIX".to_string()]); // no duplicate
        let _ = std::fs::remove_dir_all(&root);
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
        ]);
        q.sort_for_display();
        let ids: Vec<&str> = q.tasks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["RUN", "A", "B", "done1"]);
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
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        sh(&["add", "base.txt"]);
        sh(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "init",
        ]);

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

        save_task_state_on_latest_queue(&ws, &mut stale, "YARD-010", TaskState::Partial).unwrap();

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
