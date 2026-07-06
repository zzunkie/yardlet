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
use serde::Serialize;

use crate::packet::{self, PacketInputs};
use crate::schemas::{Task, TaskState, WorkQueue, WorkerProfile};
use crate::state::{self, append_str, write_str, Workspace};
use crate::{evaluator, guard, inspect, routing, run, workers};

/// Indices of tasks eligible to run together right now: queued, dependencies
/// met, not approval-gated. Priority order, up to `max`.
pub fn ready_independent(queue: &WorkQueue, max: usize) -> Vec<usize> {
    let mut ready: Vec<usize> = queue
        .tasks
        .iter()
        .enumerate()
        .filter(|(_, t)| {
            // A required-validation task is excluded: parallel skips validation,
            // so it must run serially where validation actually gates Done.
            t.state == TaskState::Queued
                && !t.approval_required()
                && !t.requires_validation()
                && queue.deps_met(t)
        })
        .map(|(i, _)| i)
        .collect();
    ready.sort_by_key(|&i| queue.tasks[i].priority);
    ready.truncate(max);
    ready
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
    queue_idx: usize,
    task: Task,
    worker_id: String,
    reason: String,
    bin: PathBuf,
    profile: WorkerProfile,
    run_id: String,
    run_dir: PathBuf,
    wt_path: PathBuf,
    branch: String,
    packet_text: String,
    session: Option<String>,
}

struct Finished {
    prep_idx: usize,
    outcome: Result<workers::WorkerOutcome>,
    wall_seconds: u64,
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
        let task = queue.tasks[idx].clone();
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
        let run_id = format!(
            "run-{}-{}",
            Local::now().format("%Y%m%d-%H%M%S"),
            task.id.to_lowercase()
        );
        let run_dir = ws.runs_dir().join(&run_id);
        let session = (resolved.worker_id == "claude-code").then(|| run::gen_session_uuid(&run_id));
        preps.push(Prep {
            queue_idx: idx,
            branch: format!("yard/{}", task.id.to_lowercase()),
            wt_path: ws
                .agents_dir()
                .join("worktrees")
                .join(task.id.to_lowercase()),
            task,
            worker_id: resolved.worker_id,
            reason: resolved.reason,
            bin: resolved.bin,
            profile: eff_profile,
            run_id,
            run_dir,
            packet_text: String::new(), // compiled below, after the worktree exists
            session,
        });
    }
    if preps.is_empty() {
        return Err(anyhow!("no runnable task in the batch"));
    }

    // ---- worktrees + run dirs + packets ----------------------------------
    let mut ok: Vec<Prep> = Vec::new();
    for mut p in preps {
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
        for d in ["rules", "skills", "agents"] {
            copy_dir(&ws.agents_dir().join(d), &wt_agents.join(d));
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
        });
        write_str(&workers::packet_path(&p.run_dir), &p.packet_text)?;
        state::save_yaml(
            &p.run_dir.join("run.yaml"),
            &run::RunRecord {
                schema_version: 1,
                run_id: p.run_id.clone(),
                task_id: p.task.id.clone(),
                intent_id: queue.intent_id.clone(),
                worker: p.worker_id.clone(),
                state: "running".to_string(),
                started_at: Local::now().to_rfc3339(),
                completed_at: None,
                worktree: p.wt_path.display().to_string(),
            },
        )?;
        ok.push(p);
    }
    let preps = ok;
    if preps.is_empty() {
        return Err(anyhow!("no worktree could be prepared for the batch"));
    }

    // ---- mark running (one write), then spawn workers --------------------
    for p in &preps {
        queue.tasks[p.queue_idx].state = TaskState::Running;
    }
    ws.save_queue(&queue)?;
    on_event(&format!(
        "parallel batch: {}",
        preps
            .iter()
            .map(|p| format!("{} via {}", p.task.id, p.worker_id))
            .collect::<Vec<_>>()
            .join(", ")
    ));

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
        let log_path = p.run_dir.join("worker-output.log");
        let timeout = Duration::from_secs(p.profile.limits.max_wall_minutes as u64 * 60);
        let images = images.clone();
        let session = p.session.clone();
        handles.push(std::thread::spawn(move || {
            let started = std::time::Instant::now();
            let outcome = workers::spawn(
                &profile,
                &bin,
                &packet_text,
                &cwd,
                &env,
                &log_path,
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

        match &outcome {
            Ok(o) => on_event(&format!(
                "{}: worker finished ({}); integrating",
                p.task.id, o.note
            )),
            Err(e) => on_event(&format!("{}: worker error: {e}", p.task.id)),
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
                    reason = format!("failover from {from} ({})", alt.reason);
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
                            continuation: None,
                            chained_from: None,
                            language: &language,
                            images: &images,
                            role_notes: &role_notes,
                            harness: &harness,
                        });
                        write_str(&workers::packet_path(&p.run_dir), &failover_packet)?;
                        let session = (worker_id == "claude-code")
                            .then(|| run::gen_session_uuid(&format!("{}-{worker_id}", p.run_id)));
                        workers::spawn(
                            &eff_profile,
                            &alt.bin,
                            &failover_packet,
                            &p.wt_path,
                            &env,
                            &p.run_dir.join("worker-output.log"),
                            timeout,
                            full_access,
                            &images,
                            session.as_deref(),
                            false,
                        )
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
        let evidence = evaluator::changed_paths(&p.wt_path).map(|paths| {
            paths
                .into_iter()
                .filter(|path| !path.starts_with(".agents/"))
                .collect()
        });
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
            if let Err(e) = append_failover_note(&p.run_dir, note) {
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

fn append_failover_note(run_dir: &Path, note: &str) -> Result<()> {
    let mut md = String::from("\n## Worker failover\n\n");
    md.push_str(note);
    md.push('\n');
    append_str(&run_dir.join("checkpoint.md"), &md)?;
    append_str(&run_dir.join("handoff.md"), &md)?;
    Ok(())
}

pub(crate) enum Integration {
    Merged,
    NoChanges,
    Conflict(String),
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

/// Commit whatever the worker left in the worktree (excluding Yardlet's `.agents/`
/// state copies) and merge the branch back into the main workspace.
pub(crate) fn integrate_worktree(
    root: &Path,
    wt: &Path,
    branch: &str,
    task_id: &str,
) -> Result<Integration> {
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
    git(wt, &["add", "-A", "--", ".", ":(exclude).agents"])?;
    let staged = git(wt, &["diff", "--cached", "--name-only"])?;
    if !staged.trim().is_empty() {
        let message = commit_message(root, task_id);
        git(wt, &["commit", "-m", &message])?;
    }
    let ahead = git(root, &["rev-list", "--count", &format!("HEAD..{branch}")])?;
    if ahead.trim() == "0" {
        return Ok(Integration::NoChanges);
    }
    match git(root, &["merge", "--no-ff", "--no-edit", branch]) {
        Ok(_) => Ok(Integration::Merged),
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

fn create_worktree(root: &Path, wt: &Path, branch: &str) -> Result<()> {
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
    let _ = git(
        root,
        &["worktree", "remove", "--force", &wt.display().to_string()],
    );
    let _ = git(root, &["branch", "-D", branch]);
}

/// Keep `.agents/worktrees/` out of `git status` in any repo Yardlet runs in,
/// without touching the repo's own .gitignore: use the repo-local exclude file.
fn ensure_worktrees_excluded(root: &Path) {
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
fn copy_dir(src: &Path, dst: &Path) {
    let Ok(rd) = std::fs::read_dir(src) else {
        return;
    };
    let _ = std::fs::create_dir_all(dst);
    for e in rd.flatten() {
        let from = e.path();
        let to = dst.join(e.file_name());
        if from.is_dir() {
            copy_dir(&from, &to);
        } else {
            let _ = std::fs::copy(&from, &to);
        }
    }
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
            effort: String::new(),
            depends_on: deps,
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
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
    fn ready_set_excludes_required_validation_tasks() {
        // A required-validation task is held back from parallel batches (parallel
        // skips validation), so it runs serially where validation gates Done.
        let mut needs_val = task("V", TaskState::Queued, 5, vec![]);
        needs_val.validation = Some(crate::yaml::from_str("required: true").unwrap());
        let q = queue(vec![task("A", TaskState::Queued, 10, vec![]), needs_val]);
        // Only A is parallel-ready; V is excluded despite its lower priority.
        assert_eq!(ready_independent(&q, 10), vec![0]);
    }

    fn sh_git(dir: &Path, args: &[&str]) -> String {
        git(dir, args).unwrap_or_else(|e| panic!("git {args:?} in {dir:?}: {e}"))
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

    #[test]
    fn worktree_roundtrip_merges_worker_changes() {
        let root = temp_repo("merge");
        assert!(git_preflight(&root).is_ok());
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        let mut t = task("YARD-001", TaskState::Queued, 10, vec![]);
        t.title = "병렬 worktree 정리".into();
        state::save_yaml(&root.join(".agents/work-queue.yaml"), &queue(vec![t])).unwrap();
        let wt = root.join(".agents/worktrees/yard-001");
        create_worktree(&root, &wt, "yard/yard-001").unwrap();
        // Simulate a worker: edit a file in the worktree, plus .agents noise
        // that must NOT be committed.
        std::fs::write(wt.join("feature.txt"), "new\n").unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();
        std::fs::write(wt.join(".agents/work-queue.yaml"), "copy").unwrap();
        match integrate_worktree(&root, &wt, "yard/yard-001", "YARD-001").unwrap() {
            Integration::Merged => {}
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
    fn merge_conflict_is_reported_and_main_stays_clean() {
        let root = temp_repo("conflict");
        let wt = root.join(".agents/worktrees/yard-002");
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
        match integrate_worktree(&root, &wt, "yard/yard-002", "YARD-002").unwrap() {
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
        create_worktree(&root, &wt, "yard/yard-009").unwrap();
        std::fs::write(wt.join("other.txt"), "fine\n").unwrap();
        match integrate_worktree(&root, &wt, "yard/yard-009", "YARD-009").unwrap() {
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
        create_worktree(&root, &wt, "yard/yard-003").unwrap();
        match integrate_worktree(&root, &wt, "yard/yard-003", "YARD-003").unwrap() {
            Integration::NoChanges => {}
            _ => panic!("expected no changes"),
        }
        let _ = std::fs::remove_dir_all(&root);
    }
}
