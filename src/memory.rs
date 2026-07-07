//! Project-memory init/refresh.
//!
//! Workers draft memory documents into an isolated run directory. Yardlet core
//! is the sole writer of canonical `.agents/memory/*.md` files and the generated
//! index through `Workspace::write_memory_documents`.

use std::collections::HashSet;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::Local;
use serde::Deserialize;

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

#[derive(Debug, Default, Deserialize)]
struct MemoryResult {
    #[serde(default)]
    documents: Vec<MemoryResultDocument>,
    #[serde(default)]
    rationale: String,
}

#[derive(Debug, Default, Deserialize)]
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
    let prefix = git_show_prefix(&ws.root);
    Ok(h.memory
        .into_iter()
        .map(|m| {
            let stale = if m.look_at.is_empty() {
                false
            } else {
                let doc_ct = git_commit_time(&ws.root, &m.path);
                m.look_at.iter().any(|p| {
                    let rel = p.trim_start_matches("./");
                    uncommitted.contains(format!("{prefix}{rel}").as_str())
                        || matches!(
                            (doc_ct, git_commit_time(&ws.root, rel)),
                            (Some(d), Some(t)) if t > d
                        )
                })
            };
            MemoryEntry {
                title: m.title,
                summary: m.summary,
                path: m.path,
                look_at: m.look_at,
                stale,
            }
        })
        .collect())
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

    let run_id = format!("memory-{}", Local::now().format("%Y%m%d-%H%M%S"));
    let run_dir = ws.runs_dir().join(&run_id);
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
        set.insert(entry[3..].to_string());
        if xy.starts_with('R') || xy.starts_with('C') {
            chunks.next();
        }
    }
    set
}

fn git_show_prefix(root: &std::path::Path) -> String {
    std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["rev-parse", "--show-prefix"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn git_commit_time(root: &std::path::Path, pathspec: &str) -> Option<i64> {
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
        .parse::<i64>()
        .ok()
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
        let selected = vec![MemoryRefreshTarget {
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
}
