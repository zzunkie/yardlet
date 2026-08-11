//! `yardlet gc` against a real repository with real retained run worktrees.
//!
//! Issue #139: retention has no end-of-life, so `.agents/worktrees/` grew to 39
//! worktrees / 4.0GB. The judgment this command makes is about Git history and
//! live processes, and neither is faithfully reproducible in a unit test — a
//! fake "is ancestor" answer proves nothing about `git merge-base`, and a fake
//! pid proves nothing about a worker that is genuinely still running.

mod common;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use common::{ChildGuard, WorkspaceGuard};

fn sh_git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("git {args:?} in {}: {error}", dir.display()));
    assert!(
        output.status.success(),
        "git {args:?} in {} failed:\n{}",
        dir.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn write(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    fs::write(path, contents).unwrap();
}

fn commit(dir: &Path, message: &str) {
    sh_git(dir, &["add", "-A"]);
    sh_git(dir, &["commit", "-q", "-m", message]);
}

fn yardlet(root: &Path, args: &[&str]) -> (bool, String, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_yardlet"))
        .args(args)
        .current_dir(root)
        .output()
        .unwrap();
    (
        output.status.success(),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    )
}

fn gc(root: &Path, args: &[&str]) -> String {
    let mut argv = vec!["gc"];
    argv.extend_from_slice(args);
    let (ok, stdout, stderr) = yardlet(root, &argv);
    assert!(
        ok,
        "yardlet {argv:?} failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
    stdout
}

/// The report line whose first column is this worktree.
fn line_for<'a>(stdout: &'a str, name: &str) -> &'a str {
    stdout
        .lines()
        .find(|line| line.split_whitespace().next() == Some(name))
        .unwrap_or_else(|| panic!("no report line for {name} in:\n{stdout}"))
}

fn branch_exists(root: &Path, branch: &str) -> bool {
    Command::new("git")
        .arg("-C")
        .arg(root)
        .args([
            "rev-parse",
            "--verify",
            "--quiet",
            &format!("refs/heads/{branch}"),
        ])
        .output()
        .unwrap()
        .status
        .success()
}

struct Fixture {
    guard: WorkspaceGuard,
    /// Kept alive for the whole test: this is the "worker" that must pin its
    /// worktree. Dropping it kills and reaps the process.
    _worker: ChildGuard,
}

impl Fixture {
    fn root(&self) -> &Path {
        self.guard.path()
    }

    fn worktree(&self, run_id: &str) -> PathBuf {
        self.guard.join(".agents/worktrees").join(run_id)
    }
}

/// Five retained worktrees, one per verdict the command has to reach, plus a
/// plain directory Git does not know about.
fn fixture(name: &str) -> Fixture {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let guard = WorkspaceGuard::create(
        std::env::temp_dir().join(format!("yardlet-gc-{name}-{}-{nonce}", std::process::id())),
    );
    let root = guard.path().to_path_buf();

    sh_git(&root, &["init", "-q"]);
    // Pin the branch name: `init.defaultBranch` is per-machine, and the
    // command's fallback target is `main`.
    sh_git(&root, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    sh_git(&root, &["config", "user.name", "Local User"]);
    sh_git(&root, &["config", "user.email", "local@example.test"]);
    sh_git(&root, &["config", "commit.gpgsign", "false"]);
    // Yardlet keeps its runtime state out of the repo it runs in (see
    // `parallel::ensure_worktrees_excluded`). Without it, a root commit here
    // would swallow the nested worktrees as gitlinks.
    write(&root.join(".git/info/exclude"), ".agents/\n");
    write(&root.join("README.md"), "base\n");
    commit(&root, "init");

    let (ok, stdout, stderr) = yardlet(&root, &["init"]);
    assert!(
        ok,
        "yardlet init failed\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );

    let add = |run_id: &str, branch: &str| -> PathBuf {
        let path = root.join(".agents/worktrees").join(run_id);
        sh_git(
            &root,
            &[
                "worktree",
                "add",
                "-q",
                &path.display().to_string(),
                "-b",
                branch,
            ],
        );
        path
    };
    let merge = |branch: &str| {
        sh_git(&root, &["merge", "-q", "--no-ff", "--no-edit", branch]);
    };

    // Merged, nothing left in the working copy.
    let clean = add("run-clean", "yard/yard-001/run-clean");
    write(&clean.join("landed.txt"), "landed\n");
    commit(&clean, "landed work");
    merge("yard/yard-001/run-clean");

    // Merged, and its leftover edit is byte-identical to what the target now
    // holds: the superseded draft the audit found again and again.
    let superseded = add("run-superseded", "yard/yard-002/run-superseded");
    write(&superseded.join("note.txt"), "draft\n");
    commit(&superseded, "draft note");
    merge("yard/yard-002/run-superseded");
    write(&root.join("note.txt"), "final\n");
    commit(&root, "finish the note");
    write(&superseded.join("note.txt"), "final\n");

    // Merged, but carrying bytes the target does not have.
    let dirty = add("run-dirty", "yard/yard-003/run-dirty");
    write(&dirty.join("shipped.txt"), "shipped\n");
    commit(&dirty, "shipped work");
    merge("yard/yard-003/run-dirty");
    write(&dirty.join("shipped.txt"), "shipped + local\n");
    write(&dirty.join("draft.txt"), "unsaved work\n");

    // Never integrated.
    let unmerged = add("run-unmerged", "yard/yard-004/run-unmerged");
    write(&unmerged.join("never.txt"), "never landed\n");
    commit(&unmerged, "unmerged work");

    // Merged and clean, but its worker is genuinely still running.
    let live = add("run-live", "yard/yard-005/run-live");
    write(&live.join("live.txt"), "live\n");
    commit(&live, "live work");
    merge("yard/yard-005/run-live");
    let worker = ChildGuard::new(
        Command::new("sleep")
            .arg("300")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    let pid = worker.id();
    let marker = Command::new("ps")
        .args(["-p", &pid.to_string(), "-o", "lstart="])
        .output()
        .unwrap();
    assert!(
        marker.status.success(),
        "ps could not read the worker's start time"
    );
    let marker = String::from_utf8_lossy(&marker.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    assert!(!marker.is_empty(), "empty process start marker");
    let run_dir = root.join(".agents/runs/run-live");
    write(
        &run_dir.join("run.yaml"),
        "schema_version: 1\n\
         run_id: run-live\n\
         task_id: YARD-005\n\
         intent_id: intent-archived\n\
         worker: codex\n\
         state: running\n\
         started_at: '2026-08-11T00:00:00+09:00'\n\
         worktree: .agents/worktrees/run-live\n",
    );
    write(
        &run_dir.join("worker-process.yaml"),
        &format!(
            "schema_version: 1\n\
             run_id: run-live\n\
             attempt_id: attempt-1\n\
             worker_id: codex\n\
             pid: {pid}\n\
             process_start_marker: \"{marker}\"\n\
             state: running\n"
        ),
    );

    // A directory Git never registered as a worktree.
    write(
        &root.join(".agents/worktrees/not-a-worktree/leftover.txt"),
        "junk\n",
    );

    Fixture {
        guard,
        _worker: worker,
    }
}

#[test]
fn dry_run_classifies_every_retained_worktree_and_removes_nothing() {
    let fixture = fixture("dry-run");
    let stdout = gc(fixture.root(), &[]);

    assert!(
        line_for(&stdout, "run-clean").contains("clean-merged"),
        "run-clean must classify as clean-merged:\n{stdout}"
    );
    assert!(
        line_for(&stdout, "run-superseded").contains("superseded-merged"),
        "a leftover edit already in the target is superseded, not dirty:\n{stdout}"
    );
    assert!(
        line_for(&stdout, "run-dirty").contains("dirty-merged"),
        "run-dirty must classify as dirty-merged:\n{stdout}"
    );
    // The name itself contains "unmerged", so the label alone would prove
    // nothing: require the reason too.
    let unmerged_line = line_for(&stdout, "run-unmerged");
    assert!(
        unmerged_line.contains("unmerged") && unmerged_line.contains("not an ancestor"),
        "run-unmerged must classify as unmerged and say why:\n{stdout}"
    );
    assert!(
        line_for(&stdout, "run-live").contains("alive"),
        "run-live must be held by its live worker:\n{stdout}"
    );
    assert!(
        line_for(&stdout, "not-a-worktree").contains("registered"),
        "a directory Git does not list must say so:\n{stdout}"
    );

    for run_id in [
        "run-clean",
        "run-superseded",
        "run-dirty",
        "run-unmerged",
        "run-live",
    ] {
        assert!(
            fixture.worktree(run_id).is_dir(),
            "a dry run must remove nothing, but {run_id} is gone"
        );
    }
    for branch in [
        "yard/yard-001/run-clean",
        "yard/yard-002/run-superseded",
        "yard/yard-003/run-dirty",
        "yard/yard-004/run-unmerged",
        "yard/yard-005/run-live",
    ] {
        assert!(
            branch_exists(fixture.root(), branch),
            "a dry run must delete no branch, but {branch} is gone"
        );
    }
}

#[test]
fn apply_removes_only_what_cannot_lose_anything() {
    let fixture = fixture("apply");
    let stdout = gc(fixture.root(), &["--apply"]);

    for (run_id, branch) in [
        ("run-clean", "yard/yard-001/run-clean"),
        ("run-superseded", "yard/yard-002/run-superseded"),
    ] {
        assert!(
            !fixture.worktree(run_id).exists(),
            "{run_id} should have been removed:\n{stdout}"
        );
        assert!(
            !branch_exists(fixture.root(), branch),
            "{branch} should have been deleted with its worktree:\n{stdout}"
        );
    }

    for (run_id, branch) in [
        ("run-dirty", "yard/yard-003/run-dirty"),
        ("run-unmerged", "yard/yard-004/run-unmerged"),
        ("run-live", "yard/yard-005/run-live"),
    ] {
        assert!(
            fixture.worktree(run_id).is_dir(),
            "{run_id} must be kept without --salvage:\n{stdout}"
        );
        assert!(
            branch_exists(fixture.root(), branch),
            "{branch} must survive with its worktree:\n{stdout}"
        );
    }

    assert!(
        !fixture.guard.join(".agents").join("gc-salvage").exists(),
        "--apply without --salvage must record nothing:\n{stdout}"
    );

    // The removals really left Git's own bookkeeping consistent.
    let listed = sh_git(fixture.root(), &["worktree", "list", "--porcelain"]);
    assert!(
        !listed.contains("run-clean"),
        "removed worktrees must not stay registered:\n{listed}"
    );
}

#[test]
fn salvage_records_a_dirty_worktree_before_removing_it() {
    let fixture = fixture("salvage");
    let stdout = gc(fixture.root(), &["--apply", "--salvage"]);

    assert!(
        !fixture.worktree("run-dirty").exists(),
        "--salvage must remove the dirty-merged worktree:\n{stdout}"
    );
    assert!(
        !branch_exists(fixture.root(), "yard/yard-003/run-dirty"),
        "the salvaged worktree's branch must go with it:\n{stdout}"
    );

    let salvage = fixture.guard.join(".agents/gc-salvage/run-dirty");
    let patch = fs::read_to_string(salvage.join("tracked.patch"))
        .unwrap_or_else(|error| panic!("no tracked patch in {}: {error}", salvage.display()));
    assert!(
        patch.contains("shipped + local"),
        "the tracked diff must carry the removed bytes:\n{patch}"
    );
    assert_eq!(
        fs::read_to_string(salvage.join("untracked/draft.txt")).unwrap(),
        "unsaved work\n",
        "an untracked file must be copied out before removal"
    );

    // Salvage is not a licence to touch the untouchable.
    assert!(
        fixture.worktree("run-unmerged").is_dir(),
        "--salvage must not reach an unmerged worktree:\n{stdout}"
    );
    assert!(
        fixture.worktree("run-live").is_dir(),
        "--salvage must not reach a live worker's worktree:\n{stdout}"
    );
    assert!(
        !fixture
            .guard
            .join(".agents/gc-salvage/run-unmerged")
            .exists(),
        "nothing may be salvaged from a worktree that is not being removed:\n{stdout}"
    );
}
