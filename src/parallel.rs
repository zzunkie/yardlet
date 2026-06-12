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

use crate::packet::{self, PacketInputs};
use crate::schemas::{Task, TaskState, WorkQueue, WorkerProfile};
use crate::state::{self, write_str, Workspace};
use crate::{compact, evaluator, guard, inspect, routing, run, telemetry, workers};

/// Indices of tasks eligible to run together right now: queued, dependencies
/// met, not approval-gated. Priority order, up to `max`.
pub fn ready_independent(queue: &WorkQueue, max: usize) -> Vec<usize> {
    let mut ready: Vec<usize> = queue
        .tasks
        .iter()
        .enumerate()
        .filter(|(_, t)| {
            t.state == TaskState::Queued && !t.approval_required() && queue.deps_met(t)
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
        let resolved = match routing::resolve_worker(
            ws,
            &workers_file,
            &billing,
            None,
            &task.preferred_worker,
            &task.kind,
        ) {
            Ok(r) => r,
            Err(e) => {
                on_event(&format!("{}: no ready worker ({e}); skipped", task.id));
                continue;
            }
        };
        let profile = match run::find_worker(&workers_file.workers, &resolved.worker_id) {
            Ok(p) => p.clone(),
            Err(e) => {
                on_event(&format!("{}: {e}; skipped", task.id));
                continue;
            }
        };
        let mut eff_profile = profile;
        if !task.model.trim().is_empty() {
            eff_profile.model = task.model.clone();
        }
        if !task.effort.trim().is_empty() {
            eff_profile.effort = task.effort.clone();
        }
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
        // (the worktree), and Yard's runtime state is not committed — copy the
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
            prior_question: None,
            user_answer: None,
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
        match &fin.outcome {
            Ok(o) => on_event(&format!(
                "{}: worker finished ({}); integrating",
                p.task.id, o.note
            )),
            Err(e) => on_event(&format!("{}: worker error: {e}", p.task.id)),
        }

        let eval = evaluator::evaluate(&p.run_dir, &p.run_id, &p.task);
        let _ = state::write_str(
            &p.run_dir.join("evaluation.json"),
            &serde_json::to_string_pretty(&eval).unwrap_or_default(),
        );
        let result: Option<crate::schemas::RunResult> =
            std::fs::read_to_string(p.run_dir.join("result.json"))
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok());
        let _ =
            compact::write_checkpoint(&p.run_dir, &p.task, &eval, result.as_ref(), intent_summary);
        let _ = compact::write_handoff(&p.run_dir, &p.task, &eval, result.as_ref());

        let mut next = eval.next_task_state;
        if next == TaskState::Done {
            match integrate_worktree(&ws.root, &p.wt_path, &p.branch, &p.task.id) {
                Ok(Integration::Merged) => {
                    on_event(&format!(
                        "{}: merged {} into the workspace",
                        p.task.id, p.branch
                    ));
                    remove_worktree(&ws.root, &p.wt_path, &p.branch);
                }
                Ok(Integration::NoChanges) => {
                    on_event(&format!("{}: no file changes to merge", p.task.id));
                    remove_worktree(&ws.root, &p.wt_path, &p.branch);
                }
                Ok(Integration::Conflict(why)) => {
                    next = TaskState::Partial;
                    // Mark WHY it is partial: a conflict needs a human, so the
                    // auto-drain must not continue it like a worker self-report.
                    let _ = write_str(&p.run_dir.join("partial-reason"), "merge_conflict");
                    let note = format!(
                        "\n## Merge conflict\n\nYard could not merge `{}` back: {}\n\
                         The worktree is kept at `{}` for manual integration.\n",
                        p.branch,
                        why.trim(),
                        p.wt_path.display()
                    );
                    append_to(&p.run_dir.join("handoff.md"), &note);
                    on_event(&format!(
                        "{}: merge conflict — task is partial; worktree kept at {}",
                        p.task.id,
                        p.wt_path.display()
                    ));
                }
                Err(e) => {
                    next = TaskState::Partial;
                    let _ = write_str(&p.run_dir.join("partial-reason"), "merge_conflict");
                    on_event(&format!("{}: integration error: {e}", p.task.id));
                }
            }
        } else {
            // Not Done: keep the worktree as evidence; a retry starts fresh.
            on_event(&format!(
                "{}: {:?} — worktree kept at {}",
                p.task.id,
                next,
                p.wt_path.display()
            ));
        }

        queue.tasks[p.queue_idx].state = next;
        ws.save_queue(&queue)?;
        states.push((p.task.id.clone(), next));

        let _ = telemetry::append_run(
            ws,
            &telemetry::RunTelemetry {
                ts: Local::now().to_rfc3339(),
                task_id: p.task.id.clone(),
                kind: p.task.kind.clone(),
                risk: p.task.risk.clone(),
                worker: p.worker_id.clone(),
                chosen_reason: p.reason.clone(),
                result_status: result
                    .as_ref()
                    .map(|r| r.status.clone())
                    .unwrap_or_else(|| "no-result".to_string()),
                eval_state: format!("{next:?}"),
                wall_seconds: fin.wall_seconds,
                user_override: None,
            },
        );
    }
    for h in handles {
        let _ = h.join();
    }
    Ok(states)
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

/// Commit whatever the worker left in the worktree (excluding Yard's `.agents/`
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
        git(
            wt,
            &[
                "-c",
                "user.name=yard",
                "-c",
                "user.email=yard@localhost",
                "commit",
                "-m",
                &format!("yard: {task_id}"),
            ],
        )?;
    }
    let ahead = git(root, &["rev-list", "--count", &format!("HEAD..{branch}")])?;
    if ahead.trim() == "0" {
        return Ok(Integration::NoChanges);
    }
    match git(
        root,
        &[
            "-c",
            "user.name=yard",
            "-c",
            "user.email=yard@localhost",
            "merge",
            "--no-ff",
            "--no-edit",
            branch,
        ],
    ) {
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

fn create_worktree(root: &Path, wt: &Path, branch: &str) -> Result<()> {
    // Clear stale leftovers from a crashed/conflicted earlier run of this task.
    let wt_s = wt.display().to_string();
    let _ = git(root, &["worktree", "remove", "--force", &wt_s]);
    let _ = std::fs::remove_dir_all(wt);
    let _ = git(root, &["branch", "-D", branch]);
    git(root, &["worktree", "add", &wt_s, "-b", branch]).map(|_| ())
}

pub(crate) fn remove_worktree(root: &Path, wt: &Path, branch: &str) {
    let _ = git(
        root,
        &["worktree", "remove", "--force", &wt.display().to_string()],
    );
    let _ = git(root, &["branch", "-D", branch]);
}

/// Keep `.agents/worktrees/` out of `git status` in any repo Yard runs in,
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

fn append_to(path: &Path, text: &str) {
    let mut existing = std::fs::read_to_string(path).unwrap_or_default();
    existing.push_str(text);
    let _ = std::fs::write(path, existing);
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
            allowed_scope: vec![],
            acceptance: vec![],
            validation: None,
            approval: None,
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

    fn sh_git(dir: &Path, args: &[&str]) -> String {
        git(dir, args).unwrap_or_else(|e| panic!("git {args:?} in {dir:?}: {e}"))
    }

    fn temp_repo(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("yard-par-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        sh_git(&root, &["init", "-q"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
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
                "init",
            ],
        );
        root
    }

    #[test]
    fn worktree_roundtrip_merges_worker_changes() {
        let root = temp_repo("merge");
        assert!(git_preflight(&root).is_ok());
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
        assert!(!root.join(".agents/work-queue.yaml").exists());
        remove_worktree(&root, &wt, "yard/yard-001");
        assert!(!wt.exists());
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

        // Yard tries to integrate a worktree meanwhile: it must report and
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
