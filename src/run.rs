//! Run orchestration: select one bounded task, prepare it, and (optionally)
//! execute it through a hidden worker, then evaluate and compact.
//!
//! Yardlet stays deterministic until a worker is invoked. By default `run_next`
//! prepares everything (run dir, evidence, packet, sanitized env) and stops
//! *before* spawning, because spawning a subscription-backed worker consumes
//! real usage. Pass `execute: true` to actually invoke the worker.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::guard;
use crate::inspect;
use crate::packet::{self, PacketInputs};
use crate::schemas::{
    AnswerActionRequest, AttemptState, ChannelEvent, ChannelEventType, ContinuationMode,
    ConversationTurn, EventActor, EventActorKind, Question, QuestionState, RunResult, TaskState,
    TransitionActor, TransitionCause, TurnRole, WorkQueue, WorkerAttempt, WorkerProfile,
    WorkersFile,
};
use crate::state::{self, append_str, write_str, PlanningLock, Workspace};
use crate::ui::i18n::{self, Lang};
use crate::{compact, evaluator, routing, telemetry, workers};

pub(crate) use crate::state::IntegrationProvenance;

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

struct SerialWorktree {
    path: PathBuf,
    branch: String,
    baseline_oid: String,
    worker_run_dir: PathBuf,
}

struct SerialWorktreeErrorCleanup<'a> {
    ws: &'a Workspace,
    owned: Option<&'a SerialWorktree>,
    armed: bool,
}

impl<'a> SerialWorktreeErrorCleanup<'a> {
    fn new(ws: &'a Workspace, owned: Option<&'a SerialWorktree>) -> Self {
        Self {
            ws,
            owned,
            armed: owned.is_some(),
        }
    }

    fn cleanup_now(&mut self) {
        if self.armed {
            remove_unused_serial_worktree(self.ws, self.owned);
            self.armed = false;
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for SerialWorktreeErrorCleanup<'_> {
    fn drop(&mut self) {
        self.cleanup_now();
    }
}

const SERIAL_CANONICAL_SEED_DIR: &str = "evidence/canonical-state-seed";
pub(crate) const HARNESS_SEED_DIR: &str = "evidence/harness-state-seed";

fn git_stdout(root: &std::path::Path, args: &[&str]) -> Result<String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()?;
    if !output.status.success() {
        return Err(anyhow!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn prepare_serial_worktree(
    ws: &Workspace,
    run_dir: &std::path::Path,
    run_id: &str,
    task_id: &str,
) -> Result<SerialWorktree> {
    crate::parallel::ensure_worktrees_excluded(&ws.root);
    let baseline_oid = git_stdout(&ws.root, &["rev-parse", "--verify", "HEAD^{commit}"])?
        .trim()
        .to_string();
    let branch = format!("yard/{}/{}", task_id.to_lowercase(), run_id);
    let path = ws.agents_dir().join("worktrees").join(run_id);
    crate::parallel::create_worktree(&ws.root, &path, &branch)?;

    let prepared = (|| -> Result<SerialWorktree> {
        let wt_agents = path.join(crate::state::STATE_DIR);
        std::fs::create_dir_all(&wt_agents)?;
        let canonical_seed_dir = run_dir.join(SERIAL_CANONICAL_SEED_DIR);
        std::fs::create_dir_all(&canonical_seed_dir)?;
        let intent = ws.intent_path();
        if intent.is_file() {
            std::fs::copy(&intent, wt_agents.join("intent-contract.yaml"))?;
            std::fs::copy(&intent, canonical_seed_dir.join("intent-contract.yaml"))?;
        }
        let queue = ws.queue_path();
        std::fs::copy(&queue, wt_agents.join("work-queue.yaml"))?;
        std::fs::copy(&queue, canonical_seed_dir.join("work-queue.yaml"))?;
        let harness_seed_dir = run_dir.join(HARNESS_SEED_DIR);
        for directory in ["rules", "skills", "agents"] {
            crate::parallel::copy_dir(&ws.agents_dir().join(directory), &wt_agents.join(directory));
            crate::parallel::copy_dir(
                &ws.agents_dir().join(directory),
                &harness_seed_dir.join(directory),
            );
        }
        let worker_run_dir = wt_agents.join("runs").join(run_id);
        std::fs::create_dir_all(&worker_run_dir)?;
        Ok(SerialWorktree {
            path: path.clone(),
            branch: branch.clone(),
            baseline_oid: baseline_oid.clone(),
            worker_run_dir,
        })
    })();
    match prepared {
        Ok(owned) => {
            let receipt = state::SerialIntegrationReceipt {
                schema_version: 1,
                run_id: run_id.to_string(),
                task_id: task_id.to_string(),
                worktree: path.display().to_string(),
                branch,
                baseline_oid,
            };
            if let Err(error) = ws.save_serial_integration_receipt(&receipt) {
                crate::parallel::remove_worktree(&ws.root, &path, &receipt.branch);
                return Err(error);
            }
            Ok(owned)
        }
        Err(error) => {
            crate::parallel::remove_worktree(&ws.root, &path, &branch);
            Err(error)
        }
    }
}

fn seeded_canonical_file_unchanged(seed: &std::path::Path, current: &std::path::Path) -> bool {
    let Ok(metadata) = std::fs::symlink_metadata(current) else {
        return false;
    };
    metadata.is_file()
        && !metadata.file_type().is_symlink()
        && std::fs::read(seed)
            .and_then(|seed_bytes| std::fs::read(current).map(|bytes| seed_bytes == bytes))
            .unwrap_or(false)
}

struct SerialCommittedEvidence {
    paths: Vec<String>,
    merge_target_oid: String,
}

struct SerialWorktreeEvidence {
    paths: Vec<String>,
    merge_target_oid: String,
    unchanged_seeded_harness: Vec<String>,
}

fn serial_committed_paths(
    worktree: &std::path::Path,
    run_dir: &std::path::Path,
) -> Option<SerialCommittedEvidence> {
    let record = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")).ok()?;
    let baseline_oid = record.baseline_oid;
    let merge_target = if record.worktree_branch.is_empty() {
        "HEAD^{commit}".to_string()
    } else {
        format!("refs/heads/{}^{{commit}}", record.worktree_branch)
    };
    let merge_target_oid = git_stdout(worktree, &["rev-parse", "--verify", &merge_target])
        .ok()?
        .trim()
        .to_string();
    if baseline_oid.is_empty() {
        return Some(SerialCommittedEvidence {
            paths: Vec::new(),
            merge_target_oid,
        });
    }
    let range = format!("{baseline_oid}..{merge_target_oid}");
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(worktree)
        .args(["diff", "--name-only", "--no-renames", "-z", &range])
        .env("LC_ALL", "C")
        .env("LANG", "C")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(SerialCommittedEvidence {
        paths: output
            .stdout
            .split(|byte| *byte == 0)
            .filter(|path| !path.is_empty())
            .map(|path| String::from_utf8_lossy(path).into_owned())
            .collect(),
        merge_target_oid,
    })
}

/// Actual serial-worktree changes with only Yardlet's unchanged canonical seed
/// copies removed. The main run owns an exact pre-worker snapshot, so a worker
/// create, edit, delete, or symlink replacement stays in the evidence and is
/// rejected by the evaluator's forbidden-path gate. Status alone is not enough:
/// a worker may commit its own changes and detach HEAD, so paths committed on
/// the exact run-owned branch tip after the pinned baseline are unioned after
/// filtering the unchanged seed copies. The returned OID binds that evidence
/// to the later integration target.
fn serial_worktree_evidence(
    worktree: &std::path::Path,
    run_dir: &std::path::Path,
) -> Option<SerialWorktreeEvidence> {
    let mut paths = evaluator::changed_paths(worktree)?;
    let committed = serial_committed_paths(worktree, run_dir)?;
    let seed_dir = run_dir.join(SERIAL_CANONICAL_SEED_DIR);
    if !seed_dir.is_dir() {
        // Compatibility for runs created before exact seed snapshots existed:
        // retain their previous recovery behavior instead of attributing every
        // Yardlet-seeded untracked canonical copy to the worker.
        paths.retain(|path| !evaluator::is_canonical_state_path(path));
        paths.extend(committed.paths);
        paths.sort();
        paths.dedup();
        return Some(SerialWorktreeEvidence {
            paths,
            merge_target_oid: committed.merge_target_oid,
            unchanged_seeded_harness: Vec::new(),
        });
    }

    let mut seeded = std::collections::BTreeSet::new();
    let mut modified = std::collections::BTreeSet::new();
    let entries = std::fs::read_dir(&seed_dir).ok()?;
    for entry in entries {
        let entry = entry.ok()?;
        if !entry.file_type().ok()?.is_file() {
            continue;
        }
        let name = entry.file_name().to_str()?.to_string();
        let path = format!(".agents/{name}");
        if !evaluator::is_canonical_state_path(&path) {
            continue;
        }
        seeded.insert(path.clone());
        if !seeded_canonical_file_unchanged(&entry.path(), &worktree.join(&path)) {
            modified.insert(path);
        }
    }

    paths.retain(|path| {
        if !evaluator::is_canonical_state_path(path) {
            return true;
        }
        !seeded.contains(path) || modified.contains(path)
    });
    for path in modified {
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    let harness_seed_dir = run_dir.join(HARNESS_SEED_DIR);
    let mut unchanged_seeded_harness = Vec::new();
    if harness_seed_dir.is_dir() {
        let (seeded_harness, modified_harness) =
            seeded_harness_evidence(&harness_seed_dir, worktree)?;
        unchanged_seeded_harness = paths
            .iter()
            .filter(|path| seeded_harness.contains(*path) && !modified_harness.contains(*path))
            .cloned()
            .collect();
        paths.retain(|path| !seeded_harness.contains(path) || modified_harness.contains(path));
        for path in modified_harness {
            if !paths.contains(&path) {
                paths.push(path);
            }
        }
    }
    paths.extend(committed.paths);
    paths.sort();
    paths.dedup();
    Some(SerialWorktreeEvidence {
        paths,
        merge_target_oid: committed.merge_target_oid,
        unchanged_seeded_harness,
    })
}

fn remove_unchanged_seeded_harness_copies(
    worktree: &std::path::Path,
    evidence: &SerialWorktreeEvidence,
) -> Result<()> {
    for path in &evidence.unchanged_seeded_harness {
        discard_unchanged_seeded_harness_copy(worktree, path)?;
    }
    Ok(())
}

pub(crate) fn discard_unchanged_seeded_harness_copy(
    worktree: &std::path::Path,
    path: &str,
) -> Result<()> {
    git_stdout(worktree, &["reset", "-q", "HEAD", "--", path])?;
    let tracked = !git_stdout(worktree, &["ls-files", "--", path])?
        .trim()
        .is_empty();
    if tracked {
        git_stdout(
            worktree,
            &["restore", "--source=HEAD", "--worktree", "--", path],
        )?;
    } else {
        let candidate = worktree.join(path);
        if candidate.is_file() {
            std::fs::remove_file(candidate)?;
        }
    }
    Ok(())
}

pub(crate) fn seeded_harness_evidence(
    seed_root: &std::path::Path,
    worktree: &std::path::Path,
) -> Option<(
    std::collections::BTreeSet<String>,
    std::collections::BTreeSet<String>,
)> {
    fn visit(
        seed_root: &std::path::Path,
        directory: &std::path::Path,
        worktree: &std::path::Path,
        seeded: &mut std::collections::BTreeSet<String>,
        modified: &mut std::collections::BTreeSet<String>,
    ) -> Option<()> {
        for entry in std::fs::read_dir(directory).ok()? {
            let entry = entry.ok()?;
            let metadata = entry.file_type().ok()?;
            if metadata.is_dir() {
                visit(seed_root, &entry.path(), worktree, seeded, modified)?;
                continue;
            }
            if !metadata.is_file() {
                continue;
            }
            let relative = entry.path().strip_prefix(seed_root).ok()?.to_path_buf();
            let path = format!(".agents/{}", relative.to_string_lossy());
            seeded.insert(path.clone());
            if !seeded_canonical_file_unchanged(&entry.path(), &worktree.join(&path)) {
                modified.insert(path);
            }
        }
        Some(())
    }

    let mut seeded = std::collections::BTreeSet::new();
    let mut modified = std::collections::BTreeSet::new();
    visit(seed_root, seed_root, worktree, &mut seeded, &mut modified)?;
    Some((seeded, modified))
}

const MAIN_OWNED_RUN_ARTIFACT_NAMES: [&str; 18] = [
    "run.yaml",
    "task-packet.md",
    "worker.pid",
    "worker-process.yaml",
    "worker-output.log",
    "git-finish.json",
    "git-integration.json",
    "feedback.json",
    "canonical-state-seed",
    "cancelled",
    "partial-reason",
    "failover.json",
    "evaluation.json",
    "validation.json",
    "evidence",
    "hooks",
    "attempts",
    "latest-attempt",
];

fn is_main_owned_validation_log_name(name: &str) -> bool {
    let normalized = name.to_ascii_lowercase();
    normalized
        .strip_prefix("validation-")
        .and_then(|rest| rest.strip_suffix(".log"))
        .is_some_and(|index| !index.is_empty() && index.bytes().all(|byte| byte.is_ascii_digit()))
}

fn is_main_owned_run_artifact_name(name: &std::ffi::OsStr) -> bool {
    name.to_str().is_some_and(|name| {
        MAIN_OWNED_RUN_ARTIFACT_NAMES
            .iter()
            .any(|reserved| name.eq_ignore_ascii_case(reserved))
            || is_main_owned_validation_log_name(name)
    })
}

fn validation_log_ascii_alias(name: &std::ffi::OsStr) -> Option<String> {
    let name = name.to_str()?;
    let bytes = name.as_bytes();
    let start = bytes.iter().position(|byte| byte.is_ascii_digit())?;
    let end = start
        + bytes[start..]
            .iter()
            .position(|byte| !byte.is_ascii_digit())
            .unwrap_or(bytes.len() - start);
    if bytes[end..].iter().any(|byte| byte.is_ascii_digit()) {
        return None;
    }
    Some(format!("validation-{}.log", &name[start..end]))
}

fn is_main_owned_run_artifact_component(parent: &std::path::Path, name: &std::ffi::OsStr) -> bool {
    if is_main_owned_run_artifact_name(name) {
        return true;
    }

    let candidate = parent.join(name);
    let Ok(candidate) = std::fs::canonicalize(candidate) else {
        return false;
    };
    MAIN_OWNED_RUN_ARTIFACT_NAMES.iter().any(|reserved| {
        std::fs::canonicalize(parent.join(reserved)).is_ok_and(|path| path == candidate)
    }) || validation_log_ascii_alias(name).is_some_and(|reserved| {
        std::fs::canonicalize(parent.join(reserved)).is_ok_and(|path| path == candidate)
    })
}

fn import_worker_run_artifacts(from: &std::path::Path, to: &std::path::Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let name = entry.file_name();
        if is_main_owned_run_artifact_component(from, &name) {
            continue;
        }
        let metadata = std::fs::symlink_metadata(entry.path())?;
        if metadata.file_type().is_symlink() {
            continue;
        }
        let target = to.join(&name);
        if metadata.is_dir() {
            import_worker_run_artifacts(&entry.path(), &target)?;
        } else if metadata.is_file() {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

fn remove_unused_serial_worktree(ws: &Workspace, owned: Option<&SerialWorktree>) {
    if let Some(owned) = owned {
        crate::parallel::remove_worktree(&ws.root, &owned.path, &owned.branch);
    }
}

fn cleanup_cancelled_serial_worktree(ws: &Workspace, owned: Option<&SerialWorktree>) {
    if let Some(owned) = owned {
        let _ = crate::parallel::cleanup_integrated_worktree(
            &ws.root,
            &owned.path,
            &owned.branch,
            &owned.baseline_oid,
            IntegrationProvenance::SerialCoreStaged,
        );
    }
}

fn run_event_lang(ws: &Workspace) -> Lang {
    let config_lang = ws
        .load_config()
        .map(|c| c.language)
        .unwrap_or_else(|_| "auto".to_string());
    let sample = ws
        .load_intent()
        .ok()
        .flatten()
        .map(|i| {
            if i.raw_request.trim().is_empty() {
                i.summary
            } else {
                i.raw_request
            }
        })
        .or_else(|| {
            ws.load_queue().ok().map(|q| {
                q.tasks
                    .iter()
                    .map(|t| t.title.as_str())
                    .collect::<Vec<_>>()
                    .join("\n")
            })
        })
        .unwrap_or_default();
    i18n::detect(&config_lang, &sample)
}

fn task_state_progress_line(lang: Lang, task_id: &str, state: TaskState) -> String {
    format!(
        "{} \u{2192} {}",
        task_id,
        i18n::task_state_label(lang.l(), state)
    )
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
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub fallback_enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub routing_provenance: Option<crate::schemas::RoutingProvenance>,
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
    /// True only for the serial path introduced by V010-001A. Legacy and
    /// parallel worktree records deserialize false, preserving their existing
    /// always-integrate behavior during recovery.
    #[serde(default)]
    pub serial_isolated: bool,
    /// Commit from which this run's isolated worktree was created.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub baseline_oid: String,
    /// Run-unique branch used by an isolated worktree.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub worktree_branch: String,
    /// Merge commit attributed to this run, persisted before finish/push.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub integration_oid: String,
    /// First parent of integration_oid and required remote OID before push.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub integration_base_oid: String,
    /// Exact isolated commit used as the merge's second parent. Cleanup may
    /// delete only refs that still point to this OID.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub integration_worker_oid: String,
    /// Identifies the core-controlled integration protocol. Unknown legacy
    /// parallel runs are handled only through the marker-free parallel path.
    #[serde(default, skip_serializing_if = "is_unknown_integration_provenance")]
    pub integration_provenance: IntegrationProvenance,
    /// Set only after the owned worktree and refs were reconciled. A false
    /// value makes cleanup restartable after any process interruption.
    #[serde(default, skip_serializing_if = "is_false")]
    pub integration_cleanup_complete: bool,
    /// Exact commits newly reachable from baseline through integration_oid.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub owned_oids: Vec<String>,
}

impl RunRecord {
    fn resolved_selection(&self) -> Option<crate::schemas::ResolvedWorkerSelection> {
        let routing_provenance = self.routing_provenance.clone()?;
        if self.worker.trim().is_empty() || self.model.trim().is_empty() {
            return None;
        }
        Some(crate::schemas::ResolvedWorkerSelection {
            worker_id: self.worker.clone(),
            model: self.model.clone(),
            fallback_enabled: self.fallback_enabled,
            routing_provenance,
        })
    }
}

pub(crate) fn has_receipted_runtime_selection(
    ws: &Workspace,
    intent_id: &str,
    task_id: &str,
    selection: &crate::schemas::ResolvedWorkerSelection,
) -> bool {
    let Ok(entries) = std::fs::read_dir(ws.runs_dir()) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let run_dir = entry.path();
        let Some(path_run_id) = run_dir.file_name().and_then(|name| name.to_str()) else {
            return false;
        };
        if !path_run_id.starts_with("run-") {
            return false;
        }
        let Ok(record) = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")) else {
            return false;
        };
        if record.schema_version != 1
            || record.run_id != path_run_id
            || record.task_id != task_id
            || record.intent_id != intent_id
            || record.started_at.trim().is_empty()
            || record.resolved_selection().as_ref() != Some(selection)
        {
            return false;
        }
        let Ok(process) = workers::load_worker_process_provenance(&run_dir) else {
            return false;
        };
        process.schema_version == 1
            && process.run_id == record.run_id
            && !process.attempt_id.trim().is_empty()
            && process.worker_id == selection.worker_id
            && process.model == selection.model
            && process.fallback_enabled == selection.fallback_enabled
            && process.routing_provenance == selection.routing_provenance
            && process.pid != 0
            && !process.process_start_marker.trim().is_empty()
            && process.state == "exited"
            && process
                .completed_at
                .as_deref()
                .is_some_and(|completed| !completed.trim().is_empty())
    })
}

pub(crate) fn update_run_selection(
    run_dir: &std::path::Path,
    selection: &crate::schemas::ResolvedWorkerSelection,
) -> Result<()> {
    let path = run_dir.join("run.yaml");
    let mut record: RunRecord = state::load_yaml(&path)?;
    record.worker = selection.worker_id.clone();
    record.model = selection.model.clone();
    record.fallback_enabled = selection.fallback_enabled;
    record.routing_provenance = Some(selection.routing_provenance.clone());
    state::save_yaml_atomic(&path, &record)
}

pub(crate) fn apply_selection_to_task(
    task: &mut crate::schemas::Task,
    selection: &crate::schemas::ResolvedWorkerSelection,
) {
    task.preferred_worker = selection.worker_id.clone();
    task.model = selection.model.clone();
    task.fallback_enabled = Some(selection.fallback_enabled);
    task.routing_provenance = Some(selection.routing_provenance.clone());
}

fn is_unknown_integration_provenance(value: &IntegrationProvenance) -> bool {
    *value == IntegrationProvenance::Unknown
}

fn is_false(value: &bool) -> bool {
    !*value
}

#[derive(Serialize, Deserialize, Default)]
pub(crate) struct RunFailover {
    pub from: String,
    pub to: String,
    pub reason: String,
    pub at: String,
}

pub(crate) fn attempt_id_for_ordinal(run_id: &str, ordinal: u32) -> String {
    if ordinal <= 1 {
        run_id.to_string()
    } else {
        format!("{run_id}-attempt-{ordinal}")
    }
}

#[derive(Clone)]
pub(crate) struct ChannelRunContext {
    session_id: String,
    intent_id: String,
    task_id: String,
    correlation_id: String,
}

pub(crate) fn channel_run_context(
    ws: &Workspace,
    intent_id: &str,
    task_id: &str,
) -> ChannelRunContext {
    // Pre-activation/legacy queues had no intent id. Keep that execution path
    // additive while still giving the durable envelope a non-empty identity.
    let channel_intent_id = if intent_id.trim().is_empty() {
        "legacy-intent"
    } else {
        intent_id
    };
    if let Ok(existing) = ws.load_task_channel(channel_intent_id, task_id) {
        if !existing.session_id.is_empty() {
            return ChannelRunContext {
                correlation_id: existing
                    .events
                    .first()
                    .map(|event| event.correlation_id.clone())
                    .filter(|id| !id.is_empty())
                    .unwrap_or_else(|| format!("cor_{}", existing.channel_id)),
                session_id: existing.session_id,
                intent_id: channel_intent_id.to_string(),
                task_id: task_id.to_string(),
            };
        }
    }
    let session_id = ws
        .load_activated_intent()
        .ok()
        .flatten()
        .filter(|intent| intent.intent.id == channel_intent_id)
        .map(|intent| intent.planning_session_id)
        .filter(|session| !session.is_empty())
        .unwrap_or_else(|| {
            format!(
                "ses_{}",
                gen_session_uuid(channel_intent_id).replace('-', "")
            )
        });
    ChannelRunContext {
        correlation_id: format!(
            "cor_{}",
            gen_session_uuid(channel_intent_id).replace('-', "")
        ),
        session_id,
        intent_id: channel_intent_id.to_string(),
        task_id: task_id.to_string(),
    }
}

#[allow(clippy::too_many_arguments)]
fn record_channel_event(
    ws: &Workspace,
    lock: Option<&PlanningLock>,
    context: &ChannelRunContext,
    event_type: ChannelEventType,
    actor: EventActor,
    attempt_id: Option<&str>,
    causation_id: Option<String>,
    payload: serde_json::Value,
    raw_ref: Option<crate::schemas::RawEventRef>,
) -> Result<ChannelEvent> {
    let event = ChannelEvent {
        schema_version: 1,
        event_id: String::new(),
        session_id: context.session_id.clone(),
        seq: 0,
        event_type,
        recorded_at: Local::now().to_rfc3339(),
        actor,
        action_id: None,
        causation_id,
        correlation_id: context.correlation_id.clone(),
        task_id: context.task_id.clone(),
        attempt_id: attempt_id.map(str::to_string),
        payload,
        raw_ref,
    };
    match lock {
        Some(lock) => ws.record_task_event_with_lock(lock, &context.intent_id, event),
        None => ws.record_task_event(&context.intent_id, event),
    }
}

fn live_worker_event_sink(
    ws: &Workspace,
    context: &ChannelRunContext,
    attempt: &WorkerAttempt,
) -> workers::AttemptEventSink {
    let ws = ws.clone();
    let context = context.clone();
    let attempt_id = attempt.attempt_id.clone();
    let worker_id = attempt.worker_id.clone();
    std::sync::Arc::new(move |normalized| {
        let channel = ws
            .load_task_channel(&context.intent_id, &context.task_id)
            .map_err(|error| error.to_string())?;
        if let Some(existing) = channel.events.iter().find(|event| {
            event.attempt_id.as_deref() == Some(&attempt_id)
                && event.event_type == normalized.event_type
                && event.raw_ref.as_ref() == Some(&normalized.raw_ref)
        }) {
            if existing.payload == normalized.payload {
                return Ok(());
            }
            return Err(format!(
                "normalized raw event changed for {} at {}..{}",
                normalized.raw_ref.artifact_id,
                normalized.raw_ref.byte_start,
                normalized.raw_ref.byte_end
            ));
        }
        let causation_id = channel
            .events
            .iter()
            .rev()
            .find(|event| event.attempt_id.as_deref() == Some(&attempt_id))
            .map(|event| event.event_id.clone());
        record_channel_event(
            &ws,
            None,
            &context,
            normalized.event_type,
            EventActor {
                kind: EventActorKind::Worker,
                id: worker_id.clone(),
            },
            Some(&attempt_id),
            causation_id,
            normalized.payload,
            Some(normalized.raw_ref),
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
    })
}

fn raw_attempt_path(ws: &Workspace, reference: &str) -> PathBuf {
    let path = std::path::Path::new(reference);
    if path.is_absolute() {
        path.to_path_buf()
    } else if let Ok(relative) = path.strip_prefix(".agents") {
        ws.agents_dir().join(relative)
    } else if reference.starts_with("task-channels/") {
        ws.agents_dir().join(path)
    } else {
        ws.root.join(path)
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn begin_worker_attempt(
    ws: &Workspace,
    lock: Option<&PlanningLock>,
    context: &ChannelRunContext,
    run_dir: &std::path::Path,
    attempt_id: &str,
    worker_id: &str,
    worker_session_ref: Option<String>,
    continuation: ContinuationMode,
    caused_by_event_id: Option<String>,
) -> Result<(WorkerAttempt, workers::AttemptCapture)> {
    let channel = ws.load_task_channel(&context.intent_id, &context.task_id)?;
    let attempt = if let Some(existing) = channel
        .attempts
        .into_iter()
        .find(|attempt| attempt.attempt_id == attempt_id)
    {
        if existing.state != AttemptState::Prepared
            || existing.worker_id != worker_id
            || existing.continuation != continuation
        {
            return Err(anyhow!("prepared attempt does not match invocation"));
        }
        existing
    } else {
        let attempt_dir = run_dir.join("attempts").join(attempt_id);
        let attempt = WorkerAttempt {
            schema_version: 1,
            attempt_id: attempt_id.to_string(),
            session_id: context.session_id.clone(),
            intent_id: context.intent_id.clone(),
            task_id: context.task_id.clone(),
            worker_id: worker_id.to_string(),
            worker_session_ref,
            state: AttemptState::Prepared,
            continuation,
            caused_by_event_id,
            caused_by_action_id: None,
            raw_stdout_ref: attempt_dir.join("stdout.log").display().to_string(),
            raw_stderr_ref: attempt_dir.join("stderr.log").display().to_string(),
        };
        ws.record_worker_attempt(&attempt)?;
        attempt
    };
    let prepared_exists = ws
        .load_task_channel(&context.intent_id, &context.task_id)?
        .events
        .iter()
        .any(|event| {
            event.event_type == ChannelEventType::AttemptPrepared
                && event.attempt_id.as_deref() == Some(attempt_id)
        });
    let prepared_event = if prepared_exists {
        ws.load_task_channel(&context.intent_id, &context.task_id)?
            .events
            .into_iter()
            .find(|event| {
                event.event_type == ChannelEventType::AttemptPrepared
                    && event.attempt_id.as_deref() == Some(attempt_id)
            })
            .expect("prepared event checked above")
    } else {
        record_channel_event(
            ws,
            lock,
            context,
            ChannelEventType::AttemptPrepared,
            EventActor {
                kind: EventActorKind::System,
                id: String::new(),
            },
            Some(attempt_id),
            attempt.caused_by_event_id.clone(),
            serde_json::json!({
                "worker_id": worker_id,
                "worker_session_ref": attempt.worker_session_ref,
                "continuation": continuation
            }),
            None,
        )?
    };
    let started_exists = ws
        .load_task_channel(&context.intent_id, &context.task_id)?
        .events
        .iter()
        .any(|event| {
            event.event_type == ChannelEventType::WorkerStarted
                && event.attempt_id.as_deref() == Some(attempt_id)
        });
    if !started_exists {
        record_channel_event(
            ws,
            lock,
            context,
            ChannelEventType::WorkerStarted,
            EventActor {
                kind: EventActorKind::Worker,
                id: worker_id.to_string(),
            },
            Some(attempt_id),
            Some(prepared_event.event_id),
            serde_json::json!({"worker_id": worker_id}),
            None,
        )?;
    }
    state::write_str_atomic(&run_dir.join("latest-attempt"), &format!("{attempt_id}\n"))?;
    let capture = workers::AttemptCapture {
        combined_log: run_dir.join("worker-output.log"),
        stdout_log: raw_attempt_path(ws, &attempt.raw_stdout_ref),
        stderr_log: raw_attempt_path(ws, &attempt.raw_stderr_ref),
    };
    Ok((attempt, capture))
}

fn worker_attempt_result(
    run_dir: &std::path::Path,
    outcome: &workers::WorkerOutcome,
) -> &'static str {
    if run_dir.join("cancelled").is_file() {
        return "cancelled";
    }
    if outcome.timed_out {
        return "timed_out";
    }
    if let Ok(raw) = std::fs::read_to_string(run_dir.join("result.json")) {
        if let Ok(result) = serde_json::from_str::<RunResult>(&raw) {
            return match result.status.as_str() {
                "needs_user" => "needs_user",
                "failed" => "failed",
                _ => "succeeded",
            };
        }
    }
    "failed"
}

pub(crate) fn finish_worker_attempt(
    ws: &Workspace,
    lock: Option<&PlanningLock>,
    context: &ChannelRunContext,
    run_dir: &std::path::Path,
    attempt: &WorkerAttempt,
    capture: &workers::AttemptCapture,
    outcome: &workers::WorkerOutcome,
) -> Result<()> {
    let mut channel = ws.load_task_channel(&context.intent_id, &context.task_id)?;
    let mut causation_id = channel
        .events
        .iter()
        .find(|event| {
            event.event_type == ChannelEventType::WorkerStarted
                && event.attempt_id.as_deref() == Some(&attempt.attempt_id)
        })
        .map(|event| event.event_id.clone());
    // A saturated live sink deliberately sheds normalized events so raw pipe
    // readers can keep draining. Replaying the same backlog synchronously here
    // would reintroduce the completion stall; exact stdout/stderr remain the
    // authoritative evidence for the shed tail.
    if !outcome.public_events_dropped {
        for (stream, path, artifact_id) in [
            (
                workers::RawStreamKind::Stdout,
                &capture.stdout_log,
                format!("raw_{}_stdout", attempt.attempt_id),
            ),
            (
                workers::RawStreamKind::Stderr,
                &capture.stderr_log,
                format!("raw_{}_stderr", attempt.attempt_id),
            ),
        ] {
            let raw = std::fs::read(path)
                .with_context(|| format!("reading attempt raw stream {}", path.display()))?;
            for normalized in
                workers::normalize_worker_output(&attempt.worker_id, stream, &raw, &artifact_id)
            {
                let existing = channel.events.iter().find(|event| {
                    event.attempt_id.as_deref() == Some(&attempt.attempt_id)
                        && event.event_type == normalized.event_type
                        && event.raw_ref.as_ref() == Some(&normalized.raw_ref)
                });
                let recorded = if let Some(existing) = existing {
                    if existing.payload != normalized.payload {
                        return Err(anyhow!(
                            "normalized raw event changed for {} at {}..{}",
                            normalized.raw_ref.artifact_id,
                            normalized.raw_ref.byte_start,
                            normalized.raw_ref.byte_end
                        ));
                    }
                    existing.clone()
                } else {
                    let recorded = record_channel_event(
                        ws,
                        lock,
                        context,
                        normalized.event_type,
                        EventActor {
                            kind: EventActorKind::Worker,
                            id: attempt.worker_id.clone(),
                        },
                        Some(&attempt.attempt_id),
                        causation_id,
                        normalized.payload,
                        Some(normalized.raw_ref),
                    )?;
                    channel.events.push(recorded.clone());
                    recorded
                };
                causation_id = Some(recorded.event_id);
            }
        }
    }
    if worker_attempt_result(run_dir, outcome) == "needs_user" {
        if let Ok(result) = std::fs::read_to_string(run_dir.join("result.json")) {
            if let Ok(result) = serde_json::from_str::<RunResult>(&result) {
                if let Some(question) = result
                    .question_for_user
                    .as_deref()
                    .map(str::trim)
                    .filter(|question| !question.is_empty())
                {
                    if let Some(asked) = record_result_question(
                        ws,
                        lock,
                        context,
                        run_dir,
                        question,
                        EventActorKind::Worker,
                    )? {
                        causation_id = Some(asked.event_id);
                    }
                }
            }
        }
    }
    if !channel.events.iter().any(|event| {
        event.event_type == ChannelEventType::WorkerCompleted
            && event.attempt_id.as_deref() == Some(&attempt.attempt_id)
    }) {
        record_channel_event(
            ws,
            lock,
            context,
            ChannelEventType::WorkerCompleted,
            EventActor {
                kind: EventActorKind::System,
                id: String::new(),
            },
            Some(&attempt.attempt_id),
            causation_id,
            serde_json::json!({
                "result": worker_attempt_result(run_dir, outcome),
                "exit_ok": outcome.exit_ok,
                "timed_out": outcome.timed_out,
                "worker_session_ref": outcome.session_id
            }),
            None,
        )?;
    }
    ws.load_or_rebuild_task_channel(&context.intent_id, &context.task_id)?;
    Ok(())
}

pub(crate) fn finish_worker_attempt_error(
    ws: &Workspace,
    context: &ChannelRunContext,
    attempt: &WorkerAttempt,
    error: &anyhow::Error,
) -> Result<()> {
    let channel = ws.load_task_channel(&context.intent_id, &context.task_id)?;
    if channel.events.iter().any(|event| {
        event.event_type == ChannelEventType::WorkerCompleted
            && event.attempt_id.as_deref() == Some(&attempt.attempt_id)
    }) {
        return Ok(());
    }
    let causation_id = channel
        .events
        .into_iter()
        .rev()
        .find(|event| event.attempt_id.as_deref() == Some(&attempt.attempt_id))
        .map(|event| event.event_id);
    record_channel_event(
        ws,
        None,
        context,
        ChannelEventType::WorkerCompleted,
        EventActor {
            kind: EventActorKind::System,
            id: String::new(),
        },
        Some(&attempt.attempt_id),
        causation_id,
        serde_json::json!({
            "result": "failed",
            "spawn_error": error.to_string(),
            "worker_session_ref": attempt.worker_session_ref
        }),
        None,
    )?;
    ws.load_or_rebuild_task_channel(&context.intent_id, &context.task_id)?;
    Ok(())
}

fn record_result_question(
    ws: &Workspace,
    lock: Option<&PlanningLock>,
    context: &ChannelRunContext,
    run_dir: &std::path::Path,
    question_text: &str,
    actor_kind: EventActorKind,
) -> Result<Option<ChannelEvent>> {
    let attempt_id = std::fs::read_to_string(run_dir.join("latest-attempt"))
        .with_context(|| format!("reading latest attempt for {}", context.task_id))?;
    let attempt_id = attempt_id.trim();
    let channel = ws.load_task_channel(&context.intent_id, &context.task_id)?;
    if channel
        .questions
        .iter()
        .any(|question| question.attempt_id == attempt_id && question.text == question_text)
    {
        return Ok(channel
            .events
            .iter()
            .find(|event| {
                event.event_type == ChannelEventType::QuestionAsked
                    && event.attempt_id.as_deref() == Some(attempt_id)
                    && event.payload["text"] == question_text
            })
            .cloned());
    }
    let question_id = format!("qst_{attempt_id}");
    let asked = if let Some(existing) = channel.events.iter().find(|event| {
        event.event_type == ChannelEventType::QuestionAsked
            && event.attempt_id.as_deref() == Some(attempt_id)
            && event.payload["question_id"] == question_id
    }) {
        if existing.payload["text"] != question_text {
            return Err(anyhow!("question event payload changed after persistence"));
        }
        existing.clone()
    } else {
        record_channel_event(
            ws,
            lock,
            context,
            ChannelEventType::QuestionAsked,
            EventActor {
                kind: actor_kind,
                id: if actor_kind == EventActorKind::Worker {
                    channel
                        .attempts
                        .iter()
                        .find(|attempt| attempt.attempt_id == attempt_id)
                        .map(|attempt| attempt.worker_id.clone())
                        .unwrap_or_else(|| "unknown".to_string())
                } else {
                    String::new()
                },
            },
            Some(attempt_id),
            channel.events.last().map(|event| event.event_id.clone()),
            serde_json::json!({"question_id": question_id, "text": question_text}),
            None,
        )?
    };
    let context_start_seq = asked.seq.saturating_sub(20).max(1);
    ws.record_question(&Question {
        schema_version: 1,
        question_id,
        session_id: context.session_id.clone(),
        task_id: context.task_id.clone(),
        attempt_id: attempt_id.to_string(),
        asked_event_id: asked.event_id.clone(),
        asked_seq: asked.seq,
        context_start_seq,
        text: question_text.to_string(),
        state: QuestionState::Open,
        answer_id: None,
    })?;
    ws.load_or_rebuild_task_channel(&context.intent_id, &context.task_id)?;
    Ok(Some(asked))
}

fn persist_needs_user_question(
    ws: &Workspace,
    lock: Option<&PlanningLock>,
    context: &ChannelRunContext,
    run_dir: &std::path::Path,
    question_text: &str,
    actor_kind: EventActorKind,
) -> Result<()> {
    let has_attempt = std::fs::read_to_string(run_dir.join("latest-attempt"))
        .ok()
        .is_some_and(|attempt| !attempt.trim().is_empty());
    if has_attempt {
        record_result_question(ws, lock, context, run_dir, question_text, actor_kind)?;
    } else {
        // Runs created before durable task channels have no attempt identity to
        // link a typed Question to. Preserve the same non-empty invariant via
        // the canonical legacy conversation path used by latest_question_for.
        let run_id = run_dir
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or_default();
        state::append_conversation_turn(
            ws,
            &context.task_id,
            ConversationTurn {
                role: TurnRole::Worker,
                text: question_text.to_string(),
                run_id: run_id.to_string(),
                ts: Local::now().to_rfc3339(),
            },
        )?;
    }
    Ok(())
}

pub(crate) fn action_attempt_id(action_id: &str) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in action_id.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("att-action-{hash:016x}")
}

fn explicit_continuation_packet(
    attempt_id: &str,
    caused_by_event_id: Option<&str>,
    caused_by_action_id: Option<&str>,
    public_context: &[(u64, String)],
    checkpoint: Option<&str>,
) -> String {
    const CONTEXT_LIMIT: usize = 20;
    let retained = public_context.len().saturating_sub(CONTEXT_LIMIT);
    let mut packet = format!(
        "Explicit continuation packet\n\
         continuation_attempt_id: {attempt_id}\n\
         caused_by_event_id: {}\n\
         caused_by_action_id: {}\n",
        caused_by_event_id.unwrap_or("none"),
        caused_by_action_id.unwrap_or("none")
    );
    if let Some(checkpoint) = checkpoint.filter(|value| !value.trim().is_empty()) {
        packet.push_str("\nCheckpoint:\n");
        packet.push_str(checkpoint.trim());
        packet.push('\n');
    }
    packet.push_str("\nBounded public channel context:\n");
    for (seq, text) in &public_context[retained..] {
        packet.push_str(&format!("[{seq}] {}\n", text.trim()));
    }
    packet
}

fn public_channel_context(channel: &crate::schemas::TaskChannel) -> Vec<(u64, String)> {
    channel
        .events
        .iter()
        .filter_map(|event| {
            let text = match event.event_type {
                ChannelEventType::WorkerMessage
                | ChannelEventType::QuestionAsked
                | ChannelEventType::UserAnswered => event
                    .payload
                    .get("text")
                    .and_then(|value| value.as_str())
                    .map(str::to_string),
                ChannelEventType::ToolStarted | ChannelEventType::ToolCompleted => Some(format!(
                    "{}: {}",
                    event.event_type.as_str(),
                    event
                        .payload
                        .get("name")
                        .or_else(|| event.payload.get("command"))
                        .and_then(|value| value.as_str())
                        .unwrap_or("tool")
                )),
                ChannelEventType::WorkerCheckpoint => Some("worker.checkpoint".to_string()),
                ChannelEventType::WorkerCompleted => Some(format!(
                    "worker.completed: {}",
                    event
                        .payload
                        .get("result")
                        .and_then(|value| value.as_str())
                        .unwrap_or("unknown")
                )),
                _ => None,
            }?;
            (!text.trim().is_empty()).then_some((event.seq, text))
        })
        .collect()
}

/// Bind a UI or CLI reply to the exact open channel question before `run_next`
/// appends the legacy conversation turn. Legacy channels remain additive and
/// simply return `false`.
pub(crate) fn prepare_answer_action(
    ws: &Workspace,
    task_id: &str,
    reply: &str,
    requested_action_id: Option<String>,
) -> Result<bool> {
    let queue = ws.load_queue()?;
    if queue.intent_id.is_empty() {
        return Ok(false);
    }
    let channel = ws.load_task_channel(&queue.intent_id, task_id)?;
    let Some(question) = channel
        .questions
        .iter()
        .rev()
        .find(|question| question.state == QuestionState::Open)
    else {
        if channel.questions.is_empty() {
            return Ok(false);
        }
        bail!("question_closed: task {task_id} has no actionable open question");
    };
    let producer = channel
        .attempts
        .iter()
        .find(|attempt| attempt.attempt_id == question.attempt_id)
        .ok_or_else(|| anyhow!("question producer attempt is missing"))?;
    let action_id = requested_action_id.unwrap_or_else(|| {
        format!(
            "act-answer-{}-{}",
            chrono::Utc::now().format("%Y%m%d%H%M%S%6f"),
            std::process::id()
        )
    });
    let task = queue
        .tasks
        .iter()
        .find(|task| task.id == task_id)
        .ok_or_else(|| anyhow!("task {task_id} not found in queue"))?;
    let workers_file = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let selected = routing::resolve_worker_for_task(ws, &workers_file, &billing, None, task)?;
    let same_worker = selected.worker_id == producer.worker_id;
    ws.answer_question(&AnswerActionRequest {
        continuation_attempt_id: action_attempt_id(&action_id),
        answer_id: format!("ans-{}", action_attempt_id(&action_id)),
        action_id,
        session_id: channel.session_id.clone(),
        intent_id: queue.intent_id,
        task_id: task_id.to_string(),
        question_id: question.question_id.clone(),
        text: reply.to_string(),
        worker_id: selected.worker_id.clone(),
        worker_session_ref: same_worker
            .then(|| producer.worker_session_ref.clone())
            .flatten(),
        supports_native_resume: same_worker && workers::supports_native_resume(&selected.worker_id),
    })?;
    Ok(true)
}

pub fn run_next(ws: &Workspace, opts: &RunOptions) -> Result<RunReport> {
    // Serialize queue selection and the first runtime transition against a
    // planning confirmation. Once Running is canonical, confirm observes it
    // and fails closed; the worker itself never holds this lock.
    let planning_lock = ws.acquire_planning_lock()?;
    let mut queue = ws.load_queue()?;
    let workers = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let intent = ws.load_intent()?;
    let config = ws.load_config()?;

    // V010-002 activation gate. Legacy queues remain compatible, but once any
    // confirmation provenance is present every contract predicate is required.
    // Missing or contradictory linkage is visible state, never runnable work.
    crate::planning::validate_active_activation(ws)?;

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
    let mut task = queue.tasks[idx].clone();

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
                    migrate_stale_gate_to_decision(
                        ws,
                        &planning_lock,
                        &mut queue,
                        &task,
                        &unsatisfiable,
                    )?;
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
                    save_task_state_on_latest_queue_locked(
                        ws,
                        &planning_lock,
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
    let prepared_answer_attempt = ws
        .load_task_channel(&queue.intent_id, &task.id)
        .ok()
        .and_then(|channel| {
            channel.attempts.into_iter().rev().find(|attempt| {
                attempt.state == AttemptState::Prepared
                    && matches!(
                        attempt.continuation,
                        ContinuationMode::NativeResume
                            | ContinuationMode::ExplicitPacket
                            | ContinuationMode::Redirect
                    )
            })
        });
    #[cfg(debug_assertions)]
    if prepared_answer_attempt
        .as_ref()
        .is_some_and(|attempt| attempt.continuation == ContinuationMode::Redirect)
        && std::env::var("YARDLET_TEST_CRASH_AFTER_REDIRECT_RECEIPT").as_deref() == Ok("1")
    {
        bail!("injected crash after redirect receipt and before continuation spawn");
    }
    // Re-running a Partial task uses its checkpoint. An answer/redirect that
    // cannot honestly resume a native provider session receives a bounded,
    // causally explicit packet instead of an unbounded transcript.
    let continuation = if let Some(attempt) = prepared_answer_attempt.as_ref().filter(|attempt| {
        matches!(
            attempt.continuation,
            ContinuationMode::ExplicitPacket | ContinuationMode::Redirect
        )
    }) {
        let channel = ws.load_task_channel(&queue.intent_id, &task.id)?;
        let context = public_channel_context(&channel);
        Some(explicit_continuation_packet(
            &attempt.attempt_id,
            attempt.caused_by_event_id.as_deref(),
            attempt.caused_by_action_id.as_deref(),
            &context,
            continuation_context(ws, &task.id).as_deref(),
        ))
    } else if task.state == TaskState::Partial {
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
    let resolved_selection = resolved.as_ref().ok().map(|resolved| resolved.selection());
    // Keep the confirmed/runtime-added contract as the failover policy input.
    // The in-flight task below is stamped with the first effective selection
    // for packet/receipt parity; resolving failover from that stamped copy
    // would incorrectly pin an `auto` task to the first worker's model and
    // provenance instead of producing a fresh policy-authorized selection.
    let failover_task = task.clone();
    if opts.execute {
        if let Some(selection) = resolved_selection
            .as_ref()
            .filter(|selection| !selection.model.trim().is_empty())
        {
            apply_selection_to_task(&mut task, selection);
        }
    }

    // ---- run directory ---------------------------------------------------
    let base_run_id = format!(
        "run-{}-{}",
        Local::now().format("%Y%m%d-%H%M%S%9f"),
        std::process::id()
    );
    let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let serial_worktree = if opts.execute {
        Some(prepare_serial_worktree(ws, &run_dir, &run_id, &task.id)?)
    } else {
        None
    };
    let mut serial_cleanup = SerialWorktreeErrorCleanup::new(ws, serial_worktree.as_ref());
    let worker_run_dir = serial_worktree
        .as_ref()
        .map(|owned| owned.worker_run_dir.as_path())
        .unwrap_or(run_dir.as_path());
    let run_dir_rel = if serial_worktree.is_some() {
        worker_run_dir.display().to_string()
    } else {
        format!(".agents/runs/{run_id}")
    };

    let mut lines = Vec::new();
    lines.push(format!("selected task {} ({})", task.id, task.title));
    if let Some(rat) = &task.worker_rationale {
        lines.push(format!("planner rationale: {rat}"));
    }
    lines.push(format!("run dir: {run_dir_rel}"));

    // ---- deterministic evidence -----------------------------------------
    let summary = inspect::summarize(&ws.root);
    let summary_markdown = inspect::to_markdown(&summary);
    write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &summary_markdown,
    )?;
    if serial_worktree.is_some() {
        write_str(
            &worker_run_dir.join("evidence").join("repo-summary.md"),
            &summary_markdown,
        )?;
    }

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
        model: resolved_selection
            .as_ref()
            .map(|selection| selection.model.clone())
            .unwrap_or_default(),
        fallback_enabled: resolved_selection
            .as_ref()
            .is_some_and(|selection| selection.fallback_enabled),
        routing_provenance: resolved_selection
            .as_ref()
            .map(|selection| selection.routing_provenance.clone()),
        state: if opts.execute { "running" } else { "prepared" }.to_string(),
        started_at: Local::now().to_rfc3339(),
        completed_at: None,
        worktree: serial_worktree
            .as_ref()
            .map(|owned| owned.path.display().to_string())
            .unwrap_or_else(|| ".".to_string()),
        serial_isolated: serial_worktree.is_some(),
        baseline_oid: serial_worktree
            .as_ref()
            .map(|owned| owned.baseline_oid.clone())
            .unwrap_or_default(),
        worktree_branch: serial_worktree
            .as_ref()
            .map(|owned| owned.branch.clone())
            .unwrap_or_default(),
        integration_oid: String::new(),
        integration_base_oid: String::new(),
        integration_worker_oid: String::new(),
        integration_provenance: if serial_worktree.is_some() {
            IntegrationProvenance::SerialCoreStaged
        } else {
            IntegrationProvenance::Unknown
        },
        integration_cleanup_complete: false,
        owned_oids: Vec::new(),
    };
    state::save_yaml_atomic(&run_dir.join("run.yaml"), &record)?;
    if serial_worktree.is_some() {
        state::save_yaml_atomic(&worker_run_dir.join("run.yaml"), &record)?;
        write_str(&workers::packet_path(worker_run_dir), &packet_text)?;
    }

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
    let mut active_selection = resolved.selection();
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
        ws.save_queue_locked(&planning_lock, &queue)?;
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
        cleanup_cancelled_serial_worktree(ws, serial_worktree.as_ref());
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
    ws.save_queue_locked(&planning_lock, &queue)?;
    drop(planning_lock);
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
    // generates its own, captured from that child's JSONL stdout.
    let mut effective_chained = chained;
    let mut session_id: Option<String> = if chained {
        opts.chain.as_ref().map(|c| c.session.clone())
    } else if active_worker_id == "claude-code" {
        Some(gen_session_uuid(&run_id))
    } else {
        None
    };
    let channel_context = channel_run_context(ws, &queue.intent_id, &task.id);
    if let Some(attempt) = &prepared_answer_attempt {
        if attempt.continuation == ContinuationMode::NativeResume {
            session_id = attempt.worker_session_ref.clone();
            effective_chained = true;
        } else {
            effective_chained = false;
        }
    }
    // Snapshot the workspace before the worker runs so the evaluator can diff
    // against ACTUAL on-disk changes, not the worker's self-report. Git
    // workspaces use `git status`; non-git workspaces use a bounded folder scan.
    // The current run dir is excluded so Yardlet's own result/handoff artifacts
    // are not attributed as worker deliverables.
    let run_excludes = vec![run_dir.clone()];
    let baseline_fp = evaluator::run_fingerprints(&ws.root, &run_excludes);
    let worker_cwd = serial_worktree
        .as_ref()
        .map(|owned| owned.path.as_path())
        .unwrap_or(ws.root.as_path());
    let run_started = std::time::Instant::now();
    let mut attempt_ordinal = 1_u32;
    let first_attempt_id = prepared_answer_attempt
        .as_ref()
        .map(|attempt| attempt.attempt_id.clone())
        .unwrap_or_else(|| attempt_id_for_ordinal(&run_id, attempt_ordinal));
    let first_continuation = prepared_answer_attempt
        .as_ref()
        .map(|attempt| attempt.continuation)
        .unwrap_or_else(|| {
            if chained {
                ContinuationMode::NativeResume
            } else {
                ContinuationMode::Fresh
            }
        });
    let (mut current_attempt, mut current_capture) = begin_worker_attempt(
        ws,
        None,
        &channel_context,
        &run_dir,
        &first_attempt_id,
        &active_worker_id,
        session_id.clone(),
        first_continuation,
        None,
    )?;
    let mut outcome = match workers::spawn_resolved_attempt_with_sink(
        &eff_profile,
        &active_selection,
        &active_bin,
        &packet_text,
        worker_run_dir,
        worker_cwd,
        &env,
        &current_capture,
        Some(live_worker_event_sink(
            ws,
            &channel_context,
            &current_attempt,
        )),
        timeout,
        full_access,
        &images,
        session_id.as_deref(),
        effective_chained,
    ) {
        Ok(outcome) => outcome,
        Err(error) => {
            finish_worker_attempt_error(ws, &channel_context, &current_attempt, &error)?;
            return Err(error);
        }
    };
    // From this point the worktree may contain completed or partially completed
    // worker work. Any import/finalization error must retain it for recovery;
    // the guard is only for failures before a worker actually ran.
    serial_cleanup.disarm();
    import_worker_run_artifacts(worker_run_dir, &run_dir)?;
    finish_worker_attempt(
        ws,
        None,
        &channel_context,
        &run_dir,
        &current_attempt,
        &current_capture,
        &outcome,
    )?;
    if active_worker_id == "codex" && session_id.is_none() {
        session_id = outcome.session_id.clone();
        if session_id.is_none() {
            lines.push(
                "codex session id missing from child stdout; retry and hot-chain disabled"
                    .to_string(),
            );
        }
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
        attempt_ordinal += 1;
        let attempt_id = attempt_id_for_ordinal(&run_id, attempt_ordinal);
        let begun = begin_worker_attempt(
            ws,
            None,
            &channel_context,
            &run_dir,
            &attempt_id,
            &active_worker_id,
            session_id.clone(),
            ContinuationMode::NativeResume,
            None,
        )?;
        current_attempt = begun.0;
        current_capture = begun.1;
        outcome = match workers::spawn_resolved_attempt_with_sink(
            &eff_profile,
            &active_selection,
            &active_bin,
            cont,
            worker_run_dir,
            worker_cwd,
            &env,
            &current_capture,
            Some(live_worker_event_sink(
                ws,
                &channel_context,
                &current_attempt,
            )),
            timeout,
            full_access,
            &images,
            session_id.as_deref(),
            true,
        ) {
            Ok(outcome) => outcome,
            Err(error) => {
                finish_worker_attempt_error(ws, &channel_context, &current_attempt, &error)?;
                return Err(error);
            }
        };
        import_worker_run_artifacts(worker_run_dir, &run_dir)?;
        finish_worker_attempt(
            ws,
            None,
            &channel_context,
            &run_dir,
            &current_attempt,
            &current_capture,
            &outcome,
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
        cleanup_cancelled_serial_worktree(ws, serial_worktree.as_ref());
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
            &failover_task,
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
                active_selection = alt.selection();
                active_reason = format!("failover from {from} ({})", alt.reason);
                active_bin = alt.bin;
                let profile = find_worker(&workers.workers, &active_worker_id)?;
                eff_profile = workers::effective_profile(
                    profile,
                    &failover_task.model,
                    &failover_task.effort,
                );
                update_run_selection(&run_dir, &active_selection)?;
                if worker_run_dir != run_dir.as_path() {
                    update_run_selection(worker_run_dir, &active_selection)?;
                }
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
                    continuation: Some(
                        "Output-contract feedback: the previous worker exited without writing \
                         result.json. Complete the task, write every required artifact, and make \
                         sure result.json matches the packet schema exactly.",
                    ),
                    chained_from: None,
                    language: &language,
                    images: &images,
                    role_notes: &role_notes,
                    harness: &harness,
                    approved,
                });
                write_str(&workers::packet_path(&run_dir), &failover_packet)?;
                attempt_ordinal += 1;
                let attempt_id = attempt_id_for_ordinal(&run_id, attempt_ordinal);
                let begun = begin_worker_attempt(
                    ws,
                    None,
                    &channel_context,
                    &run_dir,
                    &attempt_id,
                    &active_worker_id,
                    session_id.clone(),
                    ContinuationMode::Fallback,
                    None,
                )?;
                current_attempt = begun.0;
                current_capture = begun.1;
                outcome = match workers::spawn_resolved_attempt_with_sink(
                    &eff_profile,
                    &active_selection,
                    &active_bin,
                    &failover_packet,
                    worker_run_dir,
                    worker_cwd,
                    &env,
                    &current_capture,
                    Some(live_worker_event_sink(
                        ws,
                        &channel_context,
                        &current_attempt,
                    )),
                    timeout,
                    full_access,
                    &images,
                    session_id.as_deref(),
                    false,
                ) {
                    Ok(outcome) => outcome,
                    Err(error) => {
                        finish_worker_attempt_error(
                            ws,
                            &channel_context,
                            &current_attempt,
                            &error,
                        )?;
                        return Err(error);
                    }
                };
                import_worker_run_artifacts(worker_run_dir, &run_dir)?;
                finish_worker_attempt(
                    ws,
                    None,
                    &channel_context,
                    &run_dir,
                    &current_attempt,
                    &current_capture,
                    &outcome,
                )?;
                if active_worker_id == "codex" && session_id.is_none() {
                    session_id = outcome.session_id.clone();
                    if session_id.is_none() {
                        lines.push(
                            "codex session id missing from child stdout; retry and hot-chain disabled"
                                .to_string(),
                        );
                    }
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
        cleanup_cancelled_serial_worktree(ws, serial_worktree.as_ref());
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
    let serial_evidence = serial_worktree
        .as_ref()
        .and_then(|owned| serial_worktree_evidence(&owned.path, &run_dir));
    if let (Some(owned), Some(serial_evidence)) = (&serial_worktree, &serial_evidence) {
        remove_unchanged_seeded_harness_copies(&owned.path, serial_evidence)?;
    }
    let evidence: Option<Vec<String>> = if serial_worktree.is_some() {
        serial_evidence
            .as_ref()
            .map(|evidence| evidence.paths.clone())
    } else {
        match (
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
        }
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
        worker_id: &active_worker_id,
        reason: &active_reason,
        wall_seconds,
        user_override,
        intent_summary,
        billing: &billing,
        queue: &mut queue,
        flags: FinalizeFlags::serial(),
        merge: serial_worktree.as_ref().map(|owned| MergeBack {
            wt_path: &owned.path,
            branch: &owned.branch,
            baseline_oid: &owned.baseline_oid,
            expected_tip_oid: serial_evidence
                .as_ref()
                .map(|evidence| evidence.merge_target_oid.as_str()),
            provenance: IntegrationProvenance::SerialCoreStaged,
            auto_commit: config.auto_commit,
        }),
    })?;
    let next_state = report.next_state;
    lines.extend(report.lines);
    if let Some(note) = &failover_note {
        append_failover_note(&run_dir, note)?;
    }

    serial_cleanup.disarm();
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
fn worker_changed_integratable_path(evidence: Option<&[String]>) -> bool {
    evidence
        .map(|e| e.iter().any(|p| evaluator::is_integratable_path(p)))
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
/// human). The persisted feedback ledger prevents looping on a task that keeps
/// coming back partial, including across restarts. `bypass` drops the worker sandbox for the whole run
/// (workers still self-gate dangerous actions per the packet).
#[allow(clippy::too_many_arguments)]
/// A held decision is local to its dependency branch. Auto-drain may keep
/// selecting other ready work; only a hard block or an actually running task
/// ends the current drain loop.
fn continues_auto_drain(state: TaskState) -> bool {
    !matches!(state, TaskState::Blocked | TaskState::Running)
}

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
    let event_lang = run_event_lang(ws);
    let mut parallel_warned = false;
    let mut out = Vec::new();
    let mut emit = |s: String| {
        on_event(&s);
        out.push(s);
    };
    let mut waits: HashMap<String, u32> = HashMap::new();
    // P1: the previous Done task's live session, offered to a dependent
    // successor on the same worker. Cut on anything but a clean Done.
    let mut chain: Option<ChainHandle> = None;
    // Recover orphans (interrupted runs left "running") and any unconsumed
    // planning result from an interrupted session before draining.
    crate::planning::validate_active_activation(ws)?;
    if let Some(m) = crate::planner::recover_unconsumed_plan(ws)? {
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
        // by the task's persisted feedback cap, instead of halting the drain.
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
        emit(task_state_progress_line(event_lang, &report.task_id, state));
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
                if continues_auto_drain(state) {
                    continue;
                }
                break;
            }
            TaskState::Partial => {
                // Loop back: the conflict check halts, a self-report continues
                // from its checkpoint, and the feedback ledger bounds it all.
                emit(format!(
                    "{} is partial \u{2014} continuing from its checkpoint",
                    report.task_id
                ));
                continue;
            }
            TaskState::Failed => {
                // Likely transient (e.g. a dropped connection); loop to retry it,
                // bounded by the persisted feedback cap.
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
    let eligible = |t: &crate::schemas::Task| {
        queue.is_runnable_now(t, approved(&t.id), cap_vocab)
            && !(pol.skip_if_blocked && t.state == TaskState::Blocked)
            && !(pol.skip_if_approval_required && t.approval_required() && !approved(&t.id))
    };
    // A final verifier must observe all runnable work that can change the
    // workspace or propose an implementation follow-up. Keep this as a soft
    // scheduling barrier: once other work is no longer runnable (failed,
    // deferred, blocked, or gated), the review remains selectable and cannot
    // deadlock behind a hard dependency.
    let work_ready = queue.tasks.iter().any(|t| {
        eligible(t) && !matches!(crate::packet::role_for(&t.kind), "reviewer" | "security")
    });
    let mut best: Option<usize> = None;
    for (i, t) in queue.tasks.iter().enumerate() {
        let remediation_pending =
            matches!(crate::packet::role_for(&t.kind), "reviewer" | "security")
                && queue.has_active_remediation_for(&t.id);
        if !eligible(t)
            || remediation_pending
            || (work_ready && matches!(crate::packet::role_for(&t.kind), "reviewer" | "security"))
        {
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
    lock: &PlanningLock,
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
        let task_id = t.id.clone();
        let to = t.state;
        ws.save_queue_locked(lock, &latest)?;
        state::append_conversation_turn(
            ws,
            &task_id,
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
                &task_id,
                from,
                to,
                TransitionCause::StaleMigration,
                &detail,
                TransitionActor::System,
            ),
        )?;
        *queue = latest;
    }
    Ok(())
}

/// The newest run directory recorded for a task id, as (run_id, dir). Compare
/// the typed start time and filesystem timestamp rather than the directory name:
/// claim suffixes such as `-10` do not sort correctly against `-9`.
pub(crate) fn latest_run_for(ws: &Workspace, task_id: &str) -> Option<(String, PathBuf)> {
    let mut best: Option<(String, std::time::SystemTime, String, PathBuf)> = None;
    for entry in std::fs::read_dir(ws.runs_dir()).ok()?.flatten() {
        let dir = entry.path();
        let Some(name) = dir.file_name().and_then(|n| n.to_str()).map(String::from) else {
            continue;
        };
        if !name.starts_with("run-") {
            continue;
        }
        let Ok(record) = state::load_yaml::<RunRecord>(&dir.join("run.yaml")) else {
            continue;
        };
        if record.task_id != task_id {
            continue;
        }
        let modified = std::fs::metadata(dir.join("run.yaml"))
            .and_then(|metadata| metadata.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        let replace = best
            .as_ref()
            .map(|(started, prior_modified, prior_name, _)| {
                (record.started_at.as_str(), modified, name.as_str())
                    > (started.as_str(), *prior_modified, prior_name.as_str())
            })
            .unwrap_or(true);
        if replace {
            best = Some((record.started_at, modified, name, dir));
        }
    }
    best.map(|(_, _, name, dir)| (name, dir))
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

/// A transient (likely network/infra) failure: the worker did not exit cleanly,
/// left no result, and was not stopped by us — worth resuming rather than redoing.
fn is_transient_failure(outcome: &workers::WorkerOutcome, run_dir: &std::path::Path) -> bool {
    !outcome.exit_ok && !outcome.timed_out && !run_dir.join("result.json").exists()
}

/// Validation commands configured on a task: `validation: { commands: [..] }`
/// or a bare sequence. Yardlet runs these itself (a worker's self-reported
/// validation is advisory, not the gate).
fn validation_commands(task: &crate::schemas::Task) -> Vec<String> {
    if !task.has_validation() {
        return Vec::new();
    }
    let v = task
        .validation
        .as_ref()
        .expect("has_validation guarantees validation is present");
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

pub(crate) fn verified_worker_pid_for_redirect(
    run_dir: &std::path::Path,
    expected_task_id: &str,
    expected_attempt_id: &str,
    expected_worker_id: &str,
) -> Result<u32> {
    let record: RunRecord =
        state::load_yaml(&run_dir.join("run.yaml")).context("loading redirect run identity")?;
    let path_run_id = run_dir
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("redirect run directory has no valid identity"))?;
    if record.run_id != path_run_id
        || record.task_id != expected_task_id
        || record.completed_at.is_some()
        || record.state != "running"
    {
        bail!("redirect run identity/provenance mismatch; refusing to signal a process");
    }

    let provenance = workers::load_worker_process_provenance(run_dir)
        .context("worker process provenance is missing or invalid; refusing redirect signal")?;
    if provenance.schema_version != 1
        || provenance.run_id != record.run_id
        || provenance.attempt_id != expected_attempt_id
        || provenance.worker_id != expected_worker_id
        || provenance.pid == 0
    {
        bail!(
            "worker process provenance does not match the active attempt; refusing redirect signal"
        );
    }
    let observed_start = workers::process_start_marker(provenance.pid)
        .ok_or_else(|| anyhow!("verified worker process is no longer alive"))?;
    if observed_start != provenance.process_start_marker {
        bail!("worker process identity changed since spawn; refusing redirect signal");
    }
    Ok(provenance.pid)
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

#[derive(Debug)]
struct PendingGitFinish {
    run_id: String,
    task_id: String,
    run_dir: PathBuf,
    target: (String, String),
    integration_order: usize,
    started_at: String,
}

/// Find every integration whose Git-finish or run projection still needs
/// recovery for the live intent, then order each remote target by the
/// workspace's first-parent integration history. This deliberately scans runs
/// rather than tasks: multiple non-Done runs may own distinct accumulated
/// commits even when they share a task id.
fn pending_git_finishes(ws: &Workspace, queue: &WorkQueue) -> Vec<PendingGitFinish> {
    let config_policy = ws.load_config().ok().map(|config| config.git_finish);
    let latest_done_runs = queue
        .tasks
        .iter()
        .filter(|task| task.state == TaskState::Done)
        .filter_map(|task| {
            latest_run_for(ws, &task.id).map(|(_, run_dir)| (task.id.clone(), run_dir))
        })
        .collect::<HashMap<_, _>>();
    let positions = std::process::Command::new("git")
        .arg("-C")
        .arg(&ws.root)
        .args(["rev-list", "--first-parent", "--reverse", "HEAD"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .enumerate()
                .map(|(index, oid)| (oid.trim().to_string(), index))
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default();
    let mut pending = Vec::new();
    let Ok(entries) = std::fs::read_dir(ws.runs_dir()) else {
        return pending;
    };
    for entry in entries.flatten() {
        let run_dir = entry.path();
        let Ok(run) = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")) else {
            continue;
        };
        let Some(task_state) = queue
            .tasks
            .iter()
            .find(|task| task.id == run.task_id)
            .map(|task| task.state)
        else {
            continue;
        };
        if run.intent_id != queue.intent_id || !run_dir.join("result.json").exists() {
            continue;
        }
        let finish = ws.load_git_finish_record(&run_dir).ok();
        // The live queue is authoritative for task completion, so Done tasks
        // skip historical and unverified runs. The one exception is their
        // latest run after a verified external finish when the run projection
        // is still stale. Recovery may re-seal that run without pushing again.
        let repairs_done_projection = task_state == TaskState::Done
            && latest_done_runs
                .get(&run.task_id)
                .is_some_and(|latest| latest == &run_dir)
            && finish
                .as_ref()
                .is_some_and(|record| record.status.verified_complete())
            && (run.state != "done" || run.completed_at.is_none());
        if task_state == TaskState::Done && !repairs_done_projection {
            continue;
        }
        let (auto_push, remote, target_ref, expected_oid) = match finish.as_ref() {
            Some(record) => (
                record.policy.auto_push,
                record.policy.remote.clone(),
                record.policy.target_ref.clone(),
                record.expected_oid.clone().unwrap_or_default(),
            ),
            None => {
                let Some(policy) = config_policy.as_ref() else {
                    continue;
                };
                (
                    policy.auto_push,
                    policy.remote.clone(),
                    policy.target_ref.clone(),
                    run.integration_oid.clone(),
                )
            }
        };
        if !auto_push || expected_oid.is_empty() {
            continue;
        }
        pending.push(PendingGitFinish {
            run_id: run.run_id,
            task_id: run.task_id,
            run_dir,
            target: (remote, target_ref),
            integration_order: positions.get(&expected_oid).copied().unwrap_or(usize::MAX),
            started_at: run.started_at,
        });
    }
    pending.sort_by(|a, b| {
        a.target
            .cmp(&b.target)
            .then(a.integration_order.cmp(&b.integration_order))
            .then(a.started_at.cmp(&b.started_at))
            .then(a.run_id.cmp(&b.run_id))
    });
    pending
}

fn recover_pending_git_finishes(
    ws: &Workspace,
    queue: &mut WorkQueue,
    billing: &crate::schemas::BillingPolicy,
    event_lang: Lang,
    msgs: &mut Vec<String>,
    finished: &mut Vec<String>,
) -> HashSet<String> {
    let candidates = pending_git_finishes(ws, queue);
    let mut attempted = HashSet::new();
    let mut halted_targets = BTreeMap::<(String, String), String>::new();
    for candidate in candidates {
        if halted_targets.contains_key(&candidate.target) {
            continue;
        }
        let Some(task) = queue
            .tasks
            .iter()
            .find(|task| task.id == candidate.task_id)
            .cloned()
        else {
            continue;
        };
        attempted.insert(candidate.run_id.clone());
        let evidence = evaluator::changed_paths(&ws.root).map(|paths| {
            paths
                .into_iter()
                .filter(|path| !evaluator::is_canonical_state_path(path))
                .collect()
        });
        let worker = run_worker(&candidate.run_dir).unwrap_or_default();
        let flags = if task.state == TaskState::Done {
            FinalizeFlags::done_projection_recovery()
        } else {
            FinalizeFlags::recovery()
        };
        match finalize_run(FinalizeInput {
            ws,
            run_dir: &candidate.run_dir,
            run_id: &candidate.run_id,
            task: &task,
            evidence,
            worker_id: &worker,
            reason: "git_finish_recovery",
            wall_seconds: 0,
            user_override: None,
            intent_summary: "",
            billing,
            queue,
            flags,
            merge: None,
        }) {
            Ok(report) if report.next_state == TaskState::Done => {
                for line in report.lines {
                    if line.starts_with(&format!("{}: ", candidate.task_id))
                        || line.starts_with("git finish:")
                    {
                        msgs.push(format!("{}: {line}", candidate.task_id));
                    }
                }
                finished.push(task_state_progress_line(
                    event_lang,
                    &candidate.task_id,
                    report.next_state,
                ));
            }
            Ok(report) => {
                halted_targets.insert(candidate.target, candidate.run_id);
                msgs.push(format!(
                    "{}: Git finish recovery stopped at {}",
                    candidate.task_id,
                    run_outcome_label(report.next_state)
                ));
            }
            Err(error) => {
                halted_targets.insert(candidate.target, candidate.run_id);
                msgs.push(format!(
                    "{}: Git finish recovery error: {error}",
                    candidate.task_id
                ));
            }
        }
    }
    attempted
}

fn import_completed_serial_staging(ws: &Workspace) {
    let Ok(entries) = std::fs::read_dir(ws.runs_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        let run_dir = entry.path();
        if live_worker_pid(&run_dir).is_some() {
            continue;
        }
        let Ok(record) = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")) else {
            continue;
        };
        if !record.serial_isolated || record.worktree.is_empty() || record.worktree == "." {
            continue;
        }
        let staged = PathBuf::from(&record.worktree)
            .join(crate::state::STATE_DIR)
            .join("runs")
            .join(&record.run_id);
        if staged.join("result.json").is_file() {
            let _ = import_worker_run_artifacts(&staged, &run_dir);
        }
    }
}

fn registered_recovery_worktree_matches(
    ws: &Workspace,
    worktree: &std::path::Path,
    branch: &str,
    run_id: &str,
    task_id: &str,
    allow_serial_transaction: bool,
) -> bool {
    let expected = ws.agents_dir().join("worktrees").join(run_id);
    let expected_branch = format!("yard/{}/{}", task_id.to_lowercase(), run_id);
    if worktree != expected || branch != expected_branch {
        return false;
    }
    let Ok(metadata) = std::fs::symlink_metadata(worktree) else {
        return false;
    };
    if !metadata.is_dir() || metadata.file_type().is_symlink() {
        return false;
    }
    let Some(actual) = std::fs::canonicalize(worktree).ok() else {
        return false;
    };
    let Some(owned_root) = std::fs::canonicalize(ws.agents_dir().join("worktrees")).ok() else {
        return false;
    };
    if actual != owned_root.join(run_id) {
        return false;
    }
    let Ok(listed) = git_stdout(&ws.root, &["worktree", "list", "--porcelain"]) else {
        return false;
    };
    // Git reports canonical worktree paths (for example `/private/var` on
    // macOS even when the caller used `/var`), so compare against the already
    // validated canonical owned path rather than its lexical spelling.
    let expected_path = actual.display().to_string();
    let expected_ref = format!("refs/heads/{branch}");
    let expected_transaction_ref = format!("refs/heads/yardlet-txn/{branch}");
    listed.split("\n\n").any(|entry| {
        let mut path_matches = false;
        let mut branch_matches = false;
        for line in entry.lines() {
            path_matches |= line
                .strip_prefix("worktree ")
                .is_some_and(|path| path == expected_path);
            branch_matches |= line.strip_prefix("branch ").is_some_and(|reference| {
                reference == expected_ref
                    || (allow_serial_transaction && reference == expected_transaction_ref)
            });
        }
        path_matches && branch_matches
    })
}

fn recovery_integration_provenance(
    ws: &Workspace,
    record: Option<&RunRecord>,
    run_id: &str,
    task_id: &str,
    worktree: &std::path::Path,
    branch: &str,
) -> IntegrationProvenance {
    if ws
        .checkpoints_dir()
        .join("no-change")
        .join(format!("{run_id}.yaml"))
        .exists()
    {
        return IntegrationProvenance::Unknown;
    }
    let Some(record) = record else {
        return IntegrationProvenance::Unknown;
    };
    if record.run_id != run_id
        || record.task_id != task_id
        || record.worktree != worktree.display().to_string()
        || (!record.worktree_branch.is_empty() && record.worktree_branch != branch)
    {
        return IntegrationProvenance::Unknown;
    }
    let receipt = ws.load_serial_integration_receipt(run_id).ok();
    match (
        record.serial_isolated,
        record.integration_provenance,
        receipt,
    ) {
        (true, IntegrationProvenance::SerialCoreStaged, Some(receipt))
            if receipt.schema_version == 1
                && receipt.run_id == run_id
                && receipt.task_id == task_id
                && receipt.worktree == worktree.display().to_string()
                && receipt.branch == branch
                && receipt.baseline_oid == record.baseline_oid
                && worktree.file_name().and_then(|name| name.to_str()) == Some(run_id)
                && registered_recovery_worktree_matches(
                    ws, worktree, branch, run_id, task_id, true,
                ) =>
        {
            IntegrationProvenance::SerialCoreStaged
        }
        (
            false,
            IntegrationProvenance::ParallelWorkerDirect | IntegrationProvenance::Unknown,
            None,
        ) if registered_recovery_worktree_matches(ws, worktree, branch, run_id, task_id, false) => {
            IntegrationProvenance::ParallelWorkerDirect
        }
        _ => IntegrationProvenance::Unknown,
    }
}

fn validate_integrated_cleanup_identity(
    ws: &Workspace,
    receipt: &state::IntegratedCleanupReceipt,
) -> Result<(PathBuf, String, IntegrationProvenance)> {
    if receipt.schema_version != 1
        || receipt.run_id.is_empty()
        || receipt.task_id.is_empty()
        || receipt.intent_id.is_empty()
        || receipt.worker.is_empty()
        || receipt.integration_oid.is_empty()
        || receipt.integration_base_oid.is_empty()
        || receipt.integration_worker_oid.is_empty()
        || receipt.branch != format!("yard/{}/{}", receipt.task_id.to_lowercase(), receipt.run_id)
        || receipt.owned_oids.last() != Some(&receipt.integration_oid)
        || receipt.provenance == IntegrationProvenance::Unknown
    {
        return Err(anyhow!("incomplete integrated-run ownership record"));
    }
    let worktree = PathBuf::from(&receipt.worktree);
    if !worktree.starts_with(ws.agents_dir().join("worktrees"))
        || worktree.file_name().and_then(|name| name.to_str()) != Some(receipt.run_id.as_str())
    {
        return Err(anyhow!(
            "integrated worktree path is outside the owned run path"
        ));
    }
    let parents = git_stdout(
        &ws.root,
        &["show", "-s", "--format=%P", &receipt.integration_oid],
    )?;
    let parents = parents.split_whitespace().collect::<Vec<_>>();
    if parents.len() != 2
        || parents[0] != receipt.integration_base_oid
        || parents[1] != receipt.integration_worker_oid
        || !receipt.owned_oids.contains(&receipt.integration_worker_oid)
    {
        return Err(anyhow!(
            "integration commit parent projection does not match the run record"
        ));
    }
    git_stdout(
        &ws.root,
        &[
            "merge-base",
            "--is-ancestor",
            &receipt.integration_oid,
            "HEAD",
        ],
    )?;
    if receipt.provenance == IntegrationProvenance::SerialCoreStaged {
        let serial = ws.load_serial_integration_receipt(&receipt.run_id)?;
        if serial.schema_version != 1
            || serial.run_id != receipt.run_id
            || serial.task_id != receipt.task_id
            || serial.worktree != receipt.worktree
            || serial.branch != receipt.branch
            || serial.baseline_oid != receipt.baseline_oid
        {
            return Err(anyhow!("serial and integrated core receipts disagree"));
        }
    }
    Ok((
        worktree,
        receipt.integration_worker_oid.clone(),
        receipt.provenance,
    ))
}

fn recovery_git_finish_ownership(
    ws: &Workspace,
    run_id: &str,
    task_id: &str,
) -> Option<crate::git_finish::GitFinishOwnership> {
    let receipt = ws.load_integrated_cleanup_receipt(run_id).ok()?;
    if receipt.run_id != run_id || receipt.task_id != task_id {
        return None;
    }
    validate_integrated_cleanup_identity(ws, &receipt).ok()?;
    Some(crate::git_finish::GitFinishOwnership {
        baseline_oid: receipt.integration_base_oid,
        expected_oid: receipt.integration_oid,
        owned_oids: receipt.owned_oids,
    })
}

fn validate_no_change_receipt(ws: &Workspace, receipt: &state::NoChangeReceipt) -> Result<PathBuf> {
    if receipt.schema_version != 1
        || receipt.run_id.is_empty()
        || receipt.task_id.is_empty()
        || receipt.intent_id.is_empty()
        || receipt.worker.is_empty()
        || receipt.baseline_oid.is_empty()
        || receipt.worker_oid != receipt.baseline_oid
        || receipt.branch != format!("yard/{}/{}", receipt.task_id.to_lowercase(), receipt.run_id)
        || receipt.provenance == IntegrationProvenance::Unknown
    {
        return Err(anyhow!("incomplete no-change core receipt"));
    }
    let worktree = PathBuf::from(&receipt.worktree);
    if worktree != ws.agents_dir().join("worktrees").join(&receipt.run_id) {
        return Err(anyhow!("no-change worktree is outside the owned run path"));
    }
    git_stdout(
        &ws.root,
        &["merge-base", "--is-ancestor", &receipt.worker_oid, "HEAD"],
    )?;
    if receipt.provenance == IntegrationProvenance::SerialCoreStaged {
        let serial = ws.load_serial_integration_receipt(&receipt.run_id)?;
        if serial.schema_version != 1
            || serial.run_id != receipt.run_id
            || serial.task_id != receipt.task_id
            || serial.worktree != receipt.worktree
            || serial.branch != receipt.branch
            || serial.baseline_oid != receipt.baseline_oid
        {
            return Err(anyhow!("serial and no-change core receipts disagree"));
        }
    }
    Ok(worktree)
}

fn recovery_no_change_complete(ws: &Workspace, run_id: &str, task_id: &str) -> bool {
    let Ok(receipt) = ws.load_no_change_receipt(run_id) else {
        return false;
    };
    if receipt.run_id != run_id || receipt.task_id != task_id {
        return false;
    }
    let Ok(worktree) = validate_no_change_receipt(ws, &receipt) else {
        return false;
    };
    crate::parallel::cleanup_integrated_worktree(
        &ws.root,
        &worktree,
        &receipt.branch,
        &receipt.worker_oid,
        receipt.provenance,
    )
    .complete
}

fn reconcile_no_change_outcomes(ws: &Workspace, msgs: &mut Vec<String>) {
    let receipts = match ws.load_no_change_receipts() {
        Ok(receipts) => receipts,
        Err(error) => {
            msgs.push(format!("retained incomplete no-change receipts: {error}"));
            return;
        }
    };
    for receipt in receipts {
        let run_dir = ws.runs_dir().join(&receipt.run_id);
        let worktree = match validate_no_change_receipt(ws, &receipt) {
            Ok(worktree) => worktree,
            Err(error) => {
                msgs.push(format!(
                    "{}: retained incomplete no-change cleanup: {error}",
                    receipt.task_id
                ));
                continue;
            }
        };
        // The run directory is worker-writable. Rebuild its identity from the
        // core receipt before `latest_run_for` scans it below; otherwise a
        // malformed or retargeted projection can make a completed no-op look
        // abandoned and cause the worker to run again.
        if let Err(error) = persist_no_change_projection(&run_dir, &receipt, false) {
            msgs.push(format!(
                "{}: could not repair no-change run projection: {error}",
                receipt.task_id
            ));
            continue;
        }
        let cleanup = crate::parallel::cleanup_integrated_worktree(
            &ws.root,
            &worktree,
            &receipt.branch,
            &receipt.worker_oid,
            receipt.provenance,
        );
        for warning in cleanup.warnings {
            msgs.push(format!("{}: {warning}", receipt.task_id));
        }
        if let Err(error) = persist_no_change_projection(&run_dir, &receipt, cleanup.complete) {
            msgs.push(format!(
                "{}: could not persist no-change cleanup projection: {error}",
                receipt.task_id
            ));
            continue;
        }
        if !cleanup.complete {
            continue;
        }
        match crate::git_finish::finish_no_change_run(
            ws,
            &run_dir,
            &receipt.run_id,
            &receipt.task_id,
            TaskState::Done,
        ) {
            Ok(record) if record.status.verified_complete() => {}
            Ok(record) => msgs.push(format!(
                "{}: no-change Git finish remains {}",
                receipt.task_id,
                record.status.as_str()
            )),
            Err(error) => msgs.push(format!(
                "{}: could not persist no-change Git finish: {error}",
                receipt.task_id
            )),
        }
    }
}

fn reconcile_integrated_cleanups(ws: &Workspace, msgs: &mut Vec<String>) {
    let receipts = match ws.load_integrated_cleanup_receipts() {
        Ok(receipts) => receipts,
        Err(error) => {
            msgs.push(format!("retained incomplete Git cleanup receipts: {error}"));
            return;
        }
    };
    for receipt in receipts {
        let run_dir = ws.runs_dir().join(&receipt.run_id);
        let was_complete = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
            .ok()
            .is_some_and(|record| {
                record.run_id == receipt.run_id
                    && record.task_id == receipt.task_id
                    && record.integration_oid == receipt.integration_oid
                    && record.integration_worker_oid == receipt.integration_worker_oid
                    && record.integration_cleanup_complete
            });
        let (worktree, worker_oid, provenance) =
            match validate_integrated_cleanup_identity(ws, &receipt) {
                Ok(identity) => identity,
                Err(error) => {
                    msgs.push(format!(
                        "{}: retained incomplete Git cleanup: {error}",
                        receipt.task_id
                    ));
                    continue;
                }
            };
        let cleanup = crate::parallel::cleanup_integrated_worktree(
            &ws.root,
            &worktree,
            &receipt.branch,
            &worker_oid,
            provenance,
        );
        for warning in cleanup.warnings {
            msgs.push(format!("{}: {warning}", receipt.task_id));
        }
        let _ = persist_integrated_cleanup_projection(&run_dir, &receipt, cleanup.complete);
        if cleanup.complete && !was_complete {
            msgs.push(format!(
                "{}: reconciled integrated worktree cleanup",
                receipt.task_id
            ));
        }
    }
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
    if let Err(error) = crate::planning::validate_active_activation(ws) {
        return vec![format!("recovery rejected: {error}")];
    }
    let mut msgs = Vec::new();
    let Ok(mut q) = ws.load_queue() else {
        return msgs;
    };
    // A worker writes into its isolated staging run dir. If the orchestrator
    // crashed before importing those files, recover them before classifying the
    // run as abandoned, otherwise a completed worker would be invoked twice.
    import_completed_serial_staging(ws);
    // Integration ownership is persisted before cleanup. Reconcile it even if
    // the worktree path already vanished in the crash window before ref deletion.
    reconcile_no_change_outcomes(ws, &mut msgs);
    reconcile_integrated_cleanups(ws, &mut msgs);
    let event_lang = run_event_lang(ws);
    let billing = ws.load_billing().unwrap_or_default();
    let mut requeued = Vec::new();
    let mut finished = Vec::new();
    let git_finish_attempted =
        recover_pending_git_finishes(ws, &mut q, &billing, event_lang, &mut msgs, &mut finished);
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
            TaskState::Partial => latest
                .as_ref()
                .filter(|(run_id, _)| !git_finish_attempted.contains(run_id))
                .map(|(_, run_dir)| git_finish_recovery_needed(ws, run_dir))
                .unwrap_or(false),
            TaskState::Done => latest
                .as_ref()
                .map(|(_, run_dir)| git_finish_projection_recovery_needed(ws, run_dir))
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
                let wt = run_worktree(&run_dir).filter(|w| w.exists());
                let serial_evidence = wt
                    .as_ref()
                    .and_then(|w| serial_worktree_evidence(w, &run_dir));
                if let (Some(wt), Some(serial_evidence)) = (&wt, &serial_evidence) {
                    if let Err(error) = remove_unchanged_seeded_harness_copies(wt, serial_evidence)
                    {
                        msgs.push(format!(
                            "{id}: could not remove unchanged harness seed copies: {error}"
                        ));
                    }
                }
                let evidence = if wt.is_some() {
                    serial_evidence
                        .as_ref()
                        .map(|evidence| evidence.paths.clone())
                } else {
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
                };
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
                let run_record = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")).ok();
                let branch = run_record
                    .as_ref()
                    .map(|record| record.worktree_branch.clone())
                    .filter(|branch| !branch.is_empty())
                    .unwrap_or_else(|| format!("yard/{}", id.to_lowercase()));
                let baseline_oid = run_record
                    .as_ref()
                    .map(|record| record.baseline_oid.clone())
                    .unwrap_or_default();
                let integration_enabled = !run_record
                    .as_ref()
                    .is_some_and(|record| record.serial_isolated)
                    || ws.load_config().is_ok_and(|config| config.auto_commit);
                let merge = wt.as_ref().map(|w| MergeBack {
                    wt_path: w.as_path(),
                    branch: branch.as_str(),
                    baseline_oid: baseline_oid.as_str(),
                    expected_tip_oid: serial_evidence
                        .as_ref()
                        .map(|evidence| evidence.merge_target_oid.as_str()),
                    provenance: recovery_integration_provenance(
                        ws,
                        run_record.as_ref(),
                        &run_id,
                        &id,
                        w,
                        &branch,
                    ),
                    auto_commit: integration_enabled,
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
                        finished.push(task_state_progress_line(event_lang, &id, report.next_state));
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
                // Re-read and mutate under the permanent workspace lock. A
                // concurrent add or planning confirm can never be overwritten by
                // this recovery pass's start-of-loop snapshot.
                let _ = save_task_state_on_latest_queue(
                    ws,
                    &mut q,
                    &id,
                    TaskState::Queued,
                    TransitionCause::Recover,
                    "dead orphan worker had no result; task requeued",
                    TransitionActor::System,
                );
                requeued.push(id.clone());
            }
        }
    }
    if !finished.is_empty() || !requeued.is_empty() {
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

fn git_finish_recovery_needed(ws: &Workspace, run_dir: &std::path::Path) -> bool {
    if let Ok(record) = ws.load_git_finish_record(run_dir) {
        return record.policy.auto_push
            && (record.status.recoverable()
                || record.status == crate::git_finish::GitFinishStatus::NotNeeded);
    }
    state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
        .ok()
        .is_some_and(|record| !record.integration_oid.is_empty())
}

fn git_finish_projection_recovery_needed(ws: &Workspace, run_dir: &std::path::Path) -> bool {
    let unsealed = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
        .ok()
        .is_some_and(|record| record.completed_at.is_none());
    unsealed
        && ws
            .load_git_finish_record(run_dir)
            .ok()
            .is_some_and(|record| record.policy.auto_push && record.status.verified_complete())
}

pub(crate) fn find_worker<'a>(workers: &'a [WorkerProfile], id: &str) -> Result<&'a WorkerProfile> {
    workers
        .iter()
        .find(|w| w.id == id)
        .ok_or_else(|| anyhow!("worker '{id}' is not defined in .agents/workers.yaml"))
}

pub(crate) fn save_task_state_on_latest_queue(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> Result<()> {
    let lock = ws.acquire_planning_lock()?;
    save_task_state_on_latest_queue_locked(
        ws,
        &lock,
        fallback_queue,
        task_id,
        state,
        cause,
        detail,
        actor,
    )
}

// Mirrors the unlocked wrapper while accepting its already-held transaction
// guard. Keeping the transition fields explicit avoids constructing a second
// transaction input that could accidentally be reused outside this lock.
#[allow(clippy::too_many_arguments)]
fn save_task_state_on_latest_queue_locked(
    ws: &Workspace,
    lock: &PlanningLock,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> Result<()> {
    finalize_on_latest_queue_locked(
        ws,
        lock,
        fallback_queue,
        task_id,
        state,
        &[],
        &[],
        None,
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
/// and the task's persisted feedback cap bounds the fix+re-verify loop ("try hard,
/// then ask"). Re-reads the latest queue first so a concurrent change is not
/// clobbered.
/// Of the just-ingested follow-up ids, those that are schedulable remediation:
/// `Queued` and dependency-satisfied. Approval is intentionally not part of
/// this filter. An approval-gated fix must remain linked to the review so the
/// review cannot re-run against unchanged code while approval is pending. An
/// off-vocabulary fix parked `Blocked`, a `Deferred` one, or a `Queued` fix with
/// unmet dependencies is excluded. When this is empty the review surfaces to
/// the user instead.
fn schedulable_remediation_ids(queue: &WorkQueue, ingested: &[String]) -> Vec<String> {
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

fn dedup_review_follow_ups(follow_ups: &mut Vec<crate::schemas::FollowUpTask>, queue: &WorkQueue) {
    follow_ups.retain(|fu| {
        !queue
            .tasks
            .iter()
            .any(|t| t.title.trim().eq_ignore_ascii_case(fu.title.trim()))
    });
}

pub(crate) fn requeue_review(
    ws: &Workspace,
    fallback_queue: &mut WorkQueue,
    review_id: &str,
    state: TaskState,
    fix_ids: &[String],
) -> Result<()> {
    let lock = ws.acquire_planning_lock()?;
    requeue_review_locked(ws, &lock, fallback_queue, review_id, state, fix_ids)
}

fn requeue_review_locked(
    ws: &Workspace,
    lock: &PlanningLock,
    fallback_queue: &mut WorkQueue,
    review_id: &str,
    state: TaskState,
    fix_ids: &[String],
) -> Result<()> {
    let mut latest = ws.load_queue().unwrap_or_else(|_| fallback_queue.clone());
    let mut pending_transition = None;
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
                t.add_remediation_for(review_id);
            }
        }
        if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == review_id) {
            let from = t.state;
            t.state = state;
            t.priority = front - 10;
            if from != state {
                pending_transition = Some(state::transition(
                    review_id,
                    from,
                    state,
                    TransitionCause::RunOutcome,
                    "review failed; requeued behind runnable remediation",
                    TransitionActor::System,
                ));
            }
        }
    } else if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == review_id) {
        let from = t.state;
        t.state = state;
        if from != state {
            pending_transition = Some(state::transition(
                review_id,
                from,
                state,
                TransitionCause::RunOutcome,
                "review failed with no runnable fix; paused for user",
                TransitionActor::System,
            ));
        }
    }
    ws.save_queue_locked(lock, &latest)?;
    if let Some(transition) = pending_transition {
        state::append_transition(ws, transition)?;
    }
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
fn finalize_on_latest_queue_locked(
    ws: &Workspace,
    lock: &PlanningLock,
    fallback_queue: &mut WorkQueue,
    task_id: &str,
    state: TaskState,
    intent_allowed_scope: &[String],
    follow_ups: &[crate::schemas::FollowUpTask],
    governing: Option<&crate::schemas::ResolvedWorkerSelection>,
    workers: Option<&WorkersFile>,
    cause: TransitionCause,
    detail: &str,
    actor: TransitionActor,
) -> Result<Vec<String>> {
    // Ground any just-ingested follow-up's capabilities against the real
    // workers before saving: a follow-up requiring a capability no worker has is
    // parked Blocked at ingest, not crashed into when the drain later picks it.
    let reconcile = |q: &mut WorkQueue, ingested: &[String]| {
        if let Some(w) = workers {
            let _ = crate::planner::reconcile_queue_capabilities_for_ids(q, w, ingested);
        }
    };
    let mut latest = ws.load_queue().unwrap_or_else(|_| fallback_queue.clone());
    if let Some(t) = latest.tasks.iter_mut().find(|t| t.id == task_id) {
        let from = t.state;
        t.state = state;
        if let Some(selection) = governing {
            apply_selection_to_task(t, selection);
        }
        let ingested = if let Some(governing) = governing {
            match crate::planner::ingest_follow_ups_with_governing(
                &mut latest,
                intent_allowed_scope,
                follow_ups,
                Some(ws),
                governing,
            ) {
                Ok(ingested) => ingested,
                Err(error) => {
                    // Governing ingestion is atomic, so a rejected follow-up
                    // left `latest` with only the run outcome applied. Preserve
                    // that durable outcome and its transition before surfacing
                    // the fail-closed lineage error.
                    ws.save_queue_locked(lock, &latest)?;
                    if from != state {
                        state::append_transition(
                            ws,
                            state::transition(task_id, from, state, cause, detail, actor.clone()),
                        )?;
                    }
                    *fallback_queue = latest;
                    return Err(error);
                }
            }
        } else {
            crate::planner::ingest_follow_ups(
                &mut latest,
                intent_allowed_scope,
                follow_ups,
                Some(ws),
            )
        };
        reconcile(&mut latest, &ingested);
        ws.save_queue_locked(lock, &latest)?;
        crate::planner::persist_ingested_decision_questions(ws, &latest, &ingested)?;
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

    if latest.tasks.is_empty() && latest.intent_id.is_empty() {
        let mut bootstrapped = fallback_queue.clone();
        let task = bootstrapped
            .tasks
            .iter_mut()
            .find(|task| task.id == task_id)
            .ok_or_else(|| anyhow!("task {task_id} is missing from fallback queue"))?;
        let from = task.state;
        task.state = state;
        if let Some(selection) = governing {
            apply_selection_to_task(task, selection);
        }
        let ingested = if let Some(governing) = governing {
            match crate::planner::ingest_follow_ups_with_governing(
                &mut bootstrapped,
                intent_allowed_scope,
                follow_ups,
                Some(ws),
                governing,
            ) {
                Ok(ingested) => ingested,
                Err(error) => {
                    // Match the normal latest-queue path: reject the follow-up
                    // without losing the governing task's evaluated outcome.
                    ws.save_queue_locked(lock, &bootstrapped)?;
                    if from != state {
                        state::append_transition(
                            ws,
                            state::transition(task_id, from, state, cause, detail, actor),
                        )?;
                    }
                    *fallback_queue = bootstrapped;
                    return Err(error);
                }
            }
        } else {
            crate::planner::ingest_follow_ups(
                &mut bootstrapped,
                intent_allowed_scope,
                follow_ups,
                Some(ws),
            )
        };
        reconcile(&mut bootstrapped, &ingested);
        ws.save_queue_locked(lock, &bootstrapped)?;
        crate::planner::persist_ingested_decision_questions(ws, &bootstrapped, &ingested)?;
        if from != state {
            state::append_transition(
                ws,
                state::transition(task_id, from, state, cause, detail, actor),
            )?;
        }
        append_ingested_decision_transitions(ws, &bootstrapped, &ingested)?;
        *fallback_queue = bootstrapped;
        return Ok(ingested);
    }
    anyhow::bail!(
        "queue_transaction_conflict: task {task_id} vanished from the latest queue during finalization"
    )
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
    /// Reconcile a previously integrated run whose exact OID may sit behind
    /// later integrations. The run's durable ownership proof remains immutable.
    pub git_finish_recovery: bool,
    /// Repair only the stale run projection of a queue task that is already
    /// Done with a verified Git-finish record. Re-evaluation may add diagnostics,
    /// but it cannot regress the canonical queue state or verified finish fact.
    pub repairs_done_projection: bool,
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
            git_finish_recovery: false,
            repairs_done_projection: false,
            follow_ups: true,
        }
    }

    /// The parallel path runs validation in the isolated worktree before merge,
    /// preserving the same fatal gate and channel events as serial execution.
    /// Post-run hooks remain deferred because they may rely on workspace-local
    /// dependencies. Conversation/learned are skipped (batches only pick Queued
    /// tasks). Artifacts, telemetry, and follow-up ingestion land.
    pub fn parallel() -> Self {
        Self {
            post_hooks: false,
            validation: true,
            conversation: false,
            learned: false,
            artifacts: true,
            telemetry: true,
            git_finish_recovery: false,
            repairs_done_projection: false,
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
            git_finish_recovery: true,
            repairs_done_projection: false,
            follow_ups: false,
        }
    }

    pub fn done_projection_recovery() -> Self {
        Self {
            repairs_done_projection: true,
            ..Self::recovery()
        }
    }
}

/// A worker's isolated worktree to merge back into the main workspace when its
/// run lands Done. Set by isolated serial, parallel, and recovery paths.
pub(crate) struct MergeBack<'a> {
    pub wt_path: &'a std::path::Path,
    pub branch: &'a str,
    pub baseline_oid: &'a str,
    /// Exact run-owned branch tip whose committed diff was evaluated. When
    /// present, integration fails closed if the branch moved after evidence
    /// collection. Parallel and legacy runs without this binding pass None.
    pub expected_tip_oid: Option<&'a str>,
    /// Selects the integration protocol. Serial core-staged runs may use their
    /// trusted transaction record; parallel worker-direct runs never load it.
    pub provenance: IntegrationProvenance,
    /// Serial runs obey the default-off auto_commit gate. Parallel batches
    /// already require integration and therefore pass true.
    pub auto_commit: bool,
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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(crate) struct FeedbackRecord {
    pub schema_version: u32,
    pub run_id: String,
    pub task_id: String,
    pub intent_id: String,
    pub cycle: u32,
    pub max_cycles: u32,
    pub retryable: bool,
    pub failures: Vec<String>,
    pub unmet_acceptance: Vec<String>,
    pub terminal_reason: String,
    #[serde(default)]
    pub question_for_user: Option<String>,
}

fn prior_feedback_cycles(
    ws: &Workspace,
    task_id: &str,
    intent_id: &str,
    current_run_id: &str,
) -> u32 {
    let Ok(entries) = std::fs::read_dir(ws.runs_dir()) else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let dir = entry.path();
            let name = dir.file_name()?.to_str()?;
            if name == current_run_id {
                return None;
            }
            let raw = std::fs::read_to_string(dir.join("feedback.json")).ok()?;
            serde_json::from_str::<FeedbackRecord>(&raw).ok()
        })
        .filter(|f| f.task_id == task_id && f.intent_id == intent_id && f.retryable)
        .map(|f| f.cycle)
        .max()
        .unwrap_or(0)
}

fn validation_failure_details(run_dir: &std::path::Path) -> Vec<String> {
    let Ok(raw) = std::fs::read_to_string(run_dir.join("validation.json")) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return Vec::new();
    };
    value
        .get("commands")
        .and_then(|v| v.as_array())
        .into_iter()
        .flatten()
        .filter(|cmd| !cmd.get("passed").and_then(|v| v.as_bool()).unwrap_or(false))
        .map(|cmd| {
            let log = cmd.get("log").and_then(|v| v.as_str()).unwrap_or("");
            let mut detail = format!(
                "validation command `{}` failed (exit_code={}, timed_out={}, log={})",
                cmd.get("command").and_then(|v| v.as_str()).unwrap_or(""),
                cmd.get("exit_code")
                    .map(ToString::to_string)
                    .unwrap_or_else(|| "null".to_string()),
                cmd.get("timed_out")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false),
                log
            );
            if let Ok(output) = std::fs::read_to_string(run_dir.join(log)) {
                let output = output.trim();
                if !output.is_empty() {
                    let mut excerpt = output.to_string();
                    if excerpt.len() > 2048 {
                        let mut end = 2048;
                        while !excerpt.is_char_boundary(end) {
                            end -= 1;
                        }
                        excerpt.truncate(end);
                    }
                    detail.push_str(&format!("; output: {excerpt}"));
                }
            }
            detail
        })
        .collect()
}

pub(crate) fn feedback_for_run(
    ws: &Workspace,
    run_dir: &std::path::Path,
    run_id: &str,
    intent_id: &str,
    task: &crate::schemas::Task,
    eval: &evaluator::Evaluation,
    result: Option<&RunResult>,
) -> Option<FeedbackRecord> {
    if !matches!(eval.next_task_state, TaskState::Failed | TaskState::Partial) {
        return None;
    }

    let failed_checks: Vec<&evaluator::Check> = eval
        .checks
        .iter()
        .filter(|c| c.fatal && !c.passed)
        .collect();
    let retryable_check = |name: &str| {
        matches!(
            name,
            "result_file_present"
                | "result_schema_valid"
                | "handoff_present"
                | "ids_match"
                | "validation"
                | "reported_validation"
                | "review_verdict_present"
                | "review_criteria_pass"
        )
    };
    let retryable = task.injects_failed_checks()
        && (eval.next_task_state == TaskState::Partial
            || (!failed_checks.is_empty()
                && failed_checks.iter().all(|c| retryable_check(&c.name))));

    let mut failures: Vec<String> = failed_checks
        .iter()
        .map(|c| format!("{}: {}", c.name, c.note))
        .collect();
    failures.extend(validation_failure_details(run_dir));
    if failures.is_empty() {
        failures.push(
            result
                .map(|r| format!("worker ended {}: {}", r.status, r.compact_summary.trim()))
                .unwrap_or_else(|| "worker did not complete the output contract".to_string()),
        );
    }
    failures.sort();
    failures.dedup();

    let mut unmet_acceptance = Vec::new();
    if let Some(r) = result {
        for verdict in r.verdict.iter().filter(|v| !v.pass) {
            let mut text = format!("{}: {}", verdict.criterion_id, verdict.evidence.trim());
            if let Some(index) = verdict
                .criterion_id
                .strip_prefix("AC-")
                .and_then(|n| n.parse::<usize>().ok())
                .and_then(|n| n.checked_sub(1))
            {
                if let Some(statement) = task.acceptance.get(index).and_then(|v| v.as_str()) {
                    text.push_str(&format!(" | acceptance: {statement}"));
                }
            }
            unmet_acceptance.push(text);
        }
    }
    if unmet_acceptance.is_empty()
        && failed_checks.iter().any(|c| {
            matches!(
                c.name.as_str(),
                "review_verdict_present" | "review_criteria_pass"
            )
        })
    {
        unmet_acceptance.extend(
            task.acceptance
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string)),
        );
    }
    if let Some(condition) = task
        .goal
        .as_ref()
        .map(|g| g.condition.trim())
        .filter(|s| !s.is_empty())
    {
        unmet_acceptance.push(format!("goal condition: {condition}"));
    }
    unmet_acceptance.sort();
    unmet_acceptance.dedup();

    let prior = prior_feedback_cycles(ws, &task.id, intent_id, run_id);
    let cycle = prior.saturating_add(1);
    let max_cycles = task.max_feedback_cycles();
    let terminal_reason = if !retryable {
        "failure is not safe for automatic retry".to_string()
    } else if cycle > max_cycles {
        format!("feedback retry cap exceeded ({max_cycles})")
    } else {
        String::new()
    };
    let mut feedback = FeedbackRecord {
        schema_version: 1,
        run_id: run_id.to_string(),
        task_id: task.id.clone(),
        intent_id: intent_id.to_string(),
        cycle,
        max_cycles,
        retryable,
        failures,
        unmet_acceptance,
        terminal_reason,
        question_for_user: None,
    };
    if !feedback.retryable || feedback.cycle > feedback.max_cycles {
        feedback.question_for_user = Some(feedback_question(task, &feedback));
    }
    Some(feedback)
}

pub(crate) fn feedback_next_state(feedback: &FeedbackRecord) -> TaskState {
    if feedback.retryable && feedback.cycle <= feedback.max_cycles {
        TaskState::Partial
    } else if feedback
        .question_for_user
        .as_deref()
        .map(str::trim)
        .is_some_and(|question| !question.is_empty())
    {
        TaskState::NeedsUser
    } else {
        TaskState::Failed
    }
}

fn feedback_question(task: &crate::schemas::Task, feedback: &FeedbackRecord) -> String {
    let detail = feedback
        .unmet_acceptance
        .first()
        .or_else(|| feedback.failures.first())
        .map(|detail| detail.trim().chars().take(240).collect::<String>())
        .filter(|detail| !detail.is_empty());
    match detail {
        Some(detail) => format!(
            "`{}` 작업을 자동으로 완료하지 못했습니다. 확인이 필요한 근거는 `{detail}`입니다. 어떤 방식으로 진행할까요?",
            task.id
        ),
        None => format!(
            "`{}` 작업을 자동으로 완료하지 못했습니다. 어떤 방식으로 진행할까요?",
            task.id
        ),
    }
}

fn review_without_remediation_question(task: &crate::schemas::Task) -> String {
    format!(
        "`{}` 리뷰가 통과하지 못했고 실행 가능한 수정 작업이 없습니다. 수정 작업을 큐에 추가한 뒤 리뷰를 재실행하거나 현재 판정을 수동으로 확정해 주세요. 어느 조치로 이어갈까요?",
        task.id
    )
}

fn review_evaluation_failed(is_review: bool, evaluated_state: TaskState) -> bool {
    is_review && matches!(evaluated_state, TaskState::Failed | TaskState::Partial)
}

fn artifact_content_digest(bytes: &[u8]) -> String {
    let mut hash = 0xcbf29ce484222325_u64;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("fnv1a64:{hash:016x}")
}

fn artifact_media_type(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("json") => "application/json",
        Some("yaml" | "yml") => "application/yaml",
        Some("md") => "text/markdown",
        _ => "application/octet-stream",
    }
}

fn finalization_artifact_causation(events: &[ChannelEvent], attempt_id: &str) -> Option<String> {
    for event_type in [
        ChannelEventType::ValidationCompleted,
        ChannelEventType::WorkerCompleted,
        ChannelEventType::AttemptPrepared,
    ] {
        if let Some(event) = events.iter().rev().find(|event| {
            event.attempt_id.as_deref() == Some(attempt_id) && event.event_type == event_type
        }) {
            return Some(event.event_id.clone());
        }
    }
    None
}

fn record_artifact_created(
    ws: &Workspace,
    context: &ChannelRunContext,
    attempt_id: &str,
    path: &std::path::Path,
    recorded_path: &str,
    role: &str,
    worker_authored: bool,
) -> Result<()> {
    if !path.is_file() {
        return Ok(());
    }
    let bytes = std::fs::read(path)
        .with_context(|| format!("reading artifact for channel event {}", path.display()))?;
    let content_digest = artifact_content_digest(&bytes);
    let channel = ws.load_task_channel(&context.intent_id, &context.task_id)?;
    let worker_id = channel
        .attempts
        .iter()
        .find(|attempt| attempt.attempt_id == attempt_id)
        .map(|attempt| attempt.worker_id.clone())
        .ok_or_else(|| anyhow!("artifact producer attempt missing: {attempt_id}"))?;
    let causation_id = finalization_artifact_causation(&channel.events, attempt_id)
        .unwrap_or_else(|| attempt_id.to_string());
    let artifact_role = match role {
        "handoff" | "checkpoint" => crate::schemas::ArtifactRole::Handoff,
        "evaluation" => crate::schemas::ArtifactRole::ValidationOutput,
        _ => crate::schemas::ArtifactRole::File,
    };
    let proposal = crate::schemas::ArtifactProposal {
        proposal_id: format!(
            "core-{}",
            artifact_content_digest(
                format!("{attempt_id}\0{role}\0{recorded_path}\0{content_digest}").as_bytes(),
            )
            .trim_start_matches("fnv1a64:")
        ),
        task_id: context.task_id.clone(),
        attempt_id: attempt_id.to_string(),
        producer: crate::schemas::ResourceProducer { worker_id },
        causation_id,
        path: recorded_path.to_string(),
        digest: content_digest,
        media_type: artifact_media_type(path).to_string(),
        role: artifact_role,
        channel_role: role.to_string(),
    };
    ws.publish_artifact(
        &context.session_id,
        &context.intent_id,
        &proposal,
        &path.display().to_string(),
    )?;
    let _ = worker_authored;
    Ok(())
}

fn record_finalization_artifacts(
    ws: &Workspace,
    context: &ChannelRunContext,
    run_dir: &std::path::Path,
    worker_root: &std::path::Path,
    result: Option<&RunResult>,
) -> Result<()> {
    let Some(attempt_id) = std::fs::read_to_string(run_dir.join("latest-attempt"))
        .ok()
        .map(|attempt| attempt.trim().to_string())
        .filter(|attempt| !attempt.is_empty())
    else {
        return Ok(());
    };
    for (name, role, worker_authored) in [
        ("result.json", "worker_result", true),
        ("evaluation.json", "evaluation", false),
        ("checkpoint.md", "checkpoint", false),
        ("handoff.md", "handoff", false),
    ] {
        let path = run_dir.join(name);
        let recorded_path = path
            .strip_prefix(&ws.root)
            .unwrap_or(&path)
            .display()
            .to_string();
        record_artifact_created(
            ws,
            context,
            &attempt_id,
            &path,
            &recorded_path,
            role,
            worker_authored,
        )?;
    }

    let Some(result) = result else {
        ws.load_or_rebuild_task_channel(&context.intent_id, &context.task_id)?;
        return Ok(());
    };
    if result.resource_provenance_errors(&attempt_id).is_empty() {
        crate::resource::ingest_run_proposals(
            ws,
            &context.session_id,
            &context.intent_id,
            &context.task_id,
            &attempt_id,
            &ws.load_task_channel(&context.intent_id, &context.task_id)?
                .attempts
                .into_iter()
                .find(|attempt| attempt.attempt_id == attempt_id)
                .ok_or_else(|| anyhow!("resource producer attempt missing: {attempt_id}"))?
                .worker_id,
            worker_root,
            result,
        )?;
    }
    let Ok(canonical_root) = std::fs::canonicalize(worker_root) else {
        return Ok(());
    };
    let mut declared = result
        .changes
        .files_created
        .iter()
        .chain(&result.changes.files_modified)
        .collect::<Vec<_>>();
    declared.sort();
    declared.dedup();
    for recorded_path in declared {
        let relative = std::path::Path::new(recorded_path);
        if relative.is_absolute()
            || relative.components().any(|component| {
                matches!(
                    component,
                    std::path::Component::ParentDir
                        | std::path::Component::RootDir
                        | std::path::Component::Prefix(_)
                )
            })
        {
            continue;
        }
        let path = worker_root.join(relative);
        let Ok(canonical_path) = std::fs::canonicalize(&path) else {
            continue;
        };
        if canonical_path.strip_prefix(&canonical_root).is_err() || !canonical_path.is_file() {
            continue;
        }
        record_artifact_created(
            ws,
            context,
            &attempt_id,
            &canonical_path,
            recorded_path,
            "worker_declared",
            true,
        )?;
    }
    ws.load_or_rebuild_task_channel(&context.intent_id, &context.task_id)?;
    Ok(())
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
        let validation_attempt = std::fs::read_to_string(run_dir.join("latest-attempt"))
            .ok()
            .map(|attempt| attempt.trim().to_string())
            .filter(|attempt| !attempt.is_empty());
        let validation_context = channel_run_context(ws, &intent_id, &task.id);
        let validation_started = if let Some(attempt_id) = validation_attempt.as_deref() {
            Some(record_channel_event(
                ws,
                None,
                &validation_context,
                ChannelEventType::ValidationStarted,
                EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                Some(attempt_id),
                None,
                serde_json::json!({"commands": validation_cmds.clone()}),
                None,
            )?)
        } else {
            None
        };
        let (validation_ran, validation_passed) =
            run_validation_commands(&validation_cmds, validation_cwd, run_dir, billing);
        if let Some(attempt_id) = validation_attempt.as_deref() {
            record_channel_event(
                ws,
                None,
                &validation_context,
                ChannelEventType::ValidationCompleted,
                EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                Some(attempt_id),
                validation_started.map(|event| event.event_id),
                serde_json::json!({"ran": validation_ran, "passed": validation_passed}),
                None,
            )?;
            ws.load_or_rebuild_task_channel(&validation_context.intent_id, &task.id)?;
        }
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
    let mut question_to_persist = result
        .as_ref()
        .filter(|result| result.status == "needs_user")
        .and_then(|result| result.question_for_user.as_deref())
        .map(str::trim)
        .filter(|question| !question.is_empty())
        .map(|question| (question.to_string(), EventActorKind::Worker));

    let feedback = feedback_for_run(
        ws,
        run_dir,
        run_id,
        &intent_id,
        task,
        &eval,
        result.as_ref(),
    );
    let mut next_state = eval.next_task_state;
    if let Some(f) = &feedback {
        let _ = state::write_str(
            &run_dir.join("feedback.json"),
            &serde_json::to_string_pretty(f)?,
        );
        next_state = feedback_next_state(f);
        if next_state == TaskState::Partial {
            lines.push(format!(
                "feedback cycle {}/{}: failed checks will be injected into the next attempt",
                f.cycle, f.max_cycles
            ));
        } else if next_state == TaskState::NeedsUser {
            if question_to_persist.is_none() {
                question_to_persist = f
                    .question_for_user
                    .as_ref()
                    .map(|question| (question.clone(), EventActorKind::System));
            }
            lines.push(format!("feedback stopped: {}", f.terminal_reason));
        } else {
            lines.push("feedback stopped without an actionable question".to_string());
        }
    }
    if flags.repairs_done_projection && next_state != TaskState::Done {
        lines.push(format!(
            "{}: retained Done while repairing its verified Git finish projection",
            task.id
        ));
        next_state = TaskState::Done;
    }
    // Preserve the worker/evaluator outcome before Git integration can turn a
    // passing Done into a manual-integration Partial. Review remediation is
    // about failed review evidence, not a later delivery hold.
    let evaluated_state = next_state;
    let is_review = matches!(crate::packet::role_for(&task.kind), "reviewer" | "security");
    let review_failed = review_evaluation_failed(is_review, evaluated_state);

    let mut persisted_question = if next_state == TaskState::NeedsUser {
        let (question, actor_kind) = question_to_persist.get_or_insert_with(|| {
            (
                format!("`{}` 작업을 계속하려면 어떤 결정을 내려야 할까요?", task.id),
                EventActorKind::System,
            )
        });
        let channel_context = channel_run_context(ws, &intent_id, &task.id);
        persist_needs_user_question(ws, None, &channel_context, run_dir, question, *actor_kind)?;
        Some(question.clone())
    } else {
        None
    };

    if flags.artifacts {
        compact::write_checkpoint(run_dir, task, &eval, result.as_ref(), intent_summary)?;
        compact::write_handoff(run_dir, task, &eval, result.as_ref())?;
        if let Some(r) = &result {
            append_nonblocking_follow_up_notes(run_dir, r)?;
        }
    }
    let artifact_context = channel_run_context(ws, &intent_id, &task.id);
    let worker_root = merge
        .as_ref()
        .map(|merge| merge.wt_path)
        .unwrap_or(ws.root.as_path());
    record_finalization_artifacts(ws, &artifact_context, run_dir, worker_root, result.as_ref())?;

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
    // Normal finalization starts with no ownership and receives it only from a
    // successful integration below. Recovery may reconstruct it from the
    // core-owned receipt outside the worker-writable run directory. The Git
    // finish module independently prefers any earlier durable finish record.
    let mut git_finish_not_needed =
        flags.git_finish_recovery && recovery_no_change_complete(ws, run_id, &task.id);
    let mut ownership = flags
        .git_finish_recovery
        .then(|| recovery_git_finish_ownership(ws, run_id, &task.id))
        .flatten();
    if let Some(m) = &merge {
        if !m.auto_commit {
            let has_changes = evidence
                .as_ref()
                .is_some_and(|paths| worker_changed_integratable_path(Some(paths)));
            if next_state == TaskState::Done && has_changes {
                next_state = TaskState::Partial;
                let _ = state::write_str(&run_dir.join("partial-reason"), "auto_commit_disabled");
                let note = format!(
                    "\n## Git integration paused\n\n`auto_commit` is disabled, so Yardlet did not \
                     commit or merge this run. The isolated worktree is retained at `{}`.\n",
                    m.wt_path.display()
                );
                let hp = run_dir.join("handoff.md");
                let mut existing = std::fs::read_to_string(&hp).unwrap_or_default();
                existing.push_str(&note);
                let _ = state::write_str(&hp, &existing);
                lines.push(format!(
                    "{}: auto_commit is disabled; worktree retained at {}",
                    task.id,
                    m.wt_path.display()
                ));
            } else if next_state == TaskState::Done {
                let expected_tip = m
                    .expected_tip_oid
                    .filter(|oid| !oid.is_empty())
                    .unwrap_or(m.baseline_oid);
                if expected_tip != m.baseline_oid {
                    next_state = TaskState::Partial;
                    let _ = state::write_str(
                        &run_dir.join("partial-reason"),
                        "unintegrated_commit_retained",
                    );
                    lines.push(format!(
                        "{}: unintegrated commit retained at {}",
                        task.id,
                        m.wt_path.display()
                    ));
                } else {
                    let no_change_receipt = persist_no_change_receipt(
                        ws,
                        run_dir,
                        run_id,
                        &task.id,
                        &intent_id,
                        worker_id,
                        m,
                        expected_tip,
                    )?;
                    let cleanup = crate::parallel::cleanup_integrated_worktree(
                        &ws.root,
                        m.wt_path,
                        m.branch,
                        expected_tip,
                        m.provenance,
                    );
                    for warning in cleanup.warnings {
                        lines.push(format!("{}: {warning}", task.id));
                    }
                    persist_no_change_projection(run_dir, &no_change_receipt, cleanup.complete)?;
                    if !cleanup.complete {
                        next_state = TaskState::Partial;
                        let _ = state::write_str(
                            &run_dir.join("partial-reason"),
                            "worktree_cleanup_changed",
                        );
                    } else {
                        git_finish_not_needed = true;
                    }
                }
            } else {
                lines.push(format!(
                    "{}: {} — worktree kept at {}",
                    task.id,
                    run_outcome_label(next_state),
                    m.wt_path.display()
                ));
            }
        } else if next_state == TaskState::Done {
            let integration = match m.provenance {
                IntegrationProvenance::SerialCoreStaged => {
                    crate::parallel::integrate_serial_worktree(
                        &ws.root,
                        m.wt_path,
                        run_dir,
                        run_id,
                        m.branch,
                        &task.id,
                        m.baseline_oid,
                        m.expected_tip_oid,
                    )
                }
                IntegrationProvenance::ParallelWorkerDirect => {
                    crate::parallel::integrate_parallel_worktree(
                        &ws.root,
                        m.wt_path,
                        m.branch,
                        &task.id,
                        m.baseline_oid,
                        m.expected_tip_oid,
                    )
                }
                IntegrationProvenance::Unknown => Ok(crate::parallel::Integration::Conflict(
                    "worktree integration provenance is missing or inconsistent".to_string(),
                )),
            };
            match integration {
                Ok(crate::parallel::Integration::Merged {
                    oid,
                    base_oid,
                    worker_oid,
                    owned_oids,
                }) => {
                    ownership = Some(crate::git_finish::GitFinishOwnership {
                        baseline_oid: base_oid.clone(),
                        expected_oid: oid.clone(),
                        owned_oids: owned_oids.clone(),
                    });
                    let cleanup_receipt = persist_run_integration(
                        ws,
                        run_dir,
                        run_id,
                        &task.id,
                        &intent_id,
                        worker_id,
                        m,
                        &base_oid,
                        &worker_oid,
                        &oid,
                        &owned_oids,
                    )?;
                    lines.push(format!(
                        "{}: merged {} into the workspace",
                        task.id, m.branch
                    ));
                    let cleanup = crate::parallel::cleanup_integrated_worktree(
                        &ws.root,
                        m.wt_path,
                        m.branch,
                        &worker_oid,
                        m.provenance,
                    );
                    for warning in cleanup.warnings {
                        lines.push(format!("{}: {warning}", task.id));
                    }
                    if cleanup.complete {
                        persist_integrated_cleanup_projection(run_dir, &cleanup_receipt, true)?;
                    }
                }
                Ok(crate::parallel::Integration::NoChanges { worker_oid }) => {
                    let no_change_receipt = persist_no_change_receipt(
                        ws,
                        run_dir,
                        run_id,
                        &task.id,
                        &intent_id,
                        worker_id,
                        m,
                        &worker_oid,
                    )?;
                    let cleanup = crate::parallel::cleanup_integrated_worktree(
                        &ws.root,
                        m.wt_path,
                        m.branch,
                        &worker_oid,
                        m.provenance,
                    );
                    for warning in cleanup.warnings {
                        lines.push(format!("{}: {warning}", task.id));
                    }
                    persist_no_change_projection(run_dir, &no_change_receipt, cleanup.complete)?;
                    if cleanup.complete {
                        lines.push(format!("{}: no file changes to merge", task.id));
                        git_finish_not_needed = true;
                    } else {
                        next_state = TaskState::Partial;
                        let _ = state::write_str(
                            &run_dir.join("partial-reason"),
                            "worktree_cleanup_changed",
                        );
                    }
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
                "{}: {} — worktree kept at {}",
                task.id,
                run_outcome_label(next_state),
                m.wt_path.display()
            ));
        }
    }

    // Git finish runs only after evaluation and worktree integration. The OID
    // is supplied only by the successful merge branch above, so a serial run,
    // no-op, conflict, or unrelated existing commit cannot acquire ownership.
    let git_finish = if git_finish_not_needed {
        crate::git_finish::finish_no_change_run(ws, run_dir, run_id, &task.id, next_state)?
    } else if flags.git_finish_recovery {
        crate::git_finish::recover_owned_run(
            ws,
            run_dir,
            run_id,
            &task.id,
            next_state,
            ownership,
            flags.repairs_done_projection,
        )?
    } else {
        crate::git_finish::finish_owned_run(ws, run_dir, run_id, &task.id, next_state, ownership)?
    };
    lines.push(git_finish.user_line());
    let projected_state = state_after_git_finish(next_state, &git_finish);
    if projected_state != next_state {
        next_state = projected_state;
        let _ = state::write_str(&run_dir.join("partial-reason"), "git_finish_unverified");
        lines.push(format!(
            "{}: Git finish is not remotely verified; task remains partial",
            task.id
        ));
    } else if next_state == TaskState::Done
        && std::fs::read_to_string(run_dir.join("partial-reason"))
            .ok()
            .is_some_and(|reason| reason.trim() == "git_finish_unverified")
    {
        let _ = std::fs::remove_file(run_dir.join("partial-reason"));
    }

    // Update the queue: set state AND ingest any follow-up tasks the worker
    // proposed (propose -> ingest). Yardlet stays the sole queue writer — both
    // land in one re-read-then-save.
    // Recovery (follow_ups off) only finalizes the stranded run's state — it must
    // not ingest new follow-ups or re-queue a review, which would rewrite the
    // queue graph during a crash-recovery pass.
    let queue_lock = ws.acquire_planning_lock()?;
    let mut follow_ups = if flags.follow_ups && next_state != TaskState::NeedsUser {
        result
            .as_ref()
            .map(|r| r.follow_up_tasks.clone())
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    if is_review {
        // A repeated review failure must not create another copy of a fix that
        // this same queue already ran. If that fix was insufficient, stop for a
        // human instead of multiplying identical remediation tasks.
        let latest = ws.load_queue().unwrap_or_else(|_| queue.clone());
        dedup_review_follow_ups(&mut follow_ups, &latest);
        if let Some(f) = &feedback {
            for fu in &mut follow_ups {
                for unmet in &f.unmet_acceptance {
                    if !fu.acceptance.contains(unmet) {
                        fu.acceptance.push(unmet.clone());
                    }
                }
                for failure in &f.failures {
                    let evidence = format!("failed check evidence: {failure}");
                    if !fu.acceptance.contains(&evidence) {
                        fu.acceptance.push(evidence);
                    }
                }
            }
        }
    }
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
    let governing_selection = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml"))
        .ok()
        .and_then(|record| record.resolved_selection());
    let ingested = finalize_on_latest_queue_locked(
        ws,
        &queue_lock,
        queue,
        &task.id,
        next_state,
        &intent_allowed_scope,
        &follow_ups,
        governing_selection.as_ref(),
        workers.as_ref(),
        TransitionCause::RunOutcome,
        &format!("worker evaluated task as {}", run_outcome_label(next_state)),
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
    // Review auto-remediation (1c): a review that failed its criteria must not
    // blind-loop on the same unchanged code. Re-queue THIS review to run AFTER the
    // reviewer's proposed remediation (soft priority ordering, no hard dep) so the
    // fix runs first and the review then re-verifies; the persisted feedback cap
    // bounds the cycles across serial, parallel, and resumed drains.
    if flags.follow_ups && review_failed {
        // Sequence behind fixes in the runnable graph (Queued && deps_met),
        // including approval-gated fixes. With no such remediation, surface to
        // the user instead.
        let remediation = schedulable_remediation_ids(queue, &ingested);
        if remediation.is_empty() {
            if persisted_question.is_none() {
                let question = review_without_remediation_question(task);
                let channel_context = channel_run_context(ws, &intent_id, &task.id);
                persist_needs_user_question(
                    ws,
                    Some(&queue_lock),
                    &channel_context,
                    run_dir,
                    &question,
                    EventActorKind::System,
                )?;
                persisted_question = Some(question);
            }
            requeue_review_locked(ws, &queue_lock, queue, &task.id, TaskState::NeedsUser, &[])?;
            next_state = TaskState::NeedsUser;
            lines.push(format!(
                "{}: review failed with no runnable fix — needs you",
                task.id
            ));
        } else {
            requeue_review_locked(
                ws,
                &queue_lock,
                queue,
                &task.id,
                TaskState::Queued,
                &remediation,
            )?;
            next_state = TaskState::Queued;
            lines.push(format!(
                "{}: review failed — re-queued behind remediation [{}] to re-verify",
                task.id,
                remediation.join(", ")
            ));
        }
    }

    drop(queue_lock);

    // Mirror the canonical question into the legacy conversation transcript so
    // both continuation paths receive the same actionable prompt.
    if flags.conversation {
        if let Some(question) = persisted_question.as_deref() {
            let _ = state::append_conversation_turn(
                ws,
                &task.id,
                ConversationTurn {
                    role: TurnRole::Worker,
                    text: question.to_string(),
                    run_id: run_id.to_string(),
                    ts: Local::now().to_rfc3339(),
                },
            );
        }
    }

    if let Some(attempt_id) = std::fs::read_to_string(run_dir.join("latest-attempt"))
        .ok()
        .map(|attempt| attempt.trim().to_string())
        .filter(|attempt| !attempt.is_empty())
    {
        let context = channel_run_context(ws, &intent_id, &task.id);
        let channel = ws.load_task_channel(&context.intent_id, &task.id)?;
        let completion_id = format!("cmp_{run_id}");
        if !channel.events.iter().any(|event| {
            event.event_type == ChannelEventType::CompletionRecorded
                && event.payload["completion_id"] == completion_id
        }) {
            record_channel_event(
                ws,
                None,
                &context,
                ChannelEventType::CompletionRecorded,
                EventActor {
                    kind: EventActorKind::System,
                    id: String::new(),
                },
                Some(&attempt_id),
                channel.events.last().map(|event| event.event_id.clone()),
                serde_json::json!({
                    "completion_id": completion_id,
                    "run_id": run_id,
                    "task_state": run_outcome_label(evaluated_state)
                }),
                None,
            )?;
            ws.load_or_rebuild_task_channel(&context.intent_id, &task.id)?;
        }
    }

    if flags.telemetry {
        let _ = telemetry::append_run(
            ws,
            &telemetry::RunTelemetry {
                ts: Local::now().to_rfc3339(),
                run_id: run_id.to_string(),
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
                feedback_cycle: feedback.as_ref().map(|f| f.cycle).unwrap_or(0),
                max_feedback_cycles: task.max_feedback_cycles(),
                feedback_retryable: feedback.as_ref().is_some_and(|f| f.retryable),
                git_finish_status: git_finish.status.as_str().to_string(),
            },
        );
    }

    lines.push(format!("evaluation status: {}", eval.status));
    lines.push(format!(
        "next task state: {} {}",
        next_state.glyph(),
        run_outcome_label(next_state)
    ));

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

fn state_after_git_finish(
    state: TaskState,
    record: &crate::git_finish::GitFinishRecord,
) -> TaskState {
    if state == TaskState::Done && record.policy.auto_push && !record.status.verified_complete() {
        TaskState::Partial
    } else {
        state
    }
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
        model: task.model.clone(),
        fallback_enabled: task.fallback_enabled.unwrap_or(false),
        routing_provenance: task.routing_provenance.clone(),
        state: String::new(),
        started_at: String::new(),
        completed_at: None,
        worktree: merge
            .map(|m| m.wt_path.display().to_string())
            .unwrap_or_else(|| ".".to_string()),
        serial_isolated: false,
        baseline_oid: merge
            .map(|m| m.baseline_oid.to_string())
            .unwrap_or_default(),
        worktree_branch: merge.map(|m| m.branch.to_string()).unwrap_or_default(),
        integration_oid: String::new(),
        integration_base_oid: String::new(),
        integration_worker_oid: String::new(),
        integration_provenance: merge
            .map(|m| m.provenance)
            .unwrap_or(IntegrationProvenance::Unknown),
        integration_cleanup_complete: false,
        owned_oids: Vec::new(),
    });
    // Never preserve identity or worktree-location fields from the
    // worker-writable projection. These values are all known by the core at
    // finalization time, and recovery uses them to select and clean up runs.
    rec.schema_version = 1;
    rec.run_id = run_id.to_string();
    rec.task_id = task.id.clone();
    rec.intent_id = intent_id.to_string();
    rec.worker = worker_id.to_string();
    if let Some(merge) = merge {
        apply_core_run_projection(
            &mut rec,
            CoreRunProjection {
                run_id,
                task_id: &task.id,
                intent_id,
                worker: worker_id,
                worktree: merge.wt_path,
                branch: merge.branch,
                baseline_oid: merge.baseline_oid,
                provenance: merge.provenance,
            },
        );
    }
    rec.state = run_outcome_label(next_state).to_string();
    rec.completed_at = Some(Local::now().to_rfc3339());
    if let Ok(text) = crate::yaml::to_string(&rec) {
        let _ = state::write_str_atomic(&path, &text);
    }
}

#[allow(clippy::too_many_arguments)]
fn persist_run_integration(
    ws: &Workspace,
    run_dir: &std::path::Path,
    run_id: &str,
    task_id: &str,
    intent_id: &str,
    worker_id: &str,
    merge: &MergeBack<'_>,
    base_oid: &str,
    worker_oid: &str,
    oid: &str,
    owned_oids: &[String],
) -> Result<state::IntegratedCleanupReceipt> {
    if run_dir != ws.runs_dir().join(run_id) {
        return Err(anyhow!(
            "integration run directory does not match its core identity"
        ));
    }
    let receipt = state::IntegratedCleanupReceipt {
        schema_version: 1,
        run_id: run_id.to_string(),
        task_id: task_id.to_string(),
        intent_id: intent_id.to_string(),
        worker: worker_id.to_string(),
        worktree: merge.wt_path.display().to_string(),
        branch: merge.branch.to_string(),
        baseline_oid: merge.baseline_oid.to_string(),
        integration_base_oid: base_oid.to_string(),
        integration_worker_oid: worker_oid.to_string(),
        integration_oid: oid.to_string(),
        provenance: merge.provenance,
        owned_oids: owned_oids.to_vec(),
    };
    // The external receipt is the cleanup trust root and must become durable
    // before the worker-writable run record is projected.
    ws.save_integrated_cleanup_receipt(&receipt)?;
    persist_integrated_cleanup_projection(run_dir, &receipt, false)?;
    Ok(receipt)
}

#[allow(clippy::too_many_arguments)]
fn persist_no_change_receipt(
    ws: &Workspace,
    run_dir: &std::path::Path,
    run_id: &str,
    task_id: &str,
    intent_id: &str,
    worker_id: &str,
    merge: &MergeBack<'_>,
    worker_oid: &str,
) -> Result<state::NoChangeReceipt> {
    if run_dir != ws.runs_dir().join(run_id) || worker_oid != merge.baseline_oid {
        return Err(anyhow!(
            "no-change run identity is incomplete or inconsistent"
        ));
    }
    let receipt = state::NoChangeReceipt {
        schema_version: 1,
        run_id: run_id.to_string(),
        task_id: task_id.to_string(),
        intent_id: intent_id.to_string(),
        worker: worker_id.to_string(),
        worktree: merge.wt_path.display().to_string(),
        branch: merge.branch.to_string(),
        baseline_oid: merge.baseline_oid.to_string(),
        worker_oid: worker_oid.to_string(),
        provenance: merge.provenance,
    };
    ws.save_no_change_receipt(&receipt)?;
    persist_no_change_projection(run_dir, &receipt, false)?;
    Ok(receipt)
}

#[derive(Clone, Copy)]
struct CoreRunProjection<'a> {
    run_id: &'a str,
    task_id: &'a str,
    intent_id: &'a str,
    worker: &'a str,
    worktree: &'a std::path::Path,
    branch: &'a str,
    baseline_oid: &'a str,
    provenance: IntegrationProvenance,
}

fn apply_core_run_projection(record: &mut RunRecord, projection: CoreRunProjection<'_>) {
    record.schema_version = 1;
    record.run_id = projection.run_id.to_string();
    record.task_id = projection.task_id.to_string();
    record.intent_id = projection.intent_id.to_string();
    record.worker = projection.worker.to_string();
    if record.state.is_empty() {
        record.state = "running".to_string();
    }
    record.worktree = projection.worktree.display().to_string();
    record.worktree_branch = projection.branch.to_string();
    record.serial_isolated = projection.provenance == IntegrationProvenance::SerialCoreStaged;
    record.baseline_oid = projection.baseline_oid.to_string();
    record.integration_provenance = projection.provenance;
}

fn persist_no_change_projection(
    run_dir: &std::path::Path,
    receipt: &state::NoChangeReceipt,
    cleanup_complete: bool,
) -> Result<()> {
    if run_dir.file_name().and_then(|name| name.to_str()) != Some(receipt.run_id.as_str()) {
        return Err(anyhow!(
            "no-change run directory does not match its core identity"
        ));
    }
    let path = run_dir.join("run.yaml");
    let mut record: RunRecord = state::load_yaml(&path).unwrap_or_default();
    let worktree = PathBuf::from(&receipt.worktree);
    apply_core_run_projection(
        &mut record,
        CoreRunProjection {
            run_id: &receipt.run_id,
            task_id: &receipt.task_id,
            intent_id: &receipt.intent_id,
            worker: &receipt.worker,
            worktree: &worktree,
            branch: &receipt.branch,
            baseline_oid: &receipt.baseline_oid,
            provenance: receipt.provenance,
        },
    );
    record.integration_oid.clear();
    record.integration_base_oid.clear();
    record.integration_worker_oid.clear();
    record.owned_oids.clear();
    record.integration_cleanup_complete = cleanup_complete;
    state::write_str_atomic(&path, &crate::yaml::to_string(&record)?)
}

fn persist_integrated_cleanup_projection(
    run_dir: &std::path::Path,
    receipt: &state::IntegratedCleanupReceipt,
    cleanup_complete: bool,
) -> Result<()> {
    let path = run_dir.join("run.yaml");
    let mut record: RunRecord = state::load_yaml(&path).unwrap_or_default();
    let worktree = PathBuf::from(&receipt.worktree);
    apply_core_run_projection(
        &mut record,
        CoreRunProjection {
            run_id: &receipt.run_id,
            task_id: &receipt.task_id,
            intent_id: &receipt.intent_id,
            worker: &receipt.worker,
            worktree: &worktree,
            branch: &receipt.branch,
            baseline_oid: &receipt.baseline_oid,
            provenance: receipt.provenance,
        },
    );
    record.integration_base_oid = receipt.integration_base_oid.clone();
    record.integration_worker_oid = receipt.integration_worker_oid.clone();
    record.integration_oid = receipt.integration_oid.clone();
    record.integration_provenance = receipt.provenance;
    record.integration_cleanup_complete = cleanup_complete;
    record.owned_oids = receipt.owned_oids.clone();
    state::write_str_atomic(&path, &crate::yaml::to_string(&record)?)
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
    if let Ok(raw) = std::fs::read_to_string(run_dir.join("feedback.json")) {
        if let Ok(f) = serde_json::from_str::<FeedbackRecord>(&raw) {
            s.push_str(&format!(
                "Feedback cycle {}/{} (retryable={}):\n",
                f.cycle, f.max_cycles, f.retryable
            ));
            for failure in f.failures {
                s.push_str("- Failed check: ");
                s.push_str(&failure);
                s.push('\n');
            }
            for unmet in f.unmet_acceptance {
                s.push_str("- Unmet acceptance: ");
                s.push_str(&unmet);
                s.push('\n');
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
    let current_queue = ws.load_queue().ok();
    let current_intent = current_queue
        .as_ref()
        .map(|q| q.intent_id.clone())
        .filter(|s| !s.is_empty());
    if let Some(intent_id) = current_intent.as_deref() {
        if let Ok(channel) = ws.load_task_channel(intent_id, task_id) {
            if let Some(question) = channel
                .questions
                .iter()
                .rev()
                .find(|question| question.state == QuestionState::Open)
            {
                return Some(question.text.clone());
            }
        }
    }
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
    // Canonical typed questions outrank the legacy conversation fallback. A
    // queue-CAS -> conversation crash may leave an older unattributed worker
    // turn on disk; returning it first would mask the current interaction or
    // receipt-backed capability question.
    if let Some(task) = current_queue.as_ref().and_then(|queue| {
        queue
            .tasks
            .iter()
            .find(|task| task.id == task_id && task.state == TaskState::NeedsUser)
    }) {
        if let Some(crate::yaml::Value::Mapping(interaction)) = task.interaction.as_ref() {
            if let Some(question) = interaction
                .get(crate::yaml::Value::String("decision_question".to_string()))
                .and_then(crate::yaml::Value::as_str)
                .map(str::trim)
                .filter(|question| !question.is_empty())
            {
                return Some(question.to_string());
            }
        }
        if let Some(question) = ws
            .runtime_capability_decision_question(task_id)
            .ok()
            .flatten()
        {
            return Some(question);
        }
    }
    // Legacy fallback: a question seeded straight into the conversation has
    // no result.json. It is pending only while unanswered — i.e. the last turn
    // is still the worker's; once the user replies, the last turn is theirs.
    // Conversation files survive replanning, so scope attributable turns to
    // the current intent.
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

    fn channel_event(
        event_id: &str,
        event_type: ChannelEventType,
        attempt_id: Option<&str>,
    ) -> ChannelEvent {
        ChannelEvent {
            schema_version: 1,
            event_id: event_id.into(),
            session_id: "session-test".into(),
            seq: 0,
            event_type,
            recorded_at: String::new(),
            actor: EventActor {
                kind: EventActorKind::System,
                id: String::new(),
            },
            action_id: None,
            causation_id: None,
            correlation_id: "cor-test".into(),
            task_id: "YARD-001".into(),
            attempt_id: attempt_id.map(str::to_string),
            payload: serde_json::Value::Null,
            raw_ref: None,
        }
    }

    #[test]
    fn finalization_artifact_causation_is_stable_across_recovery_publications() {
        let attempt_id = "run-test";
        let mut events = vec![
            channel_event(
                "evt-attempt",
                ChannelEventType::AttemptPrepared,
                Some(attempt_id),
            ),
            channel_event(
                "evt-worker",
                ChannelEventType::WorkerCompleted,
                Some(attempt_id),
            ),
            channel_event(
                "evt-validation",
                ChannelEventType::ValidationCompleted,
                Some(attempt_id),
            ),
        ];

        assert_eq!(
            finalization_artifact_causation(&events, attempt_id),
            Some("evt-validation".to_string())
        );

        events.push(channel_event(
            "evt-artifact",
            ChannelEventType::ArtifactCreated,
            Some(attempt_id),
        ));
        assert_eq!(
            finalization_artifact_causation(&events, attempt_id),
            Some("evt-validation".to_string())
        );
    }

    #[test]
    fn every_invocation_ordinal_gets_a_distinct_attempt_identity() {
        assert_eq!(attempt_id_for_ordinal("run-1", 1), "run-1");
        assert_eq!(attempt_id_for_ordinal("run-1", 2), "run-1-attempt-2");
        assert_eq!(attempt_id_for_ordinal("run-1", 3), "run-1-attempt-3");
        assert_ne!(
            attempt_id_for_ordinal("run-1", 2),
            attempt_id_for_ordinal("run-1", 3)
        );
    }
    use crate::schemas::{SelectionPolicy, Task, WorkQueue};

    #[test]
    fn auto_push_projects_only_remote_verified_finish_to_done() {
        let make = |status| crate::git_finish::GitFinishRecord {
            schema_version: 2,
            run_id: "run-test".into(),
            task_id: "YARD-001".into(),
            attempted_at: String::new(),
            status,
            policy: crate::git_finish::GitFinishPolicySnapshot {
                auto_push: true,
                remote: "fixture".into(),
                target_ref: "refs/heads/main".into(),
                pre_push_checks: vec![],
            },
            expected_oid: None,
            baseline_oid: String::new(),
            owned_oids: vec![],
            checks: vec![],
            push_invoked: false,
            push_succeeded: false,
            remote_oid: None,
            remote_before_oid: None,
            reason: String::new(),
        };
        for status in [
            crate::git_finish::GitFinishStatus::Prepared,
            crate::git_finish::GitFinishStatus::CheckBlocked,
            crate::git_finish::GitFinishStatus::SafetyBlocked,
            crate::git_finish::GitFinishStatus::GitFailed,
            crate::git_finish::GitFinishStatus::RemoteMismatch,
        ] {
            assert_eq!(
                state_after_git_finish(TaskState::Done, &make(status)),
                TaskState::Partial,
                "{status:?}"
            );
        }
        for status in [
            crate::git_finish::GitFinishStatus::NotNeeded,
            crate::git_finish::GitFinishStatus::Pushed,
            crate::git_finish::GitFinishStatus::AlreadyApplied,
        ] {
            assert_eq!(
                state_after_git_finish(TaskState::Done, &make(status)),
                TaskState::Done,
                "{status:?}"
            );
        }
    }

    #[test]
    fn pending_git_finish_recovery_skips_done_historical_runs_on_other_targets() {
        let root = std::env::temp_dir().join(format!(
            "yard-done-historical-git-finishes-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let ws = Workspace::at(&root);
        let mut q = queue(vec![
            task("YARD-001", TaskState::Done, 10, false),
            task("YARD-005", TaskState::Done, 20, false),
            task("YARD-010", TaskState::Partial, 30, false),
        ]);
        q.intent_id = "intent-git-finish-history".into();
        ws.save_queue(&q).unwrap();

        for (index, task_id, state, target_ref) in [
            (1, "YARD-001", "done", "refs/heads/release-v010-001"),
            (5, "YARD-005", "done", "refs/heads/release-v010-005"),
            (10, "YARD-010", "partial", "refs/heads/main"),
        ] {
            let run_id = format!("run-20990101-0000{index:02}-{task_id}");
            let run_dir = ws.runs_dir().join(&run_id);
            std::fs::create_dir_all(&run_dir).unwrap();
            write_str(&run_dir.join("result.json"), "{\"status\":\"done\"}").unwrap();
            state::save_yaml(
                &run_dir.join("run.yaml"),
                &RunRecord {
                    schema_version: 1,
                    run_id: run_id.clone(),
                    task_id: task_id.into(),
                    intent_id: q.intent_id.clone(),
                    worker: "codex".into(),
                    state: state.into(),
                    started_at: format!("2099-01-01T00:00:{index:02}+00:00"),
                    completed_at: Some(format!("2099-01-01T00:01:{index:02}+00:00")),
                    integration_oid: format!("integration-{index}"),
                    ..Default::default()
                },
            )
            .unwrap();
            ws.save_git_finish_record(
                &run_dir,
                &crate::git_finish::GitFinishRecord {
                    schema_version: 2,
                    run_id,
                    task_id: task_id.into(),
                    attempted_at: String::new(),
                    status: crate::git_finish::GitFinishStatus::CheckBlocked,
                    policy: crate::git_finish::GitFinishPolicySnapshot {
                        auto_push: true,
                        remote: format!("fixture-{index}"),
                        target_ref: target_ref.into(),
                        pre_push_checks: vec![],
                    },
                    expected_oid: Some(format!("integration-{index}")),
                    baseline_oid: format!("baseline-{index}"),
                    owned_oids: vec![format!("integration-{index}")],
                    checks: vec![],
                    push_invoked: false,
                    push_succeeded: false,
                    remote_oid: None,
                    remote_before_oid: None,
                    reason: "historical fixture".into(),
                },
            )
            .unwrap();
        }

        let candidates = pending_git_finishes(&ws, &q);
        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.task_id.as_str())
                .collect::<Vec<_>>(),
            vec!["YARD-010"],
            "Done historical runs must not be re-finalized for unrelated targets"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn pending_git_finish_recovery_retains_only_latest_verified_stale_done_run() {
        let root = std::env::temp_dir().join(format!(
            "yard-latest-verified-stale-git-finish-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let ws = Workspace::at(&root);
        let task_id = "YARD-DONE-STALE";
        let mut q = queue(vec![task(task_id, TaskState::Done, 10, false)]);
        q.intent_id = "intent-latest-verified-stale".into();
        ws.save_queue(&q).unwrap();

        for index in [1, 2] {
            let run_id = format!("run-20990101-00000{index}-{task_id}");
            let run_dir = ws.runs_dir().join(&run_id);
            std::fs::create_dir_all(&run_dir).unwrap();
            write_str(&run_dir.join("result.json"), "{\"status\":\"done\"}").unwrap();
            state::save_yaml(
                &run_dir.join("run.yaml"),
                &RunRecord {
                    schema_version: 1,
                    run_id: run_id.clone(),
                    task_id: task_id.into(),
                    intent_id: q.intent_id.clone(),
                    worker: "codex".into(),
                    state: "partial".into(),
                    started_at: format!("2099-01-01T00:00:0{index}+00:00"),
                    completed_at: Some(format!("2099-01-01T00:01:0{index}+00:00")),
                    integration_oid: format!("integration-{index}"),
                    ..Default::default()
                },
            )
            .unwrap();
            ws.save_git_finish_record(
                &run_dir,
                &crate::git_finish::GitFinishRecord {
                    schema_version: 2,
                    run_id: run_id.clone(),
                    task_id: task_id.into(),
                    attempted_at: String::new(),
                    status: crate::git_finish::GitFinishStatus::Pushed,
                    policy: crate::git_finish::GitFinishPolicySnapshot {
                        auto_push: true,
                        remote: "fixture".into(),
                        target_ref: "refs/heads/main".into(),
                        pre_push_checks: vec![],
                    },
                    expected_oid: Some(format!("integration-{index}")),
                    baseline_oid: format!("baseline-{index}"),
                    owned_oids: vec![format!("integration-{index}")],
                    checks: vec![],
                    push_invoked: true,
                    push_succeeded: true,
                    remote_oid: Some(format!("integration-{index}")),
                    remote_before_oid: Some(format!("baseline-{index}")),
                    reason: "remote_verified".into(),
                },
            )
            .unwrap();
        }

        let candidates = pending_git_finishes(&ws, &q);
        assert_eq!(
            candidates
                .iter()
                .map(|candidate| candidate.run_id.as_str())
                .collect::<Vec<_>>(),
            vec!["run-20990101-000002-YARD-DONE-STALE"],
            "only the latest verified run may repair a stale Done projection"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

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
    fn korean_drain_progress_line_uses_localized_state_label() {
        let leaked = [
            "Running",
            "Done",
            "Failed",
            "Blocked",
            "NeedsUser",
            "Partial",
            "Deferred",
            "Queued",
            "running",
            "done",
            "failed",
            "blocked",
            "needs-you",
            "partial",
            "deferred",
            "queued",
        ];

        for state in [
            TaskState::Running,
            TaskState::Done,
            TaskState::Failed,
            TaskState::Blocked,
            TaskState::NeedsUser,
            TaskState::Partial,
            TaskState::Deferred,
            TaskState::Queued,
        ] {
            let line = task_state_progress_line(Lang::Ko, "YARD-006", state);
            assert!(line.starts_with("YARD-006 \u{2192} "), "{line}");
            assert!(
                line.contains(i18n::task_state_label(Lang::Ko.l(), state)),
                "{line}"
            );
            for token in leaked {
                assert!(
                    !line.contains(token),
                    "Korean progress line leaked English state token {token}: {line}"
                );
            }
        }
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
            artifacts: vec![],
            resources: vec![],
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
            fallback_enabled: None,
            effort: String::new(),
            depends_on: vec![],
            skills: vec![],
            required_capabilities: vec![],
            allowed_scope: vec![],
            acceptance: vec![],
            goal: None,
            validation: None,
            approval: if needs_approval {
                Some(crate::yaml::from_str("required: true").unwrap())
            } else {
                None
            },
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
        write_str(&root.join("fixture.txt"), "fixture\n").unwrap();
        for args in [
            &["config", "user.name", "Yardlet Test"][..],
            &["config", "user.email", "yardlet@example.test"][..],
            &["add", "fixture.txt"][..],
            &["commit", "-q", "-m", "fixture baseline"][..],
        ] {
            let output = std::process::Command::new("git")
                .args(args)
                .current_dir(&root)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                args,
                String::from_utf8_lossy(&output.stderr)
            );
        }
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

    fn finish_record_with_ownership(
        run_id: &str,
        policy: crate::git_finish::GitFinishPolicySnapshot,
        baseline_oid: &str,
        expected_oid: &str,
    ) -> crate::git_finish::GitFinishRecord {
        crate::git_finish::GitFinishRecord {
            schema_version: 2,
            run_id: run_id.into(),
            task_id: "YARD-STAGING".into(),
            attempted_at: String::new(),
            status: crate::git_finish::GitFinishStatus::Prepared,
            policy,
            expected_oid: Some(expected_oid.into()),
            baseline_oid: baseline_oid.into(),
            owned_oids: vec![expected_oid.into()],
            checks: vec![],
            push_invoked: false,
            push_succeeded: false,
            remote_oid: None,
            remote_before_oid: Some(baseline_oid.into()),
            reason: "ready_to_push".into(),
        }
    }

    fn directory_has_ascii_case_insensitive_name(
        directory: &std::path::Path,
        expected: &str,
    ) -> bool {
        std::fs::read_dir(directory).is_ok_and(|entries| {
            entries.filter_map(Result::ok).any(|entry| {
                entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.eq_ignore_ascii_case(expected))
            })
        })
    }

    #[test]
    fn main_owned_run_artifact_names_are_ascii_case_insensitive() {
        for name in [
            "run.yaml",
            "RUN.YAML",
            "Run.Yaml",
            "TASK-PACKET.MD",
            "Worker.Pid",
            "WORKER-OUTPUT.LOG",
            "GIT-FINISH.JSON",
            "Git-Finish.Json",
            "GIT-INTEGRATION.JSON",
            "FEEDBACK.JSON",
            "CANONICAL-STATE-SEED",
            "Canonical-State-Seed",
            "CANCELLED",
            "Partial-Reason",
            "FAILOVER.JSON",
            "Evaluation.Json",
            "VALIDATION.JSON",
            "EVIDENCE",
            "Hooks",
            "validation-0.log",
            "VALIDATION-42.LOG",
        ] {
            assert!(
                is_main_owned_run_artifact_name(std::ffi::OsStr::new(name)),
                "{name} must remain main-owned"
            );
        }
        for name in [
            "result.json",
            "handoff.md",
            "checkpoint.md",
            "report.md",
            "validation.log",
            "validation-.log",
            "validation-one.log",
            "validation-1.log.bak",
            "git-finish.json.bak",
            "canonical-state-seed-copy",
        ] {
            assert!(
                !is_main_owned_run_artifact_name(std::ffi::OsStr::new(name)),
                "{name} must remain importable"
            );
        }
    }

    #[test]
    fn worker_import_keeps_main_reserved_artifacts_at_every_depth() {
        let root = std::env::temp_dir().join(format!(
            "yard-worker-import-reserved-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let staged = root.join("staged");
        let canonical = root.join("canonical");
        for directory in [
            staged.join("nested/deep"),
            staged.join("evidence/canonical-state-seed"),
            staged.join("nested/evidence/canonical-state-seed"),
            canonical.join("evidence/canonical-state-seed"),
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }

        write_str(&staged.join("result.json"), "worker result\n").unwrap();
        write_str(&staged.join("nested/deep/handoff.md"), "worker handoff\n").unwrap();
        for path in [
            staged.join("git-finish.json"),
            staged.join("nested/deep/git-finish.json"),
            staged.join("git-integration.json"),
            staged.join("nested/deep/git-integration.json"),
            staged.join("feedback.json"),
            staged.join("nested/deep/feedback.json"),
        ] {
            write_str(&path, "worker forged\n").unwrap();
        }
        write_str(
            &staged.join("evidence/canonical-state-seed/intent-contract.yaml"),
            "worker forged seed\n",
        )
        .unwrap();
        write_str(
            &staged.join("nested/evidence/canonical-state-seed/work-queue.yaml"),
            "worker forged nested seed\n",
        )
        .unwrap();

        write_str(&canonical.join("git-finish.json"), "main finish\n").unwrap();
        write_str(
            &canonical.join("git-integration.json"),
            "main transaction\n",
        )
        .unwrap();
        write_str(&canonical.join("feedback.json"), "main feedback\n").unwrap();
        write_str(
            &canonical.join("evidence/canonical-state-seed/intent-contract.yaml"),
            "main seed\n",
        )
        .unwrap();

        import_worker_run_artifacts(&staged, &canonical).unwrap();

        assert_eq!(
            std::fs::read_to_string(canonical.join("git-finish.json")).unwrap(),
            "main finish\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("git-integration.json")).unwrap(),
            "main transaction\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("feedback.json")).unwrap(),
            "main feedback\n"
        );
        assert_eq!(
            std::fs::read_to_string(
                canonical.join("evidence/canonical-state-seed/intent-contract.yaml")
            )
            .unwrap(),
            "main seed\n"
        );
        assert!(!canonical.join("nested/deep/git-finish.json").exists());
        assert!(!canonical.join("nested/deep/git-integration.json").exists());
        assert!(!canonical.join("nested/deep/feedback.json").exists());
        assert!(!canonical
            .join("nested/evidence/canonical-state-seed")
            .exists());
        assert_eq!(
            std::fs::read_to_string(canonical.join("result.json")).unwrap(),
            "worker result\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("nested/deep/handoff.md")).unwrap(),
            "worker handoff\n"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn worker_import_rejects_core_control_and_validation_artifacts() {
        let root = std::env::temp_dir().join(format!(
            "yard-worker-import-core-artifacts-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let staged = root.join("staged");
        let canonical = root.join("canonical");
        for directory in [
            staged.join("nested/deep/evidence"),
            staged.join("nested/deep/hooks/pre-run"),
            staged.join("evidence"),
            staged.join("hooks/post-run"),
            canonical.join("nested/deep"),
            canonical.join("evidence"),
            canonical.join("hooks/post-run"),
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }

        for path in [
            staged.join("cancelled"),
            staged.join("partial-reason"),
            staged.join("failover.json"),
            staged.join("evaluation.json"),
            staged.join("validation.json"),
            staged.join("validation-0.log"),
            staged.join("nested/deep/CANCELLED"),
            staged.join("nested/deep/Partial-Reason"),
            staged.join("nested/deep/FAILOVER.JSON"),
            staged.join("nested/deep/Evaluation.Json"),
            staged.join("nested/deep/VALIDATION.JSON"),
            staged.join("nested/deep/VALIDATION-42.LOG"),
        ] {
            write_str(&path, "worker forged\n").unwrap();
        }
        write_str(&staged.join("validation.log"), "worker validation\n").unwrap();
        write_str(
            &staged.join("evidence/repo-summary.md"),
            "worker evidence\n",
        )
        .unwrap();
        write_str(&staged.join("hooks/post-run/check.log"), "worker hook\n").unwrap();
        write_str(
            &staged.join("nested/deep/evidence/forged.txt"),
            "worker evidence\n",
        )
        .unwrap();
        write_str(
            &staged.join("nested/deep/hooks/pre-run/forged.log"),
            "worker hook\n",
        )
        .unwrap();

        for path in [
            canonical.join("partial-reason"),
            canonical.join("failover.json"),
            canonical.join("evaluation.json"),
            canonical.join("validation.json"),
            canonical.join("validation-0.log"),
        ] {
            write_str(&path, "main owned\n").unwrap();
        }
        write_str(
            &canonical.join("evidence/repo-summary.md"),
            "main evidence\n",
        )
        .unwrap();
        write_str(&canonical.join("hooks/post-run/check.log"), "main hook\n").unwrap();

        import_worker_run_artifacts(&staged, &canonical).unwrap();

        assert!(!canonical.join("cancelled").exists());
        for path in [
            canonical.join("partial-reason"),
            canonical.join("failover.json"),
            canonical.join("evaluation.json"),
            canonical.join("validation.json"),
            canonical.join("validation-0.log"),
        ] {
            assert_eq!(std::fs::read_to_string(path).unwrap(), "main owned\n");
        }
        for name in [
            "cancelled",
            "partial-reason",
            "failover.json",
            "evaluation.json",
            "validation.json",
            "validation-42.log",
        ] {
            assert!(
                !directory_has_ascii_case_insensitive_name(&canonical.join("nested/deep"), name),
                "nested {name} must remain main-owned"
            );
        }
        assert_eq!(
            std::fs::read_to_string(canonical.join("evidence/repo-summary.md")).unwrap(),
            "main evidence\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("hooks/post-run/check.log")).unwrap(),
            "main hook\n"
        );
        assert!(!canonical.join("nested/deep/evidence").exists());
        assert!(!canonical.join("nested/deep/hooks").exists());
        assert_eq!(
            std::fs::read_to_string(canonical.join("validation.log")).unwrap(),
            "worker validation\n"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn worker_import_rejects_case_variants_of_main_reserved_artifacts() {
        let root = std::env::temp_dir().join(format!(
            "yard-worker-import-case-reserved-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let staged = root.join("staged");
        let canonical = root.join("canonical");
        for directory in [
            staged.join("nested/deep"),
            staged.join("nested/evidence/CANONICAL-STATE-SEED"),
            canonical.join("evidence/canonical-state-seed"),
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }

        for (path, contents) in [
            (staged.join("RUN.YAML"), "worker forged run\n"),
            (staged.join("GIT-FINISH.JSON"), "worker forged finish\n"),
            (staged.join("Feedback.Json"), "worker forged feedback\n"),
            (staged.join("nested/TASK-PACKET.MD"), "worker packet\n"),
            (staged.join("nested/deep/WORKER.PID"), "123\n"),
            (staged.join("nested/deep/Worker-Output.Log"), "worker log\n"),
            (staged.join("nested/deep/result.json"), "worker result\n"),
            (
                staged.join("nested/evidence/CANONICAL-STATE-SEED/work-queue.yaml"),
                "worker forged seed\n",
            ),
        ] {
            write_str(&path, contents).unwrap();
        }

        for (path, contents) in [
            (canonical.join("run.yaml"), "main run\n"),
            (canonical.join("git-finish.json"), "main finish\n"),
            (canonical.join("feedback.json"), "main feedback\n"),
            (
                canonical.join("evidence/canonical-state-seed/work-queue.yaml"),
                "main seed\n",
            ),
        ] {
            write_str(&path, contents).unwrap();
        }

        import_worker_run_artifacts(&staged, &canonical).unwrap();

        assert_eq!(
            std::fs::read_to_string(canonical.join("run.yaml")).unwrap(),
            "main run\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("git-finish.json")).unwrap(),
            "main finish\n"
        );
        assert_eq!(
            std::fs::read_to_string(canonical.join("feedback.json")).unwrap(),
            "main feedback\n"
        );
        assert_eq!(
            std::fs::read_to_string(
                canonical.join("evidence/canonical-state-seed/work-queue.yaml")
            )
            .unwrap(),
            "main seed\n"
        );
        assert!(!directory_has_ascii_case_insensitive_name(
            &canonical.join("nested"),
            "task-packet.md"
        ));
        assert!(!directory_has_ascii_case_insensitive_name(
            &canonical.join("nested/deep"),
            "worker.pid"
        ));
        assert!(!directory_has_ascii_case_insensitive_name(
            &canonical.join("nested/deep"),
            "worker-output.log"
        ));
        assert!(!directory_has_ascii_case_insensitive_name(
            &canonical.join("nested/evidence"),
            "canonical-state-seed"
        ));
        assert_eq!(
            std::fs::read_to_string(canonical.join("nested/deep/result.json")).unwrap(),
            "worker result\n"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn worker_import_rejects_filesystem_equivalent_unicode_reserved_components() {
        let root = std::env::temp_dir().join(format!(
            "yard-worker-import-unicode-alias-reserved-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let staged = root.join("staged");
        let canonical = root.join("canonical");
        for directory in [
            staged.join("nested/deep"),
            staged.join("nested/ordinary/canonical-ſtate-seed"),
            canonical.join("nested/deep"),
            canonical.join("nested/ordinary/canonical-state-seed"),
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }

        for (path, contents) in [
            (staged.join("task-pacKet.md"), "worker forged packet\n"),
            (
                staged.join("nested/deep/git-finiſh.json"),
                "worker forged finish\n",
            ),
            (
                staged.join("nested/ordinary/canonical-ſtate-seed/work-queue.yaml"),
                "worker forged seed\n",
            ),
            (
                staged.join("nested/deep/검토-결과.json"),
                "allowed unicode artifact\n",
            ),
        ] {
            write_str(&path, contents).unwrap();
        }

        // The regression is meaningful only on a filesystem that really
        // aliases these Unicode spellings to the trusted ASCII entries. APFS
        // in its default case-insensitive mode does; case-sensitive fixtures
        // safely exercise the non-alias boundary instead.
        let unicode_aliases_are_active = std::fs::canonicalize(staged.join("task-pacKet.md"))
            .ok()
            .zip(std::fs::canonicalize(staged.join("task-packet.md")).ok())
            .is_some_and(|(unicode, ascii)| unicode == ascii)
            && std::fs::canonicalize(staged.join("nested/deep/git-finiſh.json"))
                .ok()
                .zip(std::fs::canonicalize(staged.join("nested/deep/git-finish.json")).ok())
                .is_some_and(|(unicode, ascii)| unicode == ascii);
        for (path, contents) in [
            (canonical.join("task-packet.md"), "main packet\n"),
            (
                canonical.join("nested/deep/git-finish.json"),
                "main finish\n",
            ),
            (
                canonical.join("nested/ordinary/canonical-state-seed/work-queue.yaml"),
                "main seed\n",
            ),
        ] {
            write_str(&path, contents).unwrap();
        }

        import_worker_run_artifacts(&staged, &canonical).unwrap();

        if unicode_aliases_are_active {
            assert_eq!(
                std::fs::read_to_string(canonical.join("task-packet.md")).unwrap(),
                "main packet\n"
            );
            assert_eq!(
                std::fs::read_to_string(canonical.join("nested/deep/git-finish.json")).unwrap(),
                "main finish\n"
            );
            assert_eq!(
                std::fs::read_to_string(
                    canonical.join("nested/ordinary/canonical-state-seed/work-queue.yaml")
                )
                .unwrap(),
                "main seed\n"
            );
        } else {
            assert_eq!(
                std::fs::read_to_string(canonical.join("task-packet.md")).unwrap(),
                "main packet\n"
            );
            assert_eq!(
                std::fs::read_to_string(canonical.join("task-pacKet.md")).unwrap(),
                "worker forged packet\n"
            );
            assert_eq!(
                std::fs::read_to_string(canonical.join("nested/deep/git-finish.json")).unwrap(),
                "main finish\n"
            );
            assert_eq!(
                std::fs::read_to_string(canonical.join("nested/deep/git-finiſh.json")).unwrap(),
                "worker forged finish\n"
            );
            assert_eq!(
                std::fs::read_to_string(
                    canonical.join("nested/ordinary/canonical-state-seed/work-queue.yaml")
                )
                .unwrap(),
                "main seed\n"
            );
            assert_eq!(
                std::fs::read_to_string(
                    canonical.join("nested/ordinary/canonical-ſtate-seed/work-queue.yaml")
                )
                .unwrap(),
                "worker forged seed\n"
            );
        }
        assert_eq!(
            std::fs::read_to_string(canonical.join("nested/deep/검토-결과.json")).unwrap(),
            "allowed unicode artifact\n"
        );

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn case_variant_staged_git_finish_is_not_adopted_as_recorded_ownership() {
        let ws = init_test_workspace(
            "case-staged-git-finish-seed",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let config_policy = ws.load_config().unwrap().git_finish;
        let trusted_policy = crate::git_finish::GitFinishPolicySnapshot {
            auto_push: config_policy.auto_push,
            remote: config_policy.remote,
            target_ref: config_policy.target_ref,
            pre_push_checks: vec![],
        };

        let trusted_run_id = "run-20990101-000000-case-trusted";
        let trusted_run_dir = ws.runs_dir().join(trusted_run_id);
        std::fs::create_dir_all(&trusted_run_dir).unwrap();
        let trusted_baseline = "1".repeat(40);
        let trusted_expected = "2".repeat(40);
        let trusted = finish_record_with_ownership(
            trusted_run_id,
            trusted_policy,
            &trusted_baseline,
            &trusted_expected,
        );
        ws.save_git_finish_record(&trusted_run_dir, &trusted)
            .unwrap();

        let unmodified = crate::git_finish::finish_owned_run(
            &ws,
            &trusted_run_dir,
            trusted_run_id,
            "YARD-STAGING",
            TaskState::Done,
            None,
        )
        .unwrap();
        assert_eq!(unmodified.baseline_oid, trusted_baseline);
        assert_eq!(
            unmodified.expected_oid.as_deref(),
            Some(trusted_expected.as_str())
        );
        assert_eq!(unmodified.owned_oids, vec![trusted_expected]);

        let forged_run_id = "run-20990101-000000-case-forged";
        let forged_run_dir = ws.runs_dir().join(forged_run_id);
        let staged = ws
            .agents_dir()
            .join("worktrees/case-staging-seed/.agents/runs")
            .join(forged_run_id);
        std::fs::create_dir_all(&staged).unwrap();
        let forged = finish_record_with_ownership(
            forged_run_id,
            crate::git_finish::GitFinishPolicySnapshot {
                auto_push: true,
                remote: "attacker".into(),
                target_ref: "refs/heads/main".into(),
                pre_push_checks: vec![],
            },
            &"a".repeat(40),
            &"b".repeat(40),
        );
        write_str(
            &staged.join("GIT-FINISH.JSON"),
            &serde_json::to_string_pretty(&forged).unwrap(),
        )
        .unwrap();

        import_worker_run_artifacts(&staged, &forged_run_dir).unwrap();
        let imported_worker_record =
            directory_has_ascii_case_insensitive_name(&forged_run_dir, "git-finish.json");
        let mutated = crate::git_finish::finish_owned_run(
            &ws,
            &forged_run_dir,
            forged_run_id,
            "YARD-STAGING",
            TaskState::Done,
            None,
        )
        .unwrap();
        assert!(!mutated.policy.auto_push);
        assert_eq!(mutated.expected_oid, None);
        assert!(mutated.baseline_oid.is_empty());
        assert!(mutated.owned_oids.is_empty());
        assert_eq!(mutated.status, crate::git_finish::GitFinishStatus::Disabled);
        assert!(
            !imported_worker_record,
            "worker-staged case variant reached the canonical run directory"
        );

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn worker_staged_git_finish_cannot_seed_recorded_ownership() {
        let ws = init_test_workspace(
            "staged-git-finish-seed",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let run_id = "run-20990101-000000-staging-seed";
        let run_dir = ws.runs_dir().join(run_id);
        let staged = ws
            .agents_dir()
            .join("worktrees/staging-seed/.agents/runs")
            .join(run_id);
        std::fs::create_dir_all(&staged).unwrap();
        let forged = finish_record_with_ownership(
            run_id,
            crate::git_finish::GitFinishPolicySnapshot {
                auto_push: true,
                remote: "attacker".into(),
                target_ref: "refs/heads/main".into(),
                pre_push_checks: vec![],
            },
            &"a".repeat(40),
            &"b".repeat(40),
        );
        write_str(
            &staged.join("git-finish.json"),
            &serde_json::to_string_pretty(&forged).unwrap(),
        )
        .unwrap();

        import_worker_run_artifacts(&staged, &run_dir).unwrap();
        let finished = crate::git_finish::finish_owned_run(
            &ws,
            &run_dir,
            run_id,
            "YARD-STAGING",
            TaskState::Done,
            None,
        )
        .unwrap();

        assert_eq!(
            finished.status,
            crate::git_finish::GitFinishStatus::Disabled
        );
        assert!(!finished.policy.auto_push);
        assert_eq!(finished.expected_oid, None);
        assert!(finished.baseline_oid.is_empty());
        assert!(finished.owned_oids.is_empty());
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn worker_staged_git_finish_cannot_replace_main_recorded_ownership() {
        let ws = init_test_workspace(
            "staged-git-finish-replace",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let run_id = "run-20990101-000000-staging-replace";
        let run_dir = ws.runs_dir().join(run_id);
        let staged = ws
            .agents_dir()
            .join("worktrees/staging-replace/.agents/runs")
            .join(run_id);
        std::fs::create_dir_all(&staged).unwrap();
        std::fs::create_dir_all(&run_dir).unwrap();

        let config_policy = ws.load_config().unwrap().git_finish;
        let snapshot = crate::git_finish::GitFinishPolicySnapshot {
            auto_push: config_policy.auto_push,
            remote: config_policy.remote,
            target_ref: config_policy.target_ref,
            pre_push_checks: vec![],
        };
        let trusted_baseline = "1".repeat(40);
        let trusted_expected = "2".repeat(40);
        let trusted =
            finish_record_with_ownership(run_id, snapshot, &trusted_baseline, &trusted_expected);
        ws.save_git_finish_record(&run_dir, &trusted).unwrap();

        let forged = finish_record_with_ownership(
            run_id,
            crate::git_finish::GitFinishPolicySnapshot {
                auto_push: true,
                remote: "attacker".into(),
                target_ref: "refs/heads/main".into(),
                pre_push_checks: vec![],
            },
            &"a".repeat(40),
            &"b".repeat(40),
        );
        write_str(
            &staged.join("git-finish.json"),
            &serde_json::to_string_pretty(&forged).unwrap(),
        )
        .unwrap();

        import_worker_run_artifacts(&staged, &run_dir).unwrap();
        let finished = crate::git_finish::finish_owned_run(
            &ws,
            &run_dir,
            run_id,
            "YARD-STAGING",
            TaskState::Done,
            Some(crate::git_finish::GitFinishOwnership {
                baseline_oid: trusted_baseline.clone(),
                expected_oid: trusted_expected.clone(),
                owned_oids: vec![trusted_expected.clone()],
            }),
        )
        .unwrap();

        assert_eq!(
            finished.status,
            crate::git_finish::GitFinishStatus::Disabled
        );
        assert_eq!(finished.baseline_oid, trusted_baseline);
        assert_eq!(
            finished.expected_oid.as_deref(),
            Some(trusted_expected.as_str())
        );
        assert_eq!(finished.owned_oids, vec![trusted_expected]);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn feedback_cycles_are_persisted_bounded_and_keep_exact_review_evidence() {
        let ws = init_test_workspace(
            "feedback-ledger",
            "schema_version: 1\nrouting: {default_worker: codex}\nworkers: []\n",
        );
        let mut t = task("YARD-FB", TaskState::Running, 10, false);
        t.kind = "review".into();
        t.acceptance = vec![crate::yaml::Value::String("parser tests pass".into())];
        t.goal = Some(crate::schemas::TaskGoal {
            condition: "all acceptance passes".into(),
            max_feedback_cycles: 1,
            feedback_policy: "inject_failed_checks".into(),
        });
        let eval = evaluator::Evaluation {
            run_id: "run-1".into(),
            task_id: t.id.clone(),
            status: "partial".into(),
            checks: vec![evaluator::fatal_failure(
                "review_criteria_pass",
                "criteria failed: AC-001",
            )],
            next_task_state: TaskState::Partial,
        };
        let mut result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: "run-1".into(),
            task_id: t.id.clone(),
            status: "partial".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "review failed".into(),
            verdict: vec![crate::schemas::Verdict {
                criterion_id: "AC-001".into(),
                pass: false,
                evidence: "src/parser.rs:42 still accepts invalid input".into(),
            }],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };

        let run1 = ws.runs_dir().join("run-1");
        std::fs::create_dir_all(&run1).unwrap();
        let first =
            feedback_for_run(&ws, &run1, "run-1", "intent-test", &t, &eval, Some(&result)).unwrap();
        assert_eq!(first.cycle, 1);
        assert_eq!(feedback_next_state(&first), TaskState::Partial);
        assert!(first
            .unmet_acceptance
            .iter()
            .any(|s| { s.contains("src/parser.rs:42") && s.contains("parser tests pass") }));
        write_str(
            &run1.join("feedback.json"),
            &serde_json::to_string(&first).unwrap(),
        )
        .unwrap();

        result.run_id = "run-2".into();
        let run2 = ws.runs_dir().join("run-2");
        std::fs::create_dir_all(&run2).unwrap();
        let second =
            feedback_for_run(&ws, &run2, "run-2", "intent-test", &t, &eval, Some(&result)).unwrap();
        assert_eq!(second.cycle, 2);
        assert_eq!(feedback_next_state(&second), TaskState::NeedsUser);
        assert!(second.terminal_reason.contains("cap exceeded"));
        assert!(second
            .question_for_user
            .as_deref()
            .map(str::trim)
            .is_some_and(|question| question.ends_with('?')));
        let mut invalid = second.clone();
        invalid.question_for_user = Some("   ".into());
        assert_eq!(feedback_next_state(&invalid), TaskState::Failed);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_retry_injects_failed_validation_then_converges_to_done() {
        let source =
            std::env::temp_dir().join(format!("yard-feedback-worker-src-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let worker = write_worker_script(
            &source,
            "worker.sh",
            r##"#!/bin/sh
run_dir="$1"
attempts="$2"
packet_dir="$3"
if [ -f "$attempts" ]; then n=$(cat "$attempts"); else n=0; fi
n=$((n + 1))
printf "%s" "$n" > "$attempts"
cat > "$packet_dir/packet-$n.txt"
run_id=$(basename "$run_dir")
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-FB",
  "status": "done",
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "compact_summary": "attempt $n"
}
EOF
printf "# handoff\nattempt %s\n" "$n" > "$run_dir/handoff.md"
if [ "$n" -eq 1 ]; then
  printf "merge_conflict\n" > "$run_dir/partial-reason"
fi
"##,
        );
        let root = std::env::temp_dir().join(format!("yard-feedback-auto-{}", std::process::id()));
        let attempts = root.join("attempts");
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}, {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&worker),
            shell_literal(&attempts),
            shell_literal(&root)
        );
        let ws = init_test_workspace("feedback-auto", &worker_yaml);
        let attempts = ws.root.join("attempts");
        // Rebuild the profile with paths inside the actual workspace returned
        // by init_test_workspace.
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}, {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&worker),
            shell_literal(&attempts),
            shell_literal(&ws.root)
        );
        write_str(&ws.workers_path(), &worker_yaml).unwrap();

        let mut t = task("YARD-FB", TaskState::Queued, 10, false);
        t.kind = "implementation".into();
        t.goal = Some(crate::schemas::TaskGoal {
            condition: "validation passes".into(),
            max_feedback_cycles: 1,
            feedback_policy: "inject_failed_checks".into(),
        });
        t.validation = Some(
            crate::yaml::from_str(&format!(
                "required: true\ncommands:\n  - 'test \"$(cat {})\" -ge 2'\n",
                attempts.display()
            ))
            .unwrap(),
        );
        let mut q = queue(vec![t]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();

        let events = run_auto(&ws, false, None, Some(1), true, |_| {}).unwrap();
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "2");
        let second_packet = std::fs::read_to_string(ws.root.join("packet-2.txt")).unwrap();
        assert!(second_packet.contains("Feedback cycle 1/1"));
        assert!(second_packet.contains("validation command"));
        assert!(second_packet.contains("validation passes"));
        assert!(events
            .iter()
            .any(|e| e.contains("continuing from its checkpoint")));
        let telemetry = crate::telemetry::read_runs(&ws);
        assert_eq!(telemetry.len(), 2);
        assert_eq!(telemetry[0].feedback_cycle, 1);
        assert_eq!(telemetry[0].max_feedback_cycles, 1);
        assert!(telemetry[0].feedback_retryable);
        assert_eq!(telemetry[1].eval_state, "Done");

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn shell_literal(path: &std::path::Path) -> String {
        serde_json::to_string(&path.display().to_string()).unwrap()
    }

    fn write_worker_script(root: &std::path::Path, name: &str, body: &str) -> std::path::PathBuf {
        let path = root.join(name);
        write_str(&path, body).unwrap();
        path
    }

    fn only_run_dir(ws: &Workspace) -> std::path::PathBuf {
        let mut runs = std::fs::read_dir(ws.runs_dir())
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        runs.sort();
        assert_eq!(
            runs.len(),
            1,
            "expected exactly one run directory: {runs:?}"
        );
        runs.pop().unwrap()
    }

    fn assert_serial_worktree_and_branch_removed(ws: &Workspace, run_dir: &std::path::Path) {
        let record: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert!(record.serial_isolated, "run must own a serial worktree");
        assert!(
            !std::path::Path::new(&record.worktree).exists(),
            "owned worktree must be removed: {}",
            record.worktree
        );
        assert!(
            git_stdout(&ws.root, &["branch", "--list", &record.worktree_branch])
                .unwrap()
                .trim()
                .is_empty(),
            "owned branch must be removed: {}",
            record.worktree_branch
        );
    }

    fn assert_serial_location_removed(ws: &Workspace, run_id: &str, branch: &str) {
        let worktree = ws.agents_dir().join("worktrees").join(run_id);
        assert!(
            !worktree.exists(),
            "owned worktree must be removed: {}",
            worktree.display()
        );
        assert!(
            git_stdout(&ws.root, &["branch", "--list", branch])
                .unwrap()
                .trim()
                .is_empty(),
            "owned branch must be removed: {branch}"
        );
    }

    #[test]
    fn intentless_serial_run_seeds_queue_and_executes_without_leaking_worktree() {
        let source = std::env::temp_dir().join(format!(
            "yard-intentless-serial-worker-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let builder = write_worker_script(
            &source,
            "builder.sh",
            r##"#!/bin/sh
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
test -f .agents/work-queue.yaml
test ! -e .agents/intent-contract.yaml
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-NO-INTENT",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "intent 없이 실행 완료",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# handoff\n" > "$run_dir/handoff.md"
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder)
        );
        let ws = init_test_workspace("intentless-serial-run", &worker_yaml);
        std::fs::remove_file(ws.intent_path()).unwrap();
        ws.save_queue(&queue(vec![task(
            "YARD-NO-INTENT",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-NO-INTENT".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.result_state, Some(TaskState::Done));
        assert!(report
            .run_dir
            .join("evidence/canonical-state-seed/work-queue.yaml")
            .is_file());
        assert!(!report
            .run_dir
            .join("evidence/canonical-state-seed/intent-contract.yaml")
            .exists());
        assert_serial_worktree_and_branch_removed(&ws, &report.run_dir);

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn prepare_error_after_worktree_creation_removes_worktree_and_branch() {
        let ws = init_test_workspace(
            "serial-prepare-error-cleanup",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let run_id = "run-20990101-000000-prepare-error";
        let task_id = "YARD-PREPARE-ERR";
        let branch = format!("yard/{}/{}", task_id.to_lowercase(), run_id);
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(run_dir.join("evidence")).unwrap();
        write_str(
            &run_dir.join("evidence/canonical-state-seed"),
            "blocks seed directory creation\n",
        )
        .unwrap();

        prepare_serial_worktree(&ws, &run_dir, run_id, task_id)
            .err()
            .expect("seed directory creation must fail after worktree creation");

        assert_serial_location_removed(&ws, run_id, &branch);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[cfg(unix)]
    #[test]
    fn post_create_queue_write_error_removes_worktree_and_branch() {
        use std::os::unix::fs::PermissionsExt;

        let ws = init_test_workspace(
            "serial-post-create-error-cleanup",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers:\n  - id: builder\n    invocation: {command: bash}\n",
        );
        ws.save_queue(&queue(vec![task(
            "YARD-POST-CREATE-ERR",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();
        let hooks = ws.agents_dir().join("hooks/pre-run.d");
        std::fs::create_dir_all(&hooks).unwrap();
        let hook = hooks.join("00-break-queue-write.sh");
        write_str(
            &hook,
            "#!/bin/sh\nrm -f .agents/work-queue.yaml\nmkdir .agents/work-queue.yaml\nexit 0\n",
        )
        .unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();

        run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-POST-CREATE-ERR".into()),
                ..opts()
            },
        )
        .err()
        .expect("the hook-created queue directory must fail the post-create queue write");

        assert_serial_worktree_and_branch_removed(&ws, &only_run_dir(&ws));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[cfg(unix)]
    #[test]
    fn spawn_error_removes_owned_serial_worktree_and_branch() {
        use std::os::unix::fs::PermissionsExt;

        let ws = init_test_workspace(
            "serial-spawn-error-cleanup",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let worker = write_worker_script(
            &ws.root,
            "vanishing-worker.sh",
            r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  rm -f "$0"
  printf "vanishing-worker 1.0\n"
  exit 0
fi
exit 0
"#,
        );
        let mut permissions = std::fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&worker, permissions).unwrap();
        write_str(
            &ws.workers_path(),
            &format!(
                "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: {}\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
                shell_literal(&worker)
            ),
        )
        .unwrap();
        ws.save_queue(&queue(vec![task(
            "YARD-SPAWN-ERR",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        let error = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-SPAWN-ERR".into()),
                ..opts()
            },
        )
        .err()
        .expect("the worker binary disappears after readiness probing");

        assert!(error.to_string().contains("spawning worker"), "{error:#}");
        assert_serial_worktree_and_branch_removed(&ws, &only_run_dir(&ws));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn import_error_after_worker_run_retains_owned_serial_worktree() {
        let source = std::env::temp_dir().join(format!(
            "yard-serial-import-error-source-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let worker = write_worker_script(
            &source,
            "remove-staging.sh",
            r#"#!/bin/sh
run_dir="$1"
cat >/dev/null
rm -rf "$run_dir"
exit 0
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&worker)
        );
        let ws = init_test_workspace("serial-import-error-cleanup", &worker_yaml);
        ws.save_queue(&queue(vec![task(
            "YARD-IMPORT-ERR",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-IMPORT-ERR".into()),
                ..opts()
            },
        )
        .err()
        .expect("removing the staging run directory must fail artifact import");

        let record: RunRecord = state::load_yaml(&only_run_dir(&ws).join("run.yaml")).unwrap();
        assert!(std::path::Path::new(&record.worktree).exists());
        assert!(
            !git_stdout(&ws.root, &["branch", "--list", &record.worktree_branch])
                .unwrap()
                .trim()
                .is_empty()
        );
        crate::parallel::remove_worktree(
            &ws.root,
            std::path::Path::new(&record.worktree),
            &record.worktree_branch,
        );
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn receipt_persist_error_after_merge_retains_worktree_and_refs() {
        let source = std::env::temp_dir().join(format!(
            "yard-receipt-persist-worker-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let worker = write_worker_script(
            &source,
            "worker.sh",
            r#"#!/bin/sh
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
printf 'worker change\n' > receipt-owned.txt
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-RECEIPT-ERR",
  "status": "done",
  "validation": {"commands_run": [], "passed": true, "failures": []},
  "compact_summary": "worker completed before receipt failure"
}
EOF
printf '# handoff\n' > "$run_dir/handoff.md"
"#,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&worker)
        );
        let ws = init_test_workspace("receipt-persist-error", &worker_yaml);
        let mut config = ws.load_config().unwrap();
        config.auto_commit = true;
        state::save_yaml(&ws.config_path(), &config).unwrap();
        let blocker = ws.checkpoints_dir().join("integrated-cleanup");
        write_str(&blocker, "blocks receipt directory creation\n").unwrap();
        let mut queued = task("YARD-RECEIPT-ERR", TaskState::Queued, 10, false);
        queued.kind = "implementation".into();
        ws.save_queue(&queue(vec![queued])).unwrap();

        let error = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-RECEIPT-ERR".into()),
                ..opts()
            },
        )
        .err()
        .expect("the blocked core receipt path must fail finalization");

        assert!(
            error.to_string().contains("integrated-cleanup"),
            "{error:#}"
        );
        let run_dir = only_run_dir(&ws);
        let record: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert!(std::path::Path::new(&record.worktree).exists());
        let target = git_stdout(
            &ws.root,
            &[
                "show-ref",
                "--verify",
                &format!("refs/heads/{}", record.worktree_branch),
            ],
        );
        let transaction = git_stdout(
            &ws.root,
            &[
                "show-ref",
                "--verify",
                &format!("refs/heads/yardlet-txn/{}", record.worktree_branch),
            ],
        );
        assert!(target.is_ok() || transaction.is_ok());
        assert!(ws.root.join("receipt-owned.txt").exists());
        assert!(ws.load_git_finish_record(&run_dir).is_err());

        crate::parallel::remove_worktree(
            &ws.root,
            std::path::Path::new(&record.worktree),
            &record.worktree_branch,
        );
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn no_ready_worker_removes_owned_serial_worktree_and_branch() {
        let ws = init_test_workspace(
            "serial-no-ready-cleanup",
            "schema_version: 1\nrouting: {default_worker: missing}\nworkers:\n  - id: missing\n    invocation: {command: yardlet-definitely-missing-worker-command}\n",
        );
        ws.save_queue(&queue(vec![task(
            "YARD-NO-READY",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        let error = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-NO-READY".into()),
                ..opts()
            },
        )
        .err()
        .expect("an unready worker must stop before spawn");

        assert!(error.to_string().contains("no invocable worker"), "{error}");
        assert_serial_worktree_and_branch_removed(&ws, &only_run_dir(&ws));
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn user_stop_removes_owned_serial_worktree_and_branch() {
        let source = std::env::temp_dir().join(format!(
            "yard-serial-user-stop-source-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let worker = write_worker_script(
            &source,
            "stop-worker.sh",
            r#"#!/bin/sh
run_dir="$1"
canonical_runs="$2"
run_id=$(basename "$run_dir")
cat >/dev/null
touch "$canonical_runs/$run_id/cancelled"
exit 1
"#,
        );
        let ws = init_test_workspace(
            "serial-user-stop-cleanup",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        write_str(
            &ws.workers_path(),
            &format!(
                "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
                shell_literal(&worker),
                shell_literal(&ws.runs_dir())
            ),
        )
        .unwrap();
        ws.save_queue(&queue(vec![task(
            "YARD-STOP",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-STOP".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.result_state, Some(TaskState::Queued));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Queued);
        assert_serial_worktree_and_branch_removed(&ws, &report.run_dir);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn serial_worker_uses_owned_worktree_and_main_imports_result() {
        let source = std::env::temp_dir().join(format!(
            "yard-serial-worktree-worker-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let payload = source.join("payload.txt");
        write_str(&payload, "worker change\n").unwrap();
        let builder = write_worker_script(
            &source,
            "builder.sh",
            r##"#!/bin/sh
run_dir="$1"
payload="$2"
run_id=$(basename "$run_dir")
cwd=$(pwd)
cat >/dev/null
cat "$payload" > owned.txt
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-ISO",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": ["owned.txt"], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "$cwd",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# worker handoff\n" > "$run_dir/handoff.md"
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder),
            shell_literal(&payload)
        );
        let ws = init_test_workspace("serial-owned-worktree", &worker_yaml);
        write_str(&ws.root.join("owned.txt"), "baseline\n").unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .args(args)
                .current_dir(&ws.root)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {:?}: {}",
                args,
                String::from_utf8_lossy(&output.stderr)
            );
        };
        git(&["config", "user.name", "Yardlet Test"]);
        git(&["config", "user.email", "yardlet@example.test"]);
        git(&["add", "owned.txt"]);
        git(&["commit", "-q", "-m", "baseline"]);
        let mut q = queue(vec![task("YARD-ISO", TaskState::Queued, 10, false)]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();
        let baseline_head = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-ISO".into()),
                ..opts()
            },
        )
        .unwrap();

        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let result: RunResult = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("result.json")).unwrap(),
        )
        .unwrap();
        assert_ne!(record.worktree, ".");
        assert_eq!(
            std::fs::canonicalize(&result.compact_summary).unwrap(),
            std::fs::canonicalize(&record.worktree).unwrap()
        );
        assert!(std::fs::canonicalize(&record.worktree)
            .unwrap()
            .starts_with(std::fs::canonicalize(ws.agents_dir()).unwrap()));
        assert_eq!(
            std::fs::read_to_string(ws.root.join("owned.txt")).unwrap(),
            "baseline\n"
        );
        assert!(std::path::Path::new(&record.worktree)
            .join("owned.txt")
            .exists());
        assert!(report.run_dir.join("result.json").exists());
        assert_eq!(report.result_state, Some(TaskState::Partial));
        assert_eq!(ws.load_queue().unwrap().tasks[0].id, "YARD-ISO");
        assert_eq!(
            git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap().trim(),
            baseline_head
        );

        // Explicit opt-in integrates only the isolated diff. A concurrent dirty
        // edit in the main checkout remains unstaged and unattributed.
        let retained_default_off = record.worktree.clone();
        let mut config = std::fs::read_to_string(ws.config_path()).unwrap();
        config.push_str("auto_commit: true\n");
        write_str(&ws.config_path(), &config).unwrap();
        write_str(&ws.root.join("fixture.txt"), "user concurrent edit\n").unwrap();
        let mut q = ws.load_queue().unwrap();
        q.tasks[0].state = TaskState::Queued;
        ws.save_queue(&q).unwrap();

        let integrated = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-ISO".into()),
                ..opts()
            },
        )
        .unwrap();
        assert_eq!(integrated.result_state, Some(TaskState::Done));
        assert_eq!(
            std::fs::read_to_string(ws.root.join("owned.txt")).unwrap(),
            "worker change\n"
        );
        assert_eq!(
            std::fs::read_to_string(ws.root.join("fixture.txt")).unwrap(),
            "user concurrent edit\n"
        );
        assert!(git_stdout(&ws.root, &["diff", "--cached", "--name-only"])
            .unwrap()
            .trim()
            .is_empty());
        let integrated_names =
            git_stdout(&ws.root, &["diff", "--name-only", "HEAD^1", "HEAD"]).unwrap();
        assert!(integrated_names.lines().any(|path| path == "owned.txt"));
        assert!(!integrated_names.lines().any(|path| path == "fixture.txt"));
        let integrated_record: RunRecord =
            state::load_yaml(&integrated.run_dir.join("run.yaml")).unwrap();
        assert_eq!(
            integrated_record.integration_oid,
            git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap().trim()
        );
        assert_serial_worktree_and_branch_removed(&ws, &integrated.run_dir);
        assert!(std::path::Path::new(&retained_default_off).exists());

        // An overlapping concurrent main edit is never staged or overwritten.
        // Git refuses the merge, Yardlet records Partial, and keeps the owned
        // worktree for inspection.
        write_str(&payload, "third worker change\n").unwrap();
        write_str(&ws.root.join("owned.txt"), "user overlapping edit\n").unwrap();
        let mut q = ws.load_queue().unwrap();
        q.tasks[0].state = TaskState::Queued;
        ws.save_queue(&q).unwrap();
        let conflicted = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-ISO".into()),
                ..opts()
            },
        )
        .unwrap();
        assert_eq!(conflicted.result_state, Some(TaskState::Partial));
        assert_eq!(
            std::fs::read_to_string(ws.root.join("owned.txt")).unwrap(),
            "user overlapping edit\n"
        );
        assert!(git_stdout(&ws.root, &["diff", "--cached", "--name-only"])
            .unwrap()
            .trim()
            .is_empty());
        let conflicted_record: RunRecord =
            state::load_yaml(&conflicted.run_dir.join("run.yaml")).unwrap();
        assert!(std::path::Path::new(&conflicted_record.worktree).exists());
        assert_eq!(
            std::fs::read_to_string(conflicted.run_dir.join("partial-reason"))
                .unwrap()
                .trim(),
            "merge_conflict"
        );

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn run_serial_worker_commit_case(
        name: &str,
        task_id: &str,
        mode: &str,
        auto_commit: bool,
    ) -> (Workspace, RunReport, PathBuf) {
        let source = std::env::temp_dir().join(format!(
            "yard-serial-worker-commit-{name}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let builder = write_worker_script(
            &source,
            "builder.sh",
            r##"#!/bin/sh
run_dir="$1"
task_id="$2"
mode="$3"
run_id=$(basename "$run_dir")
cat >/dev/null
case "$mode" in
  ordinary)
    printf "committed deliverable\n" > committed.txt
    git add -- committed.txt
    git -c user.name="Worker" -c user.email="worker@example.test" commit -q -m "worker commit"
    ;;
  ordinary-detach)
    printf "committed deliverable\n" > committed.txt
    git add -- committed.txt
    git -c user.name="Worker" -c user.email="worker@example.test" commit -q -m "worker commit"
    git checkout -q --detach HEAD~1
    ;;
  canonical)
    printf "schema_version: 1\nrouting: {default_worker: attacker}\nworkers: []\n" > .agents/workers.yaml
    git add -- .agents/workers.yaml
    git -c user.name="Worker" -c user.email="worker@example.test" commit -q -m "worker canonical commit"
    ;;
  canonical-detach)
    printf "schema_version: 1\nsecret_scrub: disabled-by-worker\n" > .agents/tool-policy.yaml
    git add -- .agents/tool-policy.yaml
    git -c user.name="Worker" -c user.email="worker@example.test" commit -q -m "worker canonical commit"
    git checkout -q --detach HEAD~1
    ;;
	  committed-and-uncommitted)
	    printf "committed deliverable\n" > committed.txt
	    git add -- committed.txt
	    git -c user.name="Worker" -c user.email="worker@example.test" commit -q -m "worker commit"
	    printf "schema_version: 1\nid: worker-uncommitted\nsummary: forbidden\nstatus: accepted\n" > .agents/intent-contract.yaml
	    ;;
  harness-asset)
    mkdir -p .agents/skills/example
    printf '%s\n' '---' 'name: example' 'description: fixture' '---' > .agents/skills/example/SKILL.md
    ;;
  anchor-probe)
    test -f "$run_dir/evidence/repo-summary.md" || exit 42
    ;;
esac
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
  "compact_summary": "worker commit case",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# worker handoff\n" > "$run_dir/handoff.md"
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}, {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder), task_id, mode
        );
        let ws = init_test_workspace(name, &worker_yaml);
        if mode == "preexisting-learned-rule" {
            write_str(
                &ws.agents_dir().join("rules/learned-from-earlier-run.md"),
                "# Earlier learning\n\nDo not blame the next worker.\n",
            )
            .unwrap();
        }
        if mode == "preexisting-dirty-tracked-rule" {
            let rule = ws.agents_dir().join("rules/tracked-dirty.md");
            write_str(&rule, "# Tracked baseline\n").unwrap();
            git_stdout(&ws.root, &["add", ".agents/rules/tracked-dirty.md"]).unwrap();
            git_stdout(&ws.root, &["commit", "-q", "-m", "track harness fixture"]).unwrap();
            write_str(&rule, "# User dirty edit\n").unwrap();
        }
        if mode == "canonical-detach" {
            write_str(
                &ws.agents_dir().join("tool-policy.yaml"),
                "schema_version: 1\nsecret_scrub: enabled\n",
            )
            .unwrap();
            for args in [
                &["add", ".agents/tool-policy.yaml"][..],
                &["commit", "-q", "-m", "tracked canonical policy baseline"][..],
            ] {
                let output = std::process::Command::new("git")
                    .args(args)
                    .current_dir(&ws.root)
                    .output()
                    .unwrap();
                assert!(
                    output.status.success(),
                    "git {:?}: {}",
                    args,
                    String::from_utf8_lossy(&output.stderr)
                );
            }
        }
        if auto_commit {
            let mut config = std::fs::read_to_string(ws.config_path()).unwrap();
            config.push_str("auto_commit: true\n");
            write_str(&ws.config_path(), &config).unwrap();
        }
        let mut q = queue(vec![task(task_id, TaskState::Queued, 10, false)]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();
        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some(task_id.into()),
                ..opts()
            },
        )
        .unwrap();
        (ws, report, source)
    }

    #[test]
    fn serial_evidence_combines_committed_diff_with_uncommitted_status() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-combined-commit-evidence",
            "YARD-COMBINED-EVIDENCE",
            "committed-and-uncommitted",
            false,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);

        let evidence = serial_worktree_evidence(wt, &report.run_dir).unwrap().paths;

        assert!(
            evidence.iter().any(|path| path == "committed.txt"),
            "baseline..run-owned-branch-tip committed paths must be retained: {evidence:?}"
        );
        assert!(
            evidence
                .iter()
                .any(|path| path == ".agents/intent-contract.yaml"),
            "uncommitted status paths must remain in the combined evidence: {evidence:?}"
        );

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_commit_off_retains_worker_committed_deliverable_as_partial() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-default-off-worker-commit",
            "YARD-DEFAULT-OFF-COMMIT",
            "ordinary",
            false,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);

        assert_eq!(report.result_state, Some(TaskState::Partial));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
        assert_eq!(
            std::fs::read_to_string(report.run_dir.join("partial-reason"))
                .unwrap()
                .trim(),
            "auto_commit_disabled"
        );
        assert!(wt.join("committed.txt").is_file());
        assert!(!ws.root.join("committed.txt").exists());
        assert!(
            !git_stdout(&ws.root, &["branch", "--list", &record.worktree_branch])
                .unwrap()
                .trim()
                .is_empty(),
            "the worker-owned branch must remain available for manual recovery"
        );

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_commit_off_retains_harness_asset_as_partial() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-default-off-harness-asset",
            "YARD-DEFAULT-OFF-HARNESS",
            "harness-asset",
            false,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);

        assert_eq!(report.result_state, Some(TaskState::Partial));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
        assert_eq!(
            std::fs::read_to_string(report.run_dir.join("partial-reason"))
                .unwrap()
                .trim(),
            "auto_commit_disabled"
        );
        assert!(wt.join(".agents/skills/example/SKILL.md").is_file());
        assert!(!ws.root.join(".agents/skills/example/SKILL.md").exists());

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_commit_on_blocks_worker_committed_canonical_mutation_before_merge() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-worker-canonical-commit",
            "YARD-CANONICAL-COMMIT",
            "canonical",
            true,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);
        let evaluation: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let forbidden = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "forbidden_paths_untouched")
            .unwrap();

        assert_eq!(report.result_state, Some(TaskState::NeedsUser));
        assert_eq!(forbidden["passed"], false);
        assert!(forbidden["note"]
            .as_str()
            .unwrap()
            .contains(".agents/workers.yaml"));
        assert!(record.integration_oid.is_empty());
        assert!(wt.exists(), "the rejected worktree must be retained");
        assert!(std::fs::read_to_string(ws.intent_path())
            .unwrap()
            .contains("id: intent-test"));

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_commit_on_integrates_harness_asset() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-auto-commit-harness-asset",
            "YARD-AUTO-COMMIT-HARNESS",
            "harness-asset",
            true,
        );

        assert_eq!(report.result_state, Some(TaskState::Done));
        assert!(ws.root.join(".agents/skills/example/SKILL.md").is_file());
        let integrated_names =
            git_stdout(&ws.root, &["diff", "--name-only", "HEAD^1", "HEAD"]).unwrap();
        assert!(
            integrated_names
                .lines()
                .any(|path| path == ".agents/skills/example/SKILL.md"),
            "integrated diff should contain the harness asset: {integrated_names}"
        );

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn serial_worker_packet_repo_summary_anchor_exists_before_spawn() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-repo-summary-anchor",
            "YARD-REPO-SUMMARY-ANCHOR",
            "anchor-probe",
            false,
        );

        assert_eq!(report.result_state, Some(TaskState::Done));
        assert!(report.run_dir.join("evidence/repo-summary.md").is_file());

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn serial_evidence_does_not_attribute_preexisting_learned_rule_to_next_worker() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-preexisting-learned-rule",
            "YARD-PREEXISTING-LEARNED-RULE",
            "preexisting-learned-rule",
            false,
        );

        assert_eq!(report.result_state, Some(TaskState::Done));
        let evaluation: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let disclosure = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "diff_matches_report")
            .unwrap();
        assert_eq!(disclosure["passed"], true);

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn serial_seed_cleanup_preserves_preexisting_dirty_tracked_harness_file() {
        for (name, auto_commit) in [("off", false), ("on", true)] {
            let (ws, report, source) = run_serial_worker_commit_case(
                &format!("serial-dirty-tracked-harness-{name}"),
                &format!("YARD-DIRTY-TRACKED-HARNESS-{}", name.to_uppercase()),
                "preexisting-dirty-tracked-rule",
                auto_commit,
            );

            assert_eq!(report.result_state, Some(TaskState::Done));
            assert_eq!(
                std::fs::read_to_string(ws.agents_dir().join("rules/tracked-dirty.md")).unwrap(),
                "# User dirty edit\n"
            );
            assert!(git_stdout(
                &ws.root,
                &[
                    "diff",
                    "--name-only",
                    "--",
                    ".agents/rules/tracked-dirty.md"
                ]
            )
            .unwrap()
            .lines()
            .any(|path| path == ".agents/rules/tracked-dirty.md"));

            let _ = std::fs::remove_dir_all(&source);
            let _ = std::fs::remove_dir_all(ws.root);
        }
    }

    #[test]
    fn auto_commit_on_blocks_detached_head_canonical_commit_before_merge() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-worker-canonical-detached-head",
            "YARD-CANONICAL-DETACHED-HEAD",
            "canonical-detach",
            true,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);
        let evaluation: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(report.run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let forbidden = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "forbidden_paths_untouched")
            .unwrap();

        assert_eq!(report.result_state, Some(TaskState::NeedsUser));
        assert_eq!(forbidden["passed"], false);
        assert!(forbidden["note"]
            .as_str()
            .unwrap()
            .contains(".agents/tool-policy.yaml"));
        assert!(record.integration_oid.is_empty());
        assert!(wt.exists(), "the rejected worktree must be retained");
        assert_eq!(
            git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap().trim(),
            record.baseline_oid,
            "main must remain at the pre-worker baseline"
        );
        assert!(
            std::fs::read_to_string(ws.agents_dir().join("tool-policy.yaml"))
                .unwrap()
                .contains("secret_scrub: enabled")
        );

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn auto_commit_off_retains_detached_head_branch_commit_as_partial() {
        let (ws, report, source) = run_serial_worker_commit_case(
            "serial-default-off-detached-head",
            "YARD-DEFAULT-OFF-DETACHED-HEAD",
            "ordinary-detach",
            false,
        );
        let record: RunRecord = state::load_yaml(&report.run_dir.join("run.yaml")).unwrap();
        let wt = std::path::Path::new(&record.worktree);

        assert_eq!(report.result_state, Some(TaskState::Partial));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
        assert_eq!(
            std::fs::read_to_string(report.run_dir.join("partial-reason"))
                .unwrap()
                .trim(),
            "auto_commit_disabled"
        );
        assert!(wt.exists(), "the detached worktree must be retained");
        assert!(
            !git_stdout(&ws.root, &["branch", "--list", &record.worktree_branch])
                .unwrap()
                .trim()
                .is_empty(),
            "the run-owned branch must remain available for manual recovery"
        );
        assert!(!ws.root.join("committed.txt").exists());

        crate::parallel::remove_worktree(&ws.root, wt, &record.worktree_branch);
        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn live_serial_evidence_ignores_clean_seed_but_flags_worker_mutation() {
        let source = std::env::temp_dir().join(format!(
            "yard-live-serial-seed-source-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let builder = write_worker_script(
            &source,
            "builder.sh",
            r##"#!/bin/sh
run_dir="$1"
task_id="$2"
mutate_seed="$3"
run_id=$(basename "$run_dir")
cat >/dev/null
if [ "$mutate_seed" = "yes" ]; then
  printf "schema_version: 1\nid: worker-mutated\nsummary: forbidden\nstatus: accepted\n" > "$run_dir/../../intent-contract.yaml"
fi
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
  "compact_summary": "serial seed case",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# worker handoff\n" > "$run_dir/handoff.md"
"##,
        );
        let run_case = |name: &str, task_id: &str, mutate_seed: &str| {
            let worker_yaml = format!(
                "schema_version: 1\nrouting:\n  default_worker: builder\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\", {}, {}]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
                shell_literal(&builder), task_id, mutate_seed
            );
            let ws = init_test_workspace(name, &worker_yaml);
            let mut q = queue(vec![task(task_id, TaskState::Queued, 10, false)]);
            q.intent_id = "intent-test".into();
            ws.save_queue(&q).unwrap();
            let report = run_next(
                &ws,
                &RunOptions {
                    execute: true,
                    target: Some(task_id.into()),
                    ..opts()
                },
            )
            .unwrap();
            (ws, report)
        };

        let (clean_ws, clean) = run_case("live-serial-clean-seed", "YARD-CLEAN-SEED", "no");
        assert_eq!(
            clean.result_state,
            Some(TaskState::Done),
            "the exact main-owned seed copies are not worker mutations: {:?}",
            clean.lines
        );
        assert!(!clean.run_dir.join("feedback.json").exists());
        let _ = std::fs::remove_dir_all(clean_ws.root);

        let (mutated_ws, mutated) =
            run_case("live-serial-mutated-seed", "YARD-MUTATED-SEED", "yes");
        assert_eq!(
            mutated.result_state,
            Some(TaskState::NeedsUser),
            "a live serial canonical mutation must fail the forbidden gate: {:?}",
            mutated.lines
        );
        let evaluation: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(mutated.run_dir.join("evaluation.json")).unwrap(),
        )
        .unwrap();
        let forbidden = evaluation["checks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|check| check["name"] == "forbidden_paths_untouched")
            .unwrap();
        assert_eq!(forbidden["passed"], false);
        assert!(forbidden["note"]
            .as_str()
            .unwrap()
            .contains(".agents/intent-contract.yaml"));
        assert!(std::fs::read_to_string(mutated_ws.intent_path())
            .unwrap()
            .contains("id: intent-test"));
        let record: RunRecord = state::load_yaml(&mutated.run_dir.join("run.yaml")).unwrap();
        assert!(std::path::Path::new(&record.worktree).exists());
        crate::parallel::remove_worktree(
            &mutated_ws.root,
            std::path::Path::new(&record.worktree),
            &record.worktree_branch,
        );
        let _ = std::fs::remove_dir_all(mutated_ws.root);
        let _ = std::fs::remove_dir_all(source);
    }

    #[cfg(unix)]
    #[test]
    fn run_report_session_comes_from_exact_fresh_codex_child() {
        use std::os::unix::fs::PermissionsExt;

        const EXPECTED_SESSION: &str = "11111111-2222-4333-8444-555555555555";
        let source = std::env::temp_dir().join(format!(
            "yard-codex-session-report-src-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let fake_codex = write_worker_script(
            &source,
            "codex",
            r#"#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'codex-test 0.0.0'
  exit 0
fi
run_dir=
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--add-dir" ]; then
    shift
    run_dir=$1
  fi
  shift
done
if [ -z "$run_dir" ]; then
  printf '%s\n' 'missing --add-dir' >&2
  exit 2
fi
run_id=${run_dir##*/}
printf '%s\n' '{"type":"thread.started","thread_id":"11111111-2222-4333-8444-555555555555"}'
/bin/cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-SESSION",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "session captured",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
/bin/cat > "$run_dir/handoff.md" <<EOF
# Worker handoff
session captured
EOF
exit 0
"#,
        );
        let mut permissions = std::fs::metadata(&fake_codex).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&fake_codex, permissions).unwrap();

        let worker_yaml = format!(
            "schema_version: 1\nrouting:\n  default_worker: codex\n  fallback_order: [codex]\nworkers:\n  - id: codex\n    invocation:\n      command: {}\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&fake_codex)
        );
        let ws = init_test_workspace("codex-session-report", &worker_yaml);
        ws.save_queue(&queue(vec![task(
            "YARD-SESSION",
            TaskState::Queued,
            10,
            false,
        )]))
        .unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-SESSION".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.worker_id, "codex");
        assert_eq!(report.result_state, Some(TaskState::Done));
        assert_eq!(
            report.session.as_deref(),
            Some(EXPECTED_SESSION),
            "RunReport must expose only the exact fresh child's stdout thread id"
        );

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn worker_staging_cannot_forge_user_cancellation_or_partial_reason() {
        let source = std::env::temp_dir().join(format!(
            "yard-worker-forged-cancel-src-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&source);
        std::fs::create_dir_all(&source).unwrap();
        let builder = write_worker_script(
            &source,
            "builder.sh",
            r##"#!/bin/sh
run_dir="$1"
run_id=$(basename "$run_dir")
cat >/dev/null
cat > "$run_dir/result.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$run_id",
  "task_id": "YARD-FORGED-CANCEL",
  "status": "done",
  "intent_adherence": { "drift_detected": false, "notes": "" },
  "changes": { "files_modified": [], "files_created": [], "files_deleted": [] },
  "validation": { "commands_run": [], "passed": true, "failures": [] },
  "question_for_user": null,
  "compact_summary": "worker finished",
  "verdict": [],
  "harness_suggestions": [],
  "follow_up_tasks": []
}
EOF
printf "# worker handoff\n" > "$run_dir/handoff.md"
touch "$run_dir/cancelled"
printf "merge_conflict\n" > "$run_dir/partial-reason"
"##,
        );
        let worker_yaml = format!(
            "schema_version: 1\nrouting: {{default_worker: builder}}\nworkers:\n  - id: builder\n    invocation:\n      command: bash\n      args: [{}, \"{{run_dir}}\"]\n    limits:\n      max_wall_minutes: 1\n      max_retries: 0\n",
            shell_literal(&builder)
        );
        let ws = init_test_workspace("worker-forged-cancel", &worker_yaml);
        let mut q = queue(vec![task(
            "YARD-FORGED-CANCEL",
            TaskState::Queued,
            10,
            false,
        )]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();

        let report = run_next(
            &ws,
            &RunOptions {
                execute: true,
                target: Some("YARD-FORGED-CANCEL".into()),
                ..opts()
            },
        )
        .unwrap();

        assert_eq!(report.result_state, Some(TaskState::Done));
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);
        assert!(!report.run_dir.join("cancelled").exists());
        assert!(!report.run_dir.join("partial-reason").exists());
        assert!(!report
            .lines
            .iter()
            .any(|line| line.contains("stopped by user")));

        let _ = std::fs::remove_dir_all(&source);
        let _ = std::fs::remove_dir_all(ws.root);
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
cat > "$run_dir/failover.json" <<EOF
{
  "from": "forged-worker",
  "to": "forged-target",
  "reason": "worker-controlled audit",
  "at": "2099-01-01T00:00:00Z"
}
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
        let failover_packet =
            std::fs::read_to_string(workers::packet_path(&report.run_dir)).unwrap();
        assert!(failover_packet.contains("previous worker exited without writing result.json"));
        assert!(failover_packet.contains("result.json matches the packet schema exactly"));
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
        assert_serial_worktree_and_branch_removed(&ws, &only_run_dir(&ws));

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
        assert_eq!(report.result_state, Some(TaskState::Partial));
        assert!(
            !marker.exists(),
            "fallback worker must not run when result.json exists"
        );
        assert!(!report.lines.iter().any(|l| l.contains("worker failover")));
        let handoff = std::fs::read_to_string(report.run_dir.join("handoff.md")).unwrap();
        assert!(!handoff.contains("Worker failover"));
        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::Partial,
            "output-contract failure becomes bounded feedback, without failover"
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
        assert_eq!(report.result_state, Some(TaskState::Partial));
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
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
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
        crate::planner::persist_ingested_decision_questions(&ws, &q, &ingested).unwrap();

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
        assert!(
            f.remediates_review("REV"),
            "the soft barrier relation must survive in the queue"
        );
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
    fn rejected_review_requeue_writes_no_phantom_transition() {
        let ws = crate::snapshot::corrupt_activated_state_fixture(
            "review-requeue-no-phantom-transition",
        );
        let lock = ws.acquire_planning_lock().unwrap();
        let mut fallback = ws.load_queue().unwrap();

        let error = requeue_review_locked(
            &ws,
            &lock,
            &mut fallback,
            "YARD-001",
            TaskState::NeedsUser,
            &[],
        )
        .unwrap_err()
        .to_string();

        assert!(
            error.contains("active_runtime_envelope_mismatch"),
            "{error}"
        );
        assert!(
            !ws.transition_path("YARD-001").exists(),
            "a rejected queue CAS must not leave a phantom transition"
        );
        drop(lock);
        let _ = std::fs::remove_dir_all(&ws.root);
    }

    #[test]
    fn schedulable_remediation_ids_excludes_blocked_deferred_and_dep_gated() {
        // 1c: a failed review is soft-sequenced behind fixes that belong to the
        // current runnable graph. Approval-gated Queued fixes count because the
        // review must wait for their decision; Blocked, Deferred, or dep-gated
        // fixes do not count because those terminal/unresolved branches would
        // otherwise strand the review.
        let mut q = queue(vec![
            task("FIXA", TaskState::Queued, 10, false),   // runnable
            task("FIXB", TaskState::Blocked, 20, false),  // off-vocab parked
            task("FIXC", TaskState::Deferred, 30, false), // set aside
            task("FIXD", TaskState::Queued, 40, false),   // gated by an unmet dep
            task("DEP", TaskState::Queued, 50, false),    // not Done -> gates FIXD
            task("FIXE", TaskState::Queued, 60, true),    // approval-gated but schedulable
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
            "FIXE".to_string(),
        ];
        assert_eq!(
            schedulable_remediation_ids(&q, &ingested),
            vec!["FIXA".to_string(), "FIXE".to_string()]
        );
    }

    #[test]
    fn repeated_review_fix_title_is_not_enqueued_twice() {
        let mut prior = task("FIX", TaskState::Done, 10, false);
        prior.title = "Repair parser acceptance".into();
        let q = queue(vec![prior]);
        let mut follow_ups = vec![
            crate::schemas::FollowUpTask {
                title: "repair parser acceptance".into(),
                reason: "same failed review proposed it again".into(),
                ..Default::default()
            },
            crate::schemas::FollowUpTask {
                title: "Repair a distinct serializer failure".into(),
                reason: "new failed evidence".into(),
                ..Default::default()
            },
        ];

        dedup_review_follow_ups(&mut follow_ups, &q);
        assert_eq!(follow_ups.len(), 1);
        assert_eq!(follow_ups[0].title, "Repair a distinct serializer failure");
    }

    #[test]
    fn serial_auto_commit_guidance_fires_only_on_integratable_changes() {
        // 1d worktree-only interim: a serial run never auto-commits, but it points
        // an opted-in user at a manual commit ONLY when the worker produced real
        // deliverable changes — not on a no-op Done or a .agents-only write.
        let agents_only = [".agents/work-queue.yaml".to_string(), ".agents".to_string()];
        let with_work = [
            ".agents/work-queue.yaml".to_string(),
            "src/feature.rs".to_string(),
        ];
        assert!(!worker_changed_integratable_path(None)); // no git signal
        assert!(!worker_changed_integratable_path(Some(&[]))); // nothing changed
        assert!(!worker_changed_integratable_path(Some(&agents_only))); // state-only
        assert!(!worker_changed_integratable_path(Some(&[
            "./.agents/telemetry/runs.jsonl".to_string()
        ]))); // ./-prefixed state still recognized
        assert!(worker_changed_integratable_path(Some(&with_work))); // real deliverable
        assert!(worker_changed_integratable_path(Some(&[
            "./README.md".to_string()
        ])));
        assert!(worker_changed_integratable_path(Some(&[
            ".agents/skills/example/SKILL.md".to_string()
        ])));
    }

    #[test]
    fn isolated_serial_finalize_keeps_the_full_serial_feature_surface() {
        let flags = FinalizeFlags::serial();
        assert!(flags.post_hooks);
        assert!(flags.validation);
        assert!(flags.conversation);
        assert!(flags.learned);
        assert!(flags.artifacts);
        assert!(flags.telemetry);
        assert!(flags.follow_ups);
        assert!(!flags.git_finish_recovery);
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
    fn a_new_needs_user_result_does_not_stop_the_independent_drain() {
        assert!(continues_auto_drain(TaskState::NeedsUser));
        assert!(continues_auto_drain(TaskState::Done));
        assert!(!continues_auto_drain(TaskState::Blocked));
        assert!(!continues_auto_drain(TaskState::Running));
    }

    #[test]
    fn explicit_continuation_packet_is_bounded_and_causally_exact() {
        let context = (1..=25)
            .map(|seq| (seq, format!("message-{seq}")))
            .collect::<Vec<_>>();
        let packet = explicit_continuation_packet(
            "att-next",
            Some("evt-answer"),
            Some("act-answer"),
            &context,
            Some("checkpoint text"),
        );
        assert!(!packet.contains("message-5\n"));
        assert!(packet.contains("message-6"));
        assert!(packet.contains("message-25"));
        assert!(packet.contains("caused_by_event_id: evt-answer"));
        assert!(packet.contains("caused_by_action_id: act-answer"));
        assert!(packet.contains("checkpoint text"));
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
    fn recovery_reconciles_refs_after_worktree_removal_crash() {
        let ws = init_test_workspace(
            "integrated-cleanup-recovery",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let run_id = "run-20990101-000000-cleanup";
        let task_id = "YARD-CLEANUP";
        let branch = format!("yard/{}/{}", task_id.to_lowercase(), run_id);
        let wt = ws.agents_dir().join("worktrees").join(run_id);
        let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        crate::parallel::create_worktree(&ws.root, &wt, &branch).unwrap();
        write_str(&wt.join("owned.txt"), "owned\n").unwrap();
        git_stdout(&wt, &["add", "owned.txt"]).unwrap();
        git_stdout(&wt, &["commit", "-q", "-m", "owned worker commit"]).unwrap();
        let worker_oid = git_stdout(&wt, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        git_stdout(
            &ws.root,
            &[
                "merge",
                "--no-ff",
                "--no-edit",
                "-m",
                "owned integration",
                &worker_oid,
            ],
        )
        .unwrap();
        let integration_oid = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        git_stdout(
            &ws.root,
            &[
                "update-ref",
                &format!("refs/heads/yardlet-txn/{branch}"),
                &worker_oid,
                "",
            ],
        )
        .unwrap();

        let mut q = queue(vec![task(task_id, TaskState::Done, 10, false)]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        ws.save_serial_integration_receipt(&state::SerialIntegrationReceipt {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            worktree: wt.display().to_string(),
            branch: branch.clone(),
            baseline_oid: baseline.clone(),
        })
        .unwrap();
        ws.save_integrated_cleanup_receipt(&state::IntegratedCleanupReceipt {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            intent_id: "intent-test".into(),
            worker: "builder".into(),
            worktree: wt.display().to_string(),
            branch: branch.clone(),
            baseline_oid: baseline.clone(),
            integration_base_oid: baseline.clone(),
            integration_worker_oid: worker_oid.clone(),
            integration_oid: integration_oid.clone(),
            provenance: IntegrationProvenance::SerialCoreStaged,
            owned_oids: vec![worker_oid.clone(), integration_oid.clone()],
        })
        .unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                intent_id: "intent-test".into(),
                worker: "builder".into(),
                model: String::new(),
                fallback_enabled: false,
                routing_provenance: None,
                state: "done".into(),
                started_at: Local::now().to_rfc3339(),
                completed_at: Some(Local::now().to_rfc3339()),
                worktree: wt.display().to_string(),
                serial_isolated: true,
                baseline_oid: baseline.clone(),
                worktree_branch: branch.clone(),
                integration_oid: integration_oid.clone(),
                integration_base_oid: baseline,
                integration_worker_oid: worker_oid.clone(),
                integration_provenance: IntegrationProvenance::SerialCoreStaged,
                integration_cleanup_complete: false,
                owned_oids: vec![worker_oid.clone(), integration_oid.clone()],
            },
        )
        .unwrap();

        // Exact crash window: Git removed the worktree, but Yardlet had not yet
        // deleted the owned target/transaction refs or marked cleanup complete.
        git_stdout(
            &ws.root,
            &["worktree", "remove", "--force", &wt.display().to_string()],
        )
        .unwrap();
        assert!(!wt.exists());
        write_str(&run_dir.join("run.yaml"), "not: [valid yaml").unwrap();
        assert!(!git_stdout(&ws.root, &["branch", "--list", &branch])
            .unwrap()
            .trim()
            .is_empty());

        let messages = recover_orphans(&ws);

        assert!(messages
            .iter()
            .any(|message| message.contains("reconciled integrated worktree cleanup")));
        assert!(git_stdout(&ws.root, &["branch", "--list", &branch])
            .unwrap()
            .trim()
            .is_empty());
        assert!(git_stdout(
            &ws.root,
            &[
                "show-ref",
                "--verify",
                &format!("refs/heads/yardlet-txn/{branch}")
            ]
        )
        .is_err());
        assert_eq!(
            git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap().trim(),
            integration_oid
        );
        let record: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert!(record.integration_cleanup_complete);
        assert!(!recover_orphans(&ws)
            .iter()
            .any(|message| message.contains("reconciled integrated worktree cleanup")));

        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn recovery_never_cleans_a_forged_run_projection_without_core_receipt() {
        let ws = init_test_workspace(
            "forged-cleanup-projection",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let run_id = "run-20990101-000000-forged-cleanup";
        let task_id = "YARD-FORGED-CLEANUP";
        let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
        let worktree = ws.agents_dir().join("worktrees").join(run_id);
        let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        crate::parallel::create_worktree(&ws.root, &worktree, &branch).unwrap();
        write_str(&worktree.join("owned.txt"), "worker commit\n").unwrap();
        git_stdout(&worktree, &["add", "owned.txt"]).unwrap();
        git_stdout(&worktree, &["commit", "-q", "-m", "worker commit"]).unwrap();
        let worker_oid = git_stdout(&worktree, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        let mut q = queue(vec![task(task_id, TaskState::Done, 10, false)]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                intent_id: "intent-test".into(),
                worker: "codex".into(),
                state: "done".into(),
                started_at: Local::now().to_rfc3339(),
                completed_at: Some(Local::now().to_rfc3339()),
                worktree: worktree.display().to_string(),
                baseline_oid: baseline.clone(),
                worktree_branch: branch.clone(),
                integration_oid: baseline.clone(),
                integration_base_oid: baseline,
                integration_worker_oid: worker_oid.clone(),
                integration_provenance: IntegrationProvenance::SerialCoreStaged,
                owned_oids: vec![worker_oid.clone()],
                ..Default::default()
            },
        )
        .unwrap();

        let messages = recover_orphans(&ws);

        assert!(worktree.exists());
        assert_eq!(
            git_stdout(&ws.root, &["rev-parse", &format!("refs/heads/{branch}")])
                .unwrap()
                .trim(),
            worker_oid
        );
        assert!(!messages
            .iter()
            .any(|message| message.contains("reconciled integrated worktree cleanup")));

        crate::parallel::remove_worktree(&ws.root, &worktree, &branch);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn no_change_core_receipt_recovers_before_and_after_cleanup() {
        for cleanup_before_recovery in [false, true] {
            let name = if cleanup_before_recovery {
                "nochange-after-cleanup"
            } else {
                "nochange-before-cleanup"
            };
            let ws = init_test_workspace(
                name,
                "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
            );
            let mut config = ws.load_config().unwrap();
            config.git_finish.auto_push = true;
            state::save_yaml(&ws.config_path(), &config).unwrap();
            let run_id = format!("run-20990101-000000-{name}");
            let task_id = "YARD-NOCHANGE-RECOVERY";
            let mut queued = task(task_id, TaskState::Running, 10, false);
            queued.kind = "implementation".into();
            let mut q = queue(vec![queued]);
            q.intent_id = "intent-test".into();
            ws.save_queue(&q).unwrap();
            let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
            let worktree = ws.agents_dir().join("worktrees").join(&run_id);
            let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"])
                .unwrap()
                .trim()
                .to_string();
            crate::parallel::create_worktree(&ws.root, &worktree, &branch).unwrap();
            let run_dir = ws.runs_dir().join(&run_id);
            std::fs::create_dir_all(&run_dir).unwrap();
            let result = crate::schemas::RunResult {
                schema_version: 1,
                run_id: run_id.clone(),
                task_id: task_id.into(),
                status: "done".into(),
                intent_adherence: Default::default(),
                changes: Default::default(),
                validation: Default::default(),
                question_for_user: None,
                compact_summary: "no changes".into(),
                verdict: vec![],
                harness_suggestions: vec![],
                follow_up_tasks: vec![],
                artifacts: vec![],
                resources: vec![],
            };
            write_str(
                &run_dir.join("result.json"),
                &serde_json::to_string(&result).unwrap(),
            )
            .unwrap();
            write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
            if cleanup_before_recovery {
                state::save_yaml(
                    &run_dir.join("run.yaml"),
                    &RunRecord {
                        schema_version: 999,
                        run_id: "run-worker-retargeted".into(),
                        task_id: "WORKER-RETARGETED".into(),
                        intent_id: "worker-retargeted".into(),
                        worker: "worker-retargeted".into(),
                        state: "running".into(),
                        started_at: "2099-01-01T00:00:00+00:00".into(),
                        worktree: "/tmp/worker-retargeted".into(),
                        worktree_branch: "worker/retargeted".into(),
                        baseline_oid: "worker-retargeted".into(),
                        integration_oid: "worker-retargeted".into(),
                        owned_oids: vec!["worker-retargeted".into()],
                        ..Default::default()
                    },
                )
                .unwrap();
            } else {
                write_str(&run_dir.join("run.yaml"), ": malformed\n").unwrap();
            }
            ws.save_no_change_receipt(&state::NoChangeReceipt {
                schema_version: 1,
                run_id: run_id.clone(),
                task_id: task_id.into(),
                intent_id: "intent-test".into(),
                worker: "codex".into(),
                worktree: worktree.display().to_string(),
                branch: branch.clone(),
                baseline_oid: baseline.clone(),
                worker_oid: baseline.clone(),
                provenance: IntegrationProvenance::ParallelWorkerDirect,
            })
            .unwrap();
            if cleanup_before_recovery {
                let cleanup = crate::parallel::cleanup_integrated_worktree(
                    &ws.root,
                    &worktree,
                    &branch,
                    &baseline,
                    IntegrationProvenance::ParallelWorkerDirect,
                );
                assert!(cleanup.complete, "{:?}", cleanup.warnings);
            }

            let messages = recover_orphans(&ws);

            assert!(!worktree.exists(), "{messages:?}");
            assert!(git_stdout(&ws.root, &["branch", "--list", &branch])
                .unwrap()
                .trim()
                .is_empty());
            let finish = ws.load_git_finish_record(&run_dir).unwrap();
            assert_eq!(finish.status, crate::git_finish::GitFinishStatus::NotNeeded);
            assert!(!finish.push_invoked);
            assert_eq!(
                ws.load_queue().unwrap().tasks[0].state,
                TaskState::Done,
                "{messages:?}"
            );
            let projected: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
            assert_eq!(projected.schema_version, 1);
            assert_eq!(projected.run_id, run_id);
            assert_eq!(projected.task_id, task_id);
            assert_eq!(projected.intent_id, "intent-test");
            assert_eq!(projected.worker, "codex");
            assert_eq!(projected.worktree, worktree.display().to_string());
            assert_eq!(projected.worktree_branch, branch);
            assert_eq!(projected.baseline_oid, baseline);
            assert!(projected.integration_oid.is_empty());
            assert!(projected.owned_oids.is_empty());
            assert!(projected.integration_cleanup_complete);
            assert!(projected.completed_at.is_some());

            let second = recover_orphans(&ws);
            assert!(
                second.is_empty(),
                "second recovery was not inert: {second:?}"
            );

            let _ = std::fs::remove_dir_all(ws.root);
        }
    }

    #[test]
    fn seal_run_record_overwrites_worker_forged_identity_and_merge_location() {
        let root = std::env::temp_dir().join(format!("yard-seal-forged-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let run_dir = root.join("run-trusted");
        std::fs::create_dir_all(&run_dir).unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 999,
                run_id: "run-forged".into(),
                task_id: "TASK-FORGED".into(),
                intent_id: "intent-forged".into(),
                worker: "worker-forged".into(),
                state: "running".into(),
                started_at: "2099-01-01T00:00:00+00:00".into(),
                worktree: "/tmp/forged".into(),
                serial_isolated: false,
                baseline_oid: "forged-baseline".into(),
                worktree_branch: "forged/branch".into(),
                ..Default::default()
            },
        )
        .unwrap();
        let trusted_worktree = root.join("trusted-worktree");
        let trusted_task = task("YARD-TRUSTED", TaskState::Running, 10, false);
        seal_run_record(
            &run_dir,
            "run-trusted",
            &trusted_task,
            "intent-trusted",
            "codex",
            TaskState::Partial,
            Some(&MergeBack {
                wt_path: &trusted_worktree,
                branch: "yard/yard-trusted/run-trusted",
                baseline_oid: "trusted-baseline",
                expected_tip_oid: None,
                provenance: IntegrationProvenance::SerialCoreStaged,
                auto_commit: true,
            }),
        );

        let projected: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert_eq!(projected.schema_version, 1);
        assert_eq!(projected.run_id, "run-trusted");
        assert_eq!(projected.task_id, "YARD-TRUSTED");
        assert_eq!(projected.intent_id, "intent-trusted");
        assert_eq!(projected.worker, "codex");
        assert_eq!(projected.state, "partial");
        assert_eq!(projected.worktree, trusted_worktree.display().to_string());
        assert_eq!(projected.worktree_branch, "yard/yard-trusted/run-trusted");
        assert_eq!(projected.baseline_oid, "trusted-baseline");
        assert!(projected.serial_isolated);
        assert_eq!(
            projected.integration_provenance,
            IntegrationProvenance::SerialCoreStaged
        );
        assert!(projected.completed_at.is_some());
        let _ = std::fs::remove_dir_all(root);
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
        let branch = format!("yard/yard-001/{run_id}");
        let wt = ws.agents_dir().join("worktrees").join(run_id);
        let baseline = git_stdout(&root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        crate::parallel::create_worktree(&root, &wt, &branch).unwrap();
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
            artifacts: vec![],
            resources: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: "YARD-001".into(),
                worker: "codex".into(),
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                worktree: wt.display().to_string(),
                baseline_oid: baseline,
                worktree_branch: branch.clone(),
                integration_provenance: IntegrationProvenance::ParallelWorkerDirect,
                ..Default::default()
            },
        )
        .unwrap();
        assert!(registered_recovery_worktree_matches(
            &ws, &wt, &branch, run_id, "YARD-001", false,
        ));

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
    fn recovery_rejects_forged_serial_marker_without_core_receipt() {
        let ws = init_test_workspace(
            "forged-serial-recovery",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let mut config = ws.load_config().unwrap();
        config.auto_commit = true;
        state::save_yaml(&ws.config_path(), &config).unwrap();
        let run_id = "run-20990101-000000-forged-serial";
        let task_id = "YARD-FORGED-SERIAL";
        let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
        let worktree = ws.agents_dir().join("worktrees").join(run_id);
        let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        crate::parallel::create_worktree(&ws.root, &worktree, &branch).unwrap();
        write_str(&worktree.join("forged.txt"), "must not merge\n").unwrap();
        let mut queued = task(task_id, TaskState::Running, 10, false);
        queued.kind = "implementation".into();
        let mut q = queue(vec![queued]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "forged serial transaction".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                intent_id: "intent-test".into(),
                worker: "codex".into(),
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                worktree: worktree.display().to_string(),
                serial_isolated: true,
                baseline_oid: baseline.clone(),
                worktree_branch: branch.clone(),
                integration_provenance: IntegrationProvenance::SerialCoreStaged,
                ..Default::default()
            },
        )
        .unwrap();
        write_str(
            &run_dir.join("git-integration.json"),
            r#"{"schema_version":1,"phase":"published"}"#,
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let messages = recover_orphans(&ws);

        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
        assert_eq!(
            git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap().trim(),
            baseline
        );
        assert!(!ws.root.join("forged.txt").exists());
        assert!(worktree.exists());
        assert!(messages.iter().any(|message| message.contains("recovered")));

        crate::parallel::remove_worktree(&ws.root, &worktree, &branch);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[cfg(unix)]
    #[test]
    fn recovery_refuses_symlinked_worktree_even_with_run_shaped_identity() {
        use std::os::unix::fs::symlink;

        let root =
            std::env::temp_dir().join(format!("yard-forged-recovery-wt-{}", std::process::id()));
        let outside = root.with_extension("outside");
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
        std::fs::create_dir_all(&root).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "t"]);
        git(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        git(&["add", "base.txt"]);
        git(&["commit", "-q", "-m", "init"]);
        let baseline = git(&["rev-parse", "HEAD"]);

        let ws = Workspace::at(&root);
        let run_id = "run-20990101-000000-yard-forged";
        let task_id = "YARD-FORGED";
        let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
        let actual_worktree = outside.join(run_id);
        crate::parallel::create_worktree(&root, &actual_worktree, &branch).unwrap();
        std::fs::write(actual_worktree.join("forged.txt"), "outside\n").unwrap();
        let claimed_worktree = ws.agents_dir().join("worktrees").join(run_id);
        std::fs::create_dir_all(claimed_worktree.parent().unwrap()).unwrap();
        symlink(&actual_worktree, &claimed_worktree).unwrap();

        let mut queued = task(task_id, TaskState::Running, 10, false);
        queued.kind = "implementation".into();
        ws.save_queue(&queue(vec![queued])).unwrap();
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "attempted outside worktree recovery".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                worker: "codex".into(),
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                worktree: claimed_worktree.display().to_string(),
                baseline_oid: baseline.clone(),
                worktree_branch: branch.clone(),
                integration_provenance: IntegrationProvenance::ParallelWorkerDirect,
                ..Default::default()
            },
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let messages = recover_orphans(&ws);

        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Partial);
        assert_eq!(git(&["rev-parse", "HEAD"]), baseline);
        assert!(!root.join("forged.txt").exists());
        assert!(claimed_worktree.exists(), "the symlink must be retained");
        assert!(
            actual_worktree.exists(),
            "the outside worktree must be retained"
        );
        assert!(git(&["branch", "--list", &branch]).contains(&branch));
        assert!(messages.iter().any(|message| message.contains("recovered")));

        std::fs::remove_file(&claimed_worktree).unwrap();
        crate::parallel::remove_worktree(&root, &actual_worktree, &branch);
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&outside);
    }

    #[test]
    fn recovery_imports_staged_serial_result_before_deciding_to_rerun() {
        let ws = init_test_workspace(
            "serial-staged-recovery",
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let mut config = std::fs::read_to_string(ws.config_path()).unwrap();
        config.push_str("auto_commit: true\n");
        write_str(&ws.config_path(), &config).unwrap();
        let mut t = task("YARD-STAGED", TaskState::Running, 10, false);
        t.kind = "implementation".into();
        let mut q = queue(vec![t]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();

        let run_id = "run-20990101-000000-yard-staged";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"]).unwrap();
        let baseline = baseline.trim().to_string();
        let branch = "yard/yard-staged/run-20990101-000000-yard-staged";
        let wt = ws.agents_dir().join("worktrees").join(run_id);
        crate::parallel::create_worktree(&ws.root, &wt, branch).unwrap();
        ws.save_serial_integration_receipt(&state::SerialIntegrationReceipt {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-STAGED".into(),
            worktree: wt.display().to_string(),
            branch: branch.into(),
            baseline_oid: baseline.clone(),
        })
        .unwrap();
        std::fs::write(wt.join("staged.txt"), "worker completed\n").unwrap();
        let staged_run_dir = wt.join(".agents/runs").join(run_id);
        for directory in [
            staged_run_dir.join("evidence"),
            staged_run_dir.join("hooks/pre-run"),
            run_dir.join("evidence"),
            run_dir.join("hooks/pre-run"),
        ] {
            std::fs::create_dir_all(directory).unwrap();
        }
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: "YARD-STAGED".into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "worker already completed".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        write_str(
            &staged_run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&staged_run_dir.join("handoff.md"), "# staged handoff\n").unwrap();
        for path in [
            staged_run_dir.join("cancelled"),
            staged_run_dir.join("partial-reason"),
            staged_run_dir.join("failover.json"),
            staged_run_dir.join("evaluation.json"),
            staged_run_dir.join("validation.json"),
            staged_run_dir.join("validation-0.log"),
        ] {
            write_str(&path, "worker forged recovery artifact\n").unwrap();
        }
        write_str(
            &staged_run_dir.join("evidence/repo-summary.md"),
            "worker forged evidence\n",
        )
        .unwrap();
        write_str(
            &staged_run_dir.join("hooks/pre-run/check.log"),
            "worker forged hook\n",
        )
        .unwrap();
        write_str(
            &staged_run_dir.join("validation.log"),
            "worker validation allowed\n",
        )
        .unwrap();
        write_str(
            &staged_run_dir.join("checkpoint.md"),
            "worker checkpoint allowed\n",
        )
        .unwrap();
        for path in [
            run_dir.join("failover.json"),
            run_dir.join("evaluation.json"),
            run_dir.join("validation.json"),
            run_dir.join("validation-0.log"),
        ] {
            write_str(&path, "main recovery artifact\n").unwrap();
        }
        write_str(
            &run_dir.join("evidence/repo-summary.md"),
            "main recovery evidence\n",
        )
        .unwrap();
        write_str(
            &run_dir.join("hooks/pre-run/check.log"),
            "main recovery hook\n",
        )
        .unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: "YARD-STAGED".into(),
                intent_id: "intent-test".into(),
                worker: "builder".into(),
                model: String::new(),
                fallback_enabled: false,
                routing_provenance: None,
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                completed_at: None,
                worktree: wt.display().to_string(),
                serial_isolated: true,
                baseline_oid: baseline,
                worktree_branch: branch.into(),
                integration_oid: String::new(),
                integration_base_oid: String::new(),
                integration_worker_oid: String::new(),
                integration_provenance: IntegrationProvenance::SerialCoreStaged,
                integration_cleanup_complete: false,
                owned_oids: vec![],
            },
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        let messages = recover_orphans(&ws);

        assert!(run_dir.join("result.json").exists());
        assert_eq!(ws.load_queue().unwrap().tasks[0].state, TaskState::Done);
        assert_eq!(
            std::fs::read_to_string(ws.root.join("staged.txt")).unwrap(),
            "worker completed\n"
        );
        assert!(messages.iter().any(|message| message.contains("recovered")));
        assert!(!run_dir.join("cancelled").exists());
        assert!(!run_dir.join("partial-reason").exists());
        for path in [
            run_dir.join("failover.json"),
            run_dir.join("evaluation.json"),
            run_dir.join("validation.json"),
            run_dir.join("validation-0.log"),
        ] {
            assert_eq!(
                std::fs::read_to_string(path).unwrap(),
                "main recovery artifact\n"
            );
        }
        assert_eq!(
            std::fs::read_to_string(run_dir.join("evidence/repo-summary.md")).unwrap(),
            "main recovery evidence\n"
        );
        assert_eq!(
            std::fs::read_to_string(run_dir.join("hooks/pre-run/check.log")).unwrap(),
            "main recovery hook\n"
        );
        assert_eq!(
            std::fs::read_to_string(run_dir.join("validation.log")).unwrap(),
            "worker validation allowed\n"
        );
        assert_eq!(
            std::fs::read_to_string(run_dir.join("checkpoint.md")).unwrap(),
            "worker checkpoint allowed\n"
        );
        let record: RunRecord = state::load_yaml(&run_dir.join("run.yaml")).unwrap();
        assert!(!record.integration_oid.is_empty());
        assert!(!wt.exists());

        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn finished_orphaned_serial_worktree(
        name: &str,
        mutate_seeded_intent: bool,
    ) -> (Workspace, PathBuf, PathBuf, String) {
        let ws = init_test_workspace(
            name,
            "schema_version: 1\nrouting: {default_worker: builder}\nworkers: []\n",
        );
        let task_id = "YARD-RECOVERY-SEED";
        let run_id = format!("run-20990101-000000-{name}");
        let mut queued_task = task(task_id, TaskState::Queued, 10, false);
        queued_task.kind = "implementation".into();
        let mut q = queue(vec![queued_task]);
        q.intent_id = "intent-test".into();
        ws.save_queue(&q).unwrap();

        let run_dir = ws.runs_dir().join(&run_id);
        std::fs::create_dir_all(run_dir.join("evidence/canonical-state-seed")).unwrap();
        let baseline = git_stdout(&ws.root, &["rev-parse", "HEAD"])
            .unwrap()
            .trim()
            .to_string();
        let branch = format!("yard/yard-recovery-seed/{run_id}");
        let wt = ws.agents_dir().join("worktrees").join(&run_id);
        crate::parallel::create_worktree(&ws.root, &wt, &branch).unwrap();
        std::fs::create_dir_all(wt.join(".agents")).unwrap();
        for name in ["intent-contract.yaml", "work-queue.yaml"] {
            let source = ws.agents_dir().join(name);
            std::fs::copy(&source, wt.join(".agents").join(name)).unwrap();
            std::fs::copy(
                &source,
                run_dir.join("evidence/canonical-state-seed").join(name),
            )
            .unwrap();
        }
        if mutate_seeded_intent {
            write_str(
                &wt.join(".agents/intent-contract.yaml"),
                "schema_version: 1\nid: worker-mutated\nsummary: forbidden\nstatus: accepted\n",
            )
            .unwrap();
        }

        q.tasks[0].state = TaskState::Running;
        ws.save_queue(&q).unwrap();
        let result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.clone(),
            task_id: task_id.into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "worker finished before the orchestrator crashed".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# orphan handoff\n").unwrap();
        ws.save_serial_integration_receipt(&state::SerialIntegrationReceipt {
            schema_version: 1,
            run_id: run_id.clone(),
            task_id: task_id.into(),
            worktree: wt.display().to_string(),
            branch: branch.clone(),
            baseline_oid: baseline.clone(),
        })
        .unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id,
                task_id: task_id.into(),
                intent_id: "intent-test".into(),
                worker: "builder".into(),
                model: String::new(),
                fallback_enabled: false,
                routing_provenance: None,
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                completed_at: None,
                worktree: wt.display().to_string(),
                serial_isolated: true,
                baseline_oid: baseline,
                worktree_branch: branch.clone(),
                integration_oid: String::new(),
                integration_base_oid: String::new(),
                integration_worker_oid: String::new(),
                integration_provenance: IntegrationProvenance::SerialCoreStaged,
                integration_cleanup_complete: false,
                owned_oids: vec![],
            },
        )
        .unwrap();
        write_str(&run_dir.join("worker.pid"), "2147483647").unwrap();

        (ws, run_dir, wt, branch)
    }

    #[test]
    fn recovery_ignores_unchanged_seeded_canonical_state_in_orphan_worktree() {
        let (ws, run_dir, wt, _) =
            finished_orphaned_serial_worktree("seeded-canonical-recovery", false);

        let messages = recover_orphans(&ws);

        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::Done,
            "Yardlet-seeded canonical copies are not worker changes: {messages:?}"
        );
        assert!(
            !run_dir.join("feedback.json").exists(),
            "a clean canonical seed must pass the forbidden-path gate"
        );
        assert!(!wt.exists(), "a clean recovered worktree should be removed");
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn recovery_flags_worker_modified_seeded_canonical_state_in_orphan_worktree() {
        let (ws, run_dir, wt, branch) =
            finished_orphaned_serial_worktree("mutated-canonical-recovery", true);

        let messages = recover_orphans(&ws);

        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::NeedsUser,
            "a worker canonical-state write must remain forbidden: {messages:?}"
        );
        let feedback: FeedbackRecord =
            serde_json::from_str(&std::fs::read_to_string(run_dir.join("feedback.json")).unwrap())
                .unwrap();
        assert!(
            feedback.failures.iter().any(|failure| {
                failure.contains("forbidden_paths_untouched")
                    && failure.contains(".agents/intent-contract.yaml")
            }),
            "the actual canonical mutation must be named in the gate evidence: {feedback:?}"
        );
        assert!(
            wt.exists(),
            "a forbidden run keeps its worktree for inspection"
        );

        crate::parallel::remove_worktree(&ws.root, &wt, &branch);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    fn assert_worker_staged_seed_cannot_hide_recovery_canonical_mutation(
        workspace_tag: &str,
        seed_name: &str,
    ) {
        let (ws, run_dir, wt, branch) = finished_orphaned_serial_worktree(
            &format!("staged-seed-recovery-{workspace_tag}"),
            true,
        );
        let staged = wt
            .join(".agents/runs")
            .join(run_dir.file_name().unwrap())
            .join("evidence")
            .join(seed_name);
        std::fs::create_dir_all(&staged).unwrap();
        std::fs::copy(
            wt.join(".agents/intent-contract.yaml"),
            staged.join("intent-contract.yaml"),
        )
        .unwrap();

        import_worker_run_artifacts(staged.parent().unwrap().parent().unwrap(), &run_dir).unwrap();
        let messages = recover_orphans(&ws);

        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::NeedsUser,
            "a staging seed copy must not redefine the main-owned comparison seed: {messages:?}"
        );
        let feedback: FeedbackRecord =
            serde_json::from_str(&std::fs::read_to_string(run_dir.join("feedback.json")).unwrap())
                .unwrap();
        assert!(feedback.failures.iter().any(|failure| {
            failure.contains("forbidden_paths_untouched")
                && failure.contains(".agents/intent-contract.yaml")
        }));
        assert!(wt.exists(), "the rejected worktree must be retained");

        crate::parallel::remove_worktree(&ws.root, &wt, &branch);
        let _ = std::fs::remove_dir_all(ws.root);
    }

    #[test]
    fn worker_staged_seed_cannot_hide_recovery_canonical_mutation() {
        assert_worker_staged_seed_cannot_hide_recovery_canonical_mutation(
            "exact-lowercase",
            "canonical-state-seed",
        );
    }

    #[test]
    fn worker_case_variant_staged_seed_cannot_hide_recovery_canonical_mutation() {
        assert_worker_staged_seed_cannot_hide_recovery_canonical_mutation(
            "case-variant",
            "CANONICAL-STATE-SEED",
        );
    }

    #[test]
    fn worker_unicode_alias_staged_seed_cannot_hide_recovery_canonical_mutation() {
        assert_worker_staged_seed_cannot_hide_recovery_canonical_mutation(
            "unicode-alias",
            "canonical-ſtate-seed",
        );
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
            artifacts: vec![],
            resources: vec![],
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
            artifacts: vec![],
            resources: vec![],
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
                model: String::new(),
                fallback_enabled: None,
                required_capabilities: vec![],
                decision_question: String::new(),
                worker_rationale: None,
                insert: String::new(),
                runs_before: vec![],
            }],
            artifacts: vec![],
            resources: vec![],
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
    fn conflicting_follow_up_does_not_erase_governing_task_state_transition() {
        let root = std::env::temp_dir().join(format!(
            "yard-follow-up-conflict-finalize-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let ws = Workspace::at(&root);
        let mut governing_task = task("YARD-001", TaskState::Running, 10, false);
        governing_task.preferred_worker = "codex".into();
        governing_task.model = "gpt-5.6-sol".into();
        governing_task.fallback_enabled = Some(false);
        let initial = queue(vec![governing_task]);
        ws.save_queue(&initial).unwrap();

        let governing = crate::schemas::ResolvedWorkerSelection {
            worker_id: "codex".into(),
            model: "gpt-5.6-sol".into(),
            fallback_enabled: false,
            routing_provenance: crate::schemas::RoutingProvenance {
                governing_task_id: "YARD-001".into(),
                governing_worker_id: "codex".into(),
                governing_model: "gpt-5.6-sol".into(),
                governing_fallback_enabled: false,
                ..Default::default()
            },
        };
        let conflicting = crate::schemas::FollowUpTask {
            title: "conflicting worker follow-up".into(),
            preferred_worker: "claude-code".into(),
            ..Default::default()
        };
        let lock = ws.acquire_planning_lock().unwrap();
        let mut fallback_queue = initial;
        let error = finalize_on_latest_queue_locked(
            &ws,
            &lock,
            &mut fallback_queue,
            "YARD-001",
            TaskState::Done,
            &[],
            &[conflicting],
            Some(&governing),
            None,
            TransitionCause::RunOutcome,
            "worker evaluated task as done",
            TransitionActor::Worker("run-conflicting-follow-up".into()),
        )
        .unwrap_err();

        assert!(error.to_string().contains("governing worker"), "{error:#}");
        let persisted = ws.load_queue().unwrap();
        assert_eq!(persisted.tasks.len(), 1, "conflict must stay fail-closed");
        assert_eq!(persisted.tasks[0].state, TaskState::Done);
        assert_eq!(fallback_queue.tasks[0].state, TaskState::Done);
        let transition = ws.latest_transition("YARD-001").unwrap();
        assert_eq!(transition.from, TaskState::Running);
        assert_eq!(transition.to, TaskState::Done);
        assert_eq!(transition.cause, TransitionCause::RunOutcome);
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
            artifacts: vec![],
            resources: vec![],
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
            artifacts: vec![],
            resources: vec![],
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
            artifacts: vec![],
            resources: vec![],
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
                ..Default::default()
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
        sh(&["init", "-q", "-b", "main"]);
        // The worktree integration commit inherits the repository's identity;
        // configure one locally so the test passes on runners with no global
        // git config.
        sh(&["config", "user.name", "t"]);
        sh(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        sh(&["add", "base.txt"]);
        sh(&["commit", "-q", "-m", "init"]);

        let remote = root.with_extension("bare.git");
        let _ = std::fs::remove_dir_all(&remote);
        sh(&["init", "-q", "--bare", remote.to_str().unwrap()]);
        sh(&["remote", "add", "fixture", remote.to_str().unwrap()]);
        sh(&["push", "-q", "fixture", "HEAD:refs/heads/main"]);
        crate::init::init(&root, false).unwrap();
        let ws = Workspace::at(&root);
        let mut config = ws.load_config().unwrap();
        config.git_finish = crate::schemas::GitFinishPolicy {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: "refs/heads/main".into(),
            pre_push_checks: vec![crate::schemas::GitFinishCheck {
                name: "owned-change-present".into(),
                command: "test -f feature.txt".into(),
            }],
        };
        state::save_yaml(&ws.config_path(), &config).unwrap();
        let mut t = task("YARD-001", TaskState::Running, 10, false);
        t.kind = "implementation".into();

        let run_id = "run-20990101-000000-yard-001";
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let wt = ws.agents_dir().join("worktrees").join("yard-001");
        let baseline_oid = std::process::Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(["rev-parse", "HEAD"])
            .output()
            .unwrap();
        let baseline_oid = String::from_utf8_lossy(&baseline_oid.stdout)
            .trim()
            .to_string();
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
            artifacts: vec![],
            resources: vec![],
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
                baseline_oid: &baseline_oid,
                expected_tip_oid: None,
                provenance: IntegrationProvenance::ParallelWorkerDirect,
                auto_commit: true,
            }),
        })
        .unwrap();

        // Done -> the worktree merged back into the workspace.
        assert_eq!(report.next_state, TaskState::Done, "{:?}", report.lines);
        assert!(
            root.join("feature.txt").exists(),
            "worktree change should have merged into the workspace"
        );
        let finish: crate::git_finish::GitFinishRecord = serde_json::from_str(
            &std::fs::read_to_string(run_dir.join("git-finish.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(finish.status, crate::git_finish::GitFinishStatus::Pushed);
        assert_eq!(finish.expected_oid, finish.remote_oid);
        let remote_head = std::process::Command::new("git")
            .arg("-C")
            .arg(&root)
            .args(["ls-remote", "--refs", "fixture", "refs/heads/main"])
            .output()
            .unwrap();
        assert!(remote_head.status.success());
        assert!(String::from_utf8_lossy(&remote_head.stdout)
            .starts_with(finish.expected_oid.as_deref().unwrap()));
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
    }

    #[test]
    fn no_change_finalize_ignores_forged_finish_and_never_pushes_unrelated_head() {
        let root = std::env::temp_dir().join(format!(
            "yard-nochange-forged-finish-{}",
            std::process::id()
        ));
        let remote = root.with_extension("bare.git");
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
        std::fs::create_dir_all(&root).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "t"]);
        git(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        git(&["add", "base.txt"]);
        git(&["commit", "-q", "-m", "base"]);
        let remote_baseline = git(&["rev-parse", "HEAD"]);
        git(&["init", "-q", "--bare", remote.to_str().unwrap()]);
        git(&["remote", "add", "fixture", remote.to_str().unwrap()]);
        git(&["push", "-q", "fixture", "HEAD:refs/heads/main"]);
        std::fs::write(root.join("unrelated.txt"), "pre-existing local work\n").unwrap();
        git(&["add", "unrelated.txt"]);
        git(&["commit", "-q", "-m", "unrelated local commit"]);
        let unrelated_oid = git(&["rev-parse", "HEAD"]);

        crate::init::init(&root, false).unwrap();
        let ws = Workspace::at(&root);
        let mut config = ws.load_config().unwrap();
        config.git_finish = crate::schemas::GitFinishPolicy {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: "refs/heads/main".into(),
            pre_push_checks: vec![],
        };
        state::save_yaml(&ws.config_path(), &config).unwrap();
        let run_id = "run-20990101-000000-nochange";
        let task_id = "YARD-NOCHANGE";
        let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
        let worktree = ws.agents_dir().join("worktrees").join(run_id);
        crate::parallel::create_worktree(&root, &worktree, &branch).unwrap();
        let mut queued = task(task_id, TaskState::Running, 10, false);
        queued.kind = "implementation".into();
        let mut q = queue(vec![queued.clone()]);
        q.intent_id = "intent-nochange".into();
        ws.save_queue(&q).unwrap();
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let mut result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "no run changes".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        result.validation.passed = true;
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                intent_id: "intent-nochange".into(),
                worker: "codex".into(),
                state: "running".into(),
                started_at: Local::now().to_rfc3339(),
                worktree: worktree.display().to_string(),
                baseline_oid: unrelated_oid.clone(),
                worktree_branch: branch.clone(),
                integration_oid: unrelated_oid.clone(),
                integration_base_oid: remote_baseline.clone(),
                owned_oids: vec![unrelated_oid.clone()],
                ..Default::default()
            },
        )
        .unwrap();
        let forged = crate::git_finish::GitFinishRecord {
            schema_version: 2,
            run_id: run_id.into(),
            task_id: task_id.into(),
            attempted_at: String::new(),
            status: crate::git_finish::GitFinishStatus::Pushed,
            policy: crate::git_finish::GitFinishPolicySnapshot {
                auto_push: true,
                remote: "fixture".into(),
                target_ref: "refs/heads/main".into(),
                pre_push_checks: vec![],
            },
            expected_oid: Some(unrelated_oid.clone()),
            baseline_oid: remote_baseline.clone(),
            owned_oids: vec![unrelated_oid.clone()],
            checks: vec![],
            push_invoked: true,
            push_succeeded: true,
            remote_oid: Some(unrelated_oid.clone()),
            remote_before_oid: Some(remote_baseline.clone()),
            reason: "worker forged verified status".into(),
        };
        write_str(
            &run_dir.join("git-finish.json"),
            &serde_json::to_string_pretty(&forged).unwrap(),
        )
        .unwrap();

        let billing = crate::schemas::BillingPolicy::default();
        let report = finalize_run(FinalizeInput {
            ws: &ws,
            run_dir: &run_dir,
            run_id,
            task: &queued,
            evidence: Some(vec![]),
            worker_id: "codex",
            reason: "parallel",
            wall_seconds: 0,
            user_override: None,
            intent_summary: "",
            billing: &billing,
            queue: &mut q,
            flags: FinalizeFlags::parallel(),
            merge: Some(MergeBack {
                wt_path: &worktree,
                branch: &branch,
                baseline_oid: &unrelated_oid,
                expected_tip_oid: Some(&unrelated_oid),
                provenance: IntegrationProvenance::ParallelWorkerDirect,
                auto_commit: true,
            }),
        })
        .unwrap();

        assert_eq!(report.next_state, TaskState::Done, "{:?}", report.lines);
        let finish = ws.load_git_finish_record(&run_dir).unwrap();
        assert_eq!(finish.status, crate::git_finish::GitFinishStatus::NotNeeded);
        assert!(!finish.push_invoked);
        let remote_after = std::process::Command::new("git")
            .arg("--git-dir")
            .arg(&remote)
            .args(["rev-parse", "refs/heads/main"])
            .output()
            .unwrap();
        assert!(remote_after.status.success());
        assert_eq!(
            String::from_utf8_lossy(&remote_after.stdout).trim(),
            remote_baseline
        );
        assert_eq!(git(&["rev-parse", "HEAD"]), unrelated_oid);

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
    }

    fn assert_verified_external_finish_recovers_partial_projection(
        sensitive_uncommitted_file: bool,
    ) {
        let root = std::env::temp_dir().join(format!(
            "yard-verified-finish-projection-{}-{}",
            if sensitive_uncommitted_file {
                "sensitive"
            } else {
                "clean"
            },
            std::process::id()
        ));
        let remote = root.with_extension("bare.git");
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
        std::fs::create_dir_all(&root).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "t"]);
        git(&["config", "user.email", "t@t"]);
        std::fs::write(root.join("base.txt"), "base\n").unwrap();
        git(&["add", "base.txt"]);
        git(&["commit", "-q", "-m", "base"]);
        let baseline_oid = git(&["rev-parse", "HEAD"]);
        git(&["init", "-q", "--bare", remote.to_str().unwrap()]);
        git(&["remote", "add", "fixture", remote.to_str().unwrap()]);
        git(&["push", "-q", "fixture", "HEAD:refs/heads/main"]);

        git(&["checkout", "-q", "-b", "fixture-worker"]);
        std::fs::write(root.join("owned.txt"), "owned\n").unwrap();
        git(&["add", "owned.txt"]);
        git(&["commit", "-q", "-m", "owned worker commit"]);
        let worker_oid = git(&["rev-parse", "HEAD"]);
        git(&["checkout", "-q", "main"]);
        git(&[
            "merge",
            "-q",
            "--no-ff",
            "-m",
            "owned integration",
            "fixture-worker",
        ]);
        let integration_oid = git(&["rev-parse", "HEAD"]);
        git(&[
            "push",
            "-q",
            "fixture",
            &format!("{integration_oid}:refs/heads/main"),
        ]);

        crate::init::init(&root, false).unwrap();
        let ws = Workspace::at(&root);
        let mut config = ws.load_config().unwrap();
        config.git_finish = crate::schemas::GitFinishPolicy {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: "refs/heads/main".into(),
            pre_push_checks: vec![],
        };
        state::save_yaml(&ws.config_path(), &config).unwrap();

        let run_id = "run-20990101-000000-verified-projection";
        let task_id = "YARD-VERIFIED-PROJECTION";
        let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
        let worktree = ws.agents_dir().join("worktrees").join(run_id);
        let run_dir = ws.runs_dir().join(run_id);
        std::fs::create_dir_all(&run_dir).unwrap();
        let mut queued = task(task_id, TaskState::Done, 10, false);
        queued.kind = "implementation".into();
        let mut q = queue(vec![queued]);
        q.intent_id = "intent-verified-projection".into();
        ws.save_queue(&q).unwrap();

        let mut result = crate::schemas::RunResult {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            status: "done".into(),
            intent_adherence: Default::default(),
            changes: Default::default(),
            validation: Default::default(),
            question_for_user: None,
            compact_summary: "already integrated".into(),
            verdict: vec![],
            harness_suggestions: vec![],
            follow_up_tasks: vec![],
            artifacts: vec![],
            resources: vec![],
        };
        result.validation.passed = true;
        write_str(
            &run_dir.join("result.json"),
            &serde_json::to_string(&result).unwrap(),
        )
        .unwrap();
        write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
        state::save_yaml(
            &run_dir.join("run.yaml"),
            &RunRecord {
                schema_version: 1,
                run_id: run_id.into(),
                task_id: task_id.into(),
                intent_id: "intent-verified-projection".into(),
                worker: "codex".into(),
                state: "partial".into(),
                started_at: "2099-01-01T00:00:00+00:00".into(),
                completed_at: Some("2099-01-01T00:00:01+00:00".into()),
                worktree: worktree.display().to_string(),
                worktree_branch: branch.clone(),
                baseline_oid: baseline_oid.clone(),
                integration_oid: integration_oid.clone(),
                integration_base_oid: baseline_oid.clone(),
                integration_worker_oid: worker_oid.clone(),
                integration_provenance: IntegrationProvenance::ParallelWorkerDirect,
                integration_cleanup_complete: true,
                owned_oids: vec![worker_oid.clone(), integration_oid.clone()],
                ..Default::default()
            },
        )
        .unwrap();
        ws.save_integrated_cleanup_receipt(&state::IntegratedCleanupReceipt {
            schema_version: 1,
            run_id: run_id.into(),
            task_id: task_id.into(),
            intent_id: "intent-verified-projection".into(),
            worker: "codex".into(),
            worktree: worktree.display().to_string(),
            branch,
            baseline_oid: baseline_oid.clone(),
            integration_base_oid: baseline_oid.clone(),
            integration_worker_oid: worker_oid.clone(),
            integration_oid: integration_oid.clone(),
            provenance: IntegrationProvenance::ParallelWorkerDirect,
            owned_oids: vec![worker_oid.clone(), integration_oid.clone()],
        })
        .unwrap();

        // Reproduce the post-push crash boundary: the authoritative checkpoint
        // and queue state are durable, but the completed run projection is
        // still Partial.
        std::fs::create_dir_all(run_dir.join("git-finish.json")).unwrap();
        let projection_error = ws
            .save_git_finish_record(
                &run_dir,
                &crate::git_finish::GitFinishRecord {
                    schema_version: 2,
                    run_id: run_id.into(),
                    task_id: task_id.into(),
                    attempted_at: "2099-01-01T00:00:01+00:00".into(),
                    status: crate::git_finish::GitFinishStatus::Pushed,
                    policy: crate::git_finish::GitFinishPolicySnapshot {
                        auto_push: true,
                        remote: "fixture".into(),
                        target_ref: "refs/heads/main".into(),
                        pre_push_checks: vec![],
                    },
                    expected_oid: Some(integration_oid.clone()),
                    baseline_oid: baseline_oid.clone(),
                    owned_oids: vec![worker_oid, integration_oid.clone()],
                    checks: vec![],
                    push_invoked: true,
                    push_succeeded: true,
                    remote_oid: Some(integration_oid.clone()),
                    remote_before_oid: Some(baseline_oid),
                    reason: "remote_verified".into(),
                },
            )
            .unwrap_err();
        assert!(projection_error.to_string().contains("git-finish.json"));
        assert_eq!(
            ws.load_git_finish_record(&run_dir).unwrap().status,
            crate::git_finish::GitFinishStatus::Pushed
        );
        std::fs::remove_dir_all(run_dir.join("git-finish.json")).unwrap();
        if sensitive_uncommitted_file {
            std::fs::write(root.join(".env.recovery-secret"), "must remain untouched\n").unwrap();
        }

        let messages = recover_orphans(&ws);
        assert_eq!(
            ws.load_queue().unwrap().tasks[0].state,
            TaskState::Done,
            "{messages:?}"
        );
        let finish = ws.load_git_finish_record(&run_dir).unwrap();
        if sensitive_uncommitted_file {
            assert_eq!(finish.status, crate::git_finish::GitFinishStatus::Pushed);
            assert_eq!(finish.reason, "remote_verified");
            assert_eq!(finish.attempted_at, "2099-01-01T00:00:01+00:00");
        } else {
            assert_eq!(
                finish.status,
                crate::git_finish::GitFinishStatus::AlreadyApplied
            );
            assert!(!finish.push_invoked, "recovery must not repeat the push");
        }
        assert!(finish.status.verified_complete());
        assert_eq!(finish.remote_oid.as_deref(), Some(integration_oid.as_str()));
        let sealed = state::load_yaml::<RunRecord>(&run_dir.join("run.yaml")).unwrap();
        assert_eq!(sealed.state, "done");
        assert!(sealed.completed_at.is_some());
        assert_eq!(
            git(&["ls-remote", "--refs", "fixture", "refs/heads/main"]),
            format!("{integration_oid}\trefs/heads/main")
        );
        if sensitive_uncommitted_file {
            assert_eq!(
                std::fs::read_to_string(root.join(".env.recovery-secret")).unwrap(),
                "must remain untouched\n"
            );
        }

        let second = recover_orphans(&ws);
        assert!(
            second.is_empty(),
            "second recovery was not inert: {second:?}"
        );
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
    }

    #[test]
    fn verified_external_finish_recovers_partial_projection_without_duplicate_push() {
        assert_verified_external_finish_recovers_partial_projection(false);
    }

    #[test]
    fn done_projection_recovery_preserves_verified_finish_with_sensitive_uncommitted_file() {
        assert_verified_external_finish_recovers_partial_projection(true);
    }

    #[test]
    fn recovery_projects_accumulated_finishes_in_integration_order() {
        let root =
            std::env::temp_dir().join(format!("yard-accumulated-recovery-{}", std::process::id()));
        let remote = root.with_extension("bare.git");
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
        std::fs::create_dir_all(&root).unwrap();
        let git = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .arg("-C")
                .arg(&root)
                .args(args)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            String::from_utf8_lossy(&output.stdout).trim().to_string()
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.name", "Yardlet Test"]);
        git(&["config", "user.email", "yardlet@example.test"]);
        std::fs::write(root.join("owned.txt"), "seed\n").unwrap();
        git(&["add", "owned.txt"]);
        git(&["commit", "-q", "-m", "seed"]);
        let baseline = git(&["rev-parse", "HEAD"]);
        git(&["init", "-q", "--bare", remote.to_str().unwrap()]);
        git(&["remote", "add", "fixture", remote.to_str().unwrap()]);
        git(&["push", "-q", "fixture", "HEAD:refs/heads/main"]);
        crate::init::init(&root, false).unwrap();
        let ws = Workspace::at(&root);
        let mut config = ws.load_config().unwrap();
        config.git_finish = crate::schemas::GitFinishPolicy {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: "refs/heads/main".into(),
            pre_push_checks: vec![],
        };
        state::save_yaml(&ws.config_path(), &config).unwrap();

        git(&["checkout", "-q", "-b", "fixture-worker-1"]);
        std::fs::write(root.join("owned.txt"), "first\n").unwrap();
        git(&["add", "owned.txt"]);
        git(&["commit", "-q", "-m", "first"]);
        let first_worker_oid = git(&["rev-parse", "HEAD"]);
        git(&["checkout", "-q", "main"]);
        git(&[
            "merge",
            "-q",
            "--no-ff",
            "-m",
            "first integration",
            "fixture-worker-1",
        ]);
        let first_oid = git(&["rev-parse", "HEAD"]);
        git(&["checkout", "-q", "-b", "fixture-worker-2"]);
        std::fs::write(root.join("owned.txt"), "second\n").unwrap();
        git(&["add", "owned.txt"]);
        git(&["commit", "-q", "-m", "second"]);
        let second_worker_oid = git(&["rev-parse", "HEAD"]);
        git(&["checkout", "-q", "main"]);
        git(&[
            "merge",
            "-q",
            "--no-ff",
            "-m",
            "second integration",
            "fixture-worker-2",
        ]);
        let second_oid = git(&["rev-parse", "HEAD"]);

        let mut first_task = task("YARD-001", TaskState::Partial, 10, false);
        first_task.kind = "implementation".into();
        let mut second_task = task("YARD-002", TaskState::Partial, 20, false);
        second_task.kind = "implementation".into();
        let mut q = queue(vec![first_task, second_task]);
        q.intent_id = "intent-accumulated".into();
        ws.save_queue(&q).unwrap();

        let policy_snapshot = crate::git_finish::GitFinishPolicySnapshot {
            auto_push: true,
            remote: "fixture".into(),
            target_ref: "refs/heads/main".into(),
            pre_push_checks: vec![],
        };
        for (index, task_id, base_oid, worker_oid, expected_oid, status) in [
            (
                1,
                "YARD-001",
                baseline.as_str(),
                first_worker_oid.as_str(),
                first_oid.as_str(),
                crate::git_finish::GitFinishStatus::CheckBlocked,
            ),
            (
                2,
                "YARD-002",
                first_oid.as_str(),
                second_worker_oid.as_str(),
                second_oid.as_str(),
                crate::git_finish::GitFinishStatus::SafetyBlocked,
            ),
        ] {
            let run_id = format!("run-20990101-00000{index}-{task_id}");
            let run_dir = ws.runs_dir().join(&run_id);
            let worktree = ws.agents_dir().join("worktrees").join(&run_id);
            let branch = format!("yard/{}/{run_id}", task_id.to_lowercase());
            std::fs::create_dir_all(&run_dir).unwrap();
            let mut result = crate::schemas::RunResult {
                schema_version: 1,
                run_id: run_id.clone(),
                task_id: task_id.into(),
                status: "done".into(),
                intent_adherence: Default::default(),
                changes: Default::default(),
                validation: Default::default(),
                question_for_user: None,
                compact_summary: "integrated before Git finish".into(),
                verdict: vec![],
                harness_suggestions: vec![],
                follow_up_tasks: vec![],
                artifacts: vec![],
                resources: vec![],
            };
            result.validation.passed = true;
            write_str(
                &run_dir.join("result.json"),
                &serde_json::to_string(&result).unwrap(),
            )
            .unwrap();
            write_str(&run_dir.join("handoff.md"), "# Handoff\n").unwrap();
            state::save_yaml(
                &run_dir.join("run.yaml"),
                &RunRecord {
                    schema_version: 1,
                    run_id: run_id.clone(),
                    task_id: task_id.into(),
                    intent_id: "intent-accumulated".into(),
                    worker: "codex".into(),
                    state: "partial".into(),
                    started_at: format!("2099-01-01T00:00:0{index}+00:00"),
                    completed_at: Some(format!("2099-01-01T00:00:1{index}+00:00")),
                    worktree: worktree.display().to_string(),
                    baseline_oid: base_oid.into(),
                    worktree_branch: branch.clone(),
                    integration_oid: expected_oid.into(),
                    integration_base_oid: base_oid.into(),
                    integration_worker_oid: worker_oid.into(),
                    integration_provenance: IntegrationProvenance::ParallelWorkerDirect,
                    owned_oids: vec![worker_oid.into(), expected_oid.into()],
                    ..Default::default()
                },
            )
            .unwrap();
            ws.save_integrated_cleanup_receipt(&state::IntegratedCleanupReceipt {
                schema_version: 1,
                run_id: run_id.clone(),
                task_id: task_id.into(),
                intent_id: "intent-accumulated".into(),
                worker: "codex".into(),
                worktree: worktree.display().to_string(),
                branch,
                baseline_oid: base_oid.into(),
                integration_base_oid: base_oid.into(),
                integration_worker_oid: worker_oid.into(),
                integration_oid: expected_oid.into(),
                provenance: IntegrationProvenance::ParallelWorkerDirect,
                owned_oids: vec![worker_oid.into(), expected_oid.into()],
            })
            .unwrap();
            ws.save_git_finish_record(
                &run_dir,
                &crate::git_finish::GitFinishRecord {
                    schema_version: 2,
                    run_id: run_id.clone(),
                    task_id: task_id.into(),
                    attempted_at: String::new(),
                    status,
                    policy: policy_snapshot.clone(),
                    expected_oid: Some(expected_oid.into()),
                    baseline_oid: base_oid.into(),
                    owned_oids: vec![worker_oid.into(), expected_oid.into()],
                    checks: vec![],
                    push_invoked: false,
                    push_succeeded: false,
                    remote_oid: None,
                    remote_before_oid: Some(baseline.clone()),
                    reason: "pre_recovery".into(),
                },
            )
            .unwrap();
            telemetry::append_run(
                &ws,
                &telemetry::RunTelemetry {
                    ts: format!("2099-01-01T00:00:2{index}+00:00"),
                    run_id,
                    task_id: task_id.into(),
                    intent_id: "intent-accumulated".into(),
                    kind: "implementation".into(),
                    risk: String::new(),
                    worker: "codex".into(),
                    chosen_reason: "parallel".into(),
                    result_status: "done".into(),
                    eval_state: "Partial".into(),
                    wall_seconds: 0,
                    user_override: None,
                    skills: vec![],
                    verdict_pass: None,
                    feedback_cycle: 0,
                    max_feedback_cycles: 0,
                    feedback_retryable: false,
                    git_finish_status: status.as_str().into(),
                },
            )
            .unwrap();
        }

        let messages = recover_orphans(&ws);

        assert!(
            messages.iter().any(|line| line.contains("recovered")),
            "{messages:?}"
        );
        assert!(ws
            .load_queue()
            .unwrap()
            .tasks
            .iter()
            .all(|task| task.state == TaskState::Done));
        let runs = telemetry::read_runs(&ws);
        assert_eq!(
            runs.len(),
            2,
            "recovery corrections must not double-count runs"
        );
        assert!(runs.iter().all(|run| {
            run.eval_state == "Done"
                && matches!(run.git_finish_status.as_str(), "pushed" | "already_applied")
        }));
        let first_finish = ws
            .load_git_finish_record(&ws.runs_dir().join("run-20990101-000001-YARD-001"))
            .unwrap();
        let second_finish = ws
            .load_git_finish_record(&ws.runs_dir().join("run-20990101-000002-YARD-002"))
            .unwrap();
        assert_eq!(
            first_finish.remote_before_oid.as_deref(),
            Some(baseline.as_str())
        );
        assert_eq!(
            second_finish.remote_before_oid.as_deref(),
            Some(first_oid.as_str())
        );
        assert_eq!(
            second_finish.remote_oid.as_deref(),
            Some(second_oid.as_str())
        );
        let final_report = crate::report::build_final_report(&ws).unwrap();
        assert!(final_report.contains("2/2 tasks done"));
        assert_eq!(final_report.matches("pushed and verified").count(), 2);
        assert!(
            recover_orphans(&ws).is_empty(),
            "repeated recovery must be inert"
        );

        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&remote);
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

    #[test]
    fn sequential_selector_runs_builder_before_final_review() {
        let mut review = task("REVIEW", TaskState::Queued, 10, false);
        review.kind = "review".into();
        let mut follow_up = task("FIX", TaskState::Queued, 20, false);
        follow_up.kind = "implementation".into();
        follow_up.provenance = "worker-proposed".into();
        let mut q = queue(vec![review, follow_up]);

        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1));

        q.tasks[1].state = TaskState::Deferred;
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(0));

        q.tasks[1].state = TaskState::Queued;
        q.tasks[1].approval = Some(crate::yaml::from_str("required: true").unwrap());
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(0));

        q.tasks[1].approval = None;
        q.tasks[1].kind = "research".into();
        assert_eq!(select_next(&q, &opts()).unwrap(), Some(1));
    }

    #[test]
    fn sequential_review_barrier_waits_for_linked_approval_then_releases() {
        let mut review = task("REVIEW", TaskState::Queued, 10, false);
        review.kind = "review".into();
        let mut remediation = task("FIX", TaskState::Queued, 20, true);
        remediation.kind = "implementation".into();
        remediation.add_remediation_for("REVIEW");
        let unrelated = task("QUESTION", TaskState::NeedsUser, 1, false);
        let mut q = queue(vec![review, remediation, unrelated]);
        let caps = std::collections::BTreeSet::new();

        assert_eq!(
            select_next_ready(&q, &caps, |_| false).unwrap(),
            None,
            "an unapproved linked remediation must hold the review"
        );
        assert_eq!(
            select_next_ready(&q, &caps, |id| id == "FIX").unwrap(),
            Some(1),
            "approval makes the remediation, not the review, run next"
        );

        q.tasks[1].state = TaskState::Running;
        assert_eq!(select_next_ready(&q, &caps, |_| false).unwrap(), None);

        q.tasks[1].state = TaskState::Done;
        assert_eq!(
            select_next_ready(&q, &caps, |_| false).unwrap(),
            Some(0),
            "terminal remediation and unrelated NeedsUser release the review"
        );

        q.tasks[1].state = TaskState::NeedsUser;
        assert_eq!(
            select_next_ready(&q, &caps, |_| false).unwrap(),
            Some(0),
            "a terminal remediation human hold must not deadlock re-review"
        );
    }
}
