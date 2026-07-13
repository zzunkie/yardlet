//! Project-memory init/refresh.
//!
//! Workers draft memory documents into an isolated run directory. Yardlet core
//! is the sole writer of canonical `.agents/memory/*.md` files and the generated
//! index through `Workspace::write_memory_documents`.

use std::collections::{BTreeMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::{Deserialize, Serialize};

use crate::packet::{self, MemoryRefreshTarget};
use crate::state::{MemoryDocumentDraft, MemoryWriteMode, MemoryWriteReport, Workspace};
use crate::{guard, inspect, workers};

#[derive(Debug, Clone)]
pub struct MemoryEntry {
    pub title: String,
    pub summary: String,
    pub path: String,
    pub look_at: Vec<String>,
    pub stale: bool,
    pub changed_look_at: Vec<String>,
}

#[derive(Debug)]
pub struct MemoryCommandReport {
    pub run_id: Option<String>,
    pub worker_id: Option<String>,
    pub written: Vec<String>,
    pub skipped: Vec<String>,
    pub index_path: Option<String>,
    pub rationale: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct MemoryResult {
    #[serde(default)]
    documents: Vec<MemoryResultDocument>,
    #[serde(default)]
    rationale: String,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
struct MemoryResultDocument {
    #[serde(default)]
    slug: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    look_at: Vec<String>,
    #[serde(default)]
    body: String,
}

impl MemoryResultDocument {
    fn into_draft(self) -> MemoryDocumentDraft {
        let title = first_non_empty(&[&self.title, &self.name, &self.slug]);
        let summary = first_non_empty(&[&self.summary, &self.description, &title]);
        MemoryDocumentDraft {
            slug: self.slug,
            title,
            summary,
            look_at: self.look_at,
            body: self.body,
        }
    }
}

fn first_non_empty(values: &[&str]) -> String {
    values
        .iter()
        .map(|v| v.trim())
        .find(|v| !v.is_empty())
        .unwrap_or("")
        .to_string()
}

pub fn indexed(ws: &Workspace) -> Result<Vec<MemoryEntry>> {
    let config = ws.load_config()?;
    let h = packet::discover_harness(&ws.root, config.harness_discovery);
    let uncommitted = git_uncommitted_paths(&ws.root);
    Ok(h.memory
        .into_iter()
        .map(|m| {
            let doc_time = memory_updated_time(&ws.root.join(&m.path));
            let changed_look_at: Vec<_> = m
                .look_at
                .iter()
                .filter_map(|raw| {
                    let rel = normalize_look_at(&ws.root, raw)?;
                    let landmark = ws.root.join(&rel);
                    let changed = uncommitted.contains(&rel)
                        || (doc_time.is_some() && !landmark.exists())
                        || is_newer_than_memory(
                            doc_time,
                            git_commit_time(&ws.root, &rel).or_else(|| modified_time(&landmark)),
                        );
                    changed.then_some(rel)
                })
                .collect();
            MemoryEntry {
                title: m.title,
                summary: m.summary,
                path: m.path,
                look_at: m.look_at,
                stale: !changed_look_at.is_empty(),
                changed_look_at,
            }
        })
        .collect())
}

fn is_newer_than_memory(memory_time: Option<i128>, landmark_time: Option<i128>) -> bool {
    matches!((memory_time, landmark_time), (Some(memory), Some(landmark)) if landmark > memory)
}

fn memory_updated_time(path: &Path) -> Option<i128> {
    let text = std::fs::read_to_string(path).ok()?;
    let from_frontmatter = text.lines().find_map(|line| {
        let value = line
            .trim()
            .strip_prefix("updated_at:")?
            .trim()
            .trim_matches(['\'', '"']);
        chrono::DateTime::parse_from_rfc3339(value)
            .ok()
            .and_then(|v| v.timestamp_nanos_opt())
            .map(i128::from)
    });
    from_frontmatter.or_else(|| modified_time(path))
}

fn modified_time(path: &Path) -> Option<i128> {
    path.metadata()
        .ok()?
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|v| v.as_nanos().min(i128::MAX as u128) as i128)
}

fn normalize_look_at(root: &Path, raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let path = Path::new(raw);
    let relative = if path.is_absolute() {
        path.strip_prefix(root).ok()?
    } else {
        path
    };
    let mut clean = PathBuf::new();
    for component in relative.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(part) => clean.push(part),
            Component::ParentDir => {
                if !clean.pop() {
                    return None;
                }
            }
            Component::RootDir | Component::Prefix(_) => return None,
        }
    }
    (!clean.as_os_str().is_empty()).then(|| clean.to_string_lossy().replace('\\', "/"))
}

pub fn init(ws: &Workspace) -> Result<MemoryCommandReport> {
    let (run_id, worker_id, result) = draft(ws, "init", &[])?;
    let drafts: Vec<_> = result
        .documents
        .into_iter()
        .map(MemoryResultDocument::into_draft)
        .collect();
    let write = ws.write_memory_documents(&drafts, MemoryWriteMode::Init)?;
    Ok(command_report(
        Some(run_id),
        Some(worker_id),
        write,
        result.rationale,
    ))
}

pub fn refresh(ws: &Workspace, stale_only: bool) -> Result<MemoryCommandReport> {
    let entries = indexed(ws)?;
    let selected: Vec<_> = entries
        .iter()
        .filter(|e| !stale_only || e.stale)
        .map(refresh_target)
        .collect();

    if selected.is_empty() {
        return Ok(MemoryCommandReport {
            run_id: None,
            worker_id: None,
            written: Vec::new(),
            skipped: entries
                .iter()
                .filter(|e| stale_only && !e.stale)
                .map(|e| format!("{} is fresh", e.path))
                .collect(),
            index_path: None,
            rationale: if stale_only {
                "stale-only refresh found no possibly stale memory documents".to_string()
            } else {
                "no project memory documents to refresh".to_string()
            },
        });
    }

    let allowed: HashSet<String> = selected.iter().map(|t| t.slug.clone()).collect();
    let (run_id, worker_id, result) = draft(ws, "refresh", &selected)?;
    let drafts: Vec<_> = result
        .documents
        .into_iter()
        .map(MemoryResultDocument::into_draft)
        .filter(|d| allowed.contains(&memory_slug(&d.slug)))
        .collect();
    let write = ws.write_memory_documents(&drafts, MemoryWriteMode::Refresh)?;
    Ok(command_report(
        Some(run_id),
        Some(worker_id),
        write,
        result.rationale,
    ))
}

const SCOUT_TOPICS: [(&str, &str); 4] = [
    (
        "structure-build",
        "repository structure, build, test, and validation commands",
    ),
    (
        "architecture",
        "architecture boundaries, core execution paths, and invariants",
    ),
    (
        "interfaces-data",
        "user interfaces, routes or commands, and durable data models",
    ),
    (
        "conventions",
        "non-obvious project conventions, decisions, and recurring gotchas",
    ),
];

#[derive(Debug)]
pub struct ScoutCommandReport {
    pub run_id: String,
    pub worker_id: String,
    pub reports: Vec<String>,
    pub candidate_path: String,
    pub candidates: usize,
}

/// Run independent scouts against isolated copies. Scouts can write inside
/// those disposable copies, but have no filesystem path to the live project or
/// its canonical `.agents` state. Only their report directories are writable
/// outputs in the live workspace.
pub fn scout(ws: &Workspace) -> Result<ScoutCommandReport> {
    let worker_profiles = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let (profile, bin, worker_id) =
        crate::planner::pick_ready_worker(&worker_profiles, &billing, None)?;
    let env = guard::sanitized_worker_env_for(&billing, &profile.invocation.pass_env)
        .map_err(|e| anyhow!(e))?;
    let timeout = Duration::from_secs(profile.limits.max_wall_minutes as u64 * 60);
    let base_run_id = format!("memory-scout-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
    let results = std::sync::Mutex::new(Vec::<Result<(String, MemoryResult)>>::new());

    std::thread::scope(|scope| {
        for (topic, brief) in SCOUT_TOPICS {
            let scout_run_id = run_id.clone();
            let profile = profile.clone();
            let bin = bin.clone();
            let env = env.clone();
            let worker_id = worker_id.clone();
            let live_report_dir = run_dir.join("scouts").join(topic);
            let sandbox = std::env::temp_dir().join(format!("yardlet-{scout_run_id}-{topic}"));
            let results = &results;
            scope.spawn(move || {
                let result = (|| -> Result<(String, MemoryResult)> {
                    if sandbox.exists() {
                        std::fs::remove_dir_all(&sandbox)?;
                    }
                    copy_scout_workspace(&ws.root, &sandbox)?;
                    let report_dir = sandbox.join(".yardlet-scout-output");
                    std::fs::create_dir_all(&report_dir)?;
                    let packet = packet::compile_memory_scout(
                        topic,
                        brief,
                        &worker_id,
                        ".yardlet-scout-output",
                    );
                    let outcome = workers::spawn(
                        &profile,
                        &bin,
                        &packet,
                        &report_dir,
                        &sandbox,
                        &env,
                        &report_dir.join("worker-output.log"),
                        timeout,
                        false,
                        &[],
                        None,
                        false,
                    )?;
                    let result_path = report_dir.join("scout-result.json");
                    let raw = std::fs::read_to_string(&result_path).with_context(|| {
                        format!(
                            "scout '{topic}' did not write {} ({})",
                            result_path.display(),
                            outcome.note
                        )
                    })?;
                    let parsed = serde_json::from_str(&raw)
                        .with_context(|| format!("parsing {}", result_path.display()))?;
                    std::fs::create_dir_all(&live_report_dir)?;
                    crate::state::write_str(&live_report_dir.join("packet.md"), &packet)?;
                    std::fs::copy(&result_path, live_report_dir.join("scout-result.json"))?;
                    let log = report_dir.join("worker-output.log");
                    if log.is_file() {
                        std::fs::copy(log, live_report_dir.join("worker-output.log"))?;
                    }
                    Ok((topic.to_string(), parsed))
                })();
                let _ = std::fs::remove_dir_all(&sandbox);
                results.lock().expect("scout result mutex").push(result);
            });
        }
    });

    let mut completed: Vec<_> = results
        .into_inner()
        .expect("scout result mutex")
        .into_iter()
        .collect::<Result<Vec<_>>>()?;
    completed.sort_by(|a, b| a.0.cmp(&b.0));
    let mut merged = BTreeMap::<String, MemoryResultDocument>::new();
    let mut rationale = Vec::new();
    let mut reports = Vec::new();
    for (topic, result) in completed {
        reports.push(format!(
            ".agents/runs/{run_id}/scouts/{topic}/scout-result.json"
        ));
        if !result.rationale.trim().is_empty() {
            rationale.push(format!("{topic}: {}", result.rationale.trim()));
        }
        for document in result.documents {
            let slug = memory_slug(&document.slug);
            if !slug.is_empty() {
                merged.entry(slug).or_insert(document);
            }
        }
    }
    reports.sort();
    let candidates = MemoryResult {
        documents: merged.into_values().collect(),
        rationale: rationale.join("\n"),
    };
    let candidate_path = run_dir.join("memory-candidates.json");
    crate::state::write_str(
        &candidate_path,
        &format!("{}\n", serde_json::to_string_pretty(&candidates)?),
    )?;
    Ok(ScoutCommandReport {
        run_id: run_id.clone(),
        worker_id,
        reports,
        candidate_path: format!(".agents/runs/{run_id}/memory-candidates.json"),
        candidates: candidates.documents.len(),
    })
}

pub fn apply_scout(ws: &Workspace, run_id: &str) -> Result<MemoryCommandReport> {
    if Path::new(run_id).file_name().and_then(|v| v.to_str()) != Some(run_id) {
        bail!("invalid scout run id");
    }
    let path = ws.runs_dir().join(run_id).join("memory-candidates.json");
    let raw =
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let result: MemoryResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", path.display()))?;
    let drafts: Vec<_> = result
        .documents
        .into_iter()
        .map(MemoryResultDocument::into_draft)
        .collect();
    let write = ws.write_memory_documents(&drafts, MemoryWriteMode::Init)?;
    Ok(command_report(
        Some(run_id.to_string()),
        None,
        write,
        result.rationale,
    ))
}

fn copy_scout_workspace(source: &Path, target: &Path) -> Result<()> {
    std::fs::create_dir_all(target)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        let name = entry.file_name();
        let is_runtime_artifact = source.file_name().is_some_and(|v| v == ".agents")
            && matches!(
                name.to_str(),
                Some("runs" | "checkpoints" | "handoffs" | "telemetry")
            );
        if name == ".git" || name == "target" || is_runtime_artifact {
            continue;
        }
        let from = entry.path();
        let to = target.join(&name);
        let ty = entry.file_type()?;
        if ty.is_symlink() {
            continue;
        }
        if ty.is_dir() {
            copy_scout_workspace(&from, &to)?;
        } else if ty.is_file() {
            std::fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

pub(crate) fn copy_scout_workspace_for_fixture(source: &Path, target: &Path) -> Result<()> {
    copy_scout_workspace(source, target)
}

fn refresh_target(entry: &MemoryEntry) -> MemoryRefreshTarget {
    MemoryRefreshTarget {
        slug: entry
            .path
            .strip_prefix(".agents/memory/")
            .unwrap_or(&entry.path)
            .trim_end_matches(".md")
            .to_string(),
        title: entry.title.clone(),
        summary: entry.summary.clone(),
        path: entry.path.clone(),
        look_at: entry.look_at.clone(),
    }
}

fn command_report(
    run_id: Option<String>,
    worker_id: Option<String>,
    write: MemoryWriteReport,
    rationale: String,
) -> MemoryCommandReport {
    MemoryCommandReport {
        run_id,
        worker_id,
        written: write.written,
        skipped: write
            .skipped
            .into_iter()
            .map(|s| format!("{}: {}", s.slug, s.reason))
            .collect(),
        index_path: write.index_path,
        rationale,
    }
}

fn draft(
    ws: &Workspace,
    mode: &str,
    targets: &[MemoryRefreshTarget],
) -> Result<(String, String, MemoryResult)> {
    let worker_profiles = ws.load_workers()?;
    let billing = ws.load_billing()?;
    let config = ws.load_config()?;
    let (profile, bin, worker_id) =
        crate::planner::pick_ready_worker(&worker_profiles, &billing, None)?;

    let base_run_id = format!("memory-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let (run_id, run_dir) = ws.claim_run_dir(&base_run_id)?;
    std::fs::create_dir_all(run_dir.join("evidence"))?;
    let run_dir_rel = format!(".agents/runs/{run_id}");

    let summary = inspect::summarize(&ws.root);
    crate::state::write_str(
        &run_dir.join("evidence").join("repo-summary.md"),
        &inspect::to_markdown(&summary),
    )?;
    let language = packet::resolve_language(&config.language, mode);
    let harness = packet::discover_harness(&ws.root, config.harness_discovery);
    let packet_text = packet::compile_memory(
        mode,
        &summary,
        &run_dir_rel,
        &language,
        &harness,
        &worker_id,
        targets,
    );
    crate::state::write_str(&workers::packet_path(&run_dir), &packet_text)?;

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
        &[],
        None,
        false,
    )?;

    let result_path = run_dir.join("memory-result.json");
    let raw = std::fs::read_to_string(&result_path).with_context(|| {
        format!(
            "memory worker did not write {} ({}). Inspect {}/worker-output.log",
            result_path.display(),
            outcome.note,
            run_dir_rel
        )
    })?;
    let result: MemoryResult =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", result_path.display()))?;
    if mode == "refresh" && !targets.is_empty() && result.documents.is_empty() {
        bail!(
            "memory refresh worker returned no documents for {} target(s)",
            targets.len()
        );
    }
    Ok((run_id, worker_id, result))
}

fn git_uncommitted_paths(root: &std::path::Path) -> HashSet<String> {
    let Some(out) = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["status", "--porcelain", "-z", "--untracked-files=all"])
        .output()
        .ok()
        .filter(|o| o.status.success())
    else {
        return HashSet::new();
    };
    let raw = String::from_utf8_lossy(&out.stdout);
    let mut chunks = raw.split('\0');
    let mut set = HashSet::new();
    while let Some(entry) = chunks.next() {
        if entry.len() < 4 {
            continue;
        }
        let xy = &entry[..2];
        if let Some(path) = normalize_look_at(root, &entry[3..]) {
            set.insert(path);
        }
        if xy.starts_with('R') || xy.starts_with('C') {
            if let Some(next) = chunks.next().and_then(|p| normalize_look_at(root, p)) {
                set.insert(next);
            }
        }
    }
    set
}

fn git_commit_time(root: &std::path::Path, pathspec: &str) -> Option<i128> {
    let out = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["log", "-1", "--format=%ct", "--", pathspec])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    std::str::from_utf8(&out.stdout)
        .ok()?
        .trim()
        .parse::<i128>()
        .ok()
        .map(|seconds| seconds.saturating_mul(1_000_000_000))
}

fn memory_slug(input: &str) -> String {
    input
        .trim()
        .to_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|p| !p.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refresh_filters_worker_draft_to_selected_stale_slugs() {
        let selected = [MemoryRefreshTarget {
            slug: "stale-doc".to_string(),
            title: "Stale doc".to_string(),
            summary: String::new(),
            path: ".agents/memory/stale-doc.md".to_string(),
            look_at: vec![],
        }];
        let allowed: HashSet<String> = selected.iter().map(|t| t.slug.clone()).collect();
        let drafts = vec![
            MemoryResultDocument {
                slug: "stale-doc".to_string(),
                title: "Stale doc".to_string(),
                body: "Updated body".to_string(),
                ..Default::default()
            },
            MemoryResultDocument {
                slug: "fresh-doc".to_string(),
                title: "Fresh doc".to_string(),
                body: "Must not be written".to_string(),
                ..Default::default()
            },
        ];
        let filtered: Vec<_> = drafts
            .into_iter()
            .map(MemoryResultDocument::into_draft)
            .filter(|d| allowed.contains(&memory_slug(&d.slug)))
            .collect();
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].slug, "stale-doc");
    }

    #[test]
    fn stale_evidence_handles_change_no_change_and_path_normalization() {
        let root = Path::new("/workspace/project");
        assert_eq!(
            normalize_look_at(root, "./src/../src/lib.rs").as_deref(),
            Some("src/lib.rs")
        );
        assert_eq!(
            normalize_look_at(root, "/workspace/project/docs/a.md").as_deref(),
            Some("docs/a.md")
        );
        assert!(normalize_look_at(root, "../../secret").is_none());
        assert!(is_newer_than_memory(Some(10), Some(11)));
        assert!(!is_newer_than_memory(Some(10), Some(10)));
        assert!(!is_newer_than_memory(None, Some(11)));
    }

    #[test]
    fn non_git_workspace_uses_file_times_deterministically() {
        assert!(is_newer_than_memory(Some(100), Some(101)));
        assert!(!is_newer_than_memory(Some(101), Some(100)));
    }

    #[test]
    fn indexed_marks_actual_non_git_landmark_change_and_keeps_unchanged_fresh() {
        let root = std::env::temp_dir().join(format!("yard-memory-non-git-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        crate::init::init(&root, false).unwrap();
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join("src/changed.rs"), "new").unwrap();
        std::fs::write(root.join("src/fresh.rs"), "same").unwrap();
        std::fs::write(
            root.join(".agents/memory/old.md"),
            "---\nname: Old\ndescription: old\nupdated_at: 2000-01-01T00:00:00Z\nlook_at:\n  - ./src/changed.rs\n---\n\n# Old\n\nbody\n",
        ).unwrap();
        std::fs::write(
            root.join(".agents/memory/fresh.md"),
            "---\nname: Fresh\ndescription: fresh\nupdated_at: 2999-01-01T00:00:00Z\nlook_at:\n  - src/fresh.rs\n---\n\n# Fresh\n\nbody\n",
        ).unwrap();
        std::fs::write(
            root.join(".agents/memory/deleted.md"),
            "---\nname: Deleted\ndescription: deleted\nupdated_at: 2000-01-01T00:00:00Z\nlook_at:\n  - src/deleted.rs\n---\n\n# Deleted\n\nbody\n",
        ).unwrap();
        let entries = indexed(&Workspace::at(&root)).unwrap();
        let old = entries.iter().find(|e| e.title == "Old").unwrap();
        let fresh = entries.iter().find(|e| e.title == "Fresh").unwrap();
        let deleted = entries.iter().find(|e| e.title == "Deleted").unwrap();
        assert!(old.stale);
        assert_eq!(old.changed_look_at, vec!["src/changed.rs"]);
        assert!(!fresh.stale);
        assert!(deleted.stale);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scout_copy_excludes_runtime_artifacts_and_cannot_mutate_source() {
        let base = std::env::temp_dir().join(format!("yard-scout-copy-{}", std::process::id()));
        let source = base.join("source");
        let target = base.join("target");
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(source.join(".agents/memory")).unwrap();
        std::fs::create_dir_all(source.join(".agents/runs/run-old")).unwrap();
        std::fs::write(source.join("project.txt"), "live").unwrap();
        std::fs::write(source.join(".agents/memory/fact.md"), "fact").unwrap();
        std::fs::write(source.join(".agents/runs/run-old/result.json"), "{}").unwrap();
        copy_scout_workspace(&source, &target).unwrap();
        assert!(target.join(".agents/memory/fact.md").is_file());
        assert!(!target.join(".agents/runs").exists());
        std::fs::write(target.join("project.txt"), "scout edit").unwrap();
        assert_eq!(
            std::fs::read_to_string(source.join("project.txt")).unwrap(),
            "live"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn scout_candidates_are_applied_only_by_core_action() {
        let root = std::env::temp_dir().join(format!("yard-memory-scout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let ws = Workspace::at(&root);
        let run = ws.runs_dir().join("memory-scout-test");
        std::fs::create_dir_all(&run).unwrap();
        let candidates = MemoryResult {
            documents: vec![MemoryResultDocument {
                slug: "decision".into(),
                title: "Decision".into(),
                summary: "S".into(),
                body: "Body".into(),
                ..Default::default()
            }],
            rationale: "merged".into(),
        };
        std::fs::write(
            run.join("memory-candidates.json"),
            serde_json::to_string(&candidates).unwrap(),
        )
        .unwrap();
        assert!(!ws.memory_dir().join("decision.md").exists());
        let report = apply_scout(&ws, "memory-scout-test").unwrap();
        assert_eq!(report.written, vec![".agents/memory/decision.md"]);
        assert!(ws.memory_dir().join("decision.md").exists());
        let _ = std::fs::remove_dir_all(&root);
    }
}
