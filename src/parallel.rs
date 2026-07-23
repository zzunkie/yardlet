//! Parallel batch execution.
//!
//! Runs several independent queued tasks at once, each through its own hidden
//! worker in its own git worktree. Three invariants keep this simple (see
//! docs/parallel-queue.md):
//!
//! 1. Workers run in parallel; the queue file has a single writer (this loop).
//! 2. Each task works in an isolated worktree on branch `yard/<task-id>`,
//!    branched from the current HEAD, so workers never see each other's edits.
//! 3. Integration is sequential, in completion order. A merge conflict is
//!    never auto-resolved: the task drops to Partial and its worktree is kept
//!    for inspection.
//!
//! Run artifacts stay in the MAIN workspace (the run dir is passed to the
//! worker as an absolute path and as an extra writable root), so results,
//! checkpoints, and handoffs land in `.agents/runs/` exactly as in sequential
//! runs even though the worker's cwd is the worktree.

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use anyhow::{anyhow, Result};
use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::packet::{self, PacketInputs};
use crate::schemas::{RunnableClass, Task, TaskState, WorkQueue, WorkerProfile};
use crate::state::{self, write_str, Workspace};
use crate::{evaluator, guard, inspect, routing, run, workers};

fn is_verifier(task: &Task) -> bool {
    matches!(packet::role_for(&task.kind), "reviewer" | "security")
}

fn has_queued_non_verifier(queue: &WorkQueue) -> bool {
    queue
        .tasks
        .iter()
        .any(|task| task.state == TaskState::Queued && !is_verifier(task))
}

/// Indices of tasks eligible to run together right now: queued, dependencies
/// met, not approval-gated. Priority order, up to `max`.
///
/// Final verifiers form an exclusive, serial soft barrier behind other queued
/// work. This keeps a review from sharing the snapshot with a builder or a
/// research task that may ingest an implementation follow-up, without adding a
/// hard dependency that could strand the review when work later fails, is
/// deferred, or becomes gated.
pub fn ready_independent(queue: &WorkQueue, max: usize) -> Vec<usize> {
    let caps = std::collections::BTreeSet::new();
    // Parallel selection intentionally knows neither live approvals nor the
    // real capability vocabulary. Holding verifiers behind any Queued
    // non-verifier makes it fall through to the serial selector for those edge
    // cases; that selector has the real inputs and can still choose the review
    // when other work is gated, so this remains non-deadlocking.
    let work_pending = has_queued_non_verifier(queue);
    let mut ready: Vec<usize> = queue
        .tasks
        .iter()
        .enumerate()
        .filter(|(_, t)| {
            if is_verifier(t) && (work_pending || queue.has_active_remediation_for(&t.id)) {
                return false;
            }
            queue.runnable_class(t, false, &caps) == RunnableClass::Runnable
                && !t.approval_required()
        })
        .map(|(i, _)| i)
        .collect();
    ready.sort_by_key(|&i| queue.tasks[i].priority);
    // Never run two final verifiers from the same pre-integration snapshot. A
    // verifier that proposes remediation must settle before the next verifier
    // starts, so the latter can observe the new queue/workspace state.
    let cap = if ready.first().is_some_and(|&i| is_verifier(&queue.tasks[i])) {
        1
    } else {
        max
    };
    ready.truncate(cap);
    ready
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum SequentialReason {
    ParallelDisabled { max_parallel: usize },
    RunnableTaskCount { runnable: usize },
    DependencyChain { tasks: Vec<String> },
    ApprovalRequired { tasks: Vec<String> },
    ValidationRequired { tasks: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ParallelAssessment {
    pub runnable: Vec<String>,
    pub reasons: Vec<SequentialReason>,
}

impl ParallelAssessment {
    pub fn is_parallel_ready(&self) -> bool {
        self.reasons.is_empty() && self.runnable.len() >= 2
    }

    pub fn summary(&self) -> String {
        if self.is_parallel_ready() {
            return format!("parallel-ready: {}", self.runnable.join(", "));
        }
        self.reasons
            .iter()
            .map(|reason| match reason {
                SequentialReason::ParallelDisabled { max_parallel } => {
                    format!("parallel disabled (max_parallel={max_parallel})")
                }
                SequentialReason::RunnableTaskCount { runnable } => {
                    format!("only {runnable} runnable task(s)")
                }
                SequentialReason::DependencyChain { tasks } => {
                    format!("dependency chain: {}", tasks.join(", "))
                }
                SequentialReason::ApprovalRequired { tasks } => {
                    format!("approval required: {}", tasks.join(", "))
                }
                SequentialReason::ValidationRequired { tasks } => {
                    format!("validation required: {}", tasks.join(", "))
                }
            })
            .collect::<Vec<_>>()
            .join("; ")
    }
}

/// Explain, as structured data, why the queue will not form a parallel batch
/// right now. The TUI can render this directly and tests can assert exact
/// scheduler causes instead of scraping prose.
pub fn assess_parallelism(queue: &WorkQueue, max_parallel: usize) -> ParallelAssessment {
    let runnable_indices = ready_independent(queue, max_parallel.max(1));
    let runnable = runnable_indices
        .iter()
        .map(|&i| queue.tasks[i].id.clone())
        .collect::<Vec<_>>();
    let mut reasons = Vec::new();
    if max_parallel <= 1 {
        reasons.push(SequentialReason::ParallelDisabled { max_parallel });
    }

    let blocked_by_deps = queue
        .tasks
        .iter()
        .filter(|t| {
            queue.runnable_class(t, false, &std::collections::BTreeSet::new())
                == RunnableClass::WaitingDependency
        })
        .map(|t| t.id.clone())
        .collect::<Vec<_>>();
    if !blocked_by_deps.is_empty() {
        reasons.push(SequentialReason::DependencyChain {
            tasks: blocked_by_deps,
        });
    }

    let approval_required = queue
        .tasks
        .iter()
        .filter(|t| {
            queue.runnable_class(t, false, &std::collections::BTreeSet::new())
                == RunnableClass::WaitingApproval
        })
        .map(|t| t.id.clone())
        .collect::<Vec<_>>();
    if !approval_required.is_empty() {
        reasons.push(SequentialReason::ApprovalRequired {
            tasks: approval_required,
        });
    }

    if max_parallel > 1 && runnable.len() < 2 {
        reasons.push(SequentialReason::RunnableTaskCount {
            runnable: runnable.len(),
        });
    }

    ParallelAssessment { runnable, reasons }
}

/// Can this workspace host parallel worktree runs right now? Requires a git
/// repository whose tracked files have no uncommitted changes (untracked files
/// are fine — they stay out of the worktrees and merges).
pub fn git_preflight(root: &Path) -> std::result::Result<(), String> {
    let inside = git(root, &["rev-parse", "--is-inside-work-tree"])
        .map(|s| s.trim() == "true")
        .unwrap_or(false);
    if !inside {
        return Err("not a git repository".to_string());
    }
    match git(root, &["status", "--porcelain", "--untracked-files=no"]) {
        Ok(s) if s.trim().is_empty() => Ok(()),
        Ok(_) => Err("uncommitted changes in the working tree".to_string()),
        Err(e) => Err(e.to_string()),
    }
}

struct Prep {
    task: Task,
    worker_id: String,
    reason: String,
    bin: PathBuf,
    profile: WorkerProfile,
    selection: crate::schemas::ResolvedWorkerSelection,
    run_id: String,
    run_dir: PathBuf,
    wt_path: PathBuf,
    branch: String,
    baseline_oid: String,
    packet_text: String,
    session: Option<String>,
}

struct Finished {
    prep_idx: usize,
    outcome: Result<workers::WorkerOutcome>,
    wall_seconds: u64,
}

fn mark_parallel_tasks_running(queue: &mut WorkQueue, task_ids: &[String]) -> Result<()> {
    for task_id in task_ids {
        let task = queue
            .tasks
            .iter_mut()
            .find(|task| task.id == *task_id)
            .ok_or_else(|| anyhow!("queue_transaction_conflict: task {task_id} vanished"))?;
        if task.state != TaskState::Queued {
            return Err(anyhow!(
                "queue_transaction_conflict: task {task_id} is no longer queued"
            ));
        }
        task.state = TaskState::Running;
    }
    Ok(())
}

#[derive(Serialize)]
struct ParallelFailover {
    from: String,
    to: String,
    reason: String,
    at: String,
}

/// Run the tasks at `indices` concurrently and integrate their results.
/// Returns one progress/result message per significant event; task states are
/// written to the queue as each task is integrated (single writer: this loop).
pub fn run_batch<F: FnMut(&str)>(
    ws: &Workspace,
    indices: &[usize],
    full_access: bool,
    mut on_event: F,
) -> Result<Vec<(String, TaskState)>> {
    crate::planning::validate_active_activation(ws)?;
    let mut queue = ws.load_queue()?;
    let workers_file = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let intent = ws.load_intent()?;
    let config = ws.load_config()?;
    let full_access = full_access || config.default_access.eq_ignore_ascii_case("full");
    let repo_summary = inspect::summarize(&ws.root);
    let lang_sample = intent
        .as_ref()
        .map(|i| {
            if !i.raw_request.is_empty() {
                i.raw_request.clone()
            } else {
                i.summary.clone()
            }
        })
        .unwrap_or_default();
    let language = packet::resolve_language(&config.language, &lang_sample);
    let images: Vec<String> = intent
        .as_ref()
        .map(|i| i.images.clone())
        .unwrap_or_default();

    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    ensure_worktrees_excluded(&ws.root);

    // ---- prepare every task up front (deterministic, no workers yet) -----
    let mut preps: Vec<Prep> = Vec::new();
    for &idx in indices {
        let mut task = queue.tasks[idx].clone();
        let resolved =
            match routing::resolve_worker_for_task(ws, &workers_file, &billing, None, &task) {
                Ok(r) => r,
                Err(e) => {
                    on_event(&format!("{}: no invocable worker ({e}); skipped", task.id));
                    continue;
                }
            };
        let profile = match run::find_worker(&workers_file.workers, &resolved.worker_id) {
            Ok(p) => p,
            Err(e) => {
                on_event(&format!("{}: {e}; skipped", task.id));
                continue;
            }
        };
        // "auto"/empty task model/effort keeps the profile pin (see
        // workers::effective_profile); only an explicit value overrides.
        let eff_profile = crate::workers::effective_profile(profile, &task.model, &task.effort);
        let base_run_id = format!(
            "run-{}-{}",
            Local::now().format("%Y%m%d-%H%M%S"),
            task.id.to_lowercase()
        );
        let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
        let session = (resolved.worker_id == "claude-code").then(|| run::gen_session_uuid(&run_id));
        let branch = format!("yard/{}/{}", task.id.to_lowercase(), run_id);
        let selection = resolved.selection();
        if !selection.model.trim().is_empty() {
            run::apply_selection_to_task(&mut task, &selection);
        }
        preps.push(Prep {
            branch,
            wt_path: ws.agents_dir().join("worktrees").join(&run_id),
            baseline_oid: String::new(),
            task,
            worker_id: resolved.worker_id,
            reason: resolved.reason,
            bin: resolved.bin,
            profile: eff_profile,
            selection,
            run_id,
            run_dir,
            packet_text: String::new(), // compiled below, after the worktree exists
            session,
        });
    }
    if preps.is_empty() {
        return Err(anyhow!("no runnable task in the batch"));
    }

    // Fail closed before any worktree exists or worker spawns when the enabled
    // Git-finish policy still names a branch other than the owning root's
    // checkout — the parallel twin of the serial pre-spawn preflight (issue
    // #36). Every claimed run dir gets the same core-owned SafetyBlocked
    // record the serial path writes; the batch tasks were never marked
    // Running, so they stay Queued and retry once the policy is retargeted.
    let mut retarget_error: Option<anyhow::Error> = None;
    for p in &preps {
        if let Err(error) = crate::git_finish::preflight_target_before_spawn(
            ws,
            &p.run_dir,
            &p.run_id,
            &p.task.id,
            &config.git_finish,
        ) {
            state::save_yaml_atomic(
                &p.run_dir.join("run.yaml"),
                &run::RunRecord {
                    schema_version: 1,
                    run_id: p.run_id.clone(),
                    task_id: p.task.id.clone(),
                    intent_id: queue.intent_id.clone(),
                    worker: p.worker_id.clone(),
                    model: p.selection.model.clone(),
                    fallback_enabled: p.selection.fallback_enabled,
                    routing_provenance: Some(p.selection.routing_provenance.clone()),
                    state: "blocked".to_string(),
                    started_at: Local::now().to_rfc3339(),
                    completed_at: Some(Local::now().to_rfc3339()),
                    worktree: ".".to_string(),
                    ..Default::default()
                },
            )?;
            on_event(&format!("{}: {error}", p.task.id));
            retarget_error.get_or_insert(error);
        }
    }
    if let Some(error) = retarget_error {
        return Err(error);
    }

    // ---- worktrees + run dirs + packets ----------------------------------
    let mut ok: Vec<Prep> = Vec::new();
    for mut p in preps {
        p.baseline_oid = git(&ws.root, &["rev-parse", "--verify", "HEAD^{commit}"])?
            .trim()
            .to_string();
        if let Err(e) = create_worktree(&ws.root, &p.wt_path, &p.branch) {
            on_event(&format!("{}: worktree failed ({e}); skipped", p.task.id));
            continue;
        }
        // The worker's read anchors (`.agents/*.yaml`) resolve against its cwd
        // (the worktree), and Yardlet's runtime state is not committed — copy the
        // two contract files in so the packet's anchors hold.
        let wt_agents = p.wt_path.join(crate::state::STATE_DIR);
        let _ = std::fs::create_dir_all(&wt_agents);
        let _ = std::fs::copy(ws.intent_path(), wt_agents.join("intent-contract.yaml"));
        let _ = std::fs::copy(ws.queue_path(), wt_agents.join("work-queue.yaml"));
        // Harness assets too (small text): skill anchors and role notes are
        // cwd-relative in the packet and must resolve inside the worktree.
        let harness_seed_dir = p.run_dir.join(run::HARNESS_SEED_DIR);
        let mut harness_copy_warnings: Vec<String> = Vec::new();
        for d in ["rules", "skills", "agents"] {
            harness_copy_warnings.extend(copy_dir(&ws.agents_dir().join(d), &wt_agents.join(d)));
            harness_copy_warnings.extend(copy_dir(
                &ws.agents_dir().join(d),
                &harness_seed_dir.join(d),
            ));
        }
        state::save_harness_copy_warnings(&p.run_dir, &harness_copy_warnings)?;
        if let Err(error) =
            state::materialize_resolved_dependency_outputs(ws, &queue, &p.task, &p.wt_path)
        {
            on_event(&format!(
                "{}: dependency output preparation blocked before worker spawn: {error}",
                p.task.id
            ));
            remove_worktree(&ws.root, &p.wt_path, &p.branch);
            for prepared in &ok {
                remove_worktree(&ws.root, &prepared.wt_path, &prepared.branch);
            }
            return Err(anyhow!(
                "{} dependency output preparation blocked before worker spawn: {error}",
                p.task.id
            ));
        }

        std::fs::create_dir_all(p.run_dir.join("evidence"))?;
        write_str(
            &p.run_dir.join("evidence").join("repo-summary.md"),
            &inspect::to_markdown(&repo_summary),
        )?;
        // Absolute run dir: results land in the MAIN workspace, not the worktree.
        let run_dir_abs = p.run_dir.display().to_string();
        let role_notes = packet::load_role_notes(&ws.root, packet::role_for(&p.task.kind));
        p.packet_text = packet::compile(&PacketInputs {
            worker_id: &p.worker_id,
            task: &p.task,
            intent: intent.as_ref(),
            repo: &repo_summary,
            run_dir_rel: &run_dir_abs,
            conversation: &[],
            continuation: None, // batches only pick Queued tasks
            chained_from: None,
            language: &language,
            images: &images,
            role_notes: &role_notes,
            harness: &harness,
            // The parallel path never carries approval-gated tasks (they are held
            // for the serial path), so no approval directive applies here.
            approved: false,
        });
        write_str(&workers::packet_path(&p.run_dir), &p.packet_text)?;
        state::save_yaml_atomic(
            &p.run_dir.join("run.yaml"),
            &run::RunRecord {
                schema_version: 1,
                run_id: p.run_id.clone(),
                task_id: p.task.id.clone(),
                intent_id: queue.intent_id.clone(),
                worker: p.worker_id.clone(),
                model: p.selection.model.clone(),
                fallback_enabled: p.selection.fallback_enabled,
                routing_provenance: Some(p.selection.routing_provenance.clone()),
                state: "running".to_string(),
                started_at: Local::now().to_rfc3339(),
                completed_at: None,
                worktree: p.wt_path.display().to_string(),
                serial_isolated: false,
                baseline_oid: p.baseline_oid.clone(),
                worktree_branch: p.branch.clone(),
                integration_oid: String::new(),
                integration_base_oid: String::new(),
                integration_worker_oid: String::new(),
                integration_provenance: run::IntegrationProvenance::ParallelWorkerDirect,
                integration_cleanup_complete: false,
                owned_oids: Vec::new(),
                output_contract_incident: None,
            },
        )?;
        ok.push(p);
    }
    let preps = ok;
    if preps.is_empty() {
        return Err(anyhow!("no worktree could be prepared for the batch"));
    }

    // ---- mark running (one write), then spawn workers --------------------
    let queue_lock = ws.acquire_planning_lock()?;
    let mut latest = ws.load_queue()?;
    let task_ids = preps
        .iter()
        .map(|prep| prep.task.id.clone())
        .collect::<Vec<_>>();
    mark_parallel_tasks_running(&mut latest, &task_ids)?;
    ws.save_queue_locked(&queue_lock, &latest)?;
    queue = latest;
    drop(queue_lock);
    on_event(&format!(
        "parallel batch: {}",
        preps
            .iter()
            .map(|p| format!("{} via {}", p.task.id, p.worker_id))
            .collect::<Vec<_>>()
            .join(", ")
    ));

    let attempt_runtime = preps
        .iter()
        .map(|prep| {
            let context = run::channel_run_context(ws, &queue.intent_id, &prep.task.id);
            let (attempt, capture) = run::begin_worker_attempt(
                ws,
                None,
                &context,
                &prep.run_dir,
                &prep.run_id,
                &prep.worker_id,
                prep.session.clone(),
                crate::schemas::ContinuationMode::Fresh,
                None,
            )?;
            Ok((context, attempt, capture))
        })
        .collect::<Result<Vec<_>>>()?;

    // Fail closed before ANY worker spawns: every run receipt must still
    // declare the isolated worktree its prep created, canonicalized equal to
    // the spawn cwd. A tampered or corrupted receipt aborts the whole batch
    // here (issue #34's parallel twin of the serial pre-spawn attestation);
    // `yardlet recover` reconciles the already-running-marked tasks.
    for p in &preps {
        run::attest_worker_cwd(&p.run_dir, &p.wt_path, false)?;
    }

    let (tx, rx) = mpsc::channel::<Finished>();
    let mut handles = Vec::new();
    for (i, p) in preps.iter().enumerate() {
        let tx = tx.clone();
        let env = match guard::sanitized_worker_env_for(&billing, &p.profile.invocation.pass_env) {
            Ok(e) => e,
            Err(e) => return Err(anyhow!(e)),
        };
        let profile = p.profile.clone();
        let bin = p.bin.clone();
        let packet_text = p.packet_text.clone();
        let cwd = p.wt_path.clone();
        let worker_run_dir = p.run_dir.clone();
        let capture = attempt_runtime[i].2.clone();
        let selection = p.selection.clone();
        let timeout = Duration::from_secs(p.profile.limits.max_wall_minutes as u64 * 60);
        let images = images.clone();
        let session = p.session.clone();
        handles.push(std::thread::spawn(move || {
            let started = std::time::Instant::now();
            let outcome = workers::spawn_resolved_attempt(
                &profile,
                &selection,
                &bin,
                &packet_text,
                &worker_run_dir,
                &cwd,
                &env,
                &capture,
                timeout,
                full_access,
                &images,
                session.as_deref(),
                false,
            );
            let _ = tx.send(Finished {
                prep_idx: i,
                outcome,
                wall_seconds: started.elapsed().as_secs(),
            });
        }));
    }
    drop(tx);

    // ---- integrate sequentially, in completion order ----------------------
    let mut states: Vec<(String, TaskState)> = Vec::new();
    let intent_summary = intent.as_ref().map(|i| i.summary.as_str()).unwrap_or("");
    for fin in rx {
        let p = &preps[fin.prep_idx];
        let mut outcome = fin.outcome;
        let mut worker_id = p.worker_id.clone();
        let mut reason = p.reason.clone();
        let mut wall_seconds = fin.wall_seconds;
        let mut failover_note: Option<String> = None;

        if let Ok(completed) = &outcome {
            let runtime = &attempt_runtime[fin.prep_idx];
            run::finish_worker_attempt(
                ws, None, &runtime.0, &p.run_dir, &runtime.1, &runtime.2, completed,
            )?;
        } else if let Err(error) = &outcome {
            let runtime = &attempt_runtime[fin.prep_idx];
            run::finish_worker_attempt_error(ws, &runtime.0, &runtime.1, error)?;
        }

        match &outcome {
            Ok(o) => on_event(&format!(
                "{}: worker finished ({}); integrating",
                p.task.id, o.note
            )),
            Err(e) => on_event(&format!("{}: worker error: {e}", p.task.id)),
        }

        if p.run_dir.join("cancelled").is_file() {
            let _ = std::fs::remove_file(p.run_dir.join("cancelled"));
            run::save_task_state_on_latest_queue(
                ws,
                &mut queue,
                &p.task.id,
                TaskState::Queued,
                crate::schemas::TransitionCause::RunOutcome,
                "stopped by user; task requeued",
                crate::schemas::TransitionActor::System,
            )?;
            remove_worktree(&ws.root, &p.wt_path, &p.branch);
            on_event(&format!("{}: stopped by user; requeued", p.task.id));
            states.push((p.task.id.clone(), TaskState::Queued));
            continue;
        }

        if !p.run_dir.join("result.json").exists() {
            match routing::resolve_failover_worker_for_task(
                &workers_file,
                &billing,
                &worker_id,
                &p.task,
            ) {
                Ok(alt) => {
                    let from = worker_id.clone();
                    let to = alt.worker_id.clone();
                    let note = format!(
                        "worker failover: {from} -> {to}; {from} exited without result.json"
                    );
                    on_event(&format!("{}: {note}", p.task.id));
                    record_failover(&p.run_dir, &from, &to, &note);

                    worker_id = to;
                    let selection = alt.selection();
                    reason = format!("failover from {from} ({})", alt.reason);
                    run::update_run_selection(&p.run_dir, &selection)?;
                    let failover_started = std::time::Instant::now();
                    outcome = (|| -> Result<workers::WorkerOutcome> {
                        let profile = run::find_worker(&workers_file.workers, &worker_id)?;
                        let eff_profile =
                            workers::effective_profile(profile, &p.task.model, &p.task.effort);
                        let env = guard::sanitized_worker_env_for(
                            &billing,
                            &eff_profile.invocation.pass_env,
                        )
                        .map_err(|e| anyhow!(e))?;
                        let timeout =
                            Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
                        let role_notes =
                            packet::load_role_notes(&ws.root, packet::role_for(&p.task.kind));
                        let run_dir_abs = p.run_dir.display().to_string();
                        let failover_packet = packet::compile(&PacketInputs {
                            worker_id: &worker_id,
                            task: &p.task,
                            intent: intent.as_ref(),
                            repo: &repo_summary,
                            run_dir_rel: &run_dir_abs,
                            conversation: &[],
                            continuation: Some(
                                "Output-contract feedback: the previous worker exited without \
                                 writing result.json. Complete the task, write every required \
                                 artifact, and make sure result.json matches the packet schema \
                                 exactly.",
                            ),
                            chained_from: None,
                            language: &language,
                            images: &images,
                            role_notes: &role_notes,
                            harness: &harness,
                            approved: false,
                        });
                        write_str(&workers::packet_path(&p.run_dir), &failover_packet)?;
                        // The first worker ran with full access to this run
                        // dir; re-attest the receipt before the failover
                        // spawn so a tampered worktree fails closed instead
                        // of redirecting the second worker's cwd.
                        run::attest_worker_cwd(&p.run_dir, &p.wt_path, false)?;
                        let session = (worker_id == "claude-code")
                            .then(|| run::gen_session_uuid(&format!("{}-{worker_id}", p.run_id)));
                        let context = run::channel_run_context(ws, &queue.intent_id, &p.task.id);
                        let attempt_id = run::attempt_id_for_ordinal(&p.run_id, 2);
                        let (attempt, capture) = run::begin_worker_attempt(
                            ws,
                            None,
                            &context,
                            &p.run_dir,
                            &attempt_id,
                            &worker_id,
                            session.clone(),
                            crate::schemas::ContinuationMode::Fallback,
                            None,
                        )?;
                        let completed = match workers::spawn_resolved_attempt(
                            &eff_profile,
                            &selection,
                            &alt.bin,
                            &failover_packet,
                            &p.run_dir,
                            &p.wt_path,
                            &env,
                            &capture,
                            timeout,
                            full_access,
                            &images,
                            session.as_deref(),
                            false,
                        ) {
                            Ok(completed) => completed,
                            Err(error) => {
                                run::finish_worker_attempt_error(ws, &context, &attempt, &error)?;
                                return Err(error);
                            }
                        };
                        run::finish_worker_attempt(
                            ws, None, &context, &p.run_dir, &attempt, &capture, &completed,
                        )?;
                        Ok(completed)
                    })();
                    wall_seconds += failover_started.elapsed().as_secs();
                    match &outcome {
                        Ok(o) => on_event(&format!(
                            "{}: failover worker finished ({})",
                            p.task.id, o.note
                        )),
                        Err(e) => on_event(&format!("{}: failover worker error: {e}", p.task.id)),
                    }
                    failover_note = Some(note);
                }
                Err(e) => {
                    let note = format!(
                        "worker failover unavailable after {} exited without result.json: {e}",
                        worker_id
                    );
                    on_event(&format!("{}: {note}", p.task.id));
                    failover_note = Some(note);
                }
            }
        }

        // Parallel runs execute in an isolated worktree, so its git status IS
        // the worker's diff (no baseline to subtract). finalize_run evaluates
        // the forbidden gate against that real evidence (not the worker's
        // self-report), then — only on a Done run — merges the worktree back;
        // it writes artifacts, the queue state, follow-ups, and telemetry. The
        // single finalization pipeline is shared with the serial path.
        let evidence = match parallel_worker_evidence(&p.wt_path, &p.run_dir) {
            Ok(paths) => Some(paths),
            Err(error) => {
                on_event(&format!(
                    "{}: change evidence unavailable after harness seed cleanup: {error}",
                    p.task.id
                ));
                None
            }
        };
        // A finalize error for one task (e.g. a transient queue-write hiccup)
        // must not abort the whole batch and strand the other already-finished
        // worktrees — log it and move on; `yardlet recover` salvages this one.
        let report = match run::finalize_run(run::FinalizeInput {
            ws,
            run_dir: &p.run_dir,
            run_id: &p.run_id,
            task: &p.task,
            evidence,
            worker_id: &worker_id,
            reason: &reason,
            wall_seconds,
            user_override: None,
            intent_summary,
            billing: &billing,
            queue: &mut queue,
            flags: run::FinalizeFlags::parallel(),
            merge: Some(run::MergeBack {
                wt_path: &p.wt_path,
                branch: &p.branch,
                baseline_oid: &p.baseline_oid,
                expected_tip_oid: None,
                core_input_overlays: &[],
                provenance: run::IntegrationProvenance::ParallelWorkerDirect,
                auto_commit: true,
            }),
        }) {
            Ok(r) => r,
            Err(e) => {
                // The merge may already have happened (the error can come from a
                // later queue write), so don't claim the worktree is kept — just
                // point at recover, which reconciles whatever state remains.
                on_event(&format!(
                    "{}: finalize failed ({e}); run `yardlet recover` to reconcile",
                    p.task.id
                ));
                continue;
            }
        };
        let next = report.next_state;
        if let Some(note) = &failover_note {
            if let Err(e) = run::append_failover_note(&p.run_dir, note) {
                on_event(&format!(
                    "{}: failed to append failover note: {e}",
                    p.task.id
                ));
            }
        }
        for line in report.lines {
            on_event(&line);
        }
        states.push((p.task.id.clone(), next));
    }
    for h in handles {
        let _ = h.join();
    }
    Ok(states)
}

fn record_failover(run_dir: &Path, from: &str, to: &str, reason: &str) {
    let event = ParallelFailover {
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

pub(crate) enum Integration {
    Merged {
        oid: String,
        base_oid: String,
        worker_oid: String,
        owned_oids: Vec<String>,
    },
    NoChanges {
        worker_oid: String,
    },
    Conflict(String),
}

const GIT_INTEGRATION_RECORD: &str = "git-integration.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum GitIntegrationProvenance {
    SerialCoreStaged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum GitIntegrationPhase {
    Prepared,
    CommitReady,
    Candidate,
    Published,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GitIntegrationTransaction {
    schema_version: u32,
    provenance: GitIntegrationProvenance,
    run_id: String,
    task_id: String,
    target_ref: String,
    transaction_ref: String,
    expected_tip_oid: String,
    staged_tree_oid: String,
    phase: GitIntegrationPhase,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    candidate_oid: String,
}

enum TransactionPublish {
    Published(String),
    Conflict(String),
}

fn transaction_ref(branch: &str) -> String {
    format!("refs/heads/yardlet-txn/{branch}")
}

fn transaction_path(run_dir: &Path) -> PathBuf {
    run_dir.join(GIT_INTEGRATION_RECORD)
}

fn load_transaction(run_dir: &Path) -> Result<Option<GitIntegrationTransaction>> {
    let path = transaction_path(run_dir);
    if !path.is_file() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&path)
        .map_err(|error| anyhow!("reading {}: {error}", path.display()))?;
    serde_json::from_str(&raw)
        .map(Some)
        .map_err(|error| anyhow!("parsing {}: {error}", path.display()))
}

fn persist_transaction(run_dir: &Path, record: &GitIntegrationTransaction) -> Result<()> {
    let path = transaction_path(run_dir);
    let text = serde_json::to_string_pretty(record)?;
    state::write_str_atomic(&path, &text)
}

fn ref_tip(root: &Path, reference: &str) -> Option<String> {
    git(
        root,
        &["rev-parse", "--verify", &format!("{reference}^{{commit}}")],
    )
    .ok()
    .map(|oid| oid.trim().to_string())
    .filter(|oid| !oid.is_empty())
}

fn transaction_candidate_conflict(
    root: &Path,
    candidate: &str,
    expected_parent: &str,
    expected_tree: &str,
) -> Result<Option<String>> {
    let parents = git(root, &["show", "-s", "--format=%P", candidate])?;
    let parents = parents.split_whitespace().collect::<Vec<_>>();
    if parents != [expected_parent] {
        return Ok(Some(format!(
            "transaction commit {candidate} is not a single-parent child of evaluated tip {expected_parent}"
        )));
    }
    let tree = git(
        root,
        &["rev-parse", "--verify", &format!("{candidate}^{{tree}}")],
    )?;
    if tree.trim() != expected_tree {
        return Ok(Some(format!(
            "transaction commit {candidate} does not contain the evaluated staged tree"
        )));
    }
    Ok(None)
}

/// Create the worker commit through native `git commit` on a durable internal
/// branch, then publish only that exact commit to the run-owned target with a
/// compare-and-swap. Native commit preserves repository hooks and signing;
/// the transaction record makes pre/post-CAS crashes recoverable without
/// rerunning a completed worker.
fn publish_transaction_commit(
    root: &Path,
    wt: &Path,
    run_dir: &Path,
    run_id: &str,
    branch: &str,
    task_id: &str,
    observed_tip: &str,
) -> Result<TransactionPublish> {
    let target_ref = format!("refs/heads/{branch}");
    let expected_transaction_ref = transaction_ref(branch);
    git(root, &["check-ref-format", &expected_transaction_ref])?;

    let mut record = match load_transaction(run_dir)? {
        Some(record) => record,
        None => {
            let current_tip = ref_tip(root, &target_ref).unwrap_or_else(|| "<missing>".into());
            if current_tip != observed_tip {
                return Ok(TransactionPublish::Conflict(format!(
                    "worktree branch tip changed after evidence collection: expected {observed_tip}, found {current_tip}"
                )));
            }
            let record = GitIntegrationTransaction {
                schema_version: 1,
                provenance: GitIntegrationProvenance::SerialCoreStaged,
                run_id: run_id.to_string(),
                task_id: task_id.to_string(),
                target_ref: target_ref.clone(),
                transaction_ref: expected_transaction_ref.clone(),
                expected_tip_oid: observed_tip.to_string(),
                staged_tree_oid: git(wt, &["write-tree"])?.trim().to_string(),
                phase: GitIntegrationPhase::Prepared,
                candidate_oid: String::new(),
            };
            persist_transaction(run_dir, &record)?;
            record
        }
    };

    if record.schema_version != 1
        || record.provenance != GitIntegrationProvenance::SerialCoreStaged
        || record.run_id != run_id
        || record.task_id != task_id
        || record.target_ref != target_ref
        || record.transaction_ref != expected_transaction_ref
        || record.expected_tip_oid.is_empty()
        || record.staged_tree_oid.is_empty()
    {
        return Ok(TransactionPublish::Conflict(
            "Git integration transaction record does not match this run-owned branch".to_string(),
        ));
    }
    if record.phase == GitIntegrationPhase::Failed {
        return Ok(TransactionPublish::Conflict(
            "the prior native Git commit attempt failed; worktree retained".to_string(),
        ));
    }

    let expected = record.expected_tip_oid.clone();
    let transaction = record.transaction_ref.clone();
    let mut target_tip = ref_tip(root, &target_ref).unwrap_or_else(|| "<missing>".into());
    let mut transaction_tip = ref_tip(root, &transaction);

    if record.phase == GitIntegrationPhase::Prepared {
        if target_tip != expected {
            return Ok(TransactionPublish::Conflict(format!(
                "worktree branch tip changed after evidence collection: expected {expected}, found {target_tip}"
            )));
        }
        match transaction_tip.as_deref() {
            None => {
                if git(root, &["update-ref", &transaction, &expected, ""]).is_err() {
                    let found = ref_tip(root, &transaction).unwrap_or_else(|| "<missing>".into());
                    return Ok(TransactionPublish::Conflict(format!(
                        "could not claim the run-owned Git transaction ref: expected absent, found {found}"
                    )));
                }
            }
            Some(found) if found == expected => {}
            Some(found) => {
                return Ok(TransactionPublish::Conflict(format!(
                    "run-owned Git transaction ref was already changed: expected {expected}, found {found}"
                )));
            }
        }
        record.phase = GitIntegrationPhase::CommitReady;
        persist_transaction(run_dir, &record)?;
    }

    transaction_tip = ref_tip(root, &transaction);
    let mut candidate = transaction_tip.unwrap_or_default();
    if record.phase == GitIntegrationPhase::CommitReady && candidate == expected {
        if target_tip != expected {
            return Ok(TransactionPublish::Conflict(format!(
                "worktree branch tip changed after evidence collection: expected {expected}, found {target_tip}"
            )));
        }
        let index_tree = git(wt, &["write-tree"])?.trim().to_string();
        if index_tree != record.staged_tree_oid {
            return Ok(TransactionPublish::Conflict(
                "staged tree changed after the Git integration transaction was prepared"
                    .to_string(),
            ));
        }
        git(
            wt,
            &[
                "symbolic-ref",
                "-m",
                "yardlet integration prepare",
                "HEAD",
                &transaction,
            ],
        )?;
        let message = commit_message(root, task_id);
        if let Err(error) = git(wt, &["commit", "-m", &message]) {
            let after = ref_tip(root, &transaction);
            if after.as_deref() == Some(expected.as_str()) {
                let _ = git(
                    wt,
                    &[
                        "symbolic-ref",
                        "-m",
                        "yardlet integration commit failed",
                        "HEAD",
                        &target_ref,
                    ],
                );
                let _ = git(root, &["update-ref", "-d", &transaction, &expected]);
                record.phase = GitIntegrationPhase::Failed;
                let _ = persist_transaction(run_dir, &record);
            }
            return Err(error);
        }
        candidate = ref_tip(root, &transaction).unwrap_or_else(|| "<missing>".into());
    } else if record.phase == GitIntegrationPhase::Prepared {
        return Ok(TransactionPublish::Conflict(
            "untrusted transaction commit appeared before native Git commit was authorized"
                .to_string(),
        ));
    } else if matches!(
        record.phase,
        GitIntegrationPhase::Candidate | GitIntegrationPhase::Published
    ) && (record.candidate_oid.is_empty() || record.candidate_oid != candidate)
    {
        return Ok(TransactionPublish::Conflict(format!(
            "Git transaction candidate changed: expected {}, found {candidate}",
            record.candidate_oid
        )));
    }

    if candidate == "<missing>" || candidate.is_empty() {
        return Ok(TransactionPublish::Conflict(
            "native Git commit did not leave a reachable transaction commit".to_string(),
        ));
    }
    if let Some(reason) =
        transaction_candidate_conflict(root, &candidate, &expected, &record.staged_tree_oid)?
    {
        return Ok(TransactionPublish::Conflict(reason));
    }
    if !record.candidate_oid.is_empty() && record.candidate_oid != candidate {
        return Ok(TransactionPublish::Conflict(format!(
            "Git transaction candidate changed: expected {}, found {candidate}",
            record.candidate_oid
        )));
    }
    record.candidate_oid = candidate.clone();
    if record.phase != GitIntegrationPhase::Published {
        record.phase = GitIntegrationPhase::Candidate;
        persist_transaction(run_dir, &record)?;
    }

    target_tip = ref_tip(root, &target_ref).unwrap_or_else(|| "<missing>".into());
    match record.phase {
        GitIntegrationPhase::Candidate if target_tip == expected => {
            if git(root, &["update-ref", &target_ref, &candidate, &expected]).is_err() {
                let found = ref_tip(root, &target_ref).unwrap_or_else(|| "<missing>".into());
                return Ok(TransactionPublish::Conflict(format!(
                    "worktree branch tip changed after evidence collection: expected {expected}, found {found}"
                )));
            }
        }
        GitIntegrationPhase::Candidate if target_tip == candidate => {}
        GitIntegrationPhase::Candidate => {
            return Ok(TransactionPublish::Conflict(format!(
                "worktree branch tip changed after evidence collection: expected {expected} or {candidate}, found {target_tip}"
            )));
        }
        GitIntegrationPhase::Published if target_tip == candidate => {}
        GitIntegrationPhase::Published => {
            return Ok(TransactionPublish::Conflict(format!(
                "published Git transaction target moved: expected {candidate}, found {target_tip}"
            )));
        }
        _ => {
            return Ok(TransactionPublish::Conflict(
                "Git integration transaction reached an invalid publish phase".to_string(),
            ));
        }
    }

    record.phase = GitIntegrationPhase::Published;
    persist_transaction(run_dir, &record)?;
    git(
        wt,
        &[
            "symbolic-ref",
            "-m",
            "yardlet integration published",
            "HEAD",
            &target_ref,
        ],
    )?;
    Ok(TransactionPublish::Published(candidate))
}

fn publish_parallel_commit(
    root: &Path,
    wt: &Path,
    branch_ref: &str,
    task_id: &str,
    observed_tip: &str,
) -> Result<TransactionPublish> {
    let message = commit_message(root, task_id);
    let tree_oid = git(wt, &["write-tree"])?.trim().to_string();
    let commit_oid = git(
        wt,
        &["commit-tree", &tree_oid, "-p", observed_tip, "-m", &message],
    )?
    .trim()
    .to_string();
    if git(root, &["update-ref", branch_ref, &commit_oid, observed_tip]).is_err() {
        let found = ref_tip(root, branch_ref).unwrap_or_else(|| "<missing>".to_string());
        return Ok(TransactionPublish::Conflict(format!(
            "worktree branch tip changed after evidence collection: expected {observed_tip}, found {found}"
        )));
    }
    Ok(TransactionPublish::Published(commit_oid))
}

/// Is a merge in progress in `root`, and if so, is it OUR merge of `branch`?
/// None = no merge in progress. Distinguishing matters: aborting blindly
/// would destroy a merge the USER had in progress.
fn merge_in_progress_is_ours(root: &Path, branch: &str) -> Option<bool> {
    let rel = git(root, &["rev-parse", "--git-path", "MERGE_MSG"]).ok()?;
    let path = root.join(rel.trim());
    let msg = std::fs::read_to_string(path).ok()?;
    Some(msg.contains(branch))
}

/// Locate exactly one attributable two-parent merge on current first-parent
/// history. This freezes the merge identity even if HEAD advances before the
/// merge command starts or immediately after it returns.
fn attributable_merge_after(
    root: &Path,
    since_oid: &str,
    worker_oid: &str,
) -> Result<Option<(String, String)>> {
    let history = git(
        root,
        &[
            "rev-list",
            "--first-parent",
            "--reverse",
            &format!("{since_oid}..HEAD"),
        ],
    )?;
    let mut found = Vec::new();
    for candidate in history.lines().map(str::trim).filter(|oid| !oid.is_empty()) {
        let parents = git(root, &["show", "-s", "--format=%P", candidate])?;
        let parents = parents.split_whitespace().collect::<Vec<_>>();
        if parents.len() == 2 && parents[1] == worker_oid {
            found.push((candidate.to_string(), parents[0].to_string()));
        }
    }
    match found.len() {
        0 => Ok(None),
        1 => Ok(found.pop()),
        _ => Err(anyhow!(
            "multiple attributable merges found for worker commit {worker_oid}"
        )),
    }
}

#[derive(Clone, Copy)]
enum IntegrationCommitMode<'a> {
    SerialCoreStaged { run_dir: &'a Path, run_id: &'a str },
    ParallelWorkerDirect,
}

fn serial_receipt_conflict(
    root: &Path,
    wt: &Path,
    run_dir: &Path,
    run_id: &str,
    branch: &str,
    task_id: &str,
    baseline_oid: &str,
) -> Option<String> {
    let workspace = Workspace::at(root);
    let receipt = workspace.load_serial_integration_receipt(run_id).ok()?;
    let expected_run_dir = workspace.runs_dir().join(run_id);
    (receipt.schema_version != 1
        || receipt.run_id != run_id
        || receipt.task_id != task_id
        || receipt.worktree != wt.display().to_string()
        || receipt.branch != branch
        || receipt.baseline_oid != baseline_oid
        || run_dir != expected_run_dir)
        .then(|| "serial integration receipt does not match this run-owned worktree".to_string())
}

/// Integrate a serial worker whose result artifacts were staged outside the
/// canonical run directory and imported by the core. Only this entry point can
/// load the durable native-commit transaction record.
#[allow(clippy::too_many_arguments)]
pub(crate) fn integrate_serial_worktree(
    root: &Path,
    wt: &Path,
    run_dir: &Path,
    run_id: &str,
    branch: &str,
    task_id: &str,
    baseline_oid: &str,
    expected_tip_oid: Option<&str>,
) -> Result<Integration> {
    let workspace = Workspace::at(root);
    let receipt = match workspace.load_serial_integration_receipt(run_id) {
        Ok(receipt) => receipt,
        Err(_) => {
            return Ok(Integration::Conflict(
                "core-owned serial integration receipt is missing or invalid".to_string(),
            ))
        }
    };
    if let Some(reason) =
        serial_receipt_conflict(root, wt, run_dir, run_id, branch, task_id, baseline_oid)
    {
        return Ok(Integration::Conflict(reason));
    }
    integrate_worktree_after_staged(
        root,
        wt,
        branch,
        task_id,
        baseline_oid,
        expected_tip_oid,
        IntegrationCommitMode::SerialCoreStaged { run_dir, run_id },
        &receipt.core_input_overlays,
        |_, _, _| Ok(()),
    )
}

/// Integrate a parallel worker without accepting any run-directory transaction
/// input. Its evaluated staged tree is committed with immutable Git plumbing
/// and published to the run-owned branch by exact-tip CAS.
pub(crate) fn integrate_parallel_worktree(
    root: &Path,
    wt: &Path,
    branch: &str,
    task_id: &str,
    baseline_oid: &str,
    expected_tip_oid: Option<&str>,
) -> Result<Integration> {
    integrate_worktree_after_staged(
        root,
        wt,
        branch,
        task_id,
        baseline_oid,
        expected_tip_oid,
        IntegrationCommitMode::ParallelWorkerDirect,
        &[],
        |_, _, _| Ok(()),
    )
}

// The final callback is a deterministic race-injection seam used by the unit
// test; keeping the production arguments explicit makes ownership boundaries
// visible at each call site.
#[allow(clippy::too_many_arguments)]
fn integrate_worktree_after_staged<F>(
    root: &Path,
    wt: &Path,
    branch: &str,
    task_id: &str,
    baseline_oid: &str,
    expected_tip_oid: Option<&str>,
    commit_mode: IntegrationCommitMode<'_>,
    core_input_overlays: &[state::SerialInputOverlay],
    after_staged: F,
) -> Result<Integration>
where
    F: FnOnce(&Path, &Path, &str) -> Result<()>,
{
    // Legacy run records did not persist a baseline. Recovery can safely derive
    // the worktree branch's merge-base, while new runs always pass the pinned
    // spawn-time OID recorded in run.yaml.
    let derived_baseline;
    let baseline_oid = if baseline_oid.is_empty() {
        derived_baseline = git(root, &["merge-base", "HEAD", branch])?
            .trim()
            .to_string();
        derived_baseline.as_str()
    } else {
        baseline_oid
    };
    // A previous session may have died in the middle of merging this very
    // branch, leaving the checkout mid-merge: abort OUR stale merge so the
    // retry below starts clean. A merge belonging to anyone else is left
    // untouched and reported instead.
    match merge_in_progress_is_ours(root, branch) {
        Some(true) => {
            let _ = git(root, &["merge", "--abort"]);
        }
        Some(false) => {
            return Ok(Integration::Conflict(
                "another merge is already in progress in the workspace; \
                 finish or abort it, then retry"
                    .to_string(),
            ));
        }
        None => {}
    }
    let branch_ref = format!("refs/heads/{branch}");
    let observed_tip = git(
        root,
        &["rev-parse", "--verify", &format!("{branch_ref}^{{commit}}")],
    )?
    .trim()
    .to_string();
    if let Some(expected_tip_oid) = expected_tip_oid.filter(|oid| !oid.is_empty()) {
        if observed_tip != expected_tip_oid {
            return Ok(Integration::Conflict(format!(
                "worktree branch tip changed after evidence collection: expected {expected_tip_oid}, found {observed_tip}"
            )));
        }
    }
    stage_integratable_changes(wt, core_input_overlays)?;
    let staged = git(wt, &["diff", "--cached", "--name-only"])?;
    after_staged(root, wt, branch)?;
    let transaction_exists = match commit_mode {
        IntegrationCommitMode::SerialCoreStaged { run_dir, .. } => {
            transaction_path(run_dir).is_file()
        }
        IntegrationCommitMode::ParallelWorkerDirect => false,
    };
    let worker_tip = if !staged.trim().is_empty() || transaction_exists {
        let publish = match commit_mode {
            IntegrationCommitMode::SerialCoreStaged { run_dir, run_id } => {
                publish_transaction_commit(
                    root,
                    wt,
                    run_dir,
                    run_id,
                    branch,
                    task_id,
                    &observed_tip,
                )?
            }
            IntegrationCommitMode::ParallelWorkerDirect => {
                publish_parallel_commit(root, wt, &branch_ref, task_id, &observed_tip)?
            }
        };
        match publish {
            TransactionPublish::Published(oid) => oid,
            TransactionPublish::Conflict(reason) => {
                return Ok(Integration::Conflict(reason));
            }
        }
    } else {
        let current_tip = git(
            root,
            &["rev-parse", "--verify", &format!("{branch_ref}^{{commit}}")],
        )?
        .trim()
        .to_string();
        if current_tip != observed_tip {
            return Ok(Integration::Conflict(format!(
                "worktree branch tip changed after evidence collection: expected {observed_tip}, found {current_tip}"
            )));
        }
        observed_tip
    };
    let ancestry = git(
        root,
        &["merge-base", "--is-ancestor", baseline_oid, &worker_tip],
    );
    if ancestry.is_err() {
        return Ok(Integration::Conflict(
            "worktree branch no longer descends from its recorded baseline".to_string(),
        ));
    }
    let mut owned_oids = git(
        root,
        &[
            "rev-list",
            "--reverse",
            &format!("{baseline_oid}..{worker_tip}"),
        ],
    )?
    .lines()
    .map(str::trim)
    .filter(|oid| !oid.is_empty())
    .map(str::to_string)
    .collect::<Vec<_>>();
    let base_oid = git(root, &["rev-parse", "--verify", "HEAD^{commit}"])?
        .trim()
        .to_string();
    let ahead = git(
        root,
        &["rev-list", "--count", &format!("HEAD..{worker_tip}")],
    )?;
    if ahead.trim() == "0" {
        if worker_tip != baseline_oid {
            // Crash recovery after `git merge --no-ff` succeeded but before the
            // run record persisted its integration OID. Reconstruct the exact
            // existing merge from first-parent history instead of returning
            // NoChanges and losing ownership evidence. The second parent must
            // be this run's immutable worktree tip.
            if let Some((oid, base_oid)) =
                attributable_merge_after(root, baseline_oid, &worker_tip)?
            {
                owned_oids.push(oid.clone());
                return Ok(Integration::Merged {
                    oid,
                    base_oid,
                    worker_oid: worker_tip,
                    owned_oids,
                });
            }
            return Ok(Integration::Conflict(
                "worktree commit is already reachable but its attributable merge commit \
                 could not be reconstructed"
                    .to_string(),
            ));
        }
        return Ok(Integration::NoChanges {
            worker_oid: worker_tip,
        });
    }
    let merge_message = format!("Merge run-owned branch {branch}");
    match git(
        root,
        &[
            "merge",
            "--no-ff",
            "--no-edit",
            "-m",
            &merge_message,
            &worker_tip,
        ],
    ) {
        Ok(_) => {
            let Some((oid, base_oid)) = attributable_merge_after(root, &base_oid, &worker_tip)?
            else {
                return Ok(Integration::Conflict(
                    "Git merge returned success but its exact two-parent integration commit could not be attributed"
                        .to_string(),
                ));
            };
            owned_oids.push(oid.clone());
            Ok(Integration::Merged {
                oid,
                base_oid,
                worker_oid: worker_tip,
                owned_oids,
            })
        }
        Err(e) => {
            // Abort only if the failed merge is OURS (a content conflict from
            // the command above); never touch someone else's merge state.
            if merge_in_progress_is_ours(root, branch) == Some(true) {
                let _ = git(root, &["merge", "--abort"]);
            }
            Ok(Integration::Conflict(e.to_string()))
        }
    }
}

fn commit_message(root: &Path, task_id: &str) -> String {
    let title = task_title(root, task_id)
        .map(|t| single_line(&t))
        .filter(|t| !t.is_empty() && t != task_id)
        .unwrap_or_else(|| "task changes".to_string());
    format!("yardlet({task_id}): {title}")
}

fn task_title(root: &Path, task_id: &str) -> Option<String> {
    let queue_path = root.join(crate::state::STATE_DIR).join("work-queue.yaml");
    let text = std::fs::read_to_string(queue_path).ok()?;
    let queue: WorkQueue = crate::yaml::from_str(&text).ok()?;
    queue
        .tasks
        .into_iter()
        .find(|task| task.id == task_id)
        .map(|task| task.title)
}

fn single_line(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub(crate) fn create_worktree(root: &Path, wt: &Path, branch: &str) -> Result<()> {
    // Clear stale leftovers from a crashed/conflicted earlier run of this task.
    let wt_s = wt.display().to_string();
    let _ = git(root, &["worktree", "remove", "--force", &wt_s]);
    let _ = std::fs::remove_dir_all(wt);
    let _ = git(root, &["worktree", "prune"]);
    let _ = git(root, &["branch", "-D", branch]);
    let _ = git(root, &["worktree", "prune"]);
    git(root, &["worktree", "add", &wt_s, "-b", branch]).map(|_| ())
}

pub(crate) fn remove_worktree(root: &Path, wt: &Path, branch: &str) {
    let branch_ref = format!("refs/heads/{branch}");
    let branch_tip = ref_tip(root, &branch_ref);
    let transaction = transaction_ref(branch);
    let transaction_tip = ref_tip(root, &transaction);
    let removed = git(
        root,
        &["worktree", "remove", "--force", &wt.display().to_string()],
    )
    .is_ok();
    let _ = git(root, &["worktree", "prune"]);
    if removed || (!wt.exists() && !worktree_registered(root, wt)) {
        if let Some(branch_tip) = branch_tip {
            let _ = git(root, &["update-ref", "-d", &branch_ref, &branch_tip]);
        }
        if let Some(transaction_tip) = transaction_tip {
            let _ = git(root, &["update-ref", "-d", &transaction, &transaction_tip]);
        }
    }
}

pub(crate) struct IntegratedCleanup {
    pub complete: bool,
    pub warnings: Vec<String>,
}

fn worktree_registered(root: &Path, wt: &Path) -> bool {
    let expected = wt.display().to_string();
    git(root, &["worktree", "list", "--porcelain"])
        .ok()
        .is_some_and(|listed| {
            listed
                .lines()
                .filter_map(|line| line.strip_prefix("worktree "))
                .any(|path| path == expected)
        })
}

fn cleanup_owned_ref(
    root: &Path,
    reference: &str,
    expected_oid: &str,
    label: &str,
    warnings: &mut Vec<String>,
) -> bool {
    let Some(found) = ref_tip(root, reference) else {
        return true;
    };
    if found != expected_oid {
        warnings.push(format!(
            "retained moved {label} {reference}: expected {expected_oid}, found {found}"
        ));
        return false;
    }
    if git(root, &["update-ref", "-d", reference, expected_oid]).is_err() {
        let after = ref_tip(root, reference).unwrap_or_else(|| "<missing>".to_string());
        warnings.push(format!(
            "could not delete owned {label} {reference} at {expected_oid}; found {after}"
        ));
        return false;
    }
    true
}

fn cleanup_core_input_overlays(
    root: &Path,
    wt: &Path,
    provenance: run::IntegrationProvenance,
) -> Vec<state::SerialInputOverlay> {
    if provenance != run::IntegrationProvenance::SerialCoreStaged {
        return Vec::new();
    }
    let Some(run_id) = wt.file_name().and_then(|name| name.to_str()) else {
        return Vec::new();
    };
    let workspace = Workspace::at(root);
    if let Ok(receipt) = workspace.load_integrated_cleanup_receipt(run_id) {
        if receipt.run_id == run_id
            && receipt.worktree == wt.display().to_string()
            && receipt.provenance == provenance
        {
            return receipt.core_input_overlays;
        }
        return Vec::new();
    }
    if let Ok(receipt) = workspace.load_no_change_receipt(run_id) {
        if receipt.run_id == run_id
            && receipt.worktree == wt.display().to_string()
            && receipt.provenance == provenance
        {
            return receipt.core_input_overlays;
        }
        return Vec::new();
    }
    workspace
        .load_serial_integration_receipt(run_id)
        .ok()
        .filter(|receipt| receipt.run_id == run_id && receipt.worktree == wt.display().to_string())
        .map(|receipt| receipt.core_input_overlays)
        .unwrap_or_default()
}

/// Idempotently clean a successfully integrated worktree. Ref deletion is
/// compare-and-swap against the exact merge second parent, so a concurrently
/// moved or reused branch is retained rather than mistaken for this run's.
pub(crate) fn cleanup_integrated_worktree(
    root: &Path,
    wt: &Path,
    branch: &str,
    worker_oid: &str,
    provenance: run::IntegrationProvenance,
) -> IntegratedCleanup {
    let mut warnings = Vec::new();
    let branch_ref = format!("refs/heads/{branch}");
    let transaction = transaction_ref(branch);
    if !branch.starts_with("yard/")
        || git(root, &["check-ref-format", &branch_ref]).is_err()
        || worker_oid.is_empty()
    {
        warnings.push("refused integrated cleanup with invalid ownership identity".to_string());
        return IntegratedCleanup {
            complete: false,
            warnings,
        };
    }

    // Inspect ownership before removing anything. A later session may have
    // advanced either ref after integration; retaining both the ref and its
    // checkout is safer than force-removing a worktree that no longer belongs
    // exclusively to this run.
    for (reference, label) in [
        (branch_ref.as_str(), "worktree branch"),
        (transaction.as_str(), "transaction ref"),
    ] {
        if label == "transaction ref" && provenance != run::IntegrationProvenance::SerialCoreStaged
        {
            continue;
        }
        if let Some(found) = ref_tip(root, reference) {
            if found != worker_oid {
                warnings.push(format!(
                    "retained moved {label} {reference}: expected {worker_oid}, found {found}"
                ));
                return IntegratedCleanup {
                    complete: false,
                    warnings,
                };
            }
        }
    }

    if wt.exists() {
        let core_input_overlays = cleanup_core_input_overlays(root, wt, provenance);
        let expected_symbolic = format!("refs/heads/{branch}");
        let symbolic_head = git(wt, &["symbolic-ref", "--quiet", "HEAD"])
            .ok()
            .map(|value| value.trim().to_string());
        let worktree_head = git(wt, &["rev-parse", "--verify", "HEAD^{commit}"])
            .ok()
            .map(|value| value.trim().to_string());
        if symbolic_head.as_deref() != Some(expected_symbolic.as_str())
            || worktree_head.as_deref() != Some(worker_oid)
        {
            warnings.push(format!(
                "retained worktree {} whose HEAD no longer matches the owned branch at {worker_oid}",
                wt.display()
            ));
            return IntegratedCleanup {
                complete: false,
                warnings,
            };
        }
        let Some(changed) = evaluator::changed_paths(wt) else {
            warnings.push(format!(
                "could not verify owned worktree {}; worktree and refs retained",
                wt.display()
            ));
            return IntegratedCleanup {
                complete: false,
                warnings,
            };
        };
        let retained = changed
            .into_iter()
            .filter(|path| evaluator::is_integratable_path(path))
            .filter(|path| {
                !core_input_overlays.iter().any(|overlay| {
                    overlay.path == *path && run::serial_input_overlay_matches(wt, overlay)
                })
            })
            .collect::<Vec<_>>();
        if !retained.is_empty() {
            warnings.push(format!(
                "retained worktree {} with post-integration changes: {}",
                wt.display(),
                retained.join(", ")
            ));
            return IntegratedCleanup {
                complete: false,
                warnings,
            };
        }
    }

    if (wt.exists() || worktree_registered(root, wt))
        && git(
            root,
            &["worktree", "remove", "--force", &wt.display().to_string()],
        )
        .is_err()
    {
        warnings.push(format!(
            "could not remove owned worktree {}; refs retained",
            wt.display()
        ));
    }
    let _ = git(root, &["worktree", "prune"]);
    if wt.exists() || worktree_registered(root, wt) {
        return IntegratedCleanup {
            complete: false,
            warnings,
        };
    }

    let target_clean = cleanup_owned_ref(
        root,
        &branch_ref,
        worker_oid,
        "worktree branch",
        &mut warnings,
    );
    let transaction_clean = if provenance == run::IntegrationProvenance::SerialCoreStaged {
        cleanup_owned_ref(
            root,
            &transaction_ref(branch),
            worker_oid,
            "transaction ref",
            &mut warnings,
        )
    } else {
        true
    };
    IntegratedCleanup {
        complete: target_clean && transaction_clean,
        warnings,
    }
}

fn stage_integratable_changes(
    wt: &Path,
    core_input_overlays: &[state::SerialInputOverlay],
) -> Result<()> {
    let paths = evaluator::changed_paths(wt)
        .ok_or_else(|| anyhow!("could not enumerate worktree changes before integration"))?;
    // Discard worker-controlled index state, then rebuild the staged tree from
    // the deterministic integration allowlist. This keeps canonical/runtime
    // `.agents` state out while permitting repository harness assets.
    git(wt, &["reset", "-q"])?;
    for path in paths
        .into_iter()
        .filter(|path| evaluator::is_integratable_path(path))
        .filter(|path| {
            !core_input_overlays.iter().any(|overlay| {
                overlay.path == *path && run::serial_input_overlay_matches(wt, overlay)
            })
        })
    {
        git(wt, &["add", "-A", "--", &path])?;
    }
    Ok(())
}

fn parallel_worker_evidence(wt: &Path, run_dir: &Path) -> Result<Vec<String>> {
    let mut paths = evaluator::changed_paths(wt)
        .ok_or_else(|| anyhow!("could not enumerate parallel worktree changes"))?;
    let seed_root = run_dir.join(run::HARNESS_SEED_DIR);
    if seed_root.is_dir() {
        let (seeded, modified) = run::seeded_harness_evidence(&seed_root, wt)
            .ok_or_else(|| anyhow!("could not compare harness seed snapshot"))?;
        let unchanged = paths
            .iter()
            .filter(|path| seeded.contains(*path) && !modified.contains(*path))
            .cloned()
            .collect::<Vec<_>>();
        paths.retain(|path| !seeded.contains(path) || modified.contains(path));
        for path in modified {
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
        for path in unchanged {
            run::discard_unchanged_seeded_harness_copy(wt, &path)?;
        }
    }
    Ok(paths
        .into_iter()
        .filter(|path| evaluator::is_integratable_path(path))
        .collect())
}

/// Keep `.agents/worktrees/` out of `git status` in any repo Yardlet runs in,
/// without touching the repo's own .gitignore: use the repo-local exclude file.
pub(crate) fn ensure_worktrees_excluded(root: &Path) {
    let Ok(common) = git(root, &["rev-parse", "--git-common-dir"]) else {
        return;
    };
    let common = common.trim();
    let git_dir = if Path::new(common).is_absolute() {
        PathBuf::from(common)
    } else {
        root.join(common)
    };
    let exclude = git_dir.join("info").join("exclude");
    let existing = std::fs::read_to_string(&exclude).unwrap_or_default();
    if existing.lines().any(|l| l.trim() == ".agents/worktrees/") {
        return;
    }
    let _ = std::fs::create_dir_all(git_dir.join("info"));
    let _ = std::fs::write(&exclude, format!("{existing}\n.agents/worktrees/\n"));
}

/// Best-effort recursive copy for small harness asset dirs (no-op if absent).
///
/// Symlinks are entries to preserve, never directories to traverse. This is
/// especially important when a tracked harness symlink in two Git worktrees
/// resolves to the same external directory.
/// Returns the copy warnings so run preparation can persist them as run
/// evidence; they are still echoed to stderr for interactive visibility.
pub(crate) fn copy_dir(src: &Path, dst: &Path) -> Vec<String> {
    let mut warnings = Vec::new();
    copy_dir_inner(src, dst, &mut warnings);
    for warning in &warnings {
        eprintln!("warning: {warning}");
    }
    warnings
}

fn copy_dir_inner(src: &Path, dst: &Path, warnings: &mut Vec<String>) {
    let source_metadata = match std::fs::symlink_metadata(src) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
        Err(error) => {
            warnings.push(format!(
                "could not inspect harness directory {}: {error}",
                src.display()
            ));
            return;
        }
    };
    if source_metadata.file_type().is_symlink() || !source_metadata.is_dir() {
        warnings.push(format!(
            "skipped non-directory harness root {}",
            src.display()
        ));
        return;
    }
    if std::fs::symlink_metadata(dst).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        warnings.push(format!(
            "skipped harness directory {} because destination {} is a symlink",
            src.display(),
            dst.display()
        ));
        return;
    }
    if let Err(error) = std::fs::create_dir_all(dst) {
        warnings.push(format!(
            "could not create harness directory {}: {error}",
            dst.display()
        ));
        return;
    }
    let entries = match std::fs::read_dir(src) {
        Ok(entries) => entries,
        Err(error) => {
            warnings.push(format!(
                "could not read harness directory {}: {error}",
                src.display()
            ));
            return;
        }
    };
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                warnings.push(format!(
                    "could not read an entry in harness directory {}: {error}",
                    src.display()
                ));
                continue;
            }
        };
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let metadata = match std::fs::symlink_metadata(&from) {
            Ok(metadata) => metadata,
            Err(error) => {
                warnings.push(format!(
                    "could not inspect harness entry {}: {error}",
                    from.display()
                ));
                continue;
            }
        };
        let result = if metadata.file_type().is_symlink() {
            copy_symlink(&from, &to)
        } else if metadata.is_dir() {
            copy_dir_inner(&from, &to, warnings);
            continue;
        } else if metadata.is_file() {
            copy_regular_file(&from, &to)
        } else {
            warnings.push(format!(
                "skipped unsupported harness entry {}",
                from.display()
            ));
            continue;
        };
        if let Err(error) = result {
            warnings.push(format!(
                "could not copy harness entry {} to {}: {error}",
                from.display(),
                to.display()
            ));
        }
    }
}

fn copy_regular_file(src: &Path, dst: &Path) -> std::io::Result<()> {
    if std::fs::symlink_metadata(dst).is_ok_and(|metadata| metadata.file_type().is_symlink()) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "destination is a symlink",
        ));
    }
    if let (Ok(source), Ok(destination)) = (src.canonicalize(), dst.canonicalize()) {
        if source == destination {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "source and destination resolve to the same file",
            ));
        }
    }
    std::fs::copy(src, dst).map(|_| ())
}

fn copy_symlink(src: &Path, dst: &Path) -> std::io::Result<()> {
    let target = std::fs::read_link(src)?;
    match std::fs::symlink_metadata(dst) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            if std::fs::read_link(dst)? == target {
                return Ok(());
            }
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination is a different symlink",
            ));
        }
        Ok(_) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination already exists and is not a symlink",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    create_symlink(&target, dst)
}

#[cfg(unix)]
fn create_symlink(target: &Path, link: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(target, link)
}

#[cfg(not(unix))]
fn create_symlink(_target: &Path, _link: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "preserving harness symlinks is unsupported on this platform",
    ))
}

/// Run git in `dir`, returning stdout on success and stderr in the error.
fn git(dir: &Path, args: &[&str]) -> Result<String> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| anyhow!("git not available: {e}"))?;
    if !out.status.success() {
        return Err(anyhow!(
            "git {} failed: {}",
            args.first().copied().unwrap_or(""),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::{SelectionPolicy, WorkQueue};
    use crate::state::Workspace;

    fn task(id: &str, state: TaskState, priority: i64, deps: Vec<String>) -> Task {
        Task {
            id: id.into(),
            title: id.into(),
            state,
            priority,
            risk: String::new(),
            kind: String::new(),
            preferred_worker: String::new(),
            model: String::new(),
            fallback_enabled: None,
            effort: String::new(),
            depends_on: deps,
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: None,
            interaction: None,
            worker_rationale: None,
            provenance: String::new(),
            routing_provenance: None,
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

    #[test]
    fn ready_set_respects_deps_priority_and_cap() {
        let q = queue(vec![
            task("A", TaskState::Queued, 30, vec![]),
            task("B", TaskState::Queued, 10, vec![]),
            task("C", TaskState::Queued, 20, vec!["A".into()]), // dep not done
            task("D", TaskState::Done, 5, vec![]),
            task("E", TaskState::Queued, 40, vec!["D".into()]), // dep done
        ]);
        assert_eq!(ready_independent(&q, 10), vec![1, 0, 4]); // B(10), A(30), E(40)
        assert_eq!(ready_independent(&q, 2), vec![1, 0]);
    }

    #[test]
    fn ready_set_includes_validation_tasks() {
        // Validation-bearing tasks use the same pre-merge gate in their isolated
        // worktree and therefore remain eligible for parallel batches.
        let mut needs_val = task("V", TaskState::Queued, 5, vec![]);
        needs_val.validation = Some(crate::yaml::from_str("commands: [cargo test]").unwrap());
        let q = queue(vec![task("A", TaskState::Queued, 10, vec![]), needs_val]);
        assert_eq!(ready_independent(&q, 10), vec![1, 0]);
    }

    #[test]
    fn parallel_admission_changes_only_scheduler_state_before_receipts_exist() {
        let mut q = queue(vec![
            task("YARD-001", TaskState::Queued, 10, vec![]),
            task("YARD-002", TaskState::Queued, 20, vec![]),
        ]);
        q.tasks[0].model = "auto".to_string();
        q.tasks[1].model = "auto".to_string();
        let before = q
            .tasks
            .iter()
            .map(Task::runtime_contract_digest)
            .collect::<Result<Vec<_>, _>>()
            .unwrap();

        mark_parallel_tasks_running(&mut q, &["YARD-001".to_string(), "YARD-002".to_string()])
            .unwrap();

        assert!(q.tasks.iter().all(|task| task.state == TaskState::Running));
        assert!(q.tasks.iter().all(|task| task.routing_provenance.is_none()));
        assert_eq!(
            q.tasks
                .iter()
                .map(Task::runtime_contract_digest)
                .collect::<Result<Vec<_>, _>>()
                .unwrap(),
            before
        );
    }

    #[test]
    fn final_review_waits_for_a_runnable_worker_follow_up() {
        let mut review = task("REVIEW", TaskState::Queued, 40, vec![]);
        review.kind = "review".into();
        let mut follow_up = task("FIX", TaskState::Queued, 50, vec![]);
        follow_up.kind = "implementation".into();
        follow_up.provenance = "worker-proposed".into();
        let mut q = queue(vec![review, follow_up]);

        // The verifier must not share a batch with code it has not seen yet,
        // even when its numeric priority would otherwise put it first.
        assert_eq!(ready_independent(&q, 4), vec![1]);

        q.tasks[1].state = TaskState::Done;
        assert_eq!(ready_independent(&q, 4), vec![0]);
    }

    #[test]
    fn review_barrier_is_soft_for_gated_or_terminal_builders() {
        let mut review = task("REVIEW", TaskState::Queued, 10, vec![]);
        review.kind = "review".into();
        let mut serial_builder = task("SERIAL", TaskState::Queued, 20, vec![]);
        serial_builder.kind = "implementation".into();
        serial_builder.validation = Some(crate::yaml::from_str("required: true").unwrap());
        let mut q = queue(vec![review, serial_builder]);

        // The validation-bearing builder holds the review out of the batch and
        // itself remains runnable through the parallel validation path.
        assert_eq!(ready_independent(&q, 4), vec![1]);

        q.tasks[1].validation = None;
        q.tasks[1].approval = Some(crate::yaml::from_str("required: true").unwrap());
        assert!(ready_independent(&q, 4).is_empty());

        q.tasks[1].approval = None;
        for terminal in [
            TaskState::Failed,
            TaskState::Blocked,
            TaskState::Deferred,
            TaskState::NeedsUser,
        ] {
            q.tasks[1].state = terminal;
            assert_eq!(ready_independent(&q, 4), vec![0]);
        }
    }

    #[test]
    fn linked_remediation_and_review_never_share_a_parallel_batch() {
        let mut review = task("REVIEW", TaskState::Queued, 10, vec![]);
        review.kind = "review".into();
        let mut remediation = task("FIX", TaskState::Queued, 20, vec![]);
        remediation.kind = "implementation".into();
        remediation.approval = Some(crate::yaml::from_str("required: true").unwrap());
        remediation.add_remediation_for("REVIEW");
        let unrelated = task("QUESTION", TaskState::NeedsUser, 1, vec![]);
        let mut q = queue(vec![review, remediation, unrelated]);

        assert!(
            ready_independent(&q, 4).is_empty(),
            "approval-pending remediation must hold review out of the batch"
        );

        q.tasks[1].approval = None;
        assert_eq!(
            ready_independent(&q, 4),
            vec![1],
            "only the linked remediation may enter the batch"
        );

        q.tasks[1].state = TaskState::Running;
        assert!(ready_independent(&q, 4).is_empty());

        q.tasks[1].state = TaskState::Done;
        assert_eq!(
            ready_independent(&q, 4),
            vec![0],
            "terminal remediation and unrelated NeedsUser release review"
        );
    }

    #[test]
    fn final_verifier_is_exclusive_behind_research_and_other_verifiers() {
        let mut review = task("REVIEW", TaskState::Queued, 10, vec![]);
        review.kind = "review".into();
        let mut safety = task("SAFETY", TaskState::Queued, 20, vec![]);
        safety.kind = "safety".into();
        let mut research = task("RESEARCH", TaskState::Queued, 30, vec![]);
        research.kind = "research".into();
        let mut q = queue(vec![review, safety, research]);

        assert_eq!(ready_independent(&q, 4), vec![2]);

        q.tasks[2].state = TaskState::Done;
        assert_eq!(ready_independent(&q, 4), vec![0]);

        q.tasks[0].state = TaskState::Done;
        assert_eq!(ready_independent(&q, 4), vec![1]);
    }

    #[test]
    fn sequential_assessment_reports_structured_causes() {
        let mut approval = task("APPROVE", TaskState::Queued, 10, vec![]);
        approval.approval = Some(crate::yaml::from_str("required: true").unwrap());
        let mut validation = task("VALIDATE", TaskState::Queued, 20, vec![]);
        validation.validation = Some(crate::yaml::from_str("required: true").unwrap());
        let q = queue(vec![
            task("A", TaskState::Queued, 30, vec![]),
            task("B", TaskState::Queued, 40, vec!["A".into()]),
            approval,
            validation,
        ]);

        let assessment = assess_parallelism(&q, 4);

        assert_eq!(assessment.runnable, vec!["VALIDATE", "A"]);
        assert!(assessment
            .reasons
            .contains(&SequentialReason::DependencyChain {
                tasks: vec!["B".to_string()]
            }));
        assert!(assessment
            .reasons
            .contains(&SequentialReason::ApprovalRequired {
                tasks: vec!["APPROVE".to_string()]
            }));
        assert!(!assessment
            .reasons
            .iter()
            .any(|reason| matches!(reason, SequentialReason::ValidationRequired { .. })));
    }

    #[test]
    fn appended_independent_task_enters_parallel_ready_set() {
        let root = temp_repo("add-ready");
        let ws = Workspace::at(&root);
        std::fs::create_dir_all(ws.agents_dir()).unwrap();
        ws.save_queue(&queue(vec![task(
            "YARD-001",
            TaskState::Queued,
            10,
            vec![],
        )]))
        .unwrap();

        ws.append_user_task(crate::state::UserTaskInput {
            title: "새 독립 작업".to_string(),
            risk: "low".to_string(),
            kind: "implementation".to_string(),
            preferred_worker: String::new(),
            depends_on: Vec::new(),
            allowed_scope: Vec::new(),
        })
        .unwrap();

        let q = ws.load_queue().unwrap();
        let ready_ids = ready_independent(&q, 4)
            .into_iter()
            .map(|idx| q.tasks[idx].id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(ready_ids, vec!["YARD-001", "YARD-002"]);
        assert!(assess_parallelism(&q, 4).is_parallel_ready());
        let _ = std::fs::remove_dir_all(&root);
    }

    fn sh_git(dir: &Path, args: &[&str]) -> String {
        git(dir, args).unwrap_or_else(|e| panic!("git {args:?} in {dir:?}: {e}"))
    }

    fn integration_run_dir(root: &Path, branch: &str) -> PathBuf {
        let path = root
            .join(".agents/runs")
            .join(format!("test-{}", branch.replace('/', "-")));
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    fn serial_integration_run_dir(
        root: &Path,
        wt: &Path,
        run_id: &str,
        branch: &str,
        task_id: &str,
        baseline_oid: &str,
    ) -> PathBuf {
        let workspace = Workspace::at(root);
        let path = workspace.runs_dir().join(run_id);
        std::fs::create_dir_all(&path).unwrap();
        workspace
            .save_serial_integration_receipt(&state::SerialIntegrationReceipt {
                schema_version: 1,
                run_id: run_id.to_string(),
                task_id: task_id.to_string(),
                worktree: wt.display().to_string(),
                branch: branch.to_string(),
                baseline_oid: baseline_oid.to_string(),
                core_input_overlays: vec![],
            })
            .unwrap();
        path
    }

    fn temp_repo(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("yard-par-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        sh_git(&root, &["init", "-q"]);
        sh_git(&root, &["config", "user.name", "Local User"]);
        sh_git(&root, &["config", "user.email", "local@example.test"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        sh_git(&root, &["add", "base.txt"]);
        sh_git(&root, &["commit", "-q", "-m", "init"]);
        root
    }

    #[cfg(unix)]
    fn assert_tracked_external_harness_symlink_is_safe(preparation: &str) {
        use std::os::unix::fs::symlink;

        let root = temp_repo(&format!("{preparation}-external-harness-symlink"));
        let external = std::env::temp_dir().join(format!(
            "yard-par-{preparation}-external-harness-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&external);
        let external_skill = external.join("example");
        std::fs::create_dir_all(&external_skill).unwrap();
        let sentinel = external_skill.join("SKILL.md");
        let sentinel_bytes = b"# external sentinel\nmust remain intact\n";
        std::fs::write(&sentinel, sentinel_bytes).unwrap();
        let sentinel_len = std::fs::metadata(&sentinel).unwrap().len();

        let source_skills = root.join(".agents/skills");
        std::fs::create_dir_all(&source_skills).unwrap();
        let source_link = source_skills.join("example");
        symlink(&external_skill, &source_link).unwrap();
        sh_git(&root, &["add", ".agents/skills/example"]);
        sh_git(
            &root,
            &["commit", "-q", "-m", "track external harness link"],
        );

        let run_id = format!("run-{preparation}-symlink");
        let worktree = root.join(".agents/worktrees").join(&run_id);
        let branch = format!("yard/{preparation}-symlink/{run_id}");
        create_worktree(&root, &worktree, &branch).unwrap();
        let worktree_link = worktree.join(".agents/skills/example");
        assert!(
            std::fs::symlink_metadata(&worktree_link)
                .unwrap()
                .file_type()
                .is_symlink(),
            "Git fixture must checkout the tracked symlink in the worktree"
        );

        copy_dir(&source_skills, &worktree.join(".agents/skills"));
        assert_eq!(
            std::fs::read(&sentinel).unwrap(),
            sentinel_bytes,
            "{preparation} worktree preparation followed a tracked symlink and changed the external sentinel"
        );
        assert_eq!(
            std::fs::metadata(&sentinel).unwrap().len(),
            sentinel_len,
            "{preparation} worktree preparation changed the external sentinel length"
        );

        let seed_skills = root
            .join(".agents/runs")
            .join(&run_id)
            .join(run::HARNESS_SEED_DIR)
            .join("skills");
        copy_dir(&source_skills, &seed_skills);

        for link in [&worktree_link, &seed_skills.join("example")] {
            assert!(
                std::fs::symlink_metadata(link)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "{} must remain a symlink",
                link.display()
            );
            assert_eq!(std::fs::read_link(link).unwrap(), external_skill);
        }
        assert_eq!(std::fs::read(&sentinel).unwrap(), sentinel_bytes);
        assert_eq!(std::fs::metadata(&sentinel).unwrap().len(), sentinel_len);

        remove_worktree(&root, &worktree, &branch);
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&external);
    }

    #[cfg(unix)]
    #[test]
    fn serial_harness_copy_preserves_tracked_external_symlink_sentinel() {
        assert_tracked_external_harness_symlink_is_safe("serial");
    }

    #[cfg(unix)]
    #[test]
    fn parallel_harness_copy_preserves_tracked_external_symlink_sentinel() {
        assert_tracked_external_harness_symlink_is_safe("parallel");
    }

    #[test]
    fn harness_copy_preserves_regular_files_and_nested_directories() {
        let root = temp_repo("regular-harness-copy");
        let source = root.join("fixture-source");
        let destination = root.join("fixture-destination");
        write_str(&source.join("RULE.md"), "# regular\n").unwrap();
        write_str(&source.join("nested/SKILL.md"), "# nested\n").unwrap();

        copy_dir(&source, &destination);

        assert_eq!(
            std::fs::read_to_string(destination.join("RULE.md")).unwrap(),
            "# regular\n"
        );
        assert_eq!(
            std::fs::read_to_string(destination.join("nested/SKILL.md")).unwrap(),
            "# nested\n"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_seed_cleanup_restores_dirty_tracked_harness_to_worktree_head() {
        let root = temp_repo("parallel-dirty-tracked-harness-seed");
        let tracked = root.join(".agents/rules/tracked-dirty.md");
        write_str(&tracked, "# Tracked baseline\n").unwrap();
        sh_git(&root, &["add", ".agents/rules/tracked-dirty.md"]);
        sh_git(&root, &["commit", "-q", "-m", "track harness fixture"]);
        write_str(&tracked, "# User dirty edit\n").unwrap();

        let wt = root.join(".agents/worktrees/parallel-dirty-seed");
        let branch = "yard/parallel-dirty-seed/run-test";
        create_worktree(&root, &wt, branch).unwrap();
        let run_dir = root.join(".agents/runs/run-parallel-dirty-seed");
        let seed = run_dir
            .join(run::HARNESS_SEED_DIR)
            .join("rules/tracked-dirty.md");
        write_str(
            &wt.join(".agents/rules/tracked-dirty.md"),
            "# User dirty edit\n",
        )
        .unwrap();
        write_str(&seed, "# User dirty edit\n").unwrap();

        let evidence = parallel_worker_evidence(&wt, &run_dir).unwrap();
        assert!(evidence.is_empty(), "seed copy is not worker evidence");
        assert_eq!(
            std::fs::read_to_string(wt.join(".agents/rules/tracked-dirty.md")).unwrap(),
            "# Tracked baseline\n"
        );
        assert_eq!(
            std::fs::read_to_string(&tracked).unwrap(),
            "# User dirty edit\n"
        );

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(root);
    }

    fn setup_workspace(root: &Path, worker_yaml: &str, tasks: Vec<Task>) -> Workspace {
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let ws = Workspace::at(root);
        write_str(
            &ws.config_path(),
            "schema_version: 1\nproduct: yardlet\nworkspace_id: test\ncreated_at: \"2026-07-03T00:00:00Z\"\nstate_dir: .agents\ndefault_interface: tui\ncanonical_queue: work-queue.yaml\ncurrent_intent: intent-contract.yaml\n",
        )
        .unwrap();
        write_str(&ws.billing_path(), "schema_version: 1\n").unwrap();
        write_str(
            &ws.intent_path(),
            "schema_version: 1\nid: intent-test\nsummary: 병렬 페일오버 테스트\nstatus: accepted\n",
        )
        .unwrap();
        write_str(&ws.workers_path(), worker_yaml).unwrap();
        ws.save_queue(&queue(tasks)).unwrap();
        ws
    }

    fn yaml_string(path: &Path) -> String {
        serde_json::to_string(&path.display().to_string()).unwrap()
    }

    fn write_test_worker(root: &Path, name: &str, body: &str) -> PathBuf {
        let path = root.join(".agents").join(name);
        write_str(&path, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&path).unwrap().permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&path, perms).unwrap();
        }
        path
    }

    #[test]
    fn dependency_output_digest_tamper_blocks_parallel_worker_spawn() {
        let root = temp_repo("parallel-dependency-output-tamper");
        let spawn_marker = root.join(".agents/parallel-worker-spawned");
        let worker = write_test_worker(
            &root,
            "parallel-dependency-worker.sh",
            r##"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "fixture 1.0"
  exit 0
fi
run_dir="$1"
spawn_marker="$2"
run_id=$(basename "$run_dir")
packet=$(cat)
task_id=$(printf "%s" "$packet" | sed -n 's/^# Yardlet task packet: //p' | head -n 1)
touch "$spawn_marker"
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "$task_id",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "worker should not spawn",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# handoff\n" > "$run_dir/handoff.md"
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            yaml_string(&worker),
            yaml_string(&spawn_marker)
        );
        let ws = setup_workspace(
            &root,
            &worker_yaml,
            vec![
                task("YARD-UPSTREAM", TaskState::Done, 10, vec![]),
                task(
                    "YARD-DOWNSTREAM",
                    TaskState::Queued,
                    20,
                    vec!["YARD-UPSTREAM".into()],
                ),
            ],
        );
        state::append_transition(
            &ws,
            state::transition(
                "YARD-UPSTREAM",
                TaskState::Partial,
                TaskState::Done,
                crate::schemas::TransitionCause::Recover,
                "manual integration",
                crate::schemas::TransitionActor::User,
            ),
        )
        .unwrap();
        let run_id = "run-20990101-000000-upstream";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        write_str(
            &run_dir.join("run.yaml"),
            &format!(
                "schema_version: 1\nrun_id: {run_id}\ntask_id: YARD-UPSTREAM\nstate: partial\nstarted_at: 2099-01-01T00:00:00Z\n"
            ),
        )
        .unwrap();
        let snapshots = ws
            .checkpoints_dir()
            .join("dependency-outputs")
            .join(run_id)
            .join("snapshots");
        std::fs::create_dir_all(&snapshots).unwrap();
        write_str(&snapshots.join("0000.bin"), "tampered\n").unwrap();
        state::save_yaml_atomic(
            &ws.checkpoints_dir()
                .join("dependency-outputs")
                .join(run_id)
                .join("manifest.yaml"),
            &crate::schemas::ResolvedDependencyOutputs {
                schema_version: 1,
                dependency_task_id: "YARD-UPSTREAM".into(),
                source_run_id: run_id.into(),
                outputs: vec![crate::schemas::ResolvedDependencyOutput {
                    path: "dependency-output.txt".into(),
                    content_digest: state::content_digest(b"expected\n"),
                    snapshot_file: "0000.bin".into(),
                    availability: crate::schemas::DependencyOutputAvailability::CoreSnapshot,
                }],
            },
        )
        .unwrap();

        let mut events = Vec::new();
        let error = run_batch(&ws, &[1], false, |event| events.push(event.to_string()))
            .expect_err("digest tamper must abort the batch before worker spawn");
        assert!(
            error.to_string().contains(
                "dependency_output_digest_mismatch:dependency=YARD-UPSTREAM:path=dependency-output.txt"
            ),
            "{error:#}"
        );
        assert!(!spawn_marker.exists());
        assert_eq!(ws.load_queue().unwrap().tasks[1].state, TaskState::Queued);
        assert!(events.iter().any(
            |event| event.contains("dependency output preparation blocked before worker spawn")
        ));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn parallel_resultless_worker_fails_over_once_to_alternate_worker() {
        let root = temp_repo("failover");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let dead_attempts = root.join(".agents/dead-attempts");
        let builder_attempts = root.join(".agents/builder-attempts");
        let dead = write_test_worker(
            &root,
            "dead-worker.sh",
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "dead-worker 1.0"
  exit 0
fi
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
        let builder = write_test_worker(
            &root,
            "builder-worker.sh",
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "builder-worker 1.0"
  exit 0
fi
run_dir="$1"
attempts="$2"
run_id=$(basename "$run_dir")
cat >/dev/null
if [ -f "$attempts" ]; then
  count=$(cat "$attempts")
else
  count=0
fi
count=$((count + 1))
printf "%s" "$count" > "$attempts"
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-PAR",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "병렬 페일오버 worker가 완료했다.",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff

병렬 페일오버 worker가 완료했다.
EOF
exit 0
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: dead\n  fallback_order: [dead, builder]\nworkers:\n  - id: dead\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n  - id: builder\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            yaml_string(&dead),
            yaml_string(&dead_attempts),
            yaml_string(&builder),
            yaml_string(&builder_attempts)
        );
        let ws = setup_workspace(
            &root,
            &worker_yaml,
            vec![task("YARD-PAR", TaskState::Queued, 10, vec![])],
        );
        let mut events = Vec::new();

        let states = run_batch(&ws, &[0], false, |s| events.push(s.to_string())).unwrap();

        assert_eq!(states, vec![("YARD-PAR".to_string(), TaskState::Done)]);
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);
        assert_eq!(std::fs::read_to_string(&dead_attempts).unwrap(), "1");
        assert_eq!(std::fs::read_to_string(&builder_attempts).unwrap(), "1");
        assert!(events.iter().any(|e| e.contains("dead -> builder")));
        assert!(events
            .iter()
            .any(|e| e.contains("failover worker finished")));

        let run_dirs: Vec<PathBuf> = std::fs::read_dir(ws.runs_dir())
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.is_dir())
            .collect();
        assert_eq!(run_dirs.len(), 1);
        let run_dir = &run_dirs[0];
        let failover: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(run_dir.join("failover.json")).unwrap())
                .unwrap();
        assert_eq!(failover["from"], "dead");
        assert_eq!(failover["to"], "builder");
        let handoff = std::fs::read_to_string(run_dir.join("handoff.md")).unwrap();
        assert!(handoff.contains("Worker failover"));
        assert!(handoff.contains("dead -> builder"));
        let run_record: serde_json::Value =
            crate::yaml::from_str(&std::fs::read_to_string(run_dir.join("run.yaml")).unwrap())
                .unwrap();
        assert_eq!(run_record["worker"], "builder");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn parallel_prepare_persists_harness_copy_warnings_as_run_evidence() {
        use std::os::unix::fs::symlink;

        let root = temp_repo("harness-warning-evidence");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let external_rules = root.join("external-rules");
        std::fs::create_dir_all(&external_rules).unwrap();
        symlink(&external_rules, root.join(".agents/rules")).unwrap();
        let builder = write_test_worker(
            &root,
            "builder-worker.sh",
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "builder-worker 1.0"
  exit 0
fi
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-WARN",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "harness 경고 영속화 테스트 worker가 완료했다.",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
cat > "$run_dir/handoff.md" <<EOF
# Worker handoff

harness 경고 영속화 테스트 worker가 완료했다.
EOF
exit 0
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            yaml_string(&builder)
        );
        let ws = setup_workspace(
            &root,
            &worker_yaml,
            vec![task("YARD-WARN", TaskState::Queued, 10, vec![])],
        );
        let mut events = Vec::new();

        let states = run_batch(&ws, &[0], false, |s| events.push(s.to_string())).unwrap();

        assert_eq!(states, vec![("YARD-WARN".to_string(), TaskState::Done)]);
        let run_dirs: Vec<PathBuf> = std::fs::read_dir(ws.runs_dir())
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.is_dir())
            .collect();
        assert_eq!(run_dirs.len(), 1);
        let log_path = run_dirs[0].join("evidence/harness-copy-warnings.log");
        let log = std::fs::read_to_string(&log_path).unwrap_or_else(|error| {
            panic!(
                "harness copy warnings must land in {}: {error}",
                log_path.display()
            )
        });
        assert!(
            log.contains("skipped non-directory harness root"),
            "evidence must carry the copy_dir warning text: {log}"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_batch_stale_git_finish_target_blocks_before_worker_spawn() {
        let root = temp_repo("stale-target-preflight");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let remote = std::env::temp_dir().join(format!(
            "yard-par-stale-target-remote-{}.git",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&remote);
        let init_remote = std::process::Command::new("git")
            .args(["init", "-q", "--bare"])
            .arg(&remote)
            .output()
            .unwrap();
        assert!(
            init_remote.status.success(),
            "git init --bare: {}",
            String::from_utf8_lossy(&init_remote.stderr)
        );
        sh_git(&root, &["branch", "-M", "main"]);
        sh_git(
            &root,
            &["remote", "add", "fixture", remote.to_str().unwrap()],
        );
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        let stale_target = "refs/heads/codex/yard-101-delivery";
        let checkout_ref = "refs/heads/main";
        sh_git(&root, &["push", "-q", "fixture", "HEAD:refs/heads/main"]);
        sh_git(
            &root,
            &["push", "-q", "fixture", &format!("HEAD:{stale_target}")],
        );

        let spawn_marker = root.join(".agents/worker-spawned");
        let builder = write_test_worker(
            &root,
            "builder-worker.sh",
            r##"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "builder-worker 1.0"
  exit 0
fi
run_dir="$1"
spawn_marker="$2"
run_id=$(basename "$run_dir")
cat >/dev/null
touch "$spawn_marker"
printf "stale target output\n" > stale-output.txt
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-STALE",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": ["stale-output.txt"], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "green worker가 완료했다.",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# worker handoff\n" > "$run_dir/handoff.md"
exit 0
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: {}\n      args: [\"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            yaml_string(&builder),
            yaml_string(&spawn_marker)
        );
        let mut stale_task = task("YARD-STALE", TaskState::Queued, 10, vec![]);
        stale_task.allowed_scope = vec!["stale-output.txt".into()];
        let ws = setup_workspace(&root, &worker_yaml, vec![stale_task]);
        let mut config = ws.load_config().unwrap();
        config.auto_commit = true;
        config.git_finish = crate::schemas::GitFinishPolicy {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: stale_target.into(),
            pre_push_checks: vec![],
        };
        state::save_yaml(&ws.config_path(), &config).unwrap();

        let mut events = Vec::new();
        let outcome = run_batch(&ws, &[0], false, |s| events.push(s.to_string()));

        if spawn_marker.exists() {
            panic!(
                "worker spawned before the stale target_ref was rejected; \
                 expected a pre-spawn retarget block, got batch outcome {:?}",
                outcome.map(|states| states
                    .iter()
                    .map(|(id, state)| format!("{id}:{state:?}"))
                    .collect::<Vec<_>>())
            );
        }
        let error = outcome.expect_err("stale target_ref must abort the batch before any spawn");
        let diagnostic = error.to_string();
        assert!(
            diagnostic.contains("branch_does_not_match_target_ref")
                && diagnostic.contains(stale_target)
                && diagnostic.contains(checkout_ref),
            "retarget diagnostic must name the typed reason and both refs: {diagnostic}"
        );
        assert!(
            events
                .iter()
                .any(|e| e.contains("branch_does_not_match_target_ref")),
            "the retarget diagnostic must surface as a batch event: {events:?}"
        );

        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::Queued,
            "a pre-spawn retarget block must keep the batch task retryable"
        );

        let run_dirs: Vec<PathBuf> = std::fs::read_dir(ws.runs_dir())
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.is_dir())
            .collect();
        assert_eq!(
            run_dirs.len(),
            1,
            "expected one blocked run dir: {run_dirs:?}"
        );
        let blocked = ws.load_git_finish_record(&run_dirs[0]).unwrap();
        assert_eq!(
            blocked.status,
            crate::git_finish::GitFinishStatus::SafetyBlocked
        );
        assert!(
            blocked
                .reason
                .starts_with("branch_does_not_match_target_ref:checkout_ref="),
            "the core record must carry the serial-path reason shape: {}",
            blocked.reason
        );
        assert_eq!(blocked.policy.target_ref, stale_target);
        assert!(!blocked.push_invoked);
        let blocked_run: run::RunRecord = state::load_yaml(&run_dirs[0].join("run.yaml")).unwrap();
        assert_eq!(blocked_run.state, "blocked");
        assert!(blocked_run.completed_at.is_some());

        let leftover: Vec<PathBuf> = std::fs::read_dir(root.join(".agents/worktrees"))
            .map(|entries| entries.filter_map(|e| e.ok()).map(|e| e.path()).collect())
            .unwrap_or_default();
        assert!(
            leftover.is_empty(),
            "a blocked batch must not leave worktrees behind: {leftover:?}"
        );
        assert_eq!(
            sh_git(&root, &["ls-remote", "--refs", "fixture", stale_target])
                .split_whitespace()
                .next(),
            Some(baseline.as_str()),
            "the pre-spawn block must not move the stale remote target"
        );

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
    }

    #[test]
    fn worktree_roundtrip_merges_worker_changes() {
        let root = temp_repo("merge");
        assert!(git_preflight(&root).is_ok());
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let mut t = task("YARD-001", TaskState::Queued, 10, vec![]);
        t.title = "병렬 worktree 정리".into();
        state::save_yaml(&root.join(".agents/work-queue.yaml"), &queue(vec![t])).unwrap();
        let wt = root.join(".agents/worktrees/yard-001");
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, "yard/yard-001").unwrap();
        // Simulate a worker: edit a file in the worktree, plus .agents noise
        // that must NOT be committed.
        std::fs::write(wt.join("feature.txt"), "new\n").unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();
        std::fs::write(wt.join(".agents/work-queue.yaml"), "copy").unwrap();
        match integrate_parallel_worktree(&root, &wt, "yard/yard-001", "YARD-001", &baseline, None)
            .unwrap()
        {
            Integration::Merged { oid, .. } => {
                assert_eq!(oid, sh_git(&root, &["rev-parse", "HEAD"]).trim());
            }
            _ => panic!("expected a merge"),
        }
        assert!(root.join("feature.txt").is_file());
        let root_queue = std::fs::read_to_string(root.join(".agents/work-queue.yaml")).unwrap();
        assert!(root_queue.contains("병렬 worktree 정리"));
        assert_ne!(root_queue.trim(), "copy");
        let worker_commit = sh_git(
            &root,
            &["log", "--format=%an|%ae|%s", "-1", "yard/yard-001"],
        );
        assert_eq!(
            worker_commit.trim(),
            "Local User|local@example.test|yardlet(YARD-001): 병렬 worktree 정리"
        );
        let merge_commit = sh_git(&root, &["log", "--format=%an|%ae", "-1", "HEAD"]);
        assert_eq!(merge_commit.trim(), "Local User|local@example.test");
        remove_worktree(&root, &wt, "yard/yard-001");
        assert!(!wt.exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn repeated_integration_recovers_the_same_merge_oid_without_new_commit() {
        let root = temp_repo("merge-recovery");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-recover");
        let branch = "yard/yard-recover";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("recovered.txt"), "owned\n").unwrap();
        // Fault point: the isolated commit exists, but the main-process merge
        // and run-record persistence did not happen yet.
        sh_git(&wt, &["add", "recovered.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "pre-crash isolated commit"]);
        let worker_commit = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();

        let first =
            integrate_parallel_worktree(&root, &wt, branch, "YARD-RECOVER", &baseline, None)
                .unwrap();
        let Integration::Merged {
            oid: first_oid,
            base_oid: first_base,
            owned_oids: first_owned,
            ..
        } = first
        else {
            panic!("expected first integration to merge")
        };
        let commit_count = sh_git(&root, &["rev-list", "--count", "HEAD"]);

        let repeated =
            integrate_parallel_worktree(&root, &wt, branch, "YARD-RECOVER", &baseline, None)
                .unwrap();
        let Integration::Merged {
            oid,
            base_oid,
            owned_oids,
            ..
        } = repeated
        else {
            panic!("expected recovery to reconstruct the existing integration")
        };
        assert_eq!(oid, first_oid);
        assert_eq!(base_oid, first_base);
        assert_eq!(owned_oids, first_owned);
        assert_eq!(sh_git(&wt, &["rev-parse", "HEAD"]).trim(), worker_commit);
        assert_eq!(
            sh_git(&root, &["rev-list", "--count", "HEAD"]),
            commit_count
        );

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn attributable_merge_uses_exact_parents_when_main_moves_around_it() {
        let root = temp_repo("merge-attribution-race");
        let wt = root.join(".agents/worktrees/yard-attribution-race");
        let branch = "yard/yard-attribution-race";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("worker.txt"), "worker\n").unwrap();
        sh_git(&wt, &["add", "worker.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "worker commit"]);
        let worker_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();

        std::fs::write(root.join("concurrent-before.txt"), "before\n").unwrap();
        sh_git(&root, &["add", "concurrent-before.txt"]);
        sh_git(&root, &["commit", "-q", "-m", "concurrent before merge"]);
        let actual_base = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        sh_git(
            &root,
            &[
                "merge",
                "--no-ff",
                "--no-edit",
                "-m",
                "owned merge",
                &worker_oid,
            ],
        );
        let merge_oid = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        std::fs::write(root.join("concurrent-after.txt"), "after\n").unwrap();
        sh_git(&root, &["add", "concurrent-after.txt"]);
        sh_git(&root, &["commit", "-q", "-m", "concurrent after merge"]);
        let advanced_head = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();

        let attributed = attributable_merge_after(&root, &baseline, &worker_oid)
            .unwrap()
            .expect("exact worker merge must remain attributable");
        assert_eq!(attributed, (merge_oid, actual_base));
        assert_ne!(attributed.0, advanced_head);

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_rejects_branch_tip_changed_after_evidence() {
        let root = temp_repo("merge-target-drift");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-drift");
        let branch = "yard/yard-drift";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("first.txt"), "evidence-bound\n").unwrap();
        sh_git(&wt, &["add", "first.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "evidence-bound commit"]);
        let evidence_oid = sh_git(&root, &["rev-parse", &format!("{branch}^{{commit}}")])
            .trim()
            .to_string();

        std::fs::write(wt.join("second.txt"), "moved after evidence\n").unwrap();
        sh_git(&wt, &["add", "second.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "post-evidence drift"]);
        let drifted_oid = sh_git(&root, &["rev-parse", &format!("{branch}^{{commit}}")])
            .trim()
            .to_string();
        assert_ne!(evidence_oid, drifted_oid);
        let main_before = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();

        let result = integrate_parallel_worktree(
            &root,
            &wt,
            branch,
            "YARD-DRIFT",
            &baseline,
            Some(&evidence_oid),
        )
        .unwrap();

        let Integration::Conflict(why) = result else {
            panic!("changed merge target must fail closed")
        };
        assert!(why.contains("changed after evidence"), "{why}");
        assert_eq!(sh_git(&root, &["rev-parse", "HEAD"]).trim(), main_before);
        assert!(wt.exists(), "the rejected worktree must remain available");
        assert_eq!(
            sh_git(&root, &["rev-parse", &format!("{branch}^{{commit}}")]).trim(),
            drifted_oid
        );

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_rejects_branch_tip_race_after_staging() {
        let root = temp_repo("merge-target-staged-race");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-staged-race");
        let branch = "yard/yard-staged-race";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("feature.txt"), "evidence-bound\n").unwrap();
        let evidence_oid = sh_git(
            &root,
            &["rev-parse", &format!("refs/heads/{branch}^{{commit}}")],
        )
        .trim()
        .to_string();
        let main_before = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        let mut drifted_oid = String::new();

        let result = integrate_worktree_after_staged(
            &root,
            &wt,
            branch,
            "YARD-STAGED-RACE",
            &baseline,
            Some(evidence_oid.as_str()),
            IntegrationCommitMode::ParallelWorkerDirect,
            &[],
            |root, _, branch| {
                let old_oid = sh_git(
                    root,
                    &["rev-parse", &format!("refs/heads/{branch}^{{commit}}")],
                )
                .trim()
                .to_string();
                let tree_oid = sh_git(root, &["rev-parse", &format!("{old_oid}^{{tree}}")])
                    .trim()
                    .to_string();
                drifted_oid = sh_git(
                    root,
                    &[
                        "commit-tree",
                        &tree_oid,
                        "-p",
                        &old_oid,
                        "-m",
                        "injected post-evidence drift",
                    ],
                )
                .trim()
                .to_string();
                sh_git(
                    root,
                    &[
                        "update-ref",
                        &format!("refs/heads/{branch}"),
                        &drifted_oid,
                        &old_oid,
                    ],
                );
                Ok(())
            },
        )
        .unwrap();

        let Integration::Conflict(why) = result else {
            panic!("a branch move after staging must fail closed")
        };
        assert!(why.contains("changed after evidence"), "{why}");
        assert_eq!(sh_git(&root, &["rev-parse", "HEAD"]).trim(), main_before);
        assert!(wt.exists(), "the rejected worktree must remain available");
        assert_eq!(
            sh_git(
                &root,
                &["rev-parse", &format!("refs/heads/{branch}^{{commit}}")]
            )
            .trim(),
            drifted_oid
        );

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_honors_required_commit_signing_before_publishing() {
        let root = temp_repo("commit-signing-policy");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-signing-policy");
        let branch = "yard/yard-signing-policy";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        sh_git(&root, &["config", "commit.gpgSign", "true"]);
        std::fs::write(wt.join("feature.txt"), "must be signed\n").unwrap();
        let run_dir =
            serial_integration_run_dir(&root, &wt, "run-sign", branch, "YARD-SIGN", &baseline);

        let result = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            "run-sign",
            branch,
            "YARD-SIGN",
            &baseline,
            Some(&baseline),
        );

        assert!(
            result.is_err(),
            "missing signing key must fail native commit"
        );
        assert_eq!(
            sh_git(&root, &["rev-parse", &format!("refs/heads/{branch}")]).trim(),
            baseline
        );
        assert!(wt.join("feature.txt").exists());

        sh_git(&root, &["config", "--unset", "commit.gpgSign"]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_runs_configured_commit_hook_before_publishing() {
        let root = temp_repo("commit-hook-policy");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-hook-policy");
        let branch = "yard/yard-hook-policy";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        sh_git(&root, &["config", "core.hooksPath", ".githooks"]);
        std::fs::create_dir_all(wt.join(".githooks")).unwrap();
        let hook = wt.join(".githooks/commit-msg");
        let marker = root.join(".git/commit-msg-ran");
        std::fs::write(
            &hook,
            format!("#!/bin/sh\nprintf 'ran\\n' > '{}'\n", marker.display()),
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(wt.join("feature.txt"), "hook-governed\n").unwrap();
        let run_dir =
            serial_integration_run_dir(&root, &wt, "run-hook", branch, "YARD-HOOK", &baseline);

        let result = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            "run-hook",
            branch,
            "YARD-HOOK",
            &baseline,
            Some(&baseline),
        )
        .unwrap();

        assert!(matches!(result, Integration::Merged { .. }));
        assert_eq!(std::fs::read_to_string(&marker).unwrap(), "ran\n");

        sh_git(&root, &["config", "--unset", "core.hooksPath"]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_keeps_target_unchanged_when_commit_hook_rejects() {
        let root = temp_repo("commit-hook-reject");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-hook-reject");
        let branch = "yard/yard-hook-reject";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        let run_dir = serial_integration_run_dir(
            &root,
            &wt,
            "run-hook-reject",
            branch,
            "YARD-HOOK-REJECT",
            &baseline,
        );
        sh_git(&root, &["config", "core.hooksPath", ".githooks"]);
        std::fs::create_dir_all(wt.join(".githooks")).unwrap();
        let hook = wt.join(".githooks/pre-commit");
        std::fs::write(&hook, "#!/bin/sh\nexit 23\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(wt.join("feature.txt"), "must stay staged\n").unwrap();

        let result = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            "run-hook-reject",
            branch,
            "YARD-HOOK-REJECT",
            &baseline,
            Some(&baseline),
        );

        assert!(result.is_err(), "rejecting hook must fail native commit");
        assert_eq!(
            sh_git(&root, &["rev-parse", &format!("refs/heads/{branch}")]).trim(),
            baseline
        );
        assert!(ref_tip(&root, &transaction_ref(branch)).is_none());
        assert_eq!(
            sh_git(&wt, &["symbolic-ref", "HEAD"]).trim(),
            format!("refs/heads/{branch}")
        );
        let record: GitIntegrationTransaction = serde_json::from_str(
            &std::fs::read_to_string(run_dir.join(GIT_INTEGRATION_RECORD)).unwrap(),
        )
        .unwrap();
        assert_eq!(record.phase, GitIntegrationPhase::Failed);
        assert!(wt.join("feature.txt").exists());

        sh_git(&root, &["config", "--unset", "core.hooksPath"]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integration_rejects_preexisting_transaction_candidate() {
        let root = temp_repo("preexisting-transaction");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-preexisting-transaction");
        let branch = "yard/yard-preexisting-transaction";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        let run_dir = serial_integration_run_dir(
            &root,
            &wt,
            "run-txn-forge",
            branch,
            "YARD-TXN-FORGE",
            &baseline,
        );
        std::fs::write(wt.join("feature.txt"), "evaluated worker change\n").unwrap();

        let base_tree = sh_git(&root, &["rev-parse", &format!("{baseline}^{{tree}}")])
            .trim()
            .to_string();
        let forged = sh_git(
            &root,
            &[
                "commit-tree",
                &base_tree,
                "-p",
                &baseline,
                "-m",
                "preexisting transaction",
            ],
        )
        .trim()
        .to_string();
        sh_git(&root, &["update-ref", &transaction_ref(branch), &forged]);

        let result = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            "run-txn-forge",
            branch,
            "YARD-TXN-FORGE",
            &baseline,
            Some(&baseline),
        )
        .unwrap();

        let Integration::Conflict(why) = result else {
            panic!("preexisting transaction candidate must fail closed")
        };
        assert!(why.contains("already changed"), "{why}");
        assert_eq!(
            sh_git(&root, &["rev-parse", &format!("refs/heads/{branch}")]).trim(),
            baseline
        );
        assert_eq!(ref_tip(&root, &transaction_ref(branch)).unwrap(), forged);
        assert!(wt.exists());

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_integration_never_loads_a_worker_forged_transaction_record() {
        let root = temp_repo("parallel-forged-transaction");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-parallel-forge");
        let branch = "yard/yard-parallel-forge";
        let run_dir = integration_run_dir(&root, branch);
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("feature.txt"), "evaluated parallel change\n").unwrap();
        std::fs::write(run_dir.join(GIT_INTEGRATION_RECORD), "{forged worker json").unwrap();

        let base_tree = sh_git(&root, &["rev-parse", &format!("{baseline}^{{tree}}")])
            .trim()
            .to_string();
        let forged = sh_git(
            &root,
            &[
                "commit-tree",
                &base_tree,
                "-p",
                &baseline,
                "-m",
                "forged parallel transaction",
            ],
        )
        .trim()
        .to_string();
        sh_git(&root, &["update-ref", &transaction_ref(branch), &forged]);

        let result = integrate_parallel_worktree(
            &root,
            &wt,
            branch,
            "YARD-PARALLEL-FORGE",
            &baseline,
            Some(&baseline),
        )
        .unwrap();

        let Integration::Merged { worker_oid, .. } = result else {
            panic!("parallel integration must use its evaluated staged tree")
        };
        assert_ne!(worker_oid, forged);
        assert_eq!(
            sh_git(&root, &["show", &format!("{worker_oid}:feature.txt")]).trim(),
            "evaluated parallel change"
        );
        assert_eq!(ref_tip(&root, &transaction_ref(branch)).unwrap(), forged);

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn serial_recovery_rejects_a_hook_mutated_tree_after_native_commit() {
        let root = temp_repo("serial-hook-mutated-tree");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-hook-mutated-tree");
        let branch = "yard/yard-hook-mutated-tree";
        let run_id = "run-hook-mutated-tree";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        let run_dir =
            serial_integration_run_dir(&root, &wt, run_id, branch, "YARD-HOOK-TREE", &baseline);
        sh_git(&root, &["config", "core.hooksPath", ".githooks"]);
        std::fs::create_dir_all(wt.join(".githooks")).unwrap();
        let hook = wt.join(".githooks/pre-commit");
        std::fs::write(
            &hook,
            "#!/bin/sh\nprintf 'hook-only\\n' > hook-added.txt\ngit add hook-added.txt\n",
        )
        .unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::fs::write(wt.join("feature.txt"), "evaluated before hook\n").unwrap();

        for attempt in 0..2 {
            let result = integrate_serial_worktree(
                &root,
                &wt,
                &run_dir,
                run_id,
                branch,
                "YARD-HOOK-TREE",
                &baseline,
                Some(&baseline),
            )
            .unwrap();
            let Integration::Conflict(why) = result else {
                panic!("hook-mutated candidate must fail closed on attempt {attempt}")
            };
            assert!(why.contains("evaluated staged tree"), "{why}");
            assert_eq!(sh_git(&root, &["rev-parse", "HEAD"]).trim(), baseline);
            assert_eq!(
                ref_tip(&root, &format!("refs/heads/{branch}")).unwrap(),
                baseline
            );
        }
        let record: GitIntegrationTransaction = serde_json::from_str(
            &std::fs::read_to_string(run_dir.join(GIT_INTEGRATION_RECORD)).unwrap(),
        )
        .unwrap();
        assert_eq!(record.phase, GitIntegrationPhase::CommitReady);
        assert_ne!(ref_tip(&root, &transaction_ref(branch)).unwrap(), baseline);

        sh_git(&root, &["config", "--unset", "core.hooksPath"]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn published_serial_transaction_never_reclaims_a_rolled_back_target() {
        let root = temp_repo("published-transaction-rollback");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let wt = root.join(".agents/worktrees/yard-published-rollback");
        let branch = "yard/yard-published-rollback";
        let run_id = "run-published-rollback";
        let task_id = "YARD-PUBLISHED-ROLLBACK";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("feature.txt"), "owned\n").unwrap();
        let run_dir = serial_integration_run_dir(&root, &wt, run_id, branch, task_id, &baseline);

        let first = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            run_id,
            branch,
            task_id,
            &baseline,
            Some(&baseline),
        )
        .unwrap();
        let Integration::Merged {
            oid: merge_oid,
            worker_oid,
            ..
        } = first
        else {
            panic!("first integration must merge")
        };
        sh_git(
            &root,
            &[
                "update-ref",
                &format!("refs/heads/{branch}"),
                &baseline,
                &worker_oid,
            ],
        );

        let repeated = integrate_serial_worktree(
            &root,
            &wt,
            &run_dir,
            run_id,
            branch,
            task_id,
            &baseline,
            Some(&baseline),
        )
        .unwrap();

        let Integration::Conflict(why) = repeated else {
            panic!("published target rollback must fail closed")
        };
        assert!(
            why.contains("published Git transaction target moved"),
            "{why}"
        );
        assert_eq!(
            ref_tip(&root, &format!("refs/heads/{branch}")).unwrap(),
            baseline
        );
        assert_eq!(sh_git(&root, &["rev-parse", "HEAD"]).trim(), merge_oid);

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn create_worktree_prunes_stale_checkout_before_recreate() {
        let root = temp_repo("stale");
        let wt = root.join(".agents/worktrees/yard-004");
        create_worktree(&root, &wt, "yard/yard-004").unwrap();
        std::fs::write(wt.join("stale.txt"), "leftover\n").unwrap();

        // Simulate a crash where the worktree directory disappeared but Git's
        // common metadata still marks the branch as checked out there.
        std::fs::remove_dir_all(&wt).unwrap();

        create_worktree(&root, &wt, "yard/yard-004").unwrap();

        assert!(wt.is_dir());
        assert!(!wt.join("stale.txt").exists());
        assert_eq!(
            sh_git(&wt, &["branch", "--show-current"]).trim(),
            "yard/yard-004"
        );
        let listed = sh_git(&root, &["worktree", "list", "--porcelain"]);
        assert_eq!(listed.matches("branch refs/heads/yard/yard-004").count(), 1);
        remove_worktree(&root, &wt, "yard/yard-004");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integrated_cleanup_removes_only_exact_owned_refs() {
        let root = temp_repo("integrated-cleanup-owned");
        let wt = root.join(".agents/worktrees/run-cleanup-owned");
        let branch = "yard/yard-cleanup/run-cleanup-owned";
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("owned.txt"), "owned\n").unwrap();
        sh_git(&wt, &["add", "owned.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "owned worker commit"]);
        let worker_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();
        sh_git(
            &root,
            &["update-ref", &transaction_ref(branch), &worker_oid, ""],
        );

        let cleanup = cleanup_integrated_worktree(
            &root,
            &wt,
            branch,
            &worker_oid,
            run::IntegrationProvenance::SerialCoreStaged,
        );

        assert!(cleanup.complete, "{:?}", cleanup.warnings);
        assert!(!wt.exists());
        assert!(ref_tip(&root, &format!("refs/heads/{branch}")).is_none());
        assert!(ref_tip(&root, &transaction_ref(branch)).is_none());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integrated_cleanup_preserves_a_concurrently_moved_branch() {
        let root = temp_repo("integrated-cleanup-moved");
        let wt = root.join(".agents/worktrees/run-cleanup-moved");
        let branch = "yard/yard-cleanup/run-cleanup-moved";
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("owned.txt"), "owned\n").unwrap();
        sh_git(&wt, &["add", "owned.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "owned worker commit"]);
        let worker_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();
        let tree = sh_git(&root, &["rev-parse", &format!("{worker_oid}^{{tree}}")])
            .trim()
            .to_string();
        let moved_oid = sh_git(
            &root,
            &[
                "commit-tree",
                &tree,
                "-p",
                &worker_oid,
                "-m",
                "concurrent branch move",
            ],
        )
        .trim()
        .to_string();
        sh_git(
            &root,
            &[
                "update-ref",
                &format!("refs/heads/{branch}"),
                &moved_oid,
                &worker_oid,
            ],
        );

        let cleanup = cleanup_integrated_worktree(
            &root,
            &wt,
            branch,
            &worker_oid,
            run::IntegrationProvenance::ParallelWorkerDirect,
        );

        assert!(!cleanup.complete);
        assert!(wt.exists());
        assert_eq!(
            ref_tip(&root, &format!("refs/heads/{branch}")).unwrap(),
            moved_oid
        );
        assert!(cleanup
            .warnings
            .iter()
            .any(|warning| warning.contains("retained moved worktree branch")));

        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integrated_cleanup_retains_post_integration_worktree_changes() {
        let root = temp_repo("integrated-cleanup-dirty");
        let wt = root.join(".agents/worktrees/run-cleanup-dirty");
        let branch = "yard/yard-cleanup/run-cleanup-dirty";
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("owned.txt"), "owned\n").unwrap();
        sh_git(&wt, &["add", "owned.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "owned worker commit"]);
        let worker_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();
        std::fs::write(wt.join("later.txt"), "belongs to a later session\n").unwrap();

        let cleanup = cleanup_integrated_worktree(
            &root,
            &wt,
            branch,
            &worker_oid,
            run::IntegrationProvenance::ParallelWorkerDirect,
        );

        assert!(!cleanup.complete);
        assert!(wt.exists());
        assert_eq!(
            ref_tip(&root, &format!("refs/heads/{branch}")).unwrap(),
            worker_oid
        );
        assert!(cleanup
            .warnings
            .iter()
            .any(|warning| warning.contains("post-integration changes")));

        std::fs::remove_file(wt.join("later.txt")).unwrap();
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn integrated_cleanup_retains_a_detached_clean_commit() {
        let root = temp_repo("integrated-cleanup-detached");
        let wt = root.join(".agents/worktrees/run-cleanup-detached");
        let branch = "yard/yard-cleanup/run-cleanup-detached";
        create_worktree(&root, &wt, branch).unwrap();
        std::fs::write(wt.join("owned.txt"), "owned\n").unwrap();
        sh_git(&wt, &["add", "owned.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "owned worker commit"]);
        let worker_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();
        sh_git(&wt, &["checkout", "-q", "--detach"]);
        std::fs::write(wt.join("detached.txt"), "clean detached commit\n").unwrap();
        sh_git(&wt, &["add", "detached.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "detached later commit"]);
        let detached_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();

        let cleanup = cleanup_integrated_worktree(
            &root,
            &wt,
            branch,
            &worker_oid,
            run::IntegrationProvenance::ParallelWorkerDirect,
        );

        assert!(!cleanup.complete);
        assert!(wt.exists());
        assert_eq!(sh_git(&wt, &["rev-parse", "HEAD"]).trim(), detached_oid);
        assert_eq!(
            ref_tip(&root, &format!("refs/heads/{branch}")).unwrap(),
            worker_oid
        );
        assert!(cleanup
            .warnings
            .iter()
            .any(|warning| warning.contains("HEAD no longer matches")));

        sh_git(&wt, &["checkout", "-q", branch]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn merge_conflict_is_reported_and_main_stays_clean() {
        let root = temp_repo("conflict");
        let wt = root.join(".agents/worktrees/yard-002");
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, "yard/yard-002").unwrap();
        // Diverge: both the worktree and the main checkout edit base.txt.
        std::fs::write(wt.join("base.txt"), "worker version\n").unwrap();
        std::fs::write(root.join("base.txt"), "main version\n").unwrap();
        sh_git(&root, &["add", "base.txt"]);
        sh_git(
            &root,
            &[
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "-m",
                "main edit",
            ],
        );
        match integrate_parallel_worktree(&root, &wt, "yard/yard-002", "YARD-002", &baseline, None)
            .unwrap()
        {
            Integration::Conflict(_) => {}
            _ => panic!("expected a conflict"),
        }
        // The merge was aborted: main tree is clean and keeps its own version.
        assert!(git_preflight(&root).is_ok());
        assert_eq!(
            std::fs::read_to_string(root.join("base.txt")).unwrap(),
            "main version\n"
        );
        // The worktree survives for manual integration.
        assert!(wt.join("base.txt").is_file());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_users_in_progress_merge_is_never_aborted() {
        // Integration must not destroy a merge the USER has in progress.
        // Simulate the mid-merge state directly with the files git leaves
        // behind (MERGE_HEAD + MERGE_MSG) — driving a real conflicted merge
        // here proved platform-sensitive; the state files are the contract.
        let root = temp_repo("usermerge");
        let head = sh_git(&root, &["rev-parse", "HEAD"]);
        let git_dir = root.join(".git");
        std::fs::write(git_dir.join("MERGE_HEAD"), head.trim().as_bytes()).unwrap();
        std::fs::write(git_dir.join("MERGE_MSG"), "Merge branch 'feature'\n").unwrap();
        assert_eq!(
            merge_in_progress_is_ours(&root, "yard/yard-009"),
            Some(false)
        );

        // Yardlet tries to integrate a worktree meanwhile: it must report and
        // leave the user's merge state intact.
        let wt = root.join(".agents/worktrees/yard-009");
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, "yard/yard-009").unwrap();
        std::fs::write(wt.join("other.txt"), "fine\n").unwrap();
        match integrate_parallel_worktree(&root, &wt, "yard/yard-009", "YARD-009", &baseline, None)
            .unwrap()
        {
            Integration::Conflict(why) => assert!(why.contains("another merge"), "{why}"),
            _ => panic!("expected a conflict report"),
        }
        // The user's merge is still in progress.
        assert!(git_dir.join("MERGE_HEAD").exists());
        assert_eq!(
            merge_in_progress_is_ours(&root, "yard/yard-009"),
            Some(false)
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn no_changes_short_circuits() {
        let root = temp_repo("nochange");
        let wt = root.join(".agents/worktrees/yard-003");
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, "yard/yard-003").unwrap();
        match integrate_parallel_worktree(&root, &wt, "yard/yard-003", "YARD-003", &baseline, None)
            .unwrap()
        {
            Integration::NoChanges { .. } => {}
            _ => panic!("expected no changes"),
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn no_change_cleanup_retains_a_later_clean_commit() {
        let root = temp_repo("nochange-later-commit");
        let wt = root.join(".agents/worktrees/run-nochange-later");
        let branch = "yard/yard-nochange/run-nochange-later";
        let baseline = sh_git(&root, &["rev-parse", "HEAD"]).trim().to_string();
        create_worktree(&root, &wt, branch).unwrap();
        let worker_oid =
            match integrate_parallel_worktree(&root, &wt, branch, "YARD-NOCHANGE", &baseline, None)
                .unwrap()
            {
                Integration::NoChanges { worker_oid } => worker_oid,
                _ => panic!("expected no changes"),
            };

        sh_git(&wt, &["checkout", "-q", "--detach"]);
        std::fs::write(wt.join("later.txt"), "later clean commit\n").unwrap();
        sh_git(&wt, &["add", "later.txt"]);
        sh_git(&wt, &["commit", "-q", "-m", "later detached commit"]);
        let later_oid = sh_git(&wt, &["rev-parse", "HEAD"]).trim().to_string();

        let cleanup = cleanup_integrated_worktree(
            &root,
            &wt,
            branch,
            &worker_oid,
            run::IntegrationProvenance::ParallelWorkerDirect,
        );

        assert!(!cleanup.complete);
        assert!(wt.exists());
        assert_eq!(sh_git(&wt, &["rev-parse", "HEAD"]).trim(), later_oid);
        assert_eq!(
            ref_tip(&root, &format!("refs/heads/{branch}")),
            Some(worker_oid)
        );

        sh_git(&wt, &["checkout", "-q", branch]);
        remove_worktree(&root, &wt, branch);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_failover_note_only_handoff_stays_core_authored() {
        // The parallel path appends its failover note through the shared core
        // helper (run::append_failover_note); a handoff.md holding nothing but
        // those appended sections must be classified worker_authored=false at
        // finalization, exactly like the serial path.
        let root = std::env::temp_dir().join(format!(
            "yard-parallel-failover-note-only-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();

        // Both note shapes the parallel path emits.
        run::append_failover_note(
            &root,
            "worker failover: codex -> claude-code; codex exited without result.json",
        )
        .unwrap();
        run::append_failover_note(
            &root,
            "worker failover unavailable after claude-code exited without result.json: \
             no ready worker",
        )
        .unwrap();
        assert!(root.join("handoff.md").is_file());

        let entries = run::plan_finalization_artifact_entries(&root);
        let handoff_worker_authored = entries
            .iter()
            .find(|(name, _, _)| *name == "handoff.md")
            .map(|(_, _, worker_authored)| *worker_authored)
            .expect("missing handoff.md finalization entry");
        assert!(
            !handoff_worker_authored,
            "a note-only handoff.md written by the parallel failover path must be \
             recorded worker_authored=false"
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
