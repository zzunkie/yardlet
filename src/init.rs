//! `yardlet init`: scaffold canonical `.agents/` state into a workspace.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

use anyhow::{bail, Result};
use chrono::Utc;

use crate::schemas::{GitFinishPolicy, YardConfig};
use crate::state::{self, write_str, Workspace, STATE_DIR};
use crate::templates;

pub fn init(root: &Path, force: bool) -> Result<Vec<String>> {
    let ws = Workspace::at(root);
    if ws.is_initialized() && !force {
        bail!(
            "this workspace already has {}/yardlet.yaml. Use --force to overwrite policy templates.",
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
        product: "yardlet".to_string(),
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
        skill_library: String::new(),
        auto_equip: true,
        auto_skill: true,
        auto_rule: true,
        auto_prune: true,
        hooks: true,
        auto_commit: false,
        git_finish: GitFinishPolicy::default(),
    };
    state::save_yaml(&ws.config_path(), &config)?;
    written.push("yardlet.yaml".to_string());

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

    // H3 hooks: create the (empty) hook dirs and a documented README so the
    // feature is discoverable. Yardlet ships no enabled hooks — only the docs.
    std::fs::create_dir_all(agents.join("hooks/pre-run.d"))?;
    std::fs::create_dir_all(agents.join("hooks/post-run.d"))?;
    let hooks_readme = agents.join("hooks/README.md");
    if !hooks_readme.exists() || force {
        write_str(&hooks_readme, templates::HOOKS_README)?;
        written.push("hooks/README.md".to_string());
    }

    // Project memory: an empty (git-tracked) home for durable workspace facts,
    // with a README documenting the convention. The README is not itself a
    // memory fact (discovery skips it).
    std::fs::create_dir_all(agents.join("memory"))?;
    let memory_readme = agents.join("memory/README.md");
    if !memory_readme.exists() || force {
        write_str(&memory_readme, templates::MEMORY_README)?;
        written.push("memory/README.md".to_string());
    }

    Ok(written)
}

/// Resolve a workspace, creating `.agents/` state on first use if none exists
/// in this directory or any parent. Returns `(workspace, just_created)`.
///
/// This is what makes `yardlet` work in a fresh directory without a separate
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_writes_explicit_default_off_git_finish_policy() {
        let root =
            std::env::temp_dir().join(format!("yard-init-git-finish-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        init(&root, false).unwrap();

        let text = std::fs::read_to_string(root.join(".agents/yardlet.yaml")).unwrap();
        let cfg: YardConfig = crate::yaml::from_str(&text).unwrap();
        assert!(!cfg.git_finish.auto_push);
        assert!(text.contains("git_finish:"));
        assert!(text.contains("auto_push: false"));
        assert!(text.contains("pre_push_checks: []"));

        let _ = std::fs::remove_dir_all(&root);
    }
}
