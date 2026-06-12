//! `yard init`: scaffold canonical `.agents/` state into a workspace.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

use anyhow::{bail, Result};
use chrono::Utc;

use crate::schemas::YardConfig;
use crate::state::{self, write_str, Workspace, STATE_DIR};
use crate::templates;

pub fn init(root: &Path, force: bool) -> Result<Vec<String>> {
    let ws = Workspace::at(root);
    if ws.is_initialized() && !force {
        bail!(
            "this workspace already has {}/yard.yaml. Use --force to overwrite policy templates.",
            STATE_DIR
        );
    }

    let mut written = Vec::new();
    let agents = ws.agents_dir();
    std::fs::create_dir_all(&agents)?;
    std::fs::create_dir_all(ws.runs_dir())?;
    std::fs::create_dir_all(ws.checkpoints_dir())?;
    std::fs::create_dir_all(ws.handoffs_dir())?;

    // Dynamic config.
    let config = YardConfig {
        schema_version: 1,
        product: "yard".to_string(),
        workspace_id: workspace_id(root),
        created_at: Utc::now().to_rfc3339(),
        state_dir: STATE_DIR.to_string(),
        default_interface: "tui".to_string(),
        canonical_queue: format!("{STATE_DIR}/work-queue.yaml"),
        current_intent: format!("{STATE_DIR}/intent-contract.yaml"),
        language: "auto".to_string(),
        default_access: "sandboxed".to_string(),
        max_parallel: 1,
        auto_ime: true,
        harness_discovery: true,
        ambiguity_gate: true,
    };
    state::save_yaml(&ws.config_path(), &config)?;
    written.push("yard.yaml".to_string());

    // Static templates.
    let files: &[(&str, &str)] = &[
        ("billing-policy.yaml", templates::BILLING_POLICY),
        ("tool-policy.yaml", templates::TOOL_POLICY),
        ("approval-policy.yaml", templates::APPROVAL_POLICY),
        ("interaction-policy.yaml", templates::INTERACTION_POLICY),
        ("research-policy.yaml", templates::RESEARCH_POLICY),
        ("workers.yaml", templates::WORKERS),
        ("work-queue.yaml", templates::WORK_QUEUE),
    ];
    for (name, body) in files {
        let path = agents.join(name);
        if path.exists() && !force {
            continue;
        }
        write_str(&path, body)?;
        written.push((*name).to_string());
    }

    let skill = agents.join("skills/planning-gate/SKILL.md");
    if !skill.exists() || force {
        write_str(&skill, templates::PLANNING_GATE_SKILL)?;
        written.push("skills/planning-gate/SKILL.md".to_string());
    }

    Ok(written)
}

/// Resolve a workspace, creating `.agents/` state on first use if none exists
/// in this directory or any parent. Returns `(workspace, just_created)`.
///
/// This is what makes `yard` work in a fresh directory without a separate
/// setup step: like the worker CLIs, it initializes on demand.
pub fn ensure_initialized(cwd: &Path) -> Result<(Workspace, bool)> {
    if let Some(ws) = Workspace::discover(cwd) {
        return Ok((ws, false));
    }
    init(cwd, false)?;
    Ok((Workspace::at(cwd), true))
}

/// A stable id derived from the canonical workspace path.
fn workspace_id(root: &Path) -> String {
    let canonical = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let mut hasher = DefaultHasher::new();
    canonical.hash(&mut hasher);
    format!("ws-{:016x}", hasher.finish())
}
