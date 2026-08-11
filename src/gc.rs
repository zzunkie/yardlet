//! `yardlet gc`: end-of-life for retained run worktrees.
//!
//! Per-run cleanup removes a worktree only on a verified, fully integrated
//! finish. Every other ending — Partial preservation, `auto_commit` off, a
//! receipt error, a crash window — deliberately KEEPS the worktree and its
//! `yard/<task>/<run-id>` branch as evidence. That retention is right in the
//! moment and wrong forever: nothing ever ended it, so a dogfooding audit found
//! 39 worktrees / 4.0GB still on disk months later (issue #139).
//!
//! This is the missing reaper. It never trusts the working copy on its own: a
//! worktree is only a removal candidate once its HEAD is provably an ancestor of
//! the integration target, and its leftover dirt is provably already in that
//! target byte for byte.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::Result;

use crate::run::RunRecord;
use crate::schemas::TaskState;
use crate::state::{self, Workspace};

/// Where salvaged evidence lands, relative to `.agents/`.
pub const SALVAGE_DIR: &str = "gc-salvage";

pub struct GcOptions {
    /// Remove; otherwise classify and print only.
    pub apply: bool,
    /// With `apply`, also remove `dirty-merged` worktrees after recording their
    /// tracked diff and untracked files under [`SALVAGE_DIR`].
    pub salvage: bool,
}

// ---------------------------------------------------------------------------
// Pure classification
// ---------------------------------------------------------------------------

/// One path `git status` reported in a worktree, and whether the target already
/// holds those exact bytes at the same path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirtyPath {
    pub path: String,
    /// True when the worktree's bytes and the target's bytes at this path are
    /// identical — including "absent in both", which is how a landed deletion
    /// looks.
    pub superseded: bool,
    /// True when Git reported the path as untracked (`??`).
    pub untracked: bool,
}

/// Everything the verdict depends on, gathered once per worktree.
///
/// Separating the observation from the judgment is what makes the judgment
/// testable: the interesting cases (a live worker, an unresolvable HEAD, dirt
/// that is really a superseded draft) are all a few field values here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WorktreeFacts {
    /// Directory name under `.agents/worktrees/`, which is the run id.
    pub name: String,
    /// Git still lists this path in `git worktree list --porcelain`.
    pub registered: bool,
    /// The run's task is `Running` in the live queue.
    pub queue_running: bool,
    /// The run's recorded worker process is alive AND still has the identity
    /// the run recorded (see `run::live_worker_pid`).
    pub worker_live: bool,
    /// The run belongs to the live (not yet archived) intent.
    pub intent_live: bool,
    /// `Some(true)`: HEAD is an ancestor of the integration target.
    /// `None`: ancestry could not be determined at all.
    pub merged: Option<bool>,
    /// `None`: `git status` could not be read or parsed.
    pub dirty: Option<Vec<DirtyPath>>,
}

/// Why a worktree stays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeepReason {
    QueueRunning,
    WorkerAlive,
    IntentLive,
    NotRegistered,
    AncestryUnknown,
    StatusUnknown,
}

impl KeepReason {
    pub fn text(self) -> &'static str {
        match self {
            Self::QueueRunning => "its task is Running in the live queue",
            Self::WorkerAlive => "its worker process is still alive",
            Self::IntentLive => "its intent is still live (not archived)",
            Self::NotRegistered => "not a registered Git worktree; remove it by hand if it is junk",
            Self::AncestryUnknown => "HEAD could not be compared with the integration target",
            Self::StatusUnknown => "its working-copy status could not be read",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    /// Merged and clean: nothing is left to lose.
    CleanMerged,
    /// Merged, and every dirty path is already in the target byte for byte.
    SupersededMerged,
    /// Merged, but carrying bytes the target does not have.
    DirtyMerged { unmatched: Vec<String> },
    /// HEAD is not an ancestor of the integration target.
    Unmerged,
    /// Untouchable, or not judgeable.
    Keep(KeepReason),
}

impl Verdict {
    /// Stable one-word label for the report. No label is a substring of
    /// another, so a caller may match on it.
    pub fn label(&self) -> &'static str {
        match self {
            Self::CleanMerged => "clean-merged",
            Self::SupersededMerged => "superseded-merged",
            Self::DirtyMerged { .. } => "dirty-merged",
            Self::Unmerged => "unmerged",
            Self::Keep(_) => "undecided",
        }
    }
}

/// What `gc` will do with a verdict under the given options.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Keep,
    Remove,
    SalvageAndRemove,
}

/// The judgment. Deterministic, and inviolable first: a live run wins over
/// every disk-shaped argument for removing its worktree.
pub fn classify(facts: &WorktreeFacts) -> Verdict {
    if facts.queue_running {
        return Verdict::Keep(KeepReason::QueueRunning);
    }
    if facts.worker_live {
        return Verdict::Keep(KeepReason::WorkerAlive);
    }
    if facts.intent_live {
        return Verdict::Keep(KeepReason::IntentLive);
    }
    if !facts.registered {
        return Verdict::Keep(KeepReason::NotRegistered);
    }
    match facts.merged {
        None => return Verdict::Keep(KeepReason::AncestryUnknown),
        Some(false) => return Verdict::Unmerged,
        Some(true) => {}
    }
    let Some(dirty) = facts.dirty.as_ref() else {
        return Verdict::Keep(KeepReason::StatusUnknown);
    };
    if dirty.is_empty() {
        return Verdict::CleanMerged;
    }
    let unmatched: Vec<String> = dirty
        .iter()
        .filter(|entry| !entry.superseded)
        .map(|entry| entry.path.clone())
        .collect();
    if unmatched.is_empty() {
        Verdict::SupersededMerged
    } else {
        Verdict::DirtyMerged { unmatched }
    }
}

/// Removal is opt-in twice over: `--apply` for the two verdicts that can lose
/// nothing, and `--salvage` on top for the one that can.
pub fn plan_action(verdict: &Verdict, options: &GcOptions) -> Action {
    if !options.apply {
        return Action::Keep;
    }
    match verdict {
        Verdict::CleanMerged | Verdict::SupersededMerged => Action::Remove,
        Verdict::DirtyMerged { .. } if options.salvage => Action::SalvageAndRemove,
        _ => Action::Keep,
    }
}

// ---------------------------------------------------------------------------
// Collection and execution
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Kept,
    WouldRemove,
    WouldSalvageAndRemove,
    Removed,
    SalvagedAndRemoved,
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub facts: WorktreeFacts,
    pub verdict: Verdict,
    pub outcome: Outcome,
    /// Under `--apply`: the refs actually deleted with the worktree. In a dry
    /// run: the candidate refs, each still subject to its own ancestry re-check
    /// at deletion time.
    pub branches: Vec<String>,
    /// Where salvaged evidence was written.
    pub salvage_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Default)]
pub struct GcReport {
    pub target: Option<String>,
    pub entries: Vec<Entry>,
    pub applied: bool,
}

/// Classify every retained run worktree, and — under `--apply` — end the ones
/// that can lose nothing.
pub fn collect(ws: &Workspace, options: &GcOptions) -> Result<GcReport> {
    let root = ws.root.clone();
    let worktrees_dir = ws.agents_dir().join("worktrees");

    let configured = ws
        .load_config()
        .map(|config| config.git_finish.target_ref)
        .unwrap_or_default();
    let target_ref = target_branch_ref(&configured);
    let target_oid = target_ref
        .as_ref()
        .and_then(|reference| oid_of(&root, &format!("{reference}^{{commit}}")));

    // A malformed queue is not proof that nothing is running. `queue_readable`
    // turns that into "cannot tell", which the pin below turns into "keep".
    let loaded = ws.load_queue();
    let queue_readable = loaded.is_ok();
    let queue = loaded.unwrap_or_else(|_| crate::schemas::WorkQueue::empty());
    let running: BTreeSet<String> = queue
        .tasks
        .iter()
        .filter(|task| task.state == TaskState::Running)
        .map(|task| task.id.to_lowercase())
        .collect();
    let queued_tasks: BTreeSet<String> = queue
        .tasks
        .iter()
        .map(|task| task.id.to_lowercase())
        .collect();
    let live_intent = ws
        .load_intent()
        .ok()
        .flatten()
        .map(|intent| intent.id)
        .filter(|id| !id.trim().is_empty());

    let registered = registered_worktrees(&root);

    let mut entries: Vec<Entry> = Vec::new();
    for path in retained_worktree_dirs(&worktrees_dir) {
        let Some(run_id) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let run_dir = ws.runs_dir().join(run_id);
        let record: Option<RunRecord> = state::load_yaml(&run_dir.join("run.yaml")).ok();
        let listed = registered
            .iter()
            .find(|entry| same_path(&entry.path, &path));
        let branch = listed.and_then(|entry| entry.branch.clone());

        let task_id = record
            .as_ref()
            .map(|record| record.task_id.trim().to_string())
            .filter(|id| !id.is_empty())
            .or_else(|| branch.as_deref().and_then(task_id_from_branch))
            .map(|id| id.to_lowercase());

        // Unattributable + a live queue is not "safe to remove", it is "cannot
        // tell": treat it as Running so the worktree stays.
        let queue_running = !queue_readable
            || match &task_id {
                Some(id) => running.contains(id),
                None => !running.is_empty(),
            };
        let worker_live = crate::run::live_worker_pid(&run_dir).is_some();
        let intent_live = intent_is_live(
            record.as_ref(),
            live_intent.as_deref(),
            task_id.as_deref(),
            &queued_tasks,
        );

        // Everything below costs a subprocess per worktree, and none of it can
        // change a verdict the checks above already fixed.
        let pinned = queue_running || worker_live || intent_live || listed.is_none();
        let merged = if pinned {
            None
        } else {
            oid_of(&path, "HEAD^{commit}")
                .zip(target_oid.clone())
                .and_then(|(head, target)| is_ancestor(&root, &head, &target))
        };
        let dirty = if merged == Some(true) {
            dirty_paths(&root, &path, target_oid.as_deref().unwrap_or_default())
        } else {
            None
        };

        let facts = WorktreeFacts {
            name: run_id.to_string(),
            registered: listed.is_some(),
            queue_running,
            worker_live,
            intent_live,
            merged,
            dirty,
        };
        let verdict = classify(&facts);
        let branches = if matches!(
            plan_action(
                &verdict,
                &GcOptions {
                    apply: true,
                    salvage: true
                }
            ),
            Action::Remove | Action::SalvageAndRemove
        ) {
            run_branch_refs(&root, run_id, branch.as_deref(), record.as_ref())
        } else {
            Vec::new()
        };
        entries.push(Entry {
            facts,
            verdict,
            outcome: Outcome::Kept,
            branches,
            salvage_dir: None,
        });
    }
    entries.sort_by(|a, b| a.facts.name.cmp(&b.facts.name));

    let mut removed_any = false;
    for entry in &mut entries {
        let planned = plan_action(&entry.verdict, options);
        if !options.apply {
            entry.outcome = match plan_action(
                &entry.verdict,
                &GcOptions {
                    apply: true,
                    salvage: options.salvage,
                },
            ) {
                Action::Remove => Outcome::WouldRemove,
                Action::SalvageAndRemove => Outcome::WouldSalvageAndRemove,
                Action::Keep => Outcome::Kept,
            };
            continue;
        }
        if planned == Action::Keep {
            // Under `--apply`, `branches` reports what was DELETED. A kept
            // worktree deleted nothing, so its candidate refs are not a count.
            entry.branches.clear();
            continue;
        }
        let path = worktrees_dir.join(&entry.facts.name);
        // Evidence first: a removal that runs before the salvage is written is
        // the exact loss this command exists to prevent.
        if planned == Action::SalvageAndRemove {
            match salvage(ws, &entry.facts, &path, target_ref.as_deref().unwrap_or("")) {
                Ok(dir) => entry.salvage_dir = Some(dir),
                Err(error) => {
                    entry.outcome = Outcome::Failed(format!("salvage failed: {error}"));
                    continue;
                }
            }
        }
        if !git_ok(
            &root,
            &["worktree", "remove", "--force", &path.display().to_string()],
        ) {
            entry.outcome = Outcome::Failed("git worktree remove refused".to_string());
            entry.branches.clear();
            continue;
        }
        removed_any = true;
        // Only now, and only for refs that are still provably in the target.
        let target = target_oid.clone().unwrap_or_default();
        let mut deleted = Vec::new();
        for reference in std::mem::take(&mut entry.branches) {
            let Some(tip) = oid_of(&root, &format!("{reference}^{{commit}}")) else {
                continue;
            };
            if is_ancestor(&root, &tip, &target) != Some(true) {
                continue;
            }
            if git_ok(&root, &["update-ref", "-d", &reference, &tip]) {
                deleted.push(reference);
            }
        }
        entry.branches = deleted;
        entry.outcome = if planned == Action::SalvageAndRemove {
            Outcome::SalvagedAndRemoved
        } else {
            Outcome::Removed
        };
    }
    if removed_any {
        let _ = git_ok(&root, &["worktree", "prune"]);
    }

    Ok(GcReport {
        target: target_ref,
        entries,
        applied: options.apply,
    })
}

/// Does this run belong to the live (not yet archived) intent?
///
/// The run record is authoritative when it has one. Without it, membership of
/// the live queue is the honest proxy: a task in the live queue belongs to the
/// live intent by construction.
fn intent_is_live(
    record: Option<&RunRecord>,
    live_intent: Option<&str>,
    task_id: Option<&str>,
    queued_tasks: &BTreeSet<String>,
) -> bool {
    let Some(live_intent) = live_intent else {
        return false;
    };
    match record
        .map(|record| record.intent_id.trim())
        .filter(|id| !id.is_empty())
    {
        Some(run_intent) => run_intent == live_intent,
        None => task_id.is_some_and(|id| queued_tasks.contains(id)),
    }
}

/// `yard/<task-id>/<run-id>` is the only branch shape a run worktree is created
/// with (`src/parallel.rs`, `src/run.rs`).
fn task_id_from_branch(branch: &str) -> Option<String> {
    let rest = branch
        .strip_prefix("refs/heads/")
        .unwrap_or(branch)
        .strip_prefix("yard/")?;
    let (task, _) = rest.split_once('/')?;
    (!task.is_empty()).then(|| task.to_string())
}

/// Directories under `.agents/worktrees/`, whether or not Git still lists them.
///
/// Symlinks are skipped on purpose. Following one would let a link planted here
/// nominate a worktree that lives somewhere else entirely — the workspace root,
/// or another repository — and this command's scope is exactly this directory.
fn retained_worktree_dirs(worktrees_dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(worktrees_dir) else {
        return Vec::new();
    };
    let mut out: Vec<PathBuf> = entries
        .flatten()
        .filter(|entry| {
            entry
                .path()
                .symlink_metadata()
                .is_ok_and(|meta| meta.is_dir())
        })
        .map(|entry| entry.path())
        .collect();
    out.sort();
    out
}

/// Same directory, allowing for one side being a symlinked or unresolved
/// spelling of the other. macOS in particular hands `git` a `/private/var/...`
/// path where the process's own cwd reads `/var/...`, and a plain `==` there
/// would report every worktree as unregistered.
fn same_path(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    let canonical =
        |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical(a) == canonical(b)
}

struct ListedWorktree {
    path: PathBuf,
    branch: Option<String>,
}

/// `git worktree list --porcelain`, as records. The main worktree is included;
/// callers match on path, and only paths under `.agents/worktrees/` are ever
/// candidates.
fn registered_worktrees(root: &Path) -> Vec<ListedWorktree> {
    let Some(listed) = git_stdout(root, &["worktree", "list", "--porcelain"]) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut current: Option<ListedWorktree> = None;
    for line in listed.lines() {
        if let Some(path) = line.strip_prefix("worktree ") {
            if let Some(entry) = current.take() {
                out.push(entry);
            }
            current = Some(ListedWorktree {
                path: PathBuf::from(path),
                branch: None,
            });
        } else if let Some(branch) = line.strip_prefix("branch ") {
            if let Some(entry) = current.as_mut() {
                entry.branch = Some(branch.to_string());
            }
        }
    }
    out.extend(current);
    out
}

/// Every ref that belongs to this run: the branch the worktree has checked out,
/// the one its run record names, any `refs/heads/yard/**` ref whose last segment
/// is the run id, and the paired integration-transaction ref that per-run
/// cleanup deletes alongside each of them (`parallel::remove_worktree`).
///
/// Membership here only makes a ref a CANDIDATE. Each one is re-checked against
/// the integration target immediately before it is deleted.
fn run_branch_refs(
    root: &Path,
    run_id: &str,
    checked_out: Option<&str>,
    record: Option<&RunRecord>,
) -> Vec<String> {
    let mut refs: BTreeSet<String> = BTreeSet::new();
    let mut add = |value: &str| {
        let value = value.trim();
        if value.is_empty() {
            return;
        }
        let full = if value.starts_with("refs/") {
            value.to_string()
        } else {
            format!("refs/heads/{value}")
        };
        refs.insert(full);
    };
    if let Some(branch) = checked_out {
        add(branch);
    }
    if let Some(record) = record {
        add(&record.worktree_branch);
    }
    if let Some(listed) = git_stdout(
        root,
        &["for-each-ref", "--format=%(refname)", "refs/heads/yard/"],
    ) {
        let suffix = format!("/{run_id}");
        for reference in listed.lines().filter(|line| line.ends_with(&suffix)) {
            add(reference);
        }
    }
    let mut out: Vec<String> = refs.iter().cloned().collect();
    for reference in &refs {
        if let Some(branch) = reference.strip_prefix("refs/heads/") {
            out.push(format!("refs/heads/yardlet-txn/{branch}"));
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Write the removable-only-with-consent evidence: the tracked diff as an
/// applicable patch, and a copy of every untracked file.
fn salvage(ws: &Workspace, facts: &WorktreeFacts, path: &Path, target: &str) -> Result<PathBuf> {
    let dir = ws.agents_dir().join(SALVAGE_DIR).join(&facts.name);
    let patch = git_stdout(path, &["diff", "--binary", "HEAD"]).unwrap_or_default();
    state::write_str(&dir.join("tracked.patch"), &patch)?;
    let untracked: Vec<&DirtyPath> = facts
        .dirty
        .iter()
        .flatten()
        .filter(|entry| entry.untracked)
        .collect();
    for entry in &untracked {
        let bytes = std::fs::read(path.join(&entry.path))?;
        state::write_bytes(&dir.join("untracked").join(&entry.path), &bytes)?;
    }
    let head = oid_of(path, "HEAD^{commit}").unwrap_or_else(|| "(unknown)".to_string());
    let mut manifest = format!(
        "worktree: {}\nhead: {head}\nintegration_target: {target}\nsalvaged_at: {}\n\ntracked.patch: git diff --binary HEAD\nuntracked/:\n",
        facts.name,
        chrono::Local::now().to_rfc3339(),
    );
    if untracked.is_empty() {
        manifest.push_str("  (none)\n");
    }
    for entry in &untracked {
        manifest.push_str(&format!("  {}\n", entry.path));
    }
    state::write_str(&dir.join("MANIFEST.txt"), &manifest)?;
    Ok(dir)
}

/// The local branch the workspace's Git finish policy delivers to, as a full
/// ref. `None` when the configured target is not a local branch at all, which
/// leaves every ancestry question unanswerable rather than answered wrongly.
fn target_branch_ref(configured: &str) -> Option<String> {
    let trimmed = configured.trim();
    if trimmed.is_empty() {
        return Some("refs/heads/main".to_string());
    }
    let branch = match trimmed.strip_prefix("refs/") {
        Some(rest) => rest.strip_prefix("heads/")?,
        None => trimmed,
    };
    (!branch.is_empty()).then(|| format!("refs/heads/{branch}"))
}

/// Every dirty path in the worktree, each paired with "the target already has
/// exactly these bytes at this path". `None` when the status could not be read
/// or understood, which must never be read as "clean".
fn dirty_paths(root: &Path, worktree: &Path, target_oid: &str) -> Option<Vec<DirtyPath>> {
    let raw = git_stdout_bytes(
        worktree,
        &["status", "--porcelain=v1", "-z", "--untracked-files=all"],
    )?;
    let entries = parse_status_paths(&raw)?;
    Some(
        entries
            .into_iter()
            .map(|(path, untracked)| {
                let here = std::fs::read(worktree.join(&path)).ok();
                let there =
                    git_stdout_bytes(root, &["cat-file", "blob", &format!("{target_oid}:{path}")]);
                DirtyPath {
                    // Absent on both sides counts as identical: that is what a
                    // deletion which already landed looks like.
                    superseded: here == there,
                    path,
                    untracked,
                }
            })
            .collect(),
    )
}

/// `Some(true)`/`Some(false)` only when Git actually answered; any other exit
/// is an error, not a "no".
fn is_ancestor(root: &Path, candidate: &str, target: &str) -> Option<bool> {
    let status = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["merge-base", "--is-ancestor", candidate, target])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()?;
    match status.code() {
        Some(0) => Some(true),
        Some(1) => Some(false),
        _ => None,
    }
}

fn oid_of(dir: &Path, revision: &str) -> Option<String> {
    git_stdout(dir, &["rev-parse", "--verify", revision])
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn git_stdout(dir: &Path, args: &[&str]) -> Option<String> {
    git_stdout_bytes(dir, args).map(|bytes| String::from_utf8_lossy(&bytes).into_owned())
}

fn git_stdout_bytes(dir: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    output.status.success().then_some(output.stdout)
}

fn git_ok(dir: &Path, args: &[&str]) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Every path a `git status --porcelain=v1 -z --untracked-files=all` record
/// touches, paired with "Git called it untracked". `None` means the output was
/// not in the shape this parser understands, which must never be read as
/// "clean".
fn parse_status_paths(raw: &[u8]) -> Option<Vec<(String, bool)>> {
    let mut fields = raw.split(|byte| *byte == 0);
    let mut out: Vec<(String, bool)> = Vec::new();
    while let Some(entry) = fields.next() {
        if entry.is_empty() {
            continue;
        }
        // `XY <path>`: two status letters, one space, then at least one byte of
        // path. Anything shorter or shaped differently is output this parser
        // does not understand, and guessing at it would read as "clean".
        if entry.len() < 4 || entry[2] != b' ' {
            return None;
        }
        let (x, y) = (entry[0], entry[1]);
        let path = std::str::from_utf8(&entry[3..]).ok()?;
        let untracked = x == b'?' && y == b'?';
        out.push((path.to_string(), untracked));
        // Rename/copy records carry the original path in the NEXT field (the
        // `-z` format drops the `->` and reverses the order). Both sides matter:
        // the old path is a deletion the target may or may not already have.
        if matches!(x, b'R' | b'C') || matches!(y, b'R' | b'C') {
            let original = fields.next()?;
            if original.is_empty() {
                return None;
            }
            out.push((std::str::from_utf8(original).ok()?.to_string(), false));
        }
    }
    out.sort();
    out.dedup();
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dirty(path: &str, superseded: bool) -> DirtyPath {
        DirtyPath {
            path: path.to_string(),
            superseded,
            untracked: false,
        }
    }

    fn merged_and_clean() -> WorktreeFacts {
        WorktreeFacts {
            name: "run-20260718-101010-yard-001".to_string(),
            registered: true,
            merged: Some(true),
            dirty: Some(Vec::new()),
            ..Default::default()
        }
    }

    #[test]
    fn merged_and_clean_worktree_is_clean_merged() {
        assert_eq!(classify(&merged_and_clean()), Verdict::CleanMerged);
    }

    #[test]
    fn merged_worktree_whose_dirt_already_landed_is_superseded_merged() {
        let facts = WorktreeFacts {
            dirty: Some(vec![dirty("src/run.rs", true), dirty("docs/a.md", true)]),
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::SupersededMerged);
    }

    #[test]
    fn merged_worktree_with_bytes_the_target_lacks_is_dirty_merged() {
        let facts = WorktreeFacts {
            dirty: Some(vec![dirty("src/run.rs", true), dirty("draft.txt", false)]),
            ..merged_and_clean()
        };
        assert_eq!(
            classify(&facts),
            Verdict::DirtyMerged {
                unmatched: vec!["draft.txt".to_string()],
            }
        );
    }

    #[test]
    fn head_that_is_not_an_ancestor_of_the_target_is_unmerged() {
        let facts = WorktreeFacts {
            merged: Some(false),
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Unmerged);
    }

    #[test]
    fn a_running_queue_task_pins_its_worktree_even_when_clean_merged() {
        let facts = WorktreeFacts {
            queue_running: true,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::QueueRunning));
    }

    #[test]
    fn a_live_worker_pins_its_worktree_even_when_clean_merged() {
        let facts = WorktreeFacts {
            worker_live: true,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::WorkerAlive));
    }

    #[test]
    fn a_live_intent_pins_its_worktree_even_when_clean_merged() {
        let facts = WorktreeFacts {
            intent_live: true,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::IntentLive));
    }

    #[test]
    fn undeterminable_ancestry_is_kept_not_guessed() {
        let facts = WorktreeFacts {
            merged: None,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::AncestryUnknown));
    }

    #[test]
    fn unreadable_status_is_kept_not_guessed() {
        let facts = WorktreeFacts {
            dirty: None,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::StatusUnknown));
    }

    #[test]
    fn a_directory_git_does_not_list_as_a_worktree_is_kept() {
        let facts = WorktreeFacts {
            registered: false,
            ..merged_and_clean()
        };
        assert_eq!(classify(&facts), Verdict::Keep(KeepReason::NotRegistered));
    }

    #[test]
    fn dry_run_removes_nothing_it_would_otherwise_remove() {
        let options = GcOptions {
            apply: false,
            salvage: true,
        };
        assert_eq!(plan_action(&Verdict::CleanMerged, &options), Action::Keep);
        assert_eq!(
            plan_action(&Verdict::SupersededMerged, &options),
            Action::Keep
        );
        assert_eq!(
            plan_action(
                &Verdict::DirtyMerged {
                    unmatched: vec!["draft.txt".to_string()]
                },
                &options
            ),
            Action::Keep
        );
    }

    #[test]
    fn apply_removes_merged_worktrees_with_nothing_to_lose() {
        let options = GcOptions {
            apply: true,
            salvage: false,
        };
        assert_eq!(plan_action(&Verdict::CleanMerged, &options), Action::Remove);
        assert_eq!(
            plan_action(&Verdict::SupersededMerged, &options),
            Action::Remove
        );
    }

    #[test]
    fn apply_alone_keeps_a_dirty_merged_worktree() {
        let options = GcOptions {
            apply: true,
            salvage: false,
        };
        assert_eq!(
            plan_action(
                &Verdict::DirtyMerged {
                    unmatched: vec!["draft.txt".to_string()]
                },
                &options
            ),
            Action::Keep
        );
    }

    #[test]
    fn salvage_removes_a_dirty_merged_worktree_after_recording_it() {
        let options = GcOptions {
            apply: true,
            salvage: true,
        };
        assert_eq!(
            plan_action(
                &Verdict::DirtyMerged {
                    unmatched: vec!["draft.txt".to_string()]
                },
                &options
            ),
            Action::SalvageAndRemove
        );
    }

    #[test]
    fn salvage_never_reaches_an_unmerged_or_undecided_worktree() {
        let options = GcOptions {
            apply: true,
            salvage: true,
        };
        assert_eq!(plan_action(&Verdict::Unmerged, &options), Action::Keep);
        assert_eq!(
            plan_action(&Verdict::Keep(KeepReason::WorkerAlive), &options),
            Action::Keep
        );
    }

    #[test]
    fn an_unset_git_finish_target_falls_back_to_main() {
        assert_eq!(target_branch_ref(""), Some("refs/heads/main".to_string()));
        assert_eq!(
            target_branch_ref("   "),
            Some("refs/heads/main".to_string())
        );
    }

    #[test]
    fn a_configured_target_is_read_in_either_spelling() {
        assert_eq!(
            target_branch_ref("refs/heads/release"),
            Some("refs/heads/release".to_string())
        );
        assert_eq!(
            target_branch_ref("release"),
            Some("refs/heads/release".to_string())
        );
    }

    #[test]
    fn a_target_that_is_not_a_local_branch_leaves_the_judgment_undecidable() {
        assert_eq!(target_branch_ref("refs/tags/v1"), None);
        assert_eq!(target_branch_ref("refs/heads/"), None);
    }

    #[test]
    fn status_parser_reads_every_affected_path() {
        let raw = b"?? draft.txt\0 M src/run.rs\0";
        assert_eq!(
            parse_status_paths(raw).unwrap(),
            vec![
                (String::from("draft.txt"), true),
                (String::from("src/run.rs"), false),
            ]
        );
    }

    #[test]
    fn status_parser_takes_both_sides_of_a_rename() {
        let raw = b"R  new.rs\0old.rs\0";
        assert_eq!(
            parse_status_paths(raw).unwrap(),
            vec![
                (String::from("new.rs"), false),
                (String::from("old.rs"), false),
            ]
        );
    }

    #[test]
    fn status_parser_refuses_output_it_does_not_understand() {
        assert_eq!(parse_status_paths(b"x\0"), None);
    }

    #[cfg(unix)]
    fn scratch(name: &str) -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!(
            "yardlet-gc-unit-{name}-{}-{nonce}",
            std::process::id()
        ));
        std::fs::create_dir_all(&base).unwrap();
        base
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_directory_is_never_a_retained_worktree() {
        let base = scratch("symlink-scan");
        let worktrees = base.join("worktrees");
        let elsewhere = base.join("elsewhere");
        std::fs::create_dir_all(worktrees.join("run-real")).unwrap();
        std::fs::create_dir_all(&elsewhere).unwrap();
        std::os::unix::fs::symlink(&elsewhere, worktrees.join("run-linked")).unwrap();

        // Following the link would nominate a directory outside this command's
        // scope for removal.
        assert_eq!(
            retained_worktree_dirs(&worktrees),
            vec![worktrees.join("run-real")]
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[cfg(unix)]
    #[test]
    fn two_spellings_of_one_directory_are_the_same_path() {
        let base = scratch("same-path");
        let real = base.join("real");
        let link = base.join("link");
        std::fs::create_dir_all(&real).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        assert!(same_path(&real, &link));
        assert!(!same_path(&real, &base.join("other")));
        let _ = std::fs::remove_dir_all(&base);
    }
}
