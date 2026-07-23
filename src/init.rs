//! `yardlet init`: scaffold canonical `.agents/` state into a workspace.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::Path;

use anyhow::{bail, Context, Result};
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
    let config_path = ws.config_path();
    if should_write_scaffold(&config_path, force)? {
        state::save_yaml(&config_path, &config)?;
        written.push("yardlet.yaml".to_string());
    }

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
        if should_write_scaffold(&path, force)? {
            write_str(&path, body)?;
            written.push((*name).to_string());
        }
    }

    let skill = agents.join("skills/planning-gate/SKILL.md");
    if should_write_scaffold(&skill, force)? {
        write_str(&skill, templates::PLANNING_GATE_SKILL)?;
        written.push("skills/planning-gate/SKILL.md".to_string());
    }

    // H3 hooks: create the (empty) hook dirs and a documented README so the
    // feature is discoverable. Yardlet ships no enabled hooks — only the docs.
    std::fs::create_dir_all(agents.join("hooks/pre-run.d"))?;
    std::fs::create_dir_all(agents.join("hooks/post-run.d"))?;
    let hooks_readme = agents.join("hooks/README.md");
    if should_write_scaffold(&hooks_readme, force)? {
        write_str(&hooks_readme, templates::HOOKS_README)?;
        written.push("hooks/README.md".to_string());
    }

    // Project memory: an empty (git-tracked) home for durable workspace facts,
    // with a README documenting the convention. The README is not itself a
    // memory fact (discovery skips it).
    std::fs::create_dir_all(agents.join("memory"))?;
    let memory_readme = agents.join("memory/README.md");
    if should_write_scaffold(&memory_readme, force)? {
        write_str(&memory_readme, templates::MEMORY_README)?;
        written.push("memory/README.md".to_string());
    }

    for name in crate::skills::ensure_builtin_core(&ws)? {
        written.push(format!("skills/{name}/"));
    }

    Ok(written)
}

fn should_write_scaffold(path: &Path, force: bool) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            eprintln!(
                "warning: skipped scaffold destination symlink {}",
                path.display()
            );
            Ok(false)
        }
        Ok(_) => Ok(force),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error)
            .with_context(|| format!("inspecting scaffold destination {}", path.display())),
    }
}

/// Resolve a workspace, creating `.agents/` state on first use if none exists
/// in this directory or any parent. Returns `(workspace, just_created)`.
///
/// This is what makes `yardlet` work in a fresh directory without a separate
/// setup step: like the worker CLIs, it initializes on demand.
pub fn ensure_initialized(cwd: &Path) -> Result<(Workspace, bool)> {
    if let Some(ws) = Workspace::discover(cwd) {
        crate::skills::ensure_builtin_core(&ws)?;
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

    #[cfg(unix)]
    #[test]
    fn ensure_initialized_does_not_create_targets_behind_dangling_scaffold_symlinks() {
        use std::os::unix::fs::symlink;
        use std::time::{SystemTime, UNIX_EPOCH};

        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!(
            "yard-init-dangling-symlinks-{}-{nonce}",
            std::process::id()
        ));
        let root = base.join("workspace");
        let external = base.join("external");
        std::fs::create_dir_all(root.join(".agents")).unwrap();
        std::fs::create_dir_all(&external).unwrap();

        let links = [
            ("yardlet.yaml", "yardlet.yaml"),
            ("billing-policy.yaml", "billing-policy.yaml"),
            ("skills/planning-gate/SKILL.md", "planning-gate-SKILL.md"),
            ("hooks/README.md", "hooks-README.md"),
            ("memory/README.md", "memory-README.md"),
        ];
        for (relative, external_name) in links {
            let link = root.join(".agents").join(relative);
            std::fs::create_dir_all(link.parent().unwrap()).unwrap();
            symlink(external.join(external_name), link).unwrap();
        }

        let (_, created) = ensure_initialized(&root).unwrap();
        assert!(created);
        for (relative, external_name) in links {
            let link = root.join(".agents").join(relative);
            assert!(
                std::fs::symlink_metadata(&link)
                    .unwrap()
                    .file_type()
                    .is_symlink(),
                "{} must remain a symlink",
                link.display()
            );
            assert!(
                !external.join(external_name).exists(),
                "auto init must not create an external target for {}",
                link.display()
            );
        }

        std::fs::remove_dir_all(&base).unwrap();
    }

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

    #[test]
    fn init_writes_explicit_default_off_preferred_worker_failover_policy() {
        let root = std::env::temp_dir().join(format!(
            "yard-init-preferred-worker-failover-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        init(&root, false).unwrap();

        let text = std::fs::read_to_string(root.join(".agents/workers.yaml")).unwrap();
        let workers: crate::schemas::WorkersFile = crate::yaml::from_str(&text).unwrap();
        assert!(!workers.routing.allow_preferred_worker_failover);
        assert!(text.contains("allow_preferred_worker_failover: false"));

        let _ = std::fs::remove_dir_all(&root);
    }
}
