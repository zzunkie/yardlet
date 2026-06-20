//! Rubric drift and sync.
//!
//! `init` copies the binary's embedded worker template into a workspace's
//! `.agents/workers.yaml` once, then never touches it again. When a later
//! Yardlet improves a worker's *rubric* (its planner/routing policy:
//! `capabilities`, `best_for`, `not_for`, `cost_weight`, `role_strengths`), an
//! older workspace stays pinned to the rubric it was born with. A missing hard
//! `capability` is the sharp case: a task whose `required_capabilities` lists it
//! then has no worker to satisfy it and routing fails, even though the current
//! template would route it fine.
//!
//! This module diagnoses that gap (`diff`) and merges template improvements back
//! in non-destructively (`merge`). The merge boundary is deliberate: only rubric
//! fields are candidates. Operational config (`invocation`, `model`, `effort`,
//! `limits`, `billing`, `enabled`), the top-level `routing` block, and any
//! workspace-only workers are owned by the workspace and are never rewritten.
//!
//! Like `routing review`/`apply`, diagnosis is separate from application:
//! `diff` is read-only; applying the merge is an explicit, human-run step.

use std::collections::BTreeSet;

use anyhow::Result;

use crate::routing::norm_cap;
use crate::schemas::{WorkerProfile, WorkersFile};

/// The scalar rubric text fields, compared and merged as whole strings.
const TEXT_FIELDS: [&str; 3] = ["best_for", "not_for", "cost_weight"];

/// Parse the binary's embedded worker template into a `WorkersFile`. This is the
/// only "latest" rubric we have: there is no per-version template history, so a
/// workspace's drift is always measured against the current binary.
pub fn template_workers() -> Result<WorkersFile> {
    crate::yaml::from_str(crate::templates::WORKERS)
}

/// One workspace worker's rubric drift relative to the matching template worker.
#[derive(Debug, Clone)]
pub struct WorkerDrift {
    pub id: String,
    /// Capabilities the template declares that the workspace lacks (raw template
    /// spelling). The highest-signal drift: each one is a hard routing gap.
    pub capabilities_added: Vec<String>,
    /// Capabilities only the workspace declares (local; preserved on sync).
    pub capabilities_local: Vec<String>,
    /// role_strengths the template lists that the workspace lacks.
    pub role_strengths_added: Vec<String>,
    /// Scalar text fields whose value differs from the template.
    pub text_changes: Vec<TextChange>,
}

impl WorkerDrift {
    fn is_clean(&self) -> bool {
        self.capabilities_added.is_empty()
            && self.role_strengths_added.is_empty()
            && self.text_changes.is_empty()
    }
}

/// A scalar rubric field whose workspace value differs from the template.
#[derive(Debug, Clone)]
pub struct TextChange {
    pub field: &'static str,
    pub workspace: String,
    pub template: String,
}

impl TextChange {
    /// Empty workspace value: `merge` fills it from the template even without
    /// `--adopt-text` (filling a blank is not destructive).
    pub fn workspace_empty(&self) -> bool {
        self.workspace.trim().is_empty()
    }
}

/// The full template-vs-workspace rubric comparison.
#[derive(Debug, Clone)]
pub struct RubricDrift {
    /// Per-worker drift for workers present in both template and workspace.
    pub workers: Vec<WorkerDrift>,
    /// Worker ids the template ships that the workspace lacks (sync can add).
    pub missing_workers: Vec<String>,
    /// Worker ids only in the workspace (local; never touched).
    pub extra_workers: Vec<String>,
    pub schema_version_template: u32,
    pub schema_version_workspace: u32,
}

impl RubricDrift {
    /// Whether `sync` has anything to act on. Local-only extras do not count;
    /// the `schema_version` is informational and reported separately.
    pub fn has_drift(&self) -> bool {
        !self.missing_workers.is_empty() || self.workers.iter().any(|w| !w.is_clean())
    }

    /// Customized (non-empty) text fields a default sync would preserve.
    pub fn kept_text_fields(&self) -> usize {
        self.workers
            .iter()
            .flat_map(|w| &w.text_changes)
            .filter(|t| !t.workspace_empty())
            .count()
    }
}

fn scalar<'a>(w: &'a WorkerProfile, field: &str) -> &'a str {
    match field {
        "best_for" => &w.best_for,
        "not_for" => &w.not_for,
        "cost_weight" => &w.cost_weight,
        _ => "",
    }
}

fn set_scalar(w: &mut WorkerProfile, field: &str, val: String) {
    match field {
        "best_for" => w.best_for = val,
        "not_for" => w.not_for = val,
        "cost_weight" => w.cost_weight = val,
        _ => {}
    }
}

/// Compute the rubric drift of `ws` relative to `template`. Pure; unit-tested
/// without touching disk.
pub fn diff(ws: &WorkersFile, template: &WorkersFile) -> RubricDrift {
    let mut workers = Vec::new();
    let mut missing_workers = Vec::new();

    for tw in &template.workers {
        let Some(w) = ws.workers.iter().find(|w| w.id == tw.id) else {
            missing_workers.push(tw.id.clone());
            continue;
        };

        let ws_caps: BTreeSet<String> = w.capabilities.iter().map(|c| norm_cap(c)).collect();
        let tmpl_caps: BTreeSet<String> = tw.capabilities.iter().map(|c| norm_cap(c)).collect();
        let capabilities_added: Vec<String> = tw
            .capabilities
            .iter()
            .filter(|c| !ws_caps.contains(&norm_cap(c)))
            .cloned()
            .collect();
        let capabilities_local: Vec<String> = w
            .capabilities
            .iter()
            .filter(|c| !tmpl_caps.contains(&norm_cap(c)))
            .cloned()
            .collect();

        let ws_roles: BTreeSet<&str> = w.role_strengths.iter().map(|s| s.as_str()).collect();
        let role_strengths_added: Vec<String> = tw
            .role_strengths
            .iter()
            .filter(|s| !ws_roles.contains(s.as_str()))
            .cloned()
            .collect();

        let mut text_changes = Vec::new();
        for field in TEXT_FIELDS {
            let wv = scalar(w, field);
            let tv = scalar(tw, field);
            // A template that itself leaves the field blank cannot be "ahead".
            if wv.trim() != tv.trim() && !tv.trim().is_empty() {
                text_changes.push(TextChange {
                    field,
                    workspace: wv.to_string(),
                    template: tv.to_string(),
                });
            }
        }

        workers.push(WorkerDrift {
            id: tw.id.clone(),
            capabilities_added,
            capabilities_local,
            role_strengths_added,
            text_changes,
        });
    }

    let tmpl_ids: BTreeSet<&str> = template.workers.iter().map(|w| w.id.as_str()).collect();
    let extra_workers: Vec<String> = ws
        .workers
        .iter()
        .filter(|w| !tmpl_ids.contains(w.id.as_str()))
        .map(|w| w.id.clone())
        .collect();

    RubricDrift {
        workers,
        missing_workers,
        extra_workers,
        schema_version_template: template.schema_version,
        schema_version_workspace: ws.schema_version,
    }
}

/// One field that `merge` changed, for the human-readable summary.
#[derive(Debug, Clone)]
pub struct SyncChange {
    pub worker: String,
    pub detail: String,
}

/// Merge template rubric improvements into `ws`, returning the new file and the
/// list of changes applied. Non-destructive by construction:
///
/// - `capabilities` and `role_strengths`: union (template entries the workspace
///   lacks are appended; local entries and ordering are kept).
/// - scalar text fields: a blank workspace value is filled from the template;
///   a customized (non-empty) value is replaced only when `adopt_text` is set.
/// - a template worker missing from the workspace is added whole.
/// - workspace-only workers, operational config, and `routing` are untouched.
///
/// Pure; the caller decides whether to persist the result.
pub fn merge(
    ws: &WorkersFile,
    template: &WorkersFile,
    adopt_text: bool,
) -> (WorkersFile, Vec<SyncChange>) {
    let mut out = ws.clone();
    let mut changes = Vec::new();

    for tw in &template.workers {
        let Some(w) = out.workers.iter_mut().find(|w| w.id == tw.id) else {
            out.workers.push(tw.clone());
            changes.push(SyncChange {
                worker: tw.id.clone(),
                detail: "added template worker (operational config = template defaults; review `invocation`)".to_string(),
            });
            continue;
        };

        let have_caps: BTreeSet<String> = w.capabilities.iter().map(|c| norm_cap(c)).collect();
        for cap in &tw.capabilities {
            if !have_caps.contains(&norm_cap(cap)) {
                w.capabilities.push(cap.clone());
                changes.push(SyncChange {
                    worker: w.id.clone(),
                    detail: format!("+capability {cap}"),
                });
            }
        }

        let have_roles: BTreeSet<String> = w.role_strengths.iter().cloned().collect();
        for role in &tw.role_strengths {
            if !have_roles.contains(role) {
                w.role_strengths.push(role.clone());
                changes.push(SyncChange {
                    worker: w.id.clone(),
                    detail: format!("+role_strength {role}"),
                });
            }
        }

        for field in TEXT_FIELDS {
            let wv = scalar(w, field).trim().to_string();
            let tv = scalar(tw, field).trim().to_string();
            if wv == tv || tv.is_empty() {
                continue;
            }
            let template_value = scalar(tw, field).to_string();
            if wv.is_empty() {
                set_scalar(w, field, template_value);
                changes.push(SyncChange {
                    worker: w.id.clone(),
                    detail: format!("filled {field} from template"),
                });
            } else if adopt_text {
                set_scalar(w, field, template_value);
                changes.push(SyncChange {
                    worker: w.id.clone(),
                    detail: format!("adopted template {field} (local wording replaced)"),
                });
            }
            // else: customized value preserved; needs --adopt-text to replace.
        }
    }

    (out, changes)
}

#[cfg(test)]
mod tests {
    use super::*;

    // An "old" workspace: codex with no capabilities and a stale best_for, a
    // claude-code with a blank best_for, and a local-only worker.
    fn stale_workspace() -> WorkersFile {
        crate::yaml::from_str(
            r#"
schema_version: 1
workers:
  - id: codex
    best_for: old codex rubric
    model: gpt-x
    invocation: {command: codex}
    limits: {max_wall_minutes: 99, max_retries: 3}
  - id: claude-code
    best_for: ""
    invocation: {command: claude}
  - id: my-local-worker
    capabilities: [special_local_thing]
    invocation: {command: foo}
routing:
  default_worker: codex
"#,
        )
        .unwrap()
    }

    #[test]
    fn diff_flags_missing_hard_capability() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let d = diff(&ws, &tmpl);
        let codex = d.workers.iter().find(|w| w.id == "codex").unwrap();
        // The Deadline12 case: template declares image_generation, workspace doesn't.
        assert!(codex
            .capabilities_added
            .iter()
            .any(|c| norm_cap(c) == "image_generation"));
        assert!(d.has_drift());
    }

    #[test]
    fn diff_reports_local_only_worker_without_touching_it() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let d = diff(&ws, &tmpl);
        assert_eq!(d.extra_workers, vec!["my-local-worker".to_string()]);
        assert!(d.missing_workers.is_empty());
    }

    #[test]
    fn diff_empty_when_workspace_is_the_template() {
        let tmpl = template_workers().unwrap();
        let d = diff(&tmpl, &tmpl);
        assert!(!d.has_drift());
        assert_eq!(d.kept_text_fields(), 0);
    }

    #[test]
    fn merge_adds_capability_but_keeps_operational_config() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let (merged, changes) = merge(&ws, &tmpl, false);
        let codex = merged.workers.iter().find(|w| w.id == "codex").unwrap();
        assert!(codex
            .capabilities
            .iter()
            .any(|c| norm_cap(c) == "image_generation"));
        // Operational config preserved verbatim.
        assert_eq!(codex.model, "gpt-x");
        assert_eq!(codex.limits.max_wall_minutes, 99);
        assert_eq!(codex.limits.max_retries, 3);
        assert!(changes.iter().any(|c| c.detail.contains("+capability")));
    }

    #[test]
    fn merge_default_preserves_customized_text_but_fills_blank() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let (merged, _) = merge(&ws, &tmpl, false);
        let codex = merged.workers.iter().find(|w| w.id == "codex").unwrap();
        let claude = merged
            .workers
            .iter()
            .find(|w| w.id == "claude-code")
            .unwrap();
        // codex had a customized best_for -> kept as-is without --adopt-text.
        assert_eq!(codex.best_for, "old codex rubric");
        // codex had no cost_weight -> filled from the template ("low").
        assert_eq!(codex.cost_weight, "low");
        // claude-code had a blank best_for -> filled from the template.
        assert!(!claude.best_for.trim().is_empty());
    }

    #[test]
    fn merge_adopt_text_replaces_customized_wording() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let (merged, _) = merge(&ws, &tmpl, true);
        let codex = merged.workers.iter().find(|w| w.id == "codex").unwrap();
        let tmpl_codex = tmpl.workers.iter().find(|w| w.id == "codex").unwrap();
        assert_eq!(codex.best_for, tmpl_codex.best_for);
        assert_ne!(codex.best_for, "old codex rubric");
    }

    #[test]
    fn merge_preserves_local_worker_and_local_capability() {
        let ws = stale_workspace();
        let tmpl = template_workers().unwrap();
        let (merged, _) = merge(&ws, &tmpl, true);
        let local = merged
            .workers
            .iter()
            .find(|w| w.id == "my-local-worker")
            .expect("local worker survives sync");
        assert!(local
            .capabilities
            .iter()
            .any(|c| norm_cap(c) == "special_local_thing"));
    }

    #[test]
    fn merge_adds_a_missing_template_worker() {
        // A workspace that dropped claude-code entirely gets it back.
        let ws: WorkersFile = crate::yaml::from_str(
            "schema_version: 1\nworkers:\n  - id: codex\n    invocation: {command: codex}\nrouting:\n  default_worker: codex\n",
        )
        .unwrap();
        let tmpl = template_workers().unwrap();
        let (merged, changes) = merge(&ws, &tmpl, false);
        assert!(merged.workers.iter().any(|w| w.id == "claude-code"));
        assert!(changes
            .iter()
            .any(|c| c.worker == "claude-code" && c.detail.contains("added template worker")));
    }

    #[test]
    fn merge_is_idempotent() {
        let tmpl = template_workers().unwrap();
        let (_, changes) = merge(&tmpl, &tmpl, true);
        assert!(
            changes.is_empty(),
            "syncing the template onto itself is a no-op"
        );
    }
}
